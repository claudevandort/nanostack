//! S3 bucket policy service handlers.

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const policy_parser = @import("../../wire/policy_parser.zig");
const policy_doc = @import("../../wire/policy_doc.zig");
const pab_gate = @import("../../auth/pab_gate.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn putBucketPolicy(ctx: Context, bucket: []const u8) Result {
    const owned = policy_parser.parsePolicyJson(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        policy_parser.ParseError.MalformedPolicy => return .{ .err = .malformed_policy },
        policy_parser.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    defer ctx.allocator.free(owned);

    // PAB admission gate: reject a public-granting policy when
    // BlockPublicPolicy is on for this bucket. We use the structured
    // parser to detect "Allow + Principal:*" statements precisely.
    const pab = ctx.backend.getPublicAccessBlock(bucket) catch |err| switch (err) {
        storage.Error.NoSuchPublicAccessBlockConfiguration, storage.Error.NoSuchBucket => null,
        else => return .{ .err = mod.mapStorageErr(err) },
    };
    if (pab) |cfg| {
        if (cfg.block_public_policy) {
            var doc = policy_doc.parse(ctx.allocator, owned) catch return .{ .err = .malformed_policy };
            defer doc.deinit(ctx.allocator);
            pab_gate.gatePolicyPut(doc, cfg) catch return .{ .err = .access_denied };
        }
    }

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
