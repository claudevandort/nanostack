//! HTTP server entry point.
//!
//! Uses http.zig's `handle` takeover so we own routing end-to-end.
//! Pipeline: id → log → SigV4 (stub in M0) → router → service → render.

const std = @import("std");
const httpz = @import("httpz");
const Allocator = std.mem.Allocator;

const cli = @import("cli.zig");
const router = @import("router.zig");
const errors = @import("wire/errors.zig");
const sigv4 = @import("auth/sigv4.zig");
const s3 = @import("services/s3/mod.zig");

pub const App = struct {
    config: *const cli.Config,
    io: std.Io,

    /// `handle` takeover circumvents httpz's pattern router so our service
    /// layer sees every request. AWS APIs are not a fit for path-pattern
    /// routing — the operation is encoded in (host, path, method, query).
    pub fn handle(self: *App, req: *httpz.Request, res: *httpz.Response) void {
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
        std.log.info("{s} {s} host={s} len={d}", .{
            @tagName(req.method),
            req.url.path,
            host_header,
            (req.body() orelse @as([]const u8, "")).len,
        });

        sigv4.verify(
            .{ .access_key = self.config.access_key, .secret_key = self.config.secret_key },
            req.method_string,
            req.url.path,
            req.url.query,
            &.{},
            req.body() orelse "",
        ) catch |err| {
            return respondError(res, request_id, host_id, mapAuthError(err), req.url.path);
        };

        const parsed = router.parse(host_header, req.url.path);
        const code = s3.handle(parsed, req.method_string);

        respondError(res, request_id, host_id, code, req.url.path);
        // HEAD: per RFC 9110 the response must not carry a body. Keep the
        // computed Content-Length header so clients can size the buffer.
        if (req.method == .HEAD) res.body = "";
    }
};

fn mapAuthError(e: sigv4.VerifyError) errors.Code {
    return switch (e) {
        sigv4.VerifyError.SignatureDoesNotMatch => .signature_does_not_match,
        sigv4.VerifyError.InvalidAccessKeyId => .invalid_access_key_id,
        sigv4.VerifyError.Malformed => .invalid_request,
    };
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
    // AWS S3 emits exactly `application/xml`; httpz's ContentType.XML
    // formats as `text/xml; charset=UTF-8`, so we set the header directly.
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

pub fn run(allocator: Allocator, config: *const cli.Config, init: std.process.Init) !void {
    var app: App = .{ .config = config, .io = init.io };

    const address = try std.Io.net.IpAddress.parse(config.bind, config.port);
    var server = try httpz.Server(*App).init(init.io, allocator, .{
        .address = .{ .ip = address },
    }, &app);
    defer {
        server.stop();
        server.deinit();
    }

    // `handle` takeover ignores the router, but httpz still wants one created.
    _ = try server.router(.{});

    std.log.info("nanostack listening on http://{s}:{d}  profile={s}  ephemeral={}", .{
        config.bind,
        config.port,
        config.profile,
        config.ephemeral,
    });

    if (config.self_test_ready) {
        std.log.info("self-test-ready: skeleton initialised, exiting", .{});
        return;
    }

    try server.listen();
}
