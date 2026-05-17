//! DynamoDBStreams sub-service handlers (v0.2.2).
//!
//! Four ops: ListStreams, DescribeStream, GetShardIterator, GetRecords.
//! Wire layer at `wire/dynamodb/streams.zig`. Storage layer drives the
//! actual ring buffer; this file is the thin glue.

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const wire = @import("../../wire/dynamodb/streams.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;
const ErrorBody = mod.ErrorBody;

pub fn listStreams(ctx: Context) Result {
    const req = wire.parseListStreams(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    var out = ctx.backend.listStreams(ctx.allocator, .{
        .table_name = req.table_name,
        .limit = req.limit orelse 100,
        .exclusive_start_stream_arn = req.exclusive_start_stream_arn,
        .region = ctx.region,
    }) catch |err| return .{ .err = mapStorageErr(err) };
    _ = &out;

    const body = wire.renderListStreams(ctx.allocator, out) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn describeStream(ctx: Context) Result {
    const req = wire.parseDescribeStream(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    const out = ctx.backend.describeStream(ctx.allocator, .{
        .arn = req.arn,
        .limit = req.limit orelse 100,
        .exclusive_start_shard_id = req.exclusive_start_shard_id,
        .region = ctx.region,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const body = wire.renderDescribeStream(ctx.allocator, out) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn getShardIterator(ctx: Context) Result {
    const in = wire.parseGetShardIterator(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    const iterator = ctx.backend.getShardIterator(ctx.allocator, in) catch |err|
        return .{ .err = mapStorageErr(err) };

    const body = wire.renderGetShardIterator(ctx.allocator, iterator) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn getRecords(ctx: Context) Result {
    const in = wire.parseGetRecords(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    const out = ctx.backend.getRecords(ctx.allocator, in) catch |err|
        return .{ .err = mapStorageErr(err) };

    const body = wire.renderGetRecords(ctx.allocator, out) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

fn mapParseErr(e: wire.ParseError) ErrorBody {
    return switch (e) {
        wire.ParseError.OutOfMemory => .{ .code = .internal_server_error },
        wire.ParseError.Malformed => .{ .code = .validation_exception, .message = "Could not parse the request body as JSON." },
        wire.ParseError.InvalidLimit => .{ .code = .validation_exception, .message = "Limit out of range." },
        wire.ParseError.InvalidIteratorType => .{ .code = .validation_exception, .message = "ShardIteratorType must be TRIM_HORIZON, LATEST, AT_SEQUENCE_NUMBER, or AFTER_SEQUENCE_NUMBER." },
    };
}

fn mapStorageErr(e: storage.Error) ErrorBody {
    return switch (e) {
        storage.Error.StreamNotFound => .{ .code = .resource_not_found_exception },
        storage.Error.ShardNotFound => .{ .code = .resource_not_found_exception },
        storage.Error.InvalidStreamArn => .{ .code = .validation_exception, .message = "Invalid StreamArn." },
        storage.Error.InvalidShardIterator => .{ .code = .validation_exception, .message = "Invalid ShardIterator." },
        storage.Error.OutOfMemory => .{ .code = .internal_server_error },
        storage.Error.Io => .{ .code = .internal_server_error },
        else => .{ .code = .internal_server_error },
    };
}
