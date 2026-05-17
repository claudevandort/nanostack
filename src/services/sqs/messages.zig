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

    // Long polling: if WaitTimeSeconds > 0 (or the queue's default is),
    // loop calling the backend every 100ms until either (a) we get
    // messages, (b) the deadline expires.
    //
    // Resolve the effective wait time: request value wins, else queue
    // attribute default.
    var wait_secs: u32 = req.wait_time_seconds;
    if (wait_secs == 0) {
        if (ctx.backend.getQueueAttributes(req.queue_name)) |attrs| {
            wait_secs = attrs.receive_message_wait_time_seconds;
        } else |_| {}
    }

    // Initial try.
    const first = ctx.backend.receiveMessage(ctx.allocator, .{
        .queue_name = req.queue_name,
        .max_messages = req.max_messages,
        .visibility_timeout = req.visibility_timeout,
        .wait_time_seconds = 0,
    }) catch |err| return .{ .err = mapStorageErr(err) };
    if (first.messages.len > 0 or wait_secs == 0) {
        const body = wire.renderReceiveMessage(ctx.allocator, first) catch
            return .{ .err = .{ .code = .internal_server_error } };
        return .{ .ok = .{ .body = body } };
    }

    // Long-poll loop. 100ms ticks; total wait capped at wait_secs.
    const total_ms: u64 = @as(u64, wait_secs) * 1000;
    const tick_ms: u64 = 100;
    var elapsed_ms: u64 = 0;
    var out = first;
    while (elapsed_ms < total_ms) {
        const req_ts: std.os.linux.timespec = .{
            .sec = 0,
            .nsec = @intCast(tick_ms * std.time.ns_per_ms),
        };
        _ = std.os.linux.nanosleep(&req_ts, null);
        elapsed_ms += tick_ms;
        out = ctx.backend.receiveMessage(ctx.allocator, .{
            .queue_name = req.queue_name,
            .max_messages = req.max_messages,
            .visibility_timeout = req.visibility_timeout,
            .wait_time_seconds = 0,
        }) catch |err| return .{ .err = mapStorageErr(err) };
        if (out.messages.len > 0) break;
    }
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

// ---------------------------------------------------------------------------
// Batch handlers (Phase 3)

pub fn sendMessageBatch(ctx: Context) Result {
    const req = wire.parseSendMessageBatch(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    var successful: std.ArrayList(wire.SendBatchResultEntry) = .empty;
    var failed: std.ArrayList(wire.BatchFailedEntry) = .empty;

    for (req.entries) |entry| {
        const out = ctx.backend.sendMessage(ctx.allocator, .{
            .queue_name = req.queue_name,
            .body = entry.body,
            .delay_seconds = entry.delay_seconds,
            .raw_attributes_json = entry.raw_attributes_json,
        }) catch |err| {
            const eb = mapStorageErr(err);
            failed.append(ctx.allocator, .{
                .id = entry.id,
                .code = eb.code.awsCode(),
                .message = eb.message orelse eb.code.defaultMessage(),
                .sender_fault = true,
            }) catch return .{ .err = .{ .code = .internal_server_error } };
            continue;
        };
        successful.append(ctx.allocator, .{
            .id = entry.id,
            .message_id = out.message_id,
            .md5_of_body = out.md5_of_body,
        }) catch return .{ .err = .{ .code = .internal_server_error } };
    }

    const body = wire.renderSendMessageBatch(ctx.allocator, successful.items, failed.items) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn deleteMessageBatch(ctx: Context) Result {
    const req = wire.parseDeleteMessageBatch(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    var successful: std.ArrayList([]const u8) = .empty;
    var failed: std.ArrayList(wire.BatchFailedEntry) = .empty;

    for (req.entries) |entry| {
        ctx.backend.deleteMessage(.{
            .queue_name = req.queue_name,
            .receipt_handle = entry.receipt_handle,
        }) catch |err| {
            const eb = mapStorageErr(err);
            failed.append(ctx.allocator, .{
                .id = entry.id,
                .code = eb.code.awsCode(),
                .message = eb.message orelse eb.code.defaultMessage(),
                .sender_fault = true,
            }) catch return .{ .err = .{ .code = .internal_server_error } };
            continue;
        };
        successful.append(ctx.allocator, entry.id) catch
            return .{ .err = .{ .code = .internal_server_error } };
    }

    const body = wire.renderIdOnlyBatch(ctx.allocator, successful.items, failed.items) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn changeMessageVisibilityBatch(ctx: Context) Result {
    const req = wire.parseChangeMessageVisibilityBatch(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    var successful: std.ArrayList([]const u8) = .empty;
    var failed: std.ArrayList(wire.BatchFailedEntry) = .empty;

    for (req.entries) |entry| {
        ctx.backend.changeMessageVisibility(.{
            .queue_name = req.queue_name,
            .receipt_handle = entry.receipt_handle,
            .visibility_timeout = entry.visibility_timeout,
        }) catch |err| {
            const eb = mapStorageErr(err);
            failed.append(ctx.allocator, .{
                .id = entry.id,
                .code = eb.code.awsCode(),
                .message = eb.message orelse eb.code.defaultMessage(),
                .sender_fault = true,
            }) catch return .{ .err = .{ .code = .internal_server_error } };
            continue;
        };
        successful.append(ctx.allocator, entry.id) catch
            return .{ .err = .{ .code = .internal_server_error } };
    }

    const body = wire.renderIdOnlyBatch(ctx.allocator, successful.items, failed.items) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
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
