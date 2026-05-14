//! S3 Object Lock configuration service handlers (M12).

const std = @import("std");
const olc_wire = @import("../../wire/object_lock_config.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn putObjectLockConfig(ctx: Context, bucket: []const u8) Result {
    const cfg = olc_wire.parseBody(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        olc_wire.ParseError.MalformedXml => return .{ .err = .malformed_xml },
        olc_wire.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    ctx.backend.putObjectLockConfig(bucket, cfg) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 200, .body = "" } };
}

pub fn getObjectLockConfig(ctx: Context, bucket: []const u8) Result {
    const cfg = ctx.backend.getObjectLockConfig(ctx.allocator, bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    const body = olc_wire.render(ctx.allocator, cfg) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}
