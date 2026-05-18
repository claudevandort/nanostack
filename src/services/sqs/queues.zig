//! SQS queue-management handlers (v0.3.0 Phase 1).
//!
//! Seven ops: CreateQueue, DeleteQueue, ListQueues, GetQueueUrl,
//! GetQueueAttributes, SetQueueAttributes, PurgeQueue. Thin glue
//! between wire (src/wire/sqs/queues.zig) and storage backend.

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const wire = @import("../../wire/sqs/queues.zig");
const errors = @import("../../wire/sqs/errors.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;
const ErrorBody = mod.ErrorBody;

pub fn createQueue(ctx: Context) Result {
    const req = wire.parseCreateQueue(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    const slot = ctx.backend.createQueue(.{
        .name = req.queue_name,
        .attrs = req.attrs,
        .fifo_attribute_specified = req.fifo_attribute_specified,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const body = wire.renderQueueUrl(ctx.allocator, ctx.base_url, ctx.account_id, slot.name) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn deleteQueue(ctx: Context) Result {
    const name = wire.parseQueueUrlOrName(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };
    ctx.backend.deleteQueue(name) catch |err| return .{ .err = mapStorageErr(err) };
    return .{ .ok = .{ .body = "{}" } };
}

pub fn listQueues(ctx: Context) Result {
    const req = wire.parseListQueues(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    const out = ctx.backend.listQueues(ctx.allocator, .{
        .name_prefix = req.name_prefix,
        .max_results = req.max_results orelse 1000,
        .next_token = req.next_token,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const body = wire.renderListQueues(ctx.allocator, ctx.base_url, ctx.account_id, out) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn getQueueUrl(ctx: Context) Result {
    const name = wire.parseQueueUrlOrName(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };
    const slot = ctx.backend.getQueueUrl(name) catch |err| return .{ .err = mapStorageErr(err) };
    const body = wire.renderQueueUrl(ctx.allocator, ctx.base_url, ctx.account_id, slot.name) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn getQueueAttributes(ctx: Context) Result {
    const req = wire.parseGetQueueAttributes(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };
    const attrs = ctx.backend.getQueueAttributes(req.queue_name) catch |err|
        return .{ .err = mapStorageErr(err) };
    const slot = ctx.backend.getQueueUrl(req.queue_name) catch |err|
        return .{ .err = mapStorageErr(err) };
    const body = wire.renderGetQueueAttributes(
        ctx.allocator,
        attrs,
        slot.name,
        ctx.account_id,
        req.attribute_names,
        slot.created_unix,
    ) catch return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn setQueueAttributes(ctx: Context) Result {
    const req = wire.parseSetQueueAttributes(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };
    ctx.backend.setQueueAttributes(.{
        .name = req.queue_name,
        .attrs = req.attrs,
    }) catch |err| return .{ .err = mapStorageErr(err) };
    return .{ .ok = .{ .body = "{}" } };
}

pub fn purgeQueue(ctx: Context) Result {
    const name = wire.parseQueueUrlOrName(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };
    ctx.backend.purgeQueue(name) catch |err| return .{ .err = mapStorageErr(err) };
    return .{ .ok = .{ .body = "{}" } };
}

pub fn listDeadLetterSourceQueues(ctx: Context) Result {
    const dlq_name = wire.parseListDeadLetterSourceQueues(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };
    const out = ctx.backend.listDeadLetterSourceQueues(ctx.allocator, .{ .dlq_name = dlq_name }) catch |err|
        return .{ .err = mapStorageErr(err) };
    const body = wire.renderListDeadLetterSourceQueues(ctx.allocator, ctx.base_url, ctx.account_id, out) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

// ---------------------------------------------------------------------------
// Error mapping

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
        storage.Error.QueueAlreadyExists => .{ .code = .queue_name_exists },
        storage.Error.QueueDeletedRecently => .{ .code = .queue_deleted_recently },
        storage.Error.InvalidQueueName => .{ .code = .invalid_parameter_value, .message = "Queue name is invalid." },
        storage.Error.InvalidAttributeValue => .{ .code = .invalid_attribute_value, .message = "An attribute value is invalid." },
        storage.Error.InvalidParameterValue => .{ .code = .invalid_parameter_value },
        storage.Error.MissingParameter => .{ .code = .missing_parameter },
        storage.Error.OutOfMemory => .{ .code = .internal_server_error },
        storage.Error.Io => .{ .code = .internal_server_error },
        else => .{ .code = .internal_server_error },
    };
}
