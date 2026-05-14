//! S3 UpdateObjectEncryption service handler (M13).

const std = @import("std");
const enc_wire = @import("../../wire/object_encryption_update.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn updateObjectEncryption(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const r = enc_wire.parseBody(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        enc_wire.ParseError.MalformedXml => return .{ .err = .malformed_xml },
        enc_wire.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    defer enc_wire.freeOwned(ctx.allocator, r);
    const version_id = mod.queryValue(ctx.allocator, ctx.request.query, "versionId") catch return .{ .err = .internal_error };
    ctx.backend.updateObjectEncryption(bucket, key, version_id, r.algorithm, r.kms_key_id) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 200, .body = "" } };
}
