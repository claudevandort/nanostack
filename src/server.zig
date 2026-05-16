//! HTTP server entry point.
//!
//! Uses http.zig's `handle` takeover so we own routing end-to-end.
//! Pipeline: id → log → SigV4 (M2) → router → service dispatch → render.

const std = @import("std");
const httpz = @import("httpz");
const Allocator = std.mem.Allocator;

const cli = @import("cli.zig");
const router = @import("router.zig");
const errors = @import("wire/errors.zig");
const sigv4 = @import("auth/sigv4.zig");
const authz = @import("auth/authz.zig");
const storage = @import("storage/mod.zig");
const fs_backend = @import("storage/fs.zig");
const s3 = @import("services/s3/mod.zig");

pub const App = struct {
    config: *const cli.Config,
    io: std.Io,
    backend: storage.Backend,

    /// `handle` takeover circumvents httpz's pattern router so our service
    /// layer sees every request. AWS APIs are not a fit for path-pattern
    /// routing — the operation is encoded in (host, path, method, query).
    pub fn handle(self: *App, req: *httpz.Request, res: *httpz.Response) void {
        // All response paths funnel through this `defer` so the HEAD
        // body-suppression rule (RFC 9110: HEAD responses MUST NOT carry a
        // body) applies whether we returned a success, an auth error, or
        // a 5xx.
        defer if (req.method == .HEAD) {
            res.body = "";
        };

        const arena = res.arena;
        const request_id = randomHex(self.io, arena, 8) catch {
            res.status = 500;
            res.body = "";
            return;
        };
        const host_id = randomHex(self.io, arena, 16) catch {
            res.status = 500;
            res.body = "";
            return;
        };

        const host_header = req.header("host") orelse "";
        const method_str: []const u8 = if (req.method == .OTHER) req.method_string else @tagName(req.method);
        std.log.info("{s} {s} host={s} len={d}", .{
            method_str,
            req.url.path,
            host_header,
            (req.body() orelse @as([]const u8, "")).len,
        });

        // ---------- SigV4 verification ----------
        //
        // Returns a `Principal` (anonymous when no auth headers present,
        // aws_account when SigV4 verification passed). All other failure
        // modes still raise. M14 wires this into the authz hook below.
        //
        // `--no-auth` short-circuits to the bucket-owner principal: every
        // request is treated as fully-authorised (no policy/ACL check).
        const principal: sigv4.Principal = if (self.config.no_auth)
            sigv4.Principal.awsAccount(self.config.access_key)
        else blk: {
            const verify_headers = collectHeaders(arena, req) catch {
                return respondError(res, request_id, host_id, .internal_error, req.url.path, &.{});
            };
            const p = sigv4.verify(arena, .{
                .method = method_str,
                .path = req.url.path,
                .query = req.url.query,
                .headers = verify_headers,
                .body = req.body() orelse "",
            }, .{
                .access_key = self.config.access_key,
                .secret_key = self.config.secret_key,
            }, .{
                .region = self.config.region,
                .service = "s3",
                .now_unix = fs_backend.nowUnixSeconds(self.io),
                .skew_tolerance_seconds = self.config.skew_seconds,
            }) catch |err| {
                return respondError(res, request_id, host_id, mapVerifyError(err), req.url.path, &.{});
            };
            break :blk p;
        };

        // ---------- Routing ----------
        const parsed = router.parse(method_str, host_header, req.url.path, req.url.query);

        // ---------- Authz hook (M14) ----------
        //
        // Real bucket-policy / ACL / PAB evaluation. `--no-auth` bypasses
        // (principal is the bucket owner; orchestrator's owner-implicit
        // fallback always allows). All other principals — including
        // anonymous — go through the evaluator: a public-read bucket
        // serves anonymous reads end-to-end; a private one returns 403.
        if (!self.config.no_auth) {
            const decision = authz.check(.{
                .allocator = arena,
                .backend = self.backend,
                .principal = principal,
                .owner_id = self.config.access_key,
                .parsed = parsed,
            });
            if (decision == .deny) {
                return respondError(res, request_id, host_id, .access_denied, req.url.path, &.{});
            }
        }

        // Bridge sigv4-collected headers into storage.Header for the service.
        // Same shape, just a cast — but Zig 0.16 won't let us @ptrCast slices
        // of different declared types, so rebuild explicitly.
        const all_headers = collectHeaders(arena, req) catch
            return respondError(res, request_id, host_id, .internal_error, req.url.path, &.{});
        const svc_headers = arena.alloc(storage.Header, all_headers.len) catch
            return respondError(res, request_id, host_id, .internal_error, req.url.path, &.{});
        for (all_headers, 0..) |h, i| svc_headers[i] = .{ .name = h.name, .value = h.value };

        const range_header = req.header("range");

        const result = s3.handle(.{
            .backend = self.backend,
            .allocator = arena,
            .owner_id = self.config.access_key,
            .owner_display_name = "nanostack",
            .region = self.config.region,
            .request = .{
                .headers = svc_headers,
                .body = req.body() orelse "",
                .range = range_header,
                .query = req.url.query,
            },
        }, parsed);

        switch (result) {
            .ok => |out| respondOk(res, request_id, host_id, out),
            .err => |code| respondError(res, request_id, host_id, code, req.url.path, &.{}),
            .err_with_headers => |ewh| {
                // s3.Header and storage.Header are layout-compatible; bridge.
                const extras = arena.alloc(storage.Header, ewh.extra_headers.len) catch {
                    return respondError(res, request_id, host_id, .internal_error, req.url.path, &.{});
                };
                for (ewh.extra_headers, 0..) |h, i| extras[i] = .{ .name = h.name, .value = h.value };
                respondError(res, request_id, host_id, ewh.code, req.url.path, extras);
            },
        }
    }
};

