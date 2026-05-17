//! SQS tag-ops handlers (v0.3.0 Phase 5).

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const wire = @import("../../wire/sqs/tags.zig");
const queues_wire = @import("../../wire/sqs/queues.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;
const ErrorBody = mod.ErrorBody;

pub fn tagQueue(ctx: Context) Result {
    const req = wire.parseTagQueue(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };
    ctx.backend.tagQueue(.{
        .queue_name = req.queue_name,
        .tags = req.tags,
    }) catch |err| return .{ .err = mapStorageErr(err) };
    return .{ .ok = .{ .body = "{}" } };
}

pub fn untagQueue(ctx: Context) Result {
    const req = wire.parseUntagQueue(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };
    ctx.backend.untagQueue(.{
        .queue_name = req.queue_name,
        .keys = req.keys,
    }) catch |err| return .{ .err = mapStorageErr(err) };
    return .{ .ok = .{ .body = "{}" } };
}

pub fn listQueueTags(ctx: Context) Result {
    const name = queues_wire.parseQueueUrlOrName(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };
    const out = ctx.backend.listQueueTags(ctx.allocator, name) catch |err|
        return .{ .err = mapStorageErr(err) };
    const body = wire.renderListQueueTags(ctx.allocator, out) catch
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
        storage.Error.TooManyEntries => .{ .code = .invalid_parameter_value, .message = "Too many tags (max 50)." },
        storage.Error.OutOfMemory, storage.Error.Io => .{ .code = .internal_server_error },
        else => .{ .code = .internal_server_error },
    };
}
