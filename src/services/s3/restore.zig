//! S3 RestoreObject service handler (M13).

const std = @import("std");
const restore_wire = @import("../../wire/restore_request.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn restoreObject(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const days = restore_wire.parseBody(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        restore_wire.ParseError.MalformedXml => return .{ .err = .malformed_xml },
        restore_wire.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    const version_id = mod.queryValue(ctx.allocator, ctx.request.query, "versionId") catch return .{ .err = .internal_error };
    ctx.backend.restoreObject(bucket, key, version_id, days) catch |err| return .{ .err = mod.mapStorageErr(err) };
    // AWS-exact: 202 Accepted for a new restore request. We don't model the
    // 200-vs-202 distinction for "already-restored"; always 202.
    return .{ .ok = .{ .status = 202, .body = "" } };
}
