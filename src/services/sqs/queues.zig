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

pub fn addPermission(ctx: Context) Result {
    const req = wire.parseAddPermission(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };
    // Add the "sqs:" prefix to each action name. AWS-real accepts both
    // shorthand and fully-qualified; we always store the fully-qualified
    // form for evaluator simplicity.
    var prefixed: std.ArrayList([]const u8) = .empty;
    for (req.actions) |a| {
        const owned = std.fmt.allocPrint(ctx.allocator, "sqs:{s}", .{a}) catch
            return .{ .err = .{ .code = .internal_server_error } };
        prefixed.append(ctx.allocator, owned) catch
            return .{ .err = .{ .code = .internal_server_error } };
    }
    // Build queue ARN.
    const arn = std.fmt.allocPrint(ctx.allocator, "arn:aws:sqs:{s}:{s}:{s}", .{ ctx.region, ctx.account_id, req.queue_name }) catch
        return .{ .err = .{ .code = .internal_server_error } };
    ctx.backend.addPermission(.{
        .queue_name = req.queue_name,
        .label = req.label,
        .aws_account_ids = req.aws_account_ids,
        .actions = prefixed.items,
        .queue_arn = arn,
    }) catch |err| return .{ .err = mapStorageErr(err) };
    return .{ .ok = .{ .body = "{}" } };
}

pub fn removePermission(ctx: Context) Result {
    const req = wire.parseRemovePermission(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };
    ctx.backend.removePermission(.{
        .queue_name = req.queue_name,
        .label = req.label,
    }) catch |err| return .{ .err = mapStorageErr(err) };
    return .{ .ok = .{ .body = "{}" } };
}

pub fn startMessageMoveTask(ctx: Context) Result {
    const req = wire.parseStartMessageMoveTask(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    // Extract source queue name from the ARN (last segment after the
    // final `:`).
    const src_name = arnTail(req.source_arn) orelse
        return .{ .err = .{ .code = .invalid_parameter_value, .message = "SourceArn is not a valid SQS queue ARN." } };

    // The destination ARN is optional in AWS; when omitted, the
    // service auto-derives it from the source DLQ's redrive-source.
    // For local-dev we require an explicit destination — caller
    // typically passes one.
    var dst_arn: []const u8 = undefined;
    var dst_name: []const u8 = undefined;
    if (req.destination_arn) |d| {
        dst_arn = d;
        dst_name = arnTail(d) orelse
            return .{ .err = .{ .code = .invalid_parameter_value, .message = "DestinationArn is not a valid SQS queue ARN." } };
    } else {
        // Auto-derive: find a source queue whose RedrivePolicy targets
        // this DLQ, and use that source as the destination.
        const sources = ctx.backend.listDeadLetterSourceQueues(ctx.allocator, .{ .dlq_name = src_name }) catch |err|
            return .{ .err = mapStorageErr(err) };
        if (sources.queue_names.len == 0) {
            return .{ .err = .{ .code = .invalid_parameter_value, .message = "Source queue is not configured as a dead-letter queue and no DestinationArn was provided." } };
        }
        dst_name = sources.queue_names[0];
        dst_arn = std.fmt.allocPrint(ctx.allocator, "arn:aws:sqs:{s}:{s}:{s}", .{ ctx.region, ctx.account_id, dst_name }) catch
            return .{ .err = .{ .code = .internal_server_error } };
    }

    const out = ctx.backend.startMessageMoveTask(ctx.allocator, .{
        .source_arn = req.source_arn,
        .source_name = src_name,
        .destination_arn = dst_arn,
        .destination_name = dst_name,
        .max_per_second = req.max_per_second,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const body = wire.renderStartMessageMoveTask(ctx.allocator, out.task_handle) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn cancelMessageMoveTask(ctx: Context) Result {
    const handle = wire.parseCancelMessageMoveTask(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };
    const out = ctx.backend.cancelMessageMoveTask(.{ .task_handle = handle }) catch |err|
        return .{ .err = mapStorageErr(err) };
    const body = wire.renderCancelMessageMoveTask(ctx.allocator, out.approximate_number_of_messages_moved) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn listMessageMoveTasks(ctx: Context) Result {
    const req = wire.parseListMessageMoveTasks(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };
    const out = ctx.backend.listMessageMoveTasks(ctx.allocator, .{
        .source_arn = req.source_arn,
        .max_results = req.max_results orelse 1,
    }) catch |err| return .{ .err = mapStorageErr(err) };
    const body = wire.renderListMessageMoveTasks(ctx.allocator, out) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

/// Extract the last `:`-separated segment of a queue ARN. Returns
/// null if the ARN doesn't have at least one `:`.
fn arnTail(arn: []const u8) ?[]const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, arn, ':') orelse return null;
    if (idx + 1 >= arn.len) return null;
    return arn[idx + 1 ..];
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