fn mapVerifyError(e: sigv4.VerifyError) errors.Code {
    return switch (e) {
        sigv4.VerifyError.InvalidAccessKeyId => .invalid_access_key_id,
        sigv4.VerifyError.SignatureDoesNotMatch => .signature_does_not_match,
        sigv4.VerifyError.RequestTimeTooSkewed => .request_time_too_skewed,
        sigv4.VerifyError.PresignedExpired => .access_denied,
        sigv4.VerifyError.MissingSignedHeader => .signature_does_not_match,
        sigv4.VerifyError.StreamingUnsupported => .not_implemented,
        sigv4.VerifyError.XAmzContentSha256Mismatch => .x_amz_content_sha256_mismatch,
        sigv4.VerifyError.MalformedAuthorization,
        sigv4.VerifyError.MalformedCredentialScope,
        sigv4.VerifyError.MalformedPresignedQuery,
        sigv4.VerifyError.MalformedQuery,
        sigv4.VerifyError.MalformedHeaders,
        => .invalid_request,
        sigv4.VerifyError.OutOfMemory => .internal_error,
    };
}

fn collectHeaders(allocator: Allocator, req: *httpz.Request) ![]sigv4.Header {
    var out: std.ArrayList(sigv4.Header) = .empty;
    errdefer out.deinit(allocator);
    var it = req.headers.iterator();
    while (it.next()) |kv| {
        try out.append(allocator, .{ .name = kv.key, .value = kv.value });
    }
    return out.toOwnedSlice(allocator);
}

fn respondOk(
    res: *httpz.Response,
    request_id: []const u8,
    host_id: []const u8,
    out: s3.Output,
) void {
    res.status = out.status;
    res.header("x-amz-request-id", request_id);
    res.header("x-amz-id-2", host_id);
    for (out.extra_headers) |h| res.header(h.name, h.value);

    // 304 must not carry a Content-Type (RFC 9110 §15.4.5); httpz would
    // otherwise default to text/plain on an empty body.
    if (out.status == 304) {
        res.content_type = null;
        res.body = "";
        return;
    }

    // Object responses surface the stored content type; bucket-op success
    // bodies are AWS XML. Empty bodies (PutObject, DeleteBucket, HeadObject)
    // get no Content-Type — let httpz decide.
    if (out.content_type_override) |ct| {
        res.header("Content-Type", ct);
        res.content_type = null;
    } else if (out.body.len > 0) {
        res.header("Content-Type", "application/xml");
        res.content_type = null;
    }
    res.body = out.body;
}

