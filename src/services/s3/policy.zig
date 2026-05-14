//! S3 bucket policy service handlers (M10). Accept-store-roundtrip,
//! no enforcement.

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const policy_parser = @import("../../wire/policy_parser.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn putBucketPolicy(ctx: Context, bucket: []const u8) Result {
    const owned = policy_parser.parsePolicyJson(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        policy_parser.ParseError.MalformedPolicy => return .{ .err = .malformed_policy },
        policy_parser.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    defer ctx.allocator.free(owned);
    ctx.backend.putBucketPolicy(bucket, owned) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 204, .body = "" } };
}

pub fn getBucketPolicy(ctx: Context, bucket: []const u8) Result {
    const body = ctx.backend.getBucketPolicy(ctx.allocator, bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    const hs = ctx.allocator.dupe(mod.Header, &.{
        .{ .name = "Content-Type", .value = "application/json" },
    }) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body, .extra_headers = hs } };
}

pub fn deleteBucketPolicy(ctx: Context, bucket: []const u8) Result {
    ctx.backend.deleteBucketPolicy(bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 204, .body = "" } };
}
