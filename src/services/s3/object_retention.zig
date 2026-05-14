//! S3 object retention service handlers (M12).

const std = @import("std");
const retention_wire = @import("../../wire/object_retention.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn putObjectRetention(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const version_id = mod.queryValue(ctx.allocator, ctx.request.query, "versionId") catch return .{ .err = .internal_error };
    const r = retention_wire.parseBody(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        retention_wire.ParseError.MalformedXml => return .{ .err = .malformed_xml },
        retention_wire.ParseError.InvalidRetentionPeriod => return .{ .err = .invalid_retention_period },
        retention_wire.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    const bypass = blk: {
        const hv = mod.findHeader(ctx.request.headers, "x-amz-bypass-governance-retention") orelse break :blk false;
        break :blk std.ascii.eqlIgnoreCase(hv, "true");
    };
    ctx.backend.putObjectRetention(bucket, key, version_id, r, bypass) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 200, .body = "" } };
}

pub fn getObjectRetention(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const version_id = mod.queryValue(ctx.allocator, ctx.request.query, "versionId") catch return .{ .err = .internal_error };
    const r = ctx.backend.getObjectRetention(bucket, key, version_id) catch |err| return .{ .err = mod.mapStorageErr(err) };
    const body = retention_wire.render(ctx.allocator, r) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}
