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
        if (!self.config.no_auth) {
            const all_headers = collectHeaders(arena, req) catch {
                return respondError(res, request_id, host_id, .internal_error, req.url.path);
            };
            sigv4.verify(arena, .{
                .method = method_str,
                .path = req.url.path,
                .query = req.url.query,
                .headers = all_headers,
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
                return respondError(res, request_id, host_id, mapVerifyError(err), req.url.path);
            };
        }

        // ---------- Service dispatch ----------
        const parsed = router.parse(method_str, host_header, req.url.path);
        const result = s3.handle(.{
            .backend = self.backend,
            .allocator = arena,
            .owner_id = self.config.access_key,
            .owner_display_name = "nanostack",
        }, parsed);

        switch (result) {
            .ok => |out| respondOk(res, request_id, host_id, out),
            .err => |code| respondError(res, request_id, host_id, code, req.url.path),
        }
    }
};

fn mapVerifyError(e: sigv4.VerifyError) errors.Code {
    return switch (e) {
        sigv4.VerifyError.MissingAuth => .access_denied,
        sigv4.VerifyError.InvalidAccessKeyId => .invalid_access_key_id,
        sigv4.VerifyError.SignatureDoesNotMatch => .signature_does_not_match,
        sigv4.VerifyError.RequestTimeTooSkewed => .request_time_too_skewed,
        sigv4.VerifyError.PresignedExpired => .access_denied,
        sigv4.VerifyError.MissingSignedHeader => .signature_does_not_match,
        sigv4.VerifyError.StreamingUnsupported => .not_implemented,
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
    if (out.body.len > 0) {
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
) void {
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
    var app: App = .{ .config = config, .io = init.io, .backend = backend };

    const address = try std.Io.net.IpAddress.parse(config.bind, config.port);
    var server = try httpz.Server(*App).init(init.io, allocator, .{
        .address = .{ .ip = address },
    }, &app);
    defer {
        server.stop();
        server.deinit();
    }

    _ = try server.router(.{});

    std.log.info("nanostack listening on http://{s}:{d}  profile={s}  ephemeral={}  auth={s}", .{
        config.bind,
        config.port,
        config.profile,
        config.ephemeral,
        if (config.no_auth) "OFF (--no-auth)" else "SigV4",
    });
    if (config.no_auth) {
        std.log.warn("--no-auth is set: SigV4 verification disabled. Do not use this mode for accuracy testing.", .{});
    }

    if (config.self_test_ready) {
        std.log.info("self-test-ready: skeleton initialised, exiting", .{});
        return;
    }

    try server.listen();
}
