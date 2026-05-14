//! S3 PublicAccessBlock service handlers (M10). Accept-store-roundtrip.

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const pab_wire = @import("../../wire/public_access_block.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn putPublicAccessBlock(ctx: Context, bucket: []const u8) Result {
    const pab = pab_wire.parse(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        pab_wire.ParseError.MalformedAcl => return .{ .err = .malformed_acl_error },
        pab_wire.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    ctx.backend.putPublicAccessBlock(bucket, pab) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 200, .body = "" } };
}

pub fn getPublicAccessBlock(ctx: Context, bucket: []const u8) Result {
    const pab = ctx.backend.getPublicAccessBlock(bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    const body = pab_wire.render(ctx.allocator, pab) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}

pub fn deletePublicAccessBlock(ctx: Context, bucket: []const u8) Result {
    ctx.backend.deletePublicAccessBlock(bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 204, .body = "" } };
}
