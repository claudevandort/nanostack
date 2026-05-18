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
const dynamodb = @import("services/dynamodb/mod.zig");
const ddb_errors = @import("wire/dynamodb/errors.zig");
const sqs = @import("services/sqs/mod.zig");
const sqs_errors = @import("wire/sqs/errors.zig");
const sns = @import("services/sns/mod.zig");
const sns_errors = @import("wire/sns/errors.zig");
const sns_params = @import("wire/sns/params.zig");

pub const App = struct {
    config: *const cli.Config,
    io: std.Io,
    backend: storage.Backend,
    /// DynamoDB backend, present when `--services` includes `dynamodb`.
    dynamo_backend: ?storage.DynamoBackend = null,
    /// SQS backend, present when `--services` includes `sqs`.
    sqs_backend: ?storage.SqsBackend = null,
    /// SNS backend, present when `--services` includes `sns` (v0.4.0).
    sns_backend: ?storage.SnsBackend = null,

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

        // ---------- Service detection ----------
        //
        // DynamoDB requests carry an `X-Amz-Target` header; S3 doesn't.
        // That single signal is reliable across boto3, aws-cli, and every
        // SDK we've seen. The SigV4 service-name validation (below) then
        // catches mismatched-credential-scope attacks.
        const target_header = req.header("x-amz-target") orelse req.header("X-Amz-Target");
        const is_sqs = if (target_header) |t| std.mem.startsWith(u8, t, sqs.target_prefix) else false;
        const is_ddb = target_header != null and !is_sqs;

        if (is_sqs) {
            if (!self.config.hasService("sqs")) {
                return respondSqsError(res, request_id, host_id, .{
                    .code = .invalid_parameter_value,
                    .message = "SQS is not enabled. Restart nanostack with --services s3,sqs (or similar).",
                });
            }
            return handleSqs(self, req, res, arena, request_id, host_id, target_header.?);
        }

        if (is_ddb) {
            if (!self.config.hasService("dynamodb")) {
                return respondDdbError(res, request_id, host_id, .{
                    .code = .validation_exception,
                    .message = "DynamoDB is not enabled. Restart nanostack with --services s3,dynamodb.",
                });
            }
            return handleDynamo(self, req, res, arena, request_id, host_id, target_header.?);
        }

        // SNS uses the AWS query protocol — no X-Amz-Target header,
        // body starts with `Action=<Op>&...` form-urlencoded. Detect
        // before falling through to S3.
        if (target_header == null and req.method == .POST and std.mem.eql(u8, req.url.path, "/")) {
            const body = req.body() orelse "";
            if (sniffSnsAction(body) != null) {
                if (!self.config.hasService("sns")) {
                    return respondSnsError(res, request_id, host_id, .{
                        .code = .invalid_parameter,
                        .message = "SNS is not enabled. Restart nanostack with --services s3,sns (or similar).",
                    });
                }
                return handleSns(self, req, res, arena, request_id, host_id);
            }
        }

        // ---------- SigV4 verification (S3) ----------
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
            .sqs_backend = self.sqs_backend,
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

fn handleDynamo(
    self: *App,
    req: *httpz.Request,
    res: *httpz.Response,
    arena: Allocator,
    request_id: []const u8,
    host_id: []const u8,
    target_header: []const u8,
) void {
    // SigV4 with service="dynamodb". DDB doesn't have an anonymous path;
    // unsigned requests fail at the verify step. `--no-auth` still
    // bypasses everything.
    if (!self.config.no_auth) {
        const verify_headers = collectHeaders(arena, req) catch {
            return respondDdbError(res, request_id, host_id, .{ .code = .internal_server_error });
        };
        _ = sigv4.verify(arena, .{
            .method = if (req.method == .OTHER) req.method_string else @tagName(req.method),
            .path = req.url.path,
            .query = req.url.query,
            .headers = verify_headers,
            .body = req.body() orelse "",
        }, .{
            .access_key = self.config.access_key,
            .secret_key = self.config.secret_key,
        }, .{
            .region = self.config.region,
            .service = "dynamodb",
            .now_unix = fs_backend.nowUnixSeconds(self.io),
            .skew_tolerance_seconds = self.config.skew_seconds,
        }) catch {
            // DDB collapses all auth-time failures onto a flat 400
            // ValidationException — there's no SignatureDoesNotMatch JSON
            // shape published in the official Smithy. Match observed AWS.
            return respondDdbError(res, request_id, host_id, .{
                .code = .validation_exception,
                .message = "The security token included in the request is invalid.",
            });
        };
    }

    // Strip whichever target prefix matched. Two are accepted: the
    // core DynamoDB service and the DynamoDBStreams sub-service
    // (v0.2.2). Anything else is rejected with ValidationException.
    var sub_service: dynamodb.SubService = .core;
    var target: []const u8 = "";
    if (std.mem.startsWith(u8, target_header, dynamodb.target_prefix)) {
        sub_service = .core;
        target = target_header[dynamodb.target_prefix.len..];
    } else if (std.mem.startsWith(u8, target_header, dynamodb.streams_target_prefix)) {
        sub_service = .streams;
        target = target_header[dynamodb.streams_target_prefix.len..];
    } else {
        return respondDdbError(res, request_id, host_id, .{
            .code = .validation_exception,
            .message = "Only DynamoDB_20120810 and DynamoDBStreams_20120810 targets are supported.",
        });
    }

    const all_headers = collectHeaders(arena, req) catch {
        return respondDdbError(res, request_id, host_id, .{ .code = .internal_server_error });
    };
    const svc_headers = arena.alloc(storage.Header, all_headers.len) catch {
        return respondDdbError(res, request_id, host_id, .{ .code = .internal_server_error });
    };
    for (all_headers, 0..) |h, i| svc_headers[i] = .{ .name = h.name, .value = h.value };

    const result = dynamodb.handle(.{
        .backend = self.dynamo_backend orelse unreachable, // gated by --services check upstream
        .allocator = arena,
        .region = self.config.region,
        .request = .{
            .headers = svc_headers,
            .body = req.body() orelse "",
            .target = target,
            .sub_service = sub_service,
        },
    });

    switch (result) {
        .ok => |out| respondDdbOk(res, request_id, host_id, out),
        .err => |e| respondDdbError(res, request_id, host_id, e),
    }
}

fn respondDdbOk(
    res: *httpz.Response,
    request_id: []const u8,
    host_id: []const u8,
    out: dynamodb.Output,
) void {
    res.status = out.status;
    res.header("x-amz-request-id", request_id);
    res.header("x-amzn-RequestId", request_id);
    res.header("x-amz-id-2", host_id);
    for (out.extra_headers) |h| res.header(h.name, h.value);
    res.header("Content-Type", "application/x-amz-json-1.0");
    res.content_type = null;
    res.body = out.body;
}

fn respondDdbError(
    res: *httpz.Response,
    request_id: []const u8,
    host_id: []const u8,
    e: dynamodb.ErrorBody,
) void {
    const body = ddb_errors.render(res.arena, e.code, e.message) catch {
        res.status = 500;
        res.body = "";
        return;
    };
    res.status = e.code.httpStatus();
    res.header("x-amz-request-id", request_id);
    res.header("x-amzn-RequestId", request_id);
    res.header("x-amz-id-2", host_id);
    res.header("Content-Type", "application/x-amz-json-1.0");
    res.content_type = null;
    res.body = body;
}

fn handleSqs(
    self: *App,
    req: *httpz.Request,
    res: *httpz.Response,
    arena: Allocator,
    request_id: []const u8,
    host_id: []const u8,
    target_header: []const u8,
) void {
    // SigV4 with service="sqs". Capture the verified Principal so the
    // SQS authz hook (Phase B) can evaluate queue policies against it.
    // `--no-auth` short-circuits to the configured access_key as owner
    // (matches S3).
    const principal: sigv4.Principal = if (self.config.no_auth)
        sigv4.Principal.awsAccount(self.config.access_key)
    else blk: {
        const verify_headers = collectHeaders(arena, req) catch {
            return respondSqsError(res, request_id, host_id, .{ .code = .internal_server_error });
        };
        const p = sigv4.verify(arena, .{
            .method = if (req.method == .OTHER) req.method_string else @tagName(req.method),
            .path = req.url.path,
            .query = req.url.query,
            .headers = verify_headers,
            .body = req.body() orelse "",
        }, .{
            .access_key = self.config.access_key,
            .secret_key = self.config.secret_key,
        }, .{
            .region = self.config.region,
            .service = "sqs",
            .now_unix = fs_backend.nowUnixSeconds(self.io),
            .skew_tolerance_seconds = self.config.skew_seconds,
        }) catch {
            return respondSqsError(res, request_id, host_id, .{
                .code = .invalid_parameter_value,
                .message = "The security token included in the request is invalid.",
            });
        };
        break :blk p;
    };

    if (!std.mem.startsWith(u8, target_header, sqs.target_prefix)) {
        return respondSqsError(res, request_id, host_id, .{
            .code = .invalid_parameter_value,
            .message = "Only AmazonSQS targets are supported.",
        });
    }
    const target = target_header[sqs.target_prefix.len..];

    const all_headers = collectHeaders(arena, req) catch {
        return respondSqsError(res, request_id, host_id, .{ .code = .internal_server_error });
    };
    const svc_headers = arena.alloc(storage.Header, all_headers.len) catch {
        return respondSqsError(res, request_id, host_id, .{ .code = .internal_server_error });
    };
    for (all_headers, 0..) |h, i| svc_headers[i] = .{ .name = h.name, .value = h.value };

    // Build a base URL from the `host` header (so clients reach the
    // queue via the same authority they used to call CreateQueue).
    const host_header = req.header("host") orelse "127.0.0.1";
    var base_url_buf: [256]u8 = undefined;
    const base_url = std.fmt.bufPrint(&base_url_buf, "http://{s}", .{host_header}) catch
        return respondSqsError(res, request_id, host_id, .{ .code = .internal_server_error });

    const result = sqs.handle(.{
        .backend = self.sqs_backend orelse unreachable,
        .allocator = arena,
        .region = self.config.region,
        .account_id = self.config.account_id,
        .base_url = base_url,
        .principal = principal,
        .no_auth = self.config.no_auth,
        .access_key = self.config.access_key,
        .request = .{
            .headers = svc_headers,
            .body = req.body() orelse "",
            .target = target,
        },
    });

    switch (result) {
        .ok => |out| respondSqsOk(res, request_id, host_id, out),
        .err => |e| respondSqsError(res, request_id, host_id, e),
    }
}

fn respondSqsOk(
    res: *httpz.Response,
    request_id: []const u8,
    host_id: []const u8,
    out: sqs.Output,
) void {
    res.status = out.status;
    res.header("x-amz-request-id", request_id);
    res.header("x-amzn-RequestId", request_id);
    res.header("x-amz-id-2", host_id);
    for (out.extra_headers) |h| res.header(h.name, h.value);
    res.header("Content-Type", "application/x-amz-json-1.0");
    res.content_type = null;
    res.body = out.body;
}

fn respondSqsError(
    res: *httpz.Response,
    request_id: []const u8,
    host_id: []const u8,
    e: sqs.ErrorBody,
) void {
    const body = sqs_errors.render(res.arena, e.code, e.message) catch {
        res.status = 500;
        res.body = "";
        return;
    };
    res.status = e.code.httpStatus();
    res.header("x-amz-request-id", request_id);
    res.header("x-amzn-RequestId", request_id);
    res.header("x-amz-id-2", host_id);
    res.header("Content-Type", "application/x-amz-json-1.0");
    res.content_type = null;
    res.body = body;
}

/// Peek at a request body to detect an SNS `Action=<Op>` parameter.
/// Returns the action string slice (borrows from `body`) or null.
fn sniffSnsAction(body: []const u8) ?[]const u8 {
    // Look at the first ~256 bytes — Action is conventionally the first
    // param.
    const window = body[0..@min(body.len, 256)];
    var start: usize = 0;
    while (start < window.len) {
        const eq = std.mem.indexOfScalarPos(u8, window, start, '=') orelse return null;
        const amp = std.mem.indexOfScalarPos(u8, window, eq + 1, '&') orelse window.len;
        if (std.mem.eql(u8, window[start..eq], "Action")) {
            return window[eq + 1 .. amp];
        }
        if (amp == window.len) return null;
        start = amp + 1;
    }
    return null;
}

fn handleSns(
    self: *App,
    req: *httpz.Request,
    res: *httpz.Response,
    arena: Allocator,
    request_id: []const u8,
    host_id: []const u8,
) void {
    // SigV4 with service="sns". Capture Principal (used later by an
    // SNS-side authz hook when AddPermission lands).
    const principal: sigv4.Principal = if (self.config.no_auth)
        sigv4.Principal.awsAccount(self.config.access_key)
    else blk: {
        const verify_headers = collectHeaders(arena, req) catch {
            return respondSnsError(res, request_id, host_id, .{ .code = .internal_error });
        };
        const p = sigv4.verify(arena, .{
            .method = if (req.method == .OTHER) req.method_string else @tagName(req.method),
            .path = req.url.path,
            .query = req.url.query,
            .headers = verify_headers,
            .body = req.body() orelse "",
        }, .{
            .access_key = self.config.access_key,
            .secret_key = self.config.secret_key,
        }, .{
            .region = self.config.region,
            .service = "sns",
            .now_unix = fs_backend.nowUnixSeconds(self.io),
            .skew_tolerance_seconds = self.config.skew_seconds,
        }) catch {
            return respondSnsError(res, request_id, host_id, .{ .code = .invalid_security });
        };
        break :blk p;
    };

    // Parse the body params once; service dispatch + handlers reuse.
    const params = sns_params.parse(arena, req.body() orelse "") catch {
        return respondSnsError(res, request_id, host_id, .{ .code = .invalid_parameter });
    };

    const action_opt = sns_params.get(params, "Action");
    const action = action_opt orelse {
        return respondSnsError(res, request_id, host_id, .{
            .code = .invalid_action,
            .message = "Missing Action parameter.",
        });
    };

    const host_header = req.header("host") orelse "127.0.0.1";
    var base_url_buf: [256]u8 = undefined;
    const base_url = std.fmt.bufPrint(&base_url_buf, "http://{s}", .{host_header}) catch
        return respondSnsError(res, request_id, host_id, .{ .code = .internal_error });

    const result = sns.handle(.{
        .backend = self.sns_backend orelse unreachable,
        .allocator = arena,
        .region = self.config.region,
        .account_id = self.config.account_id,
        .base_url = base_url,
        .principal = principal,
        .no_auth = self.config.no_auth,
        .access_key = self.config.access_key,
        .request = .{ .params = params, .action = action, .request_id = request_id },
    });

    switch (result) {
        .ok => |out| respondSnsOk(res, request_id, host_id, out),
        .err => |e| respondSnsError(res, request_id, host_id, e),
    }
}

fn respondSnsOk(
    res: *httpz.Response,
    request_id: []const u8,
    host_id: []const u8,
    out: sns.Output,
) void {
    res.status = out.status;
    res.header("x-amz-request-id", request_id);
    res.header("x-amzn-RequestId", request_id);
    res.header("x-amz-id-2", host_id);
    for (out.extra_headers) |h| res.header(h.name, h.value);
    res.header("Content-Type", "text/xml");
    res.content_type = null;
    res.body = out.body;
}

fn respondSnsError(
    res: *httpz.Response,
    request_id: []const u8,
    host_id: []const u8,
    e: sns.ErrorBody,
) void {
    const body = sns_errors.render(res.arena, e.code, e.message, request_id) catch {
        res.status = 500;
        res.body = "";
        return;
    };
    res.status = e.code.httpStatus();
    res.header("x-amz-request-id", request_id);
    res.header("x-amzn-RequestId", request_id);
    res.header("x-amz-id-2", host_id);
    res.header("Content-Type", "text/xml");
    res.content_type = null;
    res.body = body;
}

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
    dynamo_backend: ?storage.DynamoBackend,
    sqs_backend: ?storage.SqsBackend,
    sns_backend: ?storage.SnsBackend,
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

    var app: App = .{ .config = config, .io = init.io, .backend = backend, .dynamo_backend = dynamo_backend, .sqs_backend = sqs_backend, .sns_backend = sns_backend };
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
