//! S3 bucket ownership controls service handlers (M10).
//! Accept-store-roundtrip.

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const oc_wire = @import("../../wire/ownership_controls.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn putBucketOwnershipControls(ctx: Context, bucket: []const u8) Result {
    const oc = oc_wire.parse(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        oc_wire.ParseError.MalformedAcl => return .{ .err = .malformed_acl_error },
        oc_wire.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    ctx.backend.putBucketOwnershipControls(bucket, oc) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 200, .body = "" } };
}

pub fn getBucketOwnershipControls(ctx: Context, bucket: []const u8) Result {
    const oc = ctx.backend.getBucketOwnershipControls(bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    const body = oc_wire.render(ctx.allocator, oc) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}

pub fn deleteBucketOwnershipControls(ctx: Context, bucket: []const u8) Result {
    ctx.backend.deleteBucketOwnershipControls(bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 204, .body = "" } };
}
