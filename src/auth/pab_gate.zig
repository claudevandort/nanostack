//! Public Access Block (PAB) gating.
//!
//! Two distinct moments:
//!   - **Put-time gate**: when a client tries to `PutBucketPolicy` /
//!     `PutBucketAcl` with a public-granting body and the corresponding
//!     PAB switch is on, reject the put with `AccessDenied`. Used by
//!     handlers BEFORE persistence.
//!   - **Eval-time filter**: when evaluating access for an anonymous /
//!     non-owner principal, hide public-granting statements and grants
//!     per `IgnorePublicAcls` / `RestrictPublicBuckets`. Used by the
//!     authz hook AFTER fetching the persisted bucket-access-config.
//!
//! "Public-granting" definitions (matching AWS docs):
//!   - **Policy**: any statement with `Effect: Allow` AND
//!     `Principal: "*"` (or `{"AWS": "*"}`). NotPrincipal-bearing
//!     statements aren't considered public.
//!   - **ACL**: any grant whose grantee is the `AllUsers` group, OR the
//!     `AuthenticatedUsers` group. (AWS treats AuthenticatedUsers as
//!     public because "any AWS customer" is broad.)

const std = @import("std");
const storage = @import("../storage/mod.zig");
const policy_doc = @import("../wire/policy_doc.zig");
const principal_mod = @import("principal.zig");

// ---------------------------------------------------------------------------
// "Is public-granting?" predicates

pub fn policyIsPublicGranting(policy: policy_doc.PolicyDocument) bool {
    for (policy.statements) |stmt| {
        if (stmt.has_condition or stmt.has_unsupported) continue;
        if (stmt.effect != .allow) continue;
        if (stmt.principal == .wildcard) return true;
    }
    return false;
}

pub fn aclIsPublicGranting(acl: storage.Acl) bool {
    for (acl.grants) |grant| {
        if (grant.grantee.kind != .group) continue;
        if (std.mem.eql(u8, grant.grantee.uri, storage.group_all_users)) return true;
        if (std.mem.eql(u8, grant.grantee.uri, storage.group_authenticated_users)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Put-time gates

pub const GateError = error{AccessDenied};

/// Reject a PutBucketPolicy if it would publicly-grant AND
/// `block_public_policy` is on.
pub fn gatePolicyPut(policy: policy_doc.PolicyDocument, pab: ?storage.PublicAccessBlockConfig) GateError!void {
    const cfg = pab orelse return;
    if (!cfg.block_public_policy) return;
    if (policyIsPublicGranting(policy)) return GateError.AccessDenied;
}

/// Reject a PutBucketAcl / PutObjectAcl if it would publicly-grant AND
/// `block_public_acls` is on.
pub fn gateAclPut(acl: storage.Acl, pab: ?storage.PublicAccessBlockConfig) GateError!void {
    const cfg = pab orelse return;
    if (!cfg.block_public_acls) return;
    if (aclIsPublicGranting(acl)) return GateError.AccessDenied;
}

// ---------------------------------------------------------------------------
// Eval-time filters

/// True if PAB says we should ignore public-ACL grants when evaluating
/// access for `who` (non-bucket-owner). Bucket-owner bypasses PAB.
pub fn shouldIgnorePublicAcls(pab: ?storage.PublicAccessBlockConfig, who: principal_mod.Principal, owner_id: []const u8) bool {
    const cfg = pab orelse return false;
    if (!cfg.ignore_public_acls) return false;
    // Bucket owner bypasses IgnorePublicAcls (per AWS docs).
    if (who.kind == .aws_account and std.mem.eql(u8, who.id, owner_id)) return false;
    return true;
}

/// True if PAB says we should strip public-policy statements when
/// evaluating access for `who`. Bucket-owner bypasses.
pub fn shouldRestrictPublicBuckets(pab: ?storage.PublicAccessBlockConfig, who: principal_mod.Principal, owner_id: []const u8) bool {
    const cfg = pab orelse return false;
    if (!cfg.restrict_public_buckets) return false;
    if (who.kind == .aws_account and std.mem.eql(u8, who.id, owner_id)) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Principal = principal_mod.Principal;

fn parsePolicy(body: []const u8) !policy_doc.PolicyDocument {
    return try policy_doc.parse(testing.allocator, body);
}

fn aclWith(grants: []const storage.Grant) storage.Acl {
    return .{
        .owner = .{ .id = storage.default_owner_id, .display_name = storage.default_owner_display_name },
        .grants = grants,
    };
}

test "policyIsPublicGranting: Principal:* Effect:Allow → true" {
    var doc = try parsePolicy(
        \\{"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"*"}]}
    );
    defer doc.deinit(testing.allocator);
    try testing.expect(policyIsPublicGranting(doc));
}

test "policyIsPublicGranting: Principal:* Effect:Deny → false (Deny isn't 'granting')" {
    var doc = try parsePolicy(
        \\{"Statement":[{"Effect":"Deny","Principal":"*","Action":"s3:*","Resource":"*"}]}
    );
    defer doc.deinit(testing.allocator);
    try testing.expect(!policyIsPublicGranting(doc));
}

test "policyIsPublicGranting: specific Principal → false" {
    var doc = try parsePolicy(
        \\{"Statement":[{"Effect":"Allow","Principal":{"AWS":"test"},"Action":"s3:*","Resource":"*"}]}
    );
    defer doc.deinit(testing.allocator);
    try testing.expect(!policyIsPublicGranting(doc));
}

test "policyIsPublicGranting: Condition skips → false" {
    var doc = try parsePolicy(
        \\{"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:*","Resource":"*","Condition":{"StringEquals":{"aws:Referer":"x"}}}]}
    );
    defer doc.deinit(testing.allocator);
    try testing.expect(!policyIsPublicGranting(doc));
}

test "aclIsPublicGranting: AllUsers grant → true" {
    const grants = [_]storage.Grant{
        .{ .grantee = .{ .kind = .group, .uri = storage.group_all_users }, .permission = .READ },
    };
    try testing.expect(aclIsPublicGranting(aclWith(&grants)));
}

test "aclIsPublicGranting: AuthenticatedUsers grant → true" {
    const grants = [_]storage.Grant{
        .{ .grantee = .{ .kind = .group, .uri = storage.group_authenticated_users }, .permission = .READ },
    };
    try testing.expect(aclIsPublicGranting(aclWith(&grants)));
}

test "aclIsPublicGranting: CanonicalUser only → false" {
    const grants = [_]storage.Grant{
        .{ .grantee = .{ .kind = .canonical_user, .id = "test" }, .permission = .FULL_CONTROL },
    };
    try testing.expect(!aclIsPublicGranting(aclWith(&grants)));
}

test "gatePolicyPut: BlockPublicPolicy=true + public-granting → AccessDenied" {
    var doc = try parsePolicy(
        \\{"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:*","Resource":"*"}]}
    );
    defer doc.deinit(testing.allocator);
    try testing.expectError(GateError.AccessDenied, gatePolicyPut(doc, .{ .block_public_policy = true }));
}

test "gatePolicyPut: BlockPublicPolicy=true + private-policy → OK" {
    var doc = try parsePolicy(
        \\{"Statement":[{"Effect":"Allow","Principal":{"AWS":"test"},"Action":"s3:*","Resource":"*"}]}
    );
    defer doc.deinit(testing.allocator);
    try gatePolicyPut(doc, .{ .block_public_policy = true });
}

test "gatePolicyPut: PAB null → never blocks" {
    var doc = try parsePolicy(
        \\{"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:*","Resource":"*"}]}
    );
    defer doc.deinit(testing.allocator);
    try gatePolicyPut(doc, null);
}

