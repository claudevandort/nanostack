//! ACL evaluator: does this ACL grant `required` permission to `who`?
//!
//! AWS S3 ACL semantics:
//!   - `FULL_CONTROL` implies `READ` + `WRITE` + `READ_ACP` + `WRITE_ACP`.
//!   - Group URIs:
//!     * `AllUsers` — matches anonymous AND any authenticated principal.
//!     * `AuthenticatedUsers` — matches any authenticated principal,
//!       never anonymous.
//!   - `CanonicalUser` — exact id match against the configured access_key.
//!   - `AmazonCustomerByEmail` — not supported (single-tenant, no email
//!     lookup); never matches.

const std = @import("std");
const storage = @import("../storage/mod.zig");
const principal_mod = @import("principal.zig");

/// True if `acl` grants `required` permission to `who`.
///
/// Bucket-owner-implicit FULL_CONTROL is NOT applied here — the caller
/// (the authz hook) applies that fallback after the ACL says no_match.
pub fn evaluate(acl: storage.Acl, who: principal_mod.Principal, required: storage.Permission) bool {
    for (acl.grants) |grant| {
        if (!granteeMatches(grant.grantee, who)) continue;
        if (permissionImplies(grant.permission, required)) return true;
    }
    return false;
}

fn granteeMatches(grantee: storage.Grantee, who: principal_mod.Principal) bool {
    switch (grantee.kind) {
        .canonical_user => {
            // Canonical-user grants don't match anonymous.
            if (who.kind == .anonymous) return false;
            return std.mem.eql(u8, grantee.id, who.id);
        },
        .group => {
            if (std.mem.eql(u8, grantee.uri, storage.group_all_users)) return true;
            if (std.mem.eql(u8, grantee.uri, storage.group_authenticated_users)) {
                return who.kind == .aws_account;
            }
            // LogDelivery + any other group: not granting access to ordinary requests.
            return false;
        },
        .amazon_customer_by_email => {
            // Single-tenant emulator can't resolve emails; never match.
            return false;
        },
    }
}

/// `granted` permission implies `required` if they're identical or
/// `granted` is FULL_CONTROL (which subsumes everything).
fn permissionImplies(granted: storage.Permission, required: storage.Permission) bool {
    if (granted == .FULL_CONTROL) return true;
    return granted == required;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Principal = principal_mod.Principal;

fn aclWith(grants: []const storage.Grant) storage.Acl {
    return .{
        .owner = .{ .id = storage.default_owner_id, .display_name = storage.default_owner_display_name },
        .grants = grants,
    };
}

test "evaluate: AllUsers READ matches anonymous READ" {
    const grants = [_]storage.Grant{
        .{ .grantee = .{ .kind = .group, .uri = storage.group_all_users }, .permission = .READ },
    };
    try testing.expect(evaluate(aclWith(&grants), Principal.anonymous(), .READ));
}

test "evaluate: AllUsers READ also matches authenticated READ" {
    const grants = [_]storage.Grant{
        .{ .grantee = .{ .kind = .group, .uri = storage.group_all_users }, .permission = .READ },
    };
    try testing.expect(evaluate(aclWith(&grants), Principal.awsAccount("test"), .READ));
}

test "evaluate: AllUsers READ does NOT grant WRITE" {
    const grants = [_]storage.Grant{
        .{ .grantee = .{ .kind = .group, .uri = storage.group_all_users }, .permission = .READ },
    };
    try testing.expect(!evaluate(aclWith(&grants), Principal.anonymous(), .WRITE));
}

test "evaluate: AuthenticatedUsers does NOT match anonymous" {
    const grants = [_]storage.Grant{
        .{ .grantee = .{ .kind = .group, .uri = storage.group_authenticated_users }, .permission = .READ },
    };
    try testing.expect(!evaluate(aclWith(&grants), Principal.anonymous(), .READ));
    try testing.expect(evaluate(aclWith(&grants), Principal.awsAccount("test"), .READ));
}

test "evaluate: FULL_CONTROL implies READ + WRITE + READ_ACP + WRITE_ACP" {
    const grants = [_]storage.Grant{
        .{ .grantee = .{ .kind = .group, .uri = storage.group_all_users }, .permission = .FULL_CONTROL },
    };
    try testing.expect(evaluate(aclWith(&grants), Principal.anonymous(), .READ));
    try testing.expect(evaluate(aclWith(&grants), Principal.anonymous(), .WRITE));
    try testing.expect(evaluate(aclWith(&grants), Principal.anonymous(), .READ_ACP));
    try testing.expect(evaluate(aclWith(&grants), Principal.anonymous(), .WRITE_ACP));
}

test "evaluate: CanonicalUser exact match" {
    const grants = [_]storage.Grant{
        .{ .grantee = .{ .kind = .canonical_user, .id = "test", .display_name = "x" }, .permission = .READ },
    };
    try testing.expect(evaluate(aclWith(&grants), Principal.awsAccount("test"), .READ));
    try testing.expect(!evaluate(aclWith(&grants), Principal.awsAccount("other"), .READ));
    try testing.expect(!evaluate(aclWith(&grants), Principal.anonymous(), .READ));
}

test "evaluate: empty grants → no permissions" {
    const grants = [_]storage.Grant{};
    try testing.expect(!evaluate(aclWith(&grants), Principal.anonymous(), .READ));
    try testing.expect(!evaluate(aclWith(&grants), Principal.awsAccount("test"), .READ));
}

test "evaluate: AmazonCustomerByEmail never matches (single-tenant)" {
    const grants = [_]storage.Grant{
        .{ .grantee = .{ .kind = .amazon_customer_by_email, .email_address = "x@y" }, .permission = .READ },
    };
    try testing.expect(!evaluate(aclWith(&grants), Principal.awsAccount("test"), .READ));
}

test "evaluate: LogDelivery group does not grant ordinary READ" {
    const grants = [_]storage.Grant{
        .{ .grantee = .{ .kind = .group, .uri = storage.group_log_delivery }, .permission = .WRITE },
    };
    try testing.expect(!evaluate(aclWith(&grants), Principal.awsAccount("test"), .WRITE));
}