fn respondError(
    res: *httpz.Response,
    request_id: []const u8,
    host_id: []const u8,
    code: errors.Code,
    resource: ?[]const u8,
    extra_headers: []const storage.Header,
) void {
    // RFC 9110 §15.4.5: 304 responses MUST NOT carry a body and the server
    // SHOULD suppress entity headers like Content-Type. AWS S3 follows
    // this; SDK clients expect it.
    if (code == .not_modified) {
        res.status = 304;
        res.header("x-amz-request-id", request_id);
        res.header("x-amz-id-2", host_id);
        for (extra_headers) |h| res.header(h.name, h.value);
        res.content_type = null;
        res.body = "";
        return;
    }
    const body = errors.renderBody(res.arena, .{
        .code = code,
        .request_id = request_id,
        .host_id = host_id,
        .resource = resource,
    }) catch {
        res.status = 500;
        res.body = "";
        return;
    };
    res.status = code.httpStatus();
    res.header("x-amz-request-id", request_id);
    res.header("x-amz-id-2", host_id);
    for (extra_headers) |h| res.header(h.name, h.value);
    res.header("Content-Type", "application/xml");
    res.content_type = null;
    res.body = body;
}

fn randomHex(io: std.Io, allocator: Allocator, byte_count: usize) ![]u8 {
    const out = try allocator.alloc(u8, byte_count * 2);
    var raw_buf: [32]u8 = undefined;
    std.debug.assert(byte_count <= raw_buf.len);
    const raw = raw_buf[0..byte_count];
    io.random(raw);
    const hex = "0123456789ABCDEF";
    for (raw, 0..) |b, i| {
        out[i * 2] = hex[(b >> 4) & 0xF];
        out[i * 2 + 1] = hex[b & 0xF];
    }
    return out;
}

pub fn run(
    allocator: Allocator,
    config: *const cli.Config,
    init: std.process.Init,
    backend: storage.Backend,
) !void {
    const address = try std.Io.net.IpAddress.parse(config.bind, config.port);

    // --self-test-ready: prove the binary loads, parses args, and binds
    // the configured port, then exit. Used as a cold-start smoke check
    // (PRD §12). We deliberately skip httpz setup so the wall time
    // reflects "can we even bind?", not "did the HTTP framework warm up?";
    // the bench harness measures the latter via TCP-poll.
    if (config.self_test_ready) {
        var probe = std.Io.net.IpAddress.listen(&address, init.io, .{}) catch |err| {
            std.log.err("self-test-ready: bind failed: {s}", .{@errorName(err)});
            return err;
        };
        probe.deinit(init.io);
        std.log.info("self-test-ready: bound :{d}, exiting", .{config.port});
        return;
    }

    var app: App = .{ .config = config, .io = init.io, .backend = backend };
    // Allow up to 64 MiB request bodies. AWS S3 caps single-PUT and
    // per-part uploads at 5 GiB, but httpz preallocates a per-worker pool
    // sized by `max_body_size` — anything close to AWS's ceiling OOMs the
    // process. 64 MiB covers SDK defaults (5-16 MiB parts) with headroom
    // and is documented as a known divergence in docs/SUPPORT.md.
    var server = try httpz.Server(*App).init(init.io, allocator, .{
        .address = .{ .ip = address },
        .request = .{ .max_body_size = 64 * 1024 * 1024 },
    }, &app);
    defer {
        server.stop();
        server.deinit();
    }

    _ = try server.router(.{});

    std.log.info("nanostack listening on http://{s}:{d}  profile={s}  auth={s}", .{
        config.bind,
        config.port,
        config.profile,
        if (config.no_auth) "OFF (--no-auth)" else "SigV4",
    });
    if (config.no_auth) {
        std.log.warn("--no-auth is set: SigV4 verification disabled. Do not use this mode for accuracy testing.", .{});
    }

    try server.listen();
}
