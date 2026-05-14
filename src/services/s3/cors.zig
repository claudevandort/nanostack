//! S3 bucket CORS service handlers (M11). Accept-store-roundtrip.

const std = @import("std");
const cors_wire = @import("../../wire/cors_config.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn putBucketCors(ctx: Context, bucket: []const u8) Result {
    const cfg = cors_wire.parseBody(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        cors_wire.ParseError.MalformedXml => return .{ .err = .malformed_xml },
        cors_wire.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    defer cors_wire.freeOwned(ctx.allocator, cfg);
    ctx.backend.putBucketCors(bucket, cfg) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 200, .body = "" } };
}

pub fn getBucketCors(ctx: Context, bucket: []const u8) Result {
    const cfg = ctx.backend.getBucketCors(ctx.allocator, bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    defer cors_wire.freeOwned(ctx.allocator, cfg);
    const body = cors_wire.render(ctx.allocator, cfg) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}

pub fn deleteBucketCors(ctx: Context, bucket: []const u8) Result {
    ctx.backend.deleteBucketCors(bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 204, .body = "" } };
}
