//! S3 object legal hold service handlers (M12).

const std = @import("std");
const lh_wire = @import("../../wire/object_legal_hold.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn putObjectLegalHold(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const version_id = mod.queryValue(ctx.allocator, ctx.request.query, "versionId") catch return .{ .err = .internal_error };
    const status = lh_wire.parseBody(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        lh_wire.ParseError.MalformedXml => return .{ .err = .malformed_xml },
        lh_wire.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    ctx.backend.putObjectLegalHold(bucket, key, version_id, status) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 200, .body = "" } };
}

pub fn getObjectLegalHold(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const version_id = mod.queryValue(ctx.allocator, ctx.request.query, "versionId") catch return .{ .err = .internal_error };
    const status = ctx.backend.getObjectLegalHold(bucket, key, version_id) catch |err| return .{ .err = mod.mapStorageErr(err) };
    const body = lh_wire.render(ctx.allocator, status) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}
