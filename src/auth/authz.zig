//! M14 authz hook — orchestrates policy + ACL + PAB evaluators against
//! a parsed request to produce one of two outcomes: `.allow` (let the
//! handler run) or `.deny` (403 AccessDenied).
//!
//! Called by `server.zig` between `router.parse` and `s3.handle`.
//!
//! Evaluation order (AWS-standard, scoped to v1):
//!   1. **Account-scoped ops** (ListBuckets, CreateBucket): only the
//!      configured access_key is allowed; anonymous denied.
//!   2. **Bucket missing** (NoSuchBucket from `getBucketAcl`): anonymous
//!      → deny (info-hiding), owner → allow (handler returns 404).
//!   3. **PAB filters** applied to non-owner principals
//!      (`IgnorePublicAcls`, `RestrictPublicBuckets`).
//!   4. **Bucket policy** evaluation. Allow / Deny short-circuit;
//!      no_match falls through.
//!   5. **ACL** evaluation against the bucket ACL (bucket-scope ops) or
//!      the per-object ACL (object-read ops on an existing object).
//!   6. **Bucket-owner-implicit FULL_CONTROL** fallback.
//!   7. Default: deny.
//!
//! Pure orchestration over the pure-function evaluators in this
//! directory. End-to-end coverage lives in
//! `tests/conformance/python/test_policy_enforcement.py` (Phase 6).

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../storage/mod.zig");
const router = @import("../router.zig");
const principal_mod = @import("principal.zig");
const policy_doc = @import("../wire/policy_doc.zig");
const policy_eval = @import("policy_eval.zig");
const acl_eval = @import("acl_eval.zig");
const pab_gate = @import("pab_gate.zig");
const action_map = @import("action_map.zig");

pub const Decision = enum { allow, deny };

pub const HookContext = struct {
    allocator: Allocator,
    backend: storage.Backend,
    principal: principal_mod.Principal,
    /// Configured bucket-owner identity (from `Context.owner_id`).
    owner_id: []const u8,
    parsed: router.Parsed,
};

pub fn check(ctx: HookContext) Decision {
    const op = ctx.parsed.op;

    // Unrouted ops: skip authz. The service dispatcher emits 501 NotImplemented.
    if (op == .unknown) return .allow;

    // Account-scoped: only the configured access_key may list/create buckets.
    if (action_map.isAccountScoped(op)) {
        if (ctx.principal.kind == .anonymous) return .deny;
        return .allow;
    }

    // Bucket-scope or object-scope: need a bucket name.
    const bucket = ctx.parsed.bucket orelse {
        return if (ctx.principal.kind == .anonymous) .deny else .allow;
    };

    // Fetch bucket access config via existing per-config getters.
    const bucket_acl: storage.Acl = ctx.backend.getBucketAcl(ctx.allocator, bucket) catch |err| switch (err) {
        storage.Error.NoSuchBucket => {
            // Anonymous: 403 (info-hiding). Owner: through to handler for 404.
            return if (ctx.principal.kind == .anonymous) .deny else .allow;
        },
        else => return .deny,
    };

    const policy_raw: ?[]const u8 = ctx.backend.getBucketPolicy(ctx.allocator, bucket) catch |err| switch (err) {
        storage.Error.NoSuchBucketPolicy, storage.Error.NoSuchBucket => null,
        else => return .deny,
    };

    const pab: ?storage.PublicAccessBlockConfig = ctx.backend.getPublicAccessBlock(bucket) catch |err| switch (err) {
        storage.Error.NoSuchPublicAccessBlockConfiguration, storage.Error.NoSuchBucket => null,
        else => return .deny,
    };

    const action = action_map.iamActionFor(op);
    const resource_arn = buildResourceArn(ctx.allocator, bucket, ctx.parsed.key, action_map.isObjectScoped(op)) catch
        return .deny;

    const ignore_public_acls = pab_gate.shouldIgnorePublicAcls(pab, ctx.principal, ctx.owner_id);
    const restrict_public_policy = pab_gate.shouldRestrictPublicBuckets(pab, ctx.principal, ctx.owner_id);

    // 1. Bucket policy.
    if (policy_raw) |raw| {
        var doc = policy_doc.parse(ctx.allocator, raw) catch {
            // Malformed persisted policy — putBucketPolicy validates well-formedness,
            // so this is defensive. Fall through to ACL/owner-implicit.
            return passthroughAclThenOwner(ctx, bucket_acl, action, ignore_public_acls);
        };
        defer doc.deinit(ctx.allocator);

        const eval_ctx: policy_eval.EvalContext = .{
            .principal = ctx.principal,
            .action = action,
            .resource_arn = resource_arn,
        };

        const decision: policy_eval.Decision = if (restrict_public_policy)
            evaluateWithoutPublicAllows(doc, eval_ctx)
        else
            policy_eval.evaluate(doc, eval_ctx);

        switch (decision) {
            .allow => return .allow,
            .deny => return .deny,
            .no_match => {}, // fall through to ACL.
        }
    }

    return passthroughAclThenOwner(ctx, bucket_acl, action, ignore_public_acls);
}