test "gateAclPut: BlockPublicAcls=true + AllUsers grant → AccessDenied" {
    const grants = [_]storage.Grant{
        .{ .grantee = .{ .kind = .group, .uri = storage.group_all_users }, .permission = .READ },
    };
    try testing.expectError(GateError.AccessDenied, gateAclPut(aclWith(&grants), .{ .block_public_acls = true }));
}

test "gateAclPut: BlockPublicAcls=true + canonical only → OK" {
    const grants = [_]storage.Grant{
        .{ .grantee = .{ .kind = .canonical_user, .id = "test" }, .permission = .FULL_CONTROL },
    };
    try gateAclPut(aclWith(&grants), .{ .block_public_acls = true });
}

test "shouldIgnorePublicAcls: anonymous + ignore_public_acls=true → true" {
    try testing.expect(shouldIgnorePublicAcls(.{ .ignore_public_acls = true }, Principal.anonymous(), "owner"));
}

test "shouldIgnorePublicAcls: bucket owner bypasses" {
    try testing.expect(!shouldIgnorePublicAcls(.{ .ignore_public_acls = true }, Principal.awsAccount("owner"), "owner"));
}

test "shouldIgnorePublicAcls: switch off → false" {
    try testing.expect(!shouldIgnorePublicAcls(.{ .ignore_public_acls = false }, Principal.anonymous(), "owner"));
}

test "shouldIgnorePublicAcls: PAB null → false" {
    try testing.expect(!shouldIgnorePublicAcls(null, Principal.anonymous(), "owner"));
}

test "shouldRestrictPublicBuckets: anonymous + on → true" {
    try testing.expect(shouldRestrictPublicBuckets(.{ .restrict_public_buckets = true }, Principal.anonymous(), "owner"));
}

test "shouldRestrictPublicBuckets: bucket owner bypasses" {
    try testing.expect(!shouldRestrictPublicBuckets(.{ .restrict_public_buckets = true }, Principal.awsAccount("owner"), "owner"));
}
