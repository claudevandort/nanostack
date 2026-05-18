//! SQS service dispatch (v0.3.0).
//!
//! Like DynamoDB, SQS uses one HTTP endpoint and dispatches via the
//! `X-Amz-Target` header (e.g. `AmazonSQS.SendMessage`). Method is
//! always POST; body is `application/x-amz-json-1.0`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const errors = @import("../../wire/sqs/errors.zig");
const queues_handler = @import("queues.zig");
const messages_handler = @import("messages.zig");
const tags_handler = @import("tags.zig");

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
    headers: []const storage.Header = &.{},
    body: []const u8 = "",
    /// X-Amz-Target value, post-prefix-strip — e.g. `CreateQueue`.
    target: []const u8 = "",
};

pub const Context = struct {
    backend: storage.SqsBackend,
    allocator: Allocator,
    region: []const u8 = "us-east-1",
    account_id: []const u8 = "000000000000",
    /// Base URL clients use to reach queues, e.g. `http://127.0.0.1:4566`.
    /// Appended with `/<account_id>/<queue_name>` to form QueueUrls.
    base_url: []const u8 = "http://127.0.0.1:4566",
    request: RequestData = .{},
};

pub const target_prefix = "AmazonSQS.";

pub fn handle(ctx: Context) Result {
    const target = ctx.request.target;

    // Queue management (Phase 1).
    if (std.mem.eql(u8, target, "CreateQueue")) return queues_handler.createQueue(ctx);
    if (std.mem.eql(u8, target, "DeleteQueue")) return queues_handler.deleteQueue(ctx);
    if (std.mem.eql(u8, target, "ListQueues")) return queues_handler.listQueues(ctx);
    if (std.mem.eql(u8, target, "GetQueueUrl")) return queues_handler.getQueueUrl(ctx);
    if (std.mem.eql(u8, target, "GetQueueAttributes")) return queues_handler.getQueueAttributes(ctx);
    if (std.mem.eql(u8, target, "SetQueueAttributes")) return queues_handler.setQueueAttributes(ctx);
    if (std.mem.eql(u8, target, "PurgeQueue")) return queues_handler.purgeQueue(ctx);

    // Messages (Phase 2).
    if (std.mem.eql(u8, target, "SendMessage")) return messages_handler.sendMessage(ctx);
    if (std.mem.eql(u8, target, "ReceiveMessage")) return messages_handler.receiveMessage(ctx);
    if (std.mem.eql(u8, target, "DeleteMessage")) return messages_handler.deleteMessage(ctx);
    if (std.mem.eql(u8, target, "ChangeMessageVisibility")) return messages_handler.changeMessageVisibility(ctx);

    // Batches (Phase 3).
    if (std.mem.eql(u8, target, "SendMessageBatch")) return messages_handler.sendMessageBatch(ctx);
    if (std.mem.eql(u8, target, "DeleteMessageBatch")) return messages_handler.deleteMessageBatch(ctx);
    if (std.mem.eql(u8, target, "ChangeMessageVisibilityBatch")) return messages_handler.changeMessageVisibilityBatch(ctx);

    // Tags (Phase 5).
    if (std.mem.eql(u8, target, "TagQueue")) return tags_handler.tagQueue(ctx);
    if (std.mem.eql(u8, target, "UntagQueue")) return tags_handler.untagQueue(ctx);
    if (std.mem.eql(u8, target, "ListQueueTags")) return tags_handler.listQueueTags(ctx);

    // Robustness ops (v0.3.2).
    if (std.mem.eql(u8, target, "ListDeadLetterSourceQueues")) return queues_handler.listDeadLetterSourceQueues(ctx);

    // Anything else: 400 with operation name in the message. Phase 2+
    // adds messages / batches / long polling.
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Unsupported operation: {s}", .{target}) catch
        return .{ .err = .{ .code = .internal_server_error } };
    const owned = ctx.allocator.dupe(u8, msg) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .err = .{ .code = .invalid_parameter_value, .message = owned } };
}
