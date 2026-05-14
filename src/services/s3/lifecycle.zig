//! S3 bucket lifecycle service handlers (M11). Accept-store-roundtrip.

const std = @import("std");
const lifecycle_wire = @import("../../wire/lifecycle_config.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn putBucketLifecycle(ctx: Context, bucket: []const u8) Result {
    const cfg = lifecycle_wire.parseBody(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        lifecycle_wire.ParseError.MalformedXml => return .{ .err = .malformed_xml },
        lifecycle_wire.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    defer lifecycle_wire.freeOwned(ctx.allocator, cfg);
    ctx.backend.putBucketLifecycle(bucket, cfg) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 200, .body = "" } };
}

pub fn getBucketLifecycle(ctx: Context, bucket: []const u8) Result {
    const cfg = ctx.backend.getBucketLifecycle(ctx.allocator, bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    defer lifecycle_wire.freeOwned(ctx.allocator, cfg);
    const body = lifecycle_wire.render(ctx.allocator, cfg) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}

pub fn deleteBucketLifecycle(ctx: Context, bucket: []const u8) Result {
    ctx.backend.deleteBucketLifecycle(bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 204, .body = "" } };
}
