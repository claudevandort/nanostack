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
const topics_handler = @import("topics.zig");
const subs_handler = @import("subscriptions.zig");

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

    // Topics (Phase B).
    if (std.mem.eql(u8, action, "CreateTopic")) return topics_handler.createTopic(ctx);
    if (std.mem.eql(u8, action, "DeleteTopic")) return topics_handler.deleteTopic(ctx);
    if (std.mem.eql(u8, action, "ListTopics")) return topics_handler.listTopics(ctx);
    if (std.mem.eql(u8, action, "GetTopicAttributes")) return topics_handler.getTopicAttributes(ctx);
    if (std.mem.eql(u8, action, "SetTopicAttributes")) return topics_handler.setTopicAttributes(ctx);

    // Subscriptions (Phase C).
    if (std.mem.eql(u8, action, "Subscribe")) return subs_handler.subscribe(ctx);
    if (std.mem.eql(u8, action, "Unsubscribe")) return subs_handler.unsubscribe(ctx);
    if (std.mem.eql(u8, action, "ListSubscriptions")) return subs_handler.listSubscriptions(ctx);
    if (std.mem.eql(u8, action, "ListSubscriptionsByTopic")) return subs_handler.listSubscriptionsByTopic(ctx);
    if (std.mem.eql(u8, action, "GetSubscriptionAttributes")) return subs_handler.getSubscriptionAttributes(ctx);
    if (std.mem.eql(u8, action, "SetSubscriptionAttributes")) return subs_handler.setSubscriptionAttributes(ctx);
    if (std.mem.eql(u8, action, "ConfirmSubscription")) return subs_handler.confirmSubscription(ctx);

    return .{ .err = .{
        .code = .invalid_action,
        .message = "SNS operation not yet implemented in this build.",
    } };
}
