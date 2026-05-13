//! Bucket-versioning service handlers (M8).
//!
//! Three operations: PutBucketVersioning, GetBucketVersioning,
//! ListObjectVersions. Per-object version-id query threading lives in
//! the existing GET/HEAD/DELETE handlers in `mod.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const errors = @import("../../wire/errors.zig");
const versioning_responses = @import("../../wire/versioning_responses.zig");
const versioning_config_parser = @import("../../wire/versioning_config_parser.zig");
const list_object_versions = @import("../../wire/list_object_versions.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn putBucketVersioning(ctx: Context, bucket: []const u8) Result {
    const status = versioning_config_parser.parse(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        versioning_config_parser.ParseError.InvalidBody => return .{ .err = .invalid_request },
        versioning_config_parser.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    ctx.backend.putBucketVersioning(bucket, status) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 200, .body = "" } };
}

pub fn getBucketVersioning(ctx: Context, bucket: []const u8) Result {
    const status = ctx.backend.getBucketVersioning(bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    const body = versioning_responses.renderGetBucketVersioning(ctx.allocator, status) catch
        return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}

pub fn listObjectVersions(ctx: Context, bucket: []const u8) Result {
    var echo: list_object_versions.Echo = .{};
    const q = ctx.request.query;

    if (mod.queryValue(ctx.allocator, q, "prefix") catch return .{ .err = .internal_error }) |v| echo.prefix = v;
    if (mod.queryValue(ctx.allocator, q, "delimiter") catch return .{ .err = .internal_error }) |v| echo.delimiter = v;
    if (mod.queryValue(ctx.allocator, q, "key-marker") catch return .{ .err = .internal_error }) |v| echo.key_marker = v;
    if (mod.queryValue(ctx.allocator, q, "version-id-marker") catch return .{ .err = .internal_error }) |v| echo.version_id_marker = v;
    if (mod.queryValue(ctx.allocator, q, "encoding-type") catch return .{ .err = .internal_error }) |v| {
        if (!std.mem.eql(u8, v, "url")) return .{ .err = .invalid_argument };
        echo.encoding_type = v;
    }
    if (mod.queryValue(ctx.allocator, q, "max-keys") catch return .{ .err = .internal_error }) |v| {
        const parsed = std.fmt.parseInt(u32, v, 10) catch return .{ .err = .invalid_argument };
        echo.max_keys = if (parsed > 1000) 1000 else parsed;
    }

    const result = ctx.backend.listObjectVersions(ctx.allocator, .{
        .bucket = bucket,
        .prefix = echo.prefix,
        .delimiter = echo.delimiter,
        .key_marker = echo.key_marker,
        .version_id_marker = echo.version_id_marker,
        .max_keys = echo.max_keys,
    }) catch |err| return .{ .err = mod.mapStorageErr(err) };

    const body = list_object_versions.renderListVersionsResult(ctx.allocator, bucket, echo, result) catch
        return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}
