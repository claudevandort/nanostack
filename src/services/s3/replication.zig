//! S3 bucket replication service handlers (M13). Accept-store-roundtrip;
//! no data actually crosses regions.

const std = @import("std");
const repl_wire = @import("../../wire/replication_config.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn putBucketReplication(ctx: Context, bucket: []const u8) Result {
    const cfg = repl_wire.parseBody(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        repl_wire.ParseError.MalformedXml => return .{ .err = .malformed_xml },
        repl_wire.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    defer repl_wire.freeOwned(ctx.allocator, cfg);
    ctx.backend.putBucketReplication(bucket, cfg) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 200, .body = "" } };
}

pub fn getBucketReplication(ctx: Context, bucket: []const u8) Result {
    const cfg = ctx.backend.getBucketReplication(ctx.allocator, bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    defer repl_wire.freeOwned(ctx.allocator, cfg);
    const body = repl_wire.render(ctx.allocator, cfg) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}

pub fn deleteBucketReplication(ctx: Context, bucket: []const u8) Result {
    ctx.backend.deleteBucketReplication(bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 204, .body = "" } };
}
