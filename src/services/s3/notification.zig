//! S3 bucket notification service handlers (M11). Accept-store-roundtrip.
//! No Delete op — empty Put removes.

const std = @import("std");
const notif_wire = @import("../../wire/notification_config.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn putBucketNotification(ctx: Context, bucket: []const u8) Result {
    const cfg = notif_wire.parseBody(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        notif_wire.ParseError.MalformedXml => return .{ .err = .malformed_xml },
        notif_wire.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    defer notif_wire.freeOwned(ctx.allocator, cfg);
    ctx.backend.putBucketNotification(bucket, cfg) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 200, .body = "" } };
}

pub fn getBucketNotification(ctx: Context, bucket: []const u8) Result {
    const cfg = ctx.backend.getBucketNotification(ctx.allocator, bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    defer notif_wire.freeOwned(ctx.allocator, cfg);
    const body = notif_wire.render(ctx.allocator, cfg) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}
