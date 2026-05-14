//! S3 bucket website service handlers (M11). Accept-store-roundtrip.

const std = @import("std");
const website_wire = @import("../../wire/website_config.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn putBucketWebsite(ctx: Context, bucket: []const u8) Result {
    const cfg = website_wire.parseBody(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        website_wire.ParseError.MalformedXml => return .{ .err = .malformed_xml },
        website_wire.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    defer website_wire.freeOwned(ctx.allocator, cfg);
    ctx.backend.putBucketWebsite(bucket, cfg) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 200, .body = "" } };
}

pub fn getBucketWebsite(ctx: Context, bucket: []const u8) Result {
    const cfg = ctx.backend.getBucketWebsite(ctx.allocator, bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    defer website_wire.freeOwned(ctx.allocator, cfg);
    const body = website_wire.render(ctx.allocator, cfg) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}

pub fn deleteBucketWebsite(ctx: Context, bucket: []const u8) Result {
    ctx.backend.deleteBucketWebsite(bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 204, .body = "" } };
}
