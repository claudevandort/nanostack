//! S3 bucket encryption service handlers (M11). Accept-store-roundtrip.

const std = @import("std");
const enc_wire = @import("../../wire/encryption_config.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn putBucketEncryption(ctx: Context, bucket: []const u8) Result {
    const cfg = enc_wire.parseBody(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        enc_wire.ParseError.MalformedXml => return .{ .err = .malformed_xml },
        enc_wire.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    defer enc_wire.freeOwned(ctx.allocator, cfg);
    ctx.backend.putBucketEncryption(bucket, cfg) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 200, .body = "" } };
}

pub fn getBucketEncryption(ctx: Context, bucket: []const u8) Result {
    const cfg = ctx.backend.getBucketEncryption(ctx.allocator, bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    defer enc_wire.freeOwned(ctx.allocator, cfg);
    const body = enc_wire.render(ctx.allocator, cfg) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}

pub fn deleteBucketEncryption(ctx: Context, bucket: []const u8) Result {
    ctx.backend.deleteBucketEncryption(bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 204, .body = "" } };
}
