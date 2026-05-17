//! SQS message-ops handlers (v0.3.0 Phase 2).
//!
//! SendMessage / ReceiveMessage / DeleteMessage / ChangeMessageVisibility.

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const wire = @import("../../wire/sqs/messages.zig");
const errors = @import("../../wire/sqs/errors.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;
const ErrorBody = mod.ErrorBody;

pub fn sendMessage(ctx: Context) Result {
    const req = wire.parseSendMessage(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    const out = ctx.backend.sendMessage(ctx.allocator, .{
        .queue_name = req.queue_name,
        .body = req.body,
        .delay_seconds = req.delay_seconds,
        .raw_attributes_json = req.raw_attributes_json,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const body = wire.renderSendMessage(ctx.allocator, out) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn receiveMessage(ctx: Context) Result {
    const req = wire.parseReceiveMessage(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    const out = ctx.backend.receiveMessage(ctx.allocator, .{
        .queue_name = req.queue_name,
        .max_messages = req.max_messages,
        .visibility_timeout = req.visibility_timeout,
        .wait_time_seconds = req.wait_time_seconds,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const body = wire.renderReceiveMessage(ctx.allocator, out) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn deleteMessage(ctx: Context) Result {
    const req = wire.parseDeleteMessage(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    ctx.backend.deleteMessage(.{
        .queue_name = req.queue_name,
        .receipt_handle = req.receipt_handle,
    }) catch |err| return .{ .err = mapStorageErr(err) };
    return .{ .ok = .{ .body = "{}" } };
}

pub fn changeMessageVisibility(ctx: Context) Result {
    const req = wire.parseChangeMessageVisibility(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    ctx.backend.changeMessageVisibility(.{
        .queue_name = req.queue_name,
        .receipt_handle = req.receipt_handle,
        .visibility_timeout = req.visibility_timeout,
    }) catch |err| return .{ .err = mapStorageErr(err) };
    return .{ .ok = .{ .body = "{}" } };
}

fn mapParseErr(e: wire.ParseError) ErrorBody {
    return switch (e) {
        wire.ParseError.OutOfMemory => .{ .code = .internal_server_error },
        wire.ParseError.Malformed => .{ .code = .invalid_parameter_value, .message = "Request body is malformed." },
        wire.ParseError.InvalidQueueName => .{ .code = .invalid_parameter_value, .message = "Queue name is invalid." },
        wire.ParseError.InvalidAttribute => .{ .code = .invalid_parameter_value, .message = "An attribute value is invalid." },
    };
}

fn mapStorageErr(e: storage.Error) ErrorBody {
    return switch (e) {
        storage.Error.QueueNotFound => .{ .code = .queue_does_not_exist },
        storage.Error.InvalidReceiptHandle => .{ .code = .receipt_handle_is_invalid },
        storage.Error.InvalidMessageBody => .{ .code = .invalid_message_contents },
        storage.Error.MessageNotFound => .{ .code = .receipt_handle_is_invalid },
        storage.Error.OutOfMemory, storage.Error.Io => .{ .code = .internal_server_error },
        else => .{ .code = .internal_server_error },
    };
}
