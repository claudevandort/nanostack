//! S3 GetBucketPolicyStatus service handler.
//!
//! `IsPublic` is computed by the real evaluator (M14): we synthesise an
//! anonymous request for `s3:GetObject` against the bucket's object
//! resource ARN and ask the policy evaluator whether it would allow.
//! Falls through to a coarse ACL check (`AllUsers` / `AuthenticatedUsers`
//! group grants) when the policy doesn't already say allow.

const std = @import("std");
const ps_wire = @import("../../wire/policy_status.zig");
const policy_doc = @import("../../wire/policy_doc.zig");
const policy_eval = @import("../../auth/policy_eval.zig");
const pab_gate = @import("../../auth/pab_gate.zig");
const principal_mod = @import("../../auth/principal.zig");
const storage = @import("../../storage/mod.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn getBucketPolicyStatus(ctx: Context, bucket: []const u8) Result {
    // AWS contract: NoSuchBucketPolicy when no policy is set.
    const raw = ctx.backend.getBucketPolicy(ctx.allocator, bucket) catch |err|
        return .{ .err = mod.mapStorageErr(err) };

    const is_public = isPolicyPublic(ctx, bucket, raw) catch
        return .{ .err = .internal_error };

    const body = ps_wire.render(ctx.allocator, is_public) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}

fn isPolicyPublic(ctx: Context, bucket: []const u8, raw: []const u8) !bool {
    var doc = policy_doc.parse(ctx.allocator, raw) catch {
        // Malformed persisted policy — surfaces as not-public (safe default;
        // PutBucketPolicy validates so this branch is defensive).
        return false;
    };
    defer doc.deinit(ctx.allocator);

    const resource_arn = try std.fmt.allocPrint(ctx.allocator, "arn:aws:s3:::{s}/*", .{bucket});

    const policy_allows_anonymous = policy_eval.evaluate(doc, .{
        .principal = principal_mod.Principal.anonymous(),
        .action = "s3:GetObject",
        .resource_arn = resource_arn,
    });
    if (policy_allows_anonymous == .allow) return true;

    // Coarse ACL check — IsPublic also reflects public ACL grants.
    const acl = ctx.backend.getBucketAcl(ctx.allocator, bucket) catch return false;
    return pab_gate.aclIsPublicGranting(acl);
}