fn passthroughAclThenOwner(
    ctx: HookContext,
    bucket_acl: storage.Acl,
    action: []const u8,
    ignore_public_acls: bool,
) Decision {
    const op = ctx.parsed.op;
    const required = requiredAclPermission(action);

    // Object-read ops on an existing object → object ACL.
    // Object-create ops have no object yet → fall back to bucket ACL.
    const use_object_acl = action_map.isObjectScoped(op) and !isObjectCreatingOp(op);

    const acl: storage.Acl = if (use_object_acl) blk: {
        if (ctx.parsed.key) |key| {
            const oacl = ctx.backend.getObjectAcl(ctx.allocator, ctx.parsed.bucket.?, key, null) catch
                break :blk bucket_acl;
            break :blk oacl;
        }
        break :blk bucket_acl;
    } else bucket_acl;

    // PAB `IgnorePublicAcls`: filter out AllUsers/AuthenticatedUsers grants.
    var filtered_buf: [16]storage.Grant = undefined;
    const grants_to_check: []const storage.Grant = if (ignore_public_acls)
        filterNonPublic(acl.grants, &filtered_buf)
    else
        acl.grants;
    const filtered_acl: storage.Acl = .{ .owner = acl.owner, .grants = grants_to_check };

    if (acl_eval.evaluate(filtered_acl, ctx.principal, required)) return .allow;

    // Bucket-owner-implicit FULL_CONTROL.
    if (ctx.principal.kind == .aws_account and std.mem.eql(u8, ctx.principal.id, ctx.owner_id)) {
        return .allow;
    }

    return .deny;
}

fn buildResourceArn(allocator: Allocator, bucket: []const u8, key: ?[]const u8, object_scope: bool) ![]const u8 {
    if (object_scope) {
        if (key) |k| return std.fmt.allocPrint(allocator, "arn:aws:s3:::{s}/{s}", .{ bucket, k });
    }
    return std.fmt.allocPrint(allocator, "arn:aws:s3:::{s}", .{bucket});
}

fn requiredAclPermission(action: []const u8) storage.Permission {
    // IAM action → ACL permission needed.
    // Anything not mapped here defaults to FULL_CONTROL — only bucket-owner-implicit
    // grants that, so it acts as "ACL can never grant this action" for everyone else.
    if (std.mem.eql(u8, action, "s3:GetObject")) return .READ;
    if (std.mem.eql(u8, action, "s3:GetObjectAttributes")) return .READ;
    if (std.mem.eql(u8, action, "s3:GetObjectTagging")) return .READ;
    if (std.mem.eql(u8, action, "s3:ListBucket")) return .READ;
    if (std.mem.eql(u8, action, "s3:ListBucketVersions")) return .READ;
    if (std.mem.eql(u8, action, "s3:ListBucketMultipartUploads")) return .READ;
    if (std.mem.eql(u8, action, "s3:ListMultipartUploadParts")) return .READ;
    if (std.mem.eql(u8, action, "s3:PutObject")) return .WRITE;
    if (std.mem.eql(u8, action, "s3:DeleteObject")) return .WRITE;
    if (std.mem.eql(u8, action, "s3:AbortMultipartUpload")) return .WRITE;
    if (std.mem.eql(u8, action, "s3:PutObjectTagging")) return .WRITE;
    if (std.mem.eql(u8, action, "s3:DeleteObjectTagging")) return .WRITE;
    if (std.mem.eql(u8, action, "s3:GetObjectAcl")) return .READ_ACP;
    if (std.mem.eql(u8, action, "s3:GetBucketAcl")) return .READ_ACP;
    if (std.mem.eql(u8, action, "s3:PutObjectAcl")) return .WRITE_ACP;
    if (std.mem.eql(u8, action, "s3:PutBucketAcl")) return .WRITE_ACP;
    return .FULL_CONTROL;
}

fn isObjectCreatingOp(op: router.Operation) bool {
    return switch (op) {
        .put_object,
        .create_multipart_upload,
        .upload_part,
        .complete_multipart_upload,
        => true,
        else => false,
    };
}

/// Strip statements with `Effect: Allow` + `Principal: "*"` before
/// evaluating — `RestrictPublicBuckets` semantics for non-owners.
fn evaluateWithoutPublicAllows(doc: policy_doc.PolicyDocument, ctx: policy_eval.EvalContext) policy_eval.Decision {
    var stripped: [64]policy_doc.Statement = undefined;
    var len: usize = 0;
    for (doc.statements) |s| {
        if (s.effect == .allow and s.principal == .wildcard) continue;
        if (len >= stripped.len) break;
        stripped[len] = s;
        len += 1;
    }
    return policy_eval.evaluate(.{ .statements = stripped[0..len] }, ctx);
}

fn filterNonPublic(grants: []const storage.Grant, buf: []storage.Grant) []const storage.Grant {
    var len: usize = 0;
    for (grants) |g| {
        if (g.grantee.kind == .group) {
            if (std.mem.eql(u8, g.grantee.uri, storage.group_all_users)) continue;
            if (std.mem.eql(u8, g.grantee.uri, storage.group_authenticated_users)) continue;
        }
        if (len >= buf.len) break;
        buf[len] = g;
        len += 1;
    }
    return buf[0..len];
}
