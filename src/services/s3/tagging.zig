//! S3 tagging service handlers (M9).
//!
//! 6 handlers: Put/Get/Delete on bucket and object. Object-tagging
//! handlers thread the optional `?versionId=X` query through to the
//! backend (M8 versioning interaction).

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const tagging_parser = @import("../../wire/tagging_parser.zig");
const tagging_responses = @import("../../wire/tagging_responses.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

// ---------------------------------------------------------------------------
// Bucket-level

pub fn putBucketTagging(ctx: Context, bucket: []const u8) Result {
    const tags = tagging_parser.parseBody(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        tagging_parser.ParseError.InvalidBody => return .{ .err = .invalid_request },
        tagging_parser.ParseError.InvalidTag => return .{ .err = .invalid_tag },
        tagging_parser.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    defer tagging_parser.freeOwned(ctx.allocator, tags);
    ctx.backend.putBucketTagging(bucket, tags) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 200, .body = "" } };
}

pub fn getBucketTagging(ctx: Context, bucket: []const u8) Result {
    const tags = ctx.backend.getBucketTagging(ctx.allocator, bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    const body = tagging_responses.renderTagging(ctx.allocator, tags) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}

pub fn deleteBucketTagging(ctx: Context, bucket: []const u8) Result {
    ctx.backend.deleteBucketTagging(bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 204, .body = "" } };
}

// ---------------------------------------------------------------------------
// Object-level

pub fn putObjectTagging(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const version_id = mod.queryValue(ctx.allocator, ctx.request.query, "versionId") catch return .{ .err = .internal_error };
    const tags = tagging_parser.parseBody(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        tagging_parser.ParseError.InvalidBody => return .{ .err = .invalid_request },
        tagging_parser.ParseError.InvalidTag => return .{ .err = .invalid_tag },
        tagging_parser.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    defer tagging_parser.freeOwned(ctx.allocator, tags);
    ctx.backend.putObjectTagging(bucket, key, version_id, tags) catch |err| return .{ .err = mod.mapStorageErr(err) };

    // Versioned response carries `x-amz-version-id`.
    if (version_id) |vid| {
        const hs = ctx.allocator.dupe(mod.Header, &.{
            .{ .name = "x-amz-version-id", .value = vid },
        }) catch return .{ .err = .internal_error };
        return .{ .ok = .{ .status = 200, .body = "", .extra_headers = hs } };
    }
    return .{ .ok = .{ .status = 200, .body = "" } };
}

pub fn getObjectTagging(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const version_id = mod.queryValue(ctx.allocator, ctx.request.query, "versionId") catch return .{ .err = .internal_error };
    const tags = ctx.backend.getObjectTagging(ctx.allocator, bucket, key, version_id) catch |err| return .{ .err = mod.mapStorageErr(err) };
    const body = tagging_responses.renderTagging(ctx.allocator, tags) catch return .{ .err = .internal_error };
    if (version_id) |vid| {
        const hs = ctx.allocator.dupe(mod.Header, &.{
            .{ .name = "x-amz-version-id", .value = vid },
        }) catch return .{ .err = .internal_error };
        return .{ .ok = .{ .status = 200, .body = body, .extra_headers = hs } };
    }
    return .{ .ok = .{ .status = 200, .body = body } };
}

pub fn deleteObjectTagging(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const version_id = mod.queryValue(ctx.allocator, ctx.request.query, "versionId") catch return .{ .err = .internal_error };
    ctx.backend.deleteObjectTagging(bucket, key, version_id) catch |err| return .{ .err = mod.mapStorageErr(err) };
    if (version_id) |vid| {
        const hs = ctx.allocator.dupe(mod.Header, &.{
            .{ .name = "x-amz-version-id", .value = vid },
        }) catch return .{ .err = .internal_error };
        return .{ .ok = .{ .status = 204, .body = "", .extra_headers = hs } };
    }
    return .{ .ok = .{ .status = 204, .body = "" } };
}
