//! S3 GetBucketPolicyStatus service handler (M13).

const std = @import("std");
const ps_wire = @import("../../wire/policy_status.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn getBucketPolicyStatus(ctx: Context, bucket: []const u8) Result {
    const is_public = ctx.backend.getBucketPolicyStatus(bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    const body = ps_wire.render(ctx.allocator, is_public) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}
