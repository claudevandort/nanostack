//! SNS service dispatch (v0.4.0).
//!
//! Unlike DDB / modern SQS, SNS uses the AWS query protocol: bodies are
//! `application/x-www-form-urlencoded` with an `Action=<Op>` parameter,
//! and responses are XML. server.zig peeks the body to detect SNS
//! requests and routes them here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const errors = @import("../../wire/sns/errors.zig");
const params_mod = @import("../../wire/sns/params.zig");
const principal_mod = @import("../../auth/principal.zig");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Output = struct {
    status: u16 = 200,
    body: []const u8,
    extra_headers: []const Header = &.{},
};

pub const ErrorBody = struct {
    code: errors.Code,
    message: ?[]const u8 = null,
};

pub const Result = union(enum) {
    ok: Output,
    err: ErrorBody,
};

pub const RequestData = struct {
    /// Pre-parsed body params (key-value list).
    params: []const params_mod.Param = &.{},
    /// The `Action=<Op>` value, e.g. "CreateTopic".
    action: []const u8 = "",
    /// Per-request id (for the XML response's ResponseMetadata).
    request_id: []const u8 = "",
};

pub const Context = struct {
    backend: storage.SnsBackend,
    allocator: Allocator,
    region: []const u8 = "us-east-1",
    account_id: []const u8 = "000000000000",
    base_url: []const u8 = "http://127.0.0.1:4566",
    principal: principal_mod.Principal = .{ .kind = .anonymous, .id = "" },
    no_auth: bool = false,
    access_key: []const u8 = "test",
    request: RequestData = .{},
};

pub fn handle(ctx: Context) Result {
    const action = ctx.request.action;

    // Phase A: dispatch table skeleton — every op returns a stub
    // error until Phase B fills them in.
    _ = action;
    return .{ .err = .{
        .code = .invalid_action,
        .message = "SNS operation not yet implemented in this build.",
    } };
}
