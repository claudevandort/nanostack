//! Parsers for the three forms of S3 ACL input (M10):
//!
//! 1. **XML body** — `<AccessControlPolicy>` used by PutBucketAcl /
//!    PutObjectAcl.
//! 2. **`x-amz-acl` canned header** — short string ("private",
//!    "public-read", ...) used on the ACL Puts and on write paths
//!    (PutObject, CopyObject, CreateMultipartUpload).
//! 3. **`x-amz-grant-*` headers** — five comma-separated grantee
//!    specifications (one header per Permission).
//!
//! Outputs the canonical `storage.Acl` (Owner + Grants). nanostack does
//! not enforce ACLs; everything that comes through here is persisted and
//! round-tripped through Get. Wire-level validation is light: structural
//! well-formedness only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml");
const storage = @import("../storage/mod.zig");

pub const ParseError = error{
    MalformedAcl,
    UnknownCannedAcl,
    OutOfMemory,
};

pub fn parseCanned(value: []const u8) error{UnknownCannedAcl}!storage.CannedAcl {
    return storage.parseCannedAcl(value);
}

/// Parse the XML body of PutBucketAcl / PutObjectAcl. Caller owns the
/// returned Acl + every string within (use `freeAclOwned`).
///
/// Namespace-awareness is disabled because real AWS request bodies often
/// emit `xsi:type="..."` without a matching `xmlns:xsi` declaration; the
/// strict namespace-aware reader would reject those. We accept either.
pub fn parseBody(allocator: Allocator, body: []const u8) ParseError!storage.Acl {
    var static_reader: xml.Reader.Static = .init(allocator, body, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var owner_id: ?[]u8 = null;
    var owner_display: ?[]u8 = null;
    var grants: std.ArrayList(storage.Grant) = .empty;
    errdefer {
        if (owner_id) |s| allocator.free(s);
        if (owner_display) |s| allocator.free(s);
        for (grants.items) |g| {
            allocator.free(g.grantee.id);
            allocator.free(g.grantee.display_name);
            allocator.free(g.grantee.uri);
            allocator.free(g.grantee.email_address);
        }
        grants.deinit(allocator);
    }

    var in_owner = false;
    var in_grant = false;
    var in_grantee = false;
    var g_kind: storage.GranteeKind = .canonical_user;
    var g_id: ?[]u8 = null;
    var g_display: ?[]u8 = null;
    var g_uri: ?[]u8 = null;
    var g_email: ?[]u8 = null;
    var g_perm: ?storage.Permission = null;
    errdefer {
        if (g_id) |s| allocator.free(s);
        if (g_display) |s| allocator.free(s);
        if (g_uri) |s| allocator.free(s);
        if (g_email) |s| allocator.free(s);
    }

    while (true) {
        const node = reader.read() catch return ParseError.MalformedAcl;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "Owner")) {
                    in_owner = true;
                } else if (std.mem.eql(u8, name, "Grant")) {
                    in_grant = true;
                    g_kind = .canonical_user;
                    g_id = null;
                    g_display = null;
                    g_uri = null;
                    g_email = null;
                    g_perm = null;
                } else if (in_grant and std.mem.eql(u8, name, "Grantee")) {
                    in_grantee = true;
                    // The xsi:type attribute determines the grantee kind.
                    // Reader returns attribute values borrowed from the
                    // reader's scratch — do not free.
                    var attr_idx: usize = 0;
                    while (attr_idx < reader.attributeCount()) : (attr_idx += 1) {
                        const an = reader.attributeName(attr_idx);
                        const matches_type = std.mem.eql(u8, an, "xsi:type") or std.mem.eql(u8, an, "type");
                        if (matches_type) {
                            const av = reader.attributeValue(attr_idx) catch return ParseError.MalformedAcl;
                            if (std.mem.eql(u8, av, "CanonicalUser")) {
                                g_kind = .canonical_user;
                            } else if (std.mem.eql(u8, av, "Group")) {
                                g_kind = .group;
                            } else if (std.mem.eql(u8, av, "AmazonCustomerByEmail")) {
                                g_kind = .amazon_customer_by_email;
                            }
                        }
                    }
                } else if (in_owner and std.mem.eql(u8, name, "ID")) {
                    owner_id = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedAcl;
                } else if (in_owner and std.mem.eql(u8, name, "DisplayName")) {
                    owner_display = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedAcl;
                } else if (in_grantee and std.mem.eql(u8, name, "ID")) {
                    g_id = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedAcl;
                } else if (in_grantee and std.mem.eql(u8, name, "DisplayName")) {
                    g_display = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedAcl;
                } else if (in_grantee and std.mem.eql(u8, name, "URI")) {
                    g_uri = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedAcl;
                } else if (in_grantee and std.mem.eql(u8, name, "EmailAddress")) {
                    g_email = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedAcl;
                } else if (in_grant and std.mem.eql(u8, name, "Permission")) {
                    const text = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedAcl;
                    defer allocator.free(text);
                    g_perm = storage.permissionFromXml(text) catch return ParseError.MalformedAcl;
                }
            },
            .element_end => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "Owner")) {
                    in_owner = false;
                } else if (std.mem.eql(u8, name, "Grantee")) {
                    in_grantee = false;
                } else if (std.mem.eql(u8, name, "Grant")) {
                    in_grant = false;
                    const perm = g_perm orelse return ParseError.MalformedAcl;
                    const id_v = g_id orelse (allocator.dupe(u8, "") catch return ParseError.OutOfMemory);
                    const dn_v = g_display orelse (allocator.dupe(u8, "") catch return ParseError.OutOfMemory);
                    const uri_v = g_uri orelse (allocator.dupe(u8, "") catch return ParseError.OutOfMemory);
                    const em_v = g_email orelse (allocator.dupe(u8, "") catch return ParseError.OutOfMemory);
                    grants.append(allocator, .{
                        .grantee = .{
                            .kind = g_kind,
                            .id = id_v,
                            .display_name = dn_v,
                            .uri = uri_v,
                            .email_address = em_v,
                        },
                        .permission = perm,
                    }) catch {
                        allocator.free(id_v);
                        allocator.free(dn_v);
                        allocator.free(uri_v);
                        allocator.free(em_v);
                        return ParseError.OutOfMemory;
                    };
                    g_id = null;
                    g_display = null;
                    g_uri = null;
                    g_email = null;
                    g_perm = null;
                }
            },
            else => {},
        }
    }

    const owner_id_final = owner_id orelse return ParseError.MalformedAcl;
    const owner_dn_final = owner_display orelse (allocator.dupe(u8, "") catch return ParseError.OutOfMemory);
    owner_id = null;
    owner_display = null;
    const grants_slice = grants.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
    return .{
        .owner = .{ .id = owner_id_final, .display_name = owner_dn_final },
        .grants = grants_slice,
    };
}

/// One `x-amz-grant-*` header value can contain multiple comma-separated
/// grantee entries: `id="abc", uri="http://...", emailAddress="x@y"`.
/// Parses them into Grant entries with the given Permission.
pub fn parseGrantHeader(allocator: Allocator, value: []const u8, permission: storage.Permission) ParseError![]storage.Grant {
    var out: std.ArrayList(storage.Grant) = .empty;
    errdefer {
        for (out.items) |g| {
            allocator.free(g.grantee.id);
            allocator.free(g.grantee.display_name);
            allocator.free(g.grantee.uri);
            allocator.free(g.grantee.email_address);
        }
        out.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t");
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return ParseError.MalformedAcl;
        const key = std.mem.trim(u8, entry[0..eq], " \t");
        var val = std.mem.trim(u8, entry[eq + 1 ..], " \t");
        // Strip surrounding double quotes if present.
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        }
        var kind: storage.GranteeKind = .canonical_user;
        var id_s: []const u8 = "";
        var uri_s: []const u8 = "";
        var email_s: []const u8 = "";
        if (std.ascii.eqlIgnoreCase(key, "id")) {
            kind = .canonical_user;
            id_s = val;
        } else if (std.ascii.eqlIgnoreCase(key, "uri")) {
            kind = .group;
            uri_s = val;
        } else if (std.ascii.eqlIgnoreCase(key, "emailAddress")) {
            kind = .amazon_customer_by_email;
            email_s = val;
        } else {
            return ParseError.MalformedAcl;
        }
        const g_id = allocator.dupe(u8, id_s) catch return ParseError.OutOfMemory;
        errdefer allocator.free(g_id);
        const g_dn = allocator.dupe(u8, "") catch return ParseError.OutOfMemory;
        errdefer allocator.free(g_dn);
        const g_uri = allocator.dupe(u8, uri_s) catch return ParseError.OutOfMemory;
        errdefer allocator.free(g_uri);
        const g_em = allocator.dupe(u8, email_s) catch return ParseError.OutOfMemory;
        out.append(allocator, .{
            .grantee = .{
                .kind = kind,
                .id = g_id,
                .display_name = g_dn,
                .uri = g_uri,
                .email_address = g_em,
            },
            .permission = permission,
        }) catch {
            allocator.free(g_id);
            allocator.free(g_dn);
            allocator.free(g_uri);
            allocator.free(g_em);
            return ParseError.OutOfMemory;
        };
    }
    return out.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
}

/// Expand a canned ACL to a full AccessControlPolicy. Caller owns every
/// string in the returned Acl. Always includes Owner FULL_CONTROL plus
/// any canned-specific extra grants.
pub fn cannedToAcl(allocator: Allocator, canned: storage.CannedAcl) ParseError!storage.Acl {
    var extra: std.ArrayList(GrantSpec) = .empty;
    defer extra.deinit(allocator);
    switch (canned) {
        .private => {},
        .public_read => extra.append(allocator, .{ .kind = .group, .target = storage.group_all_users, .perm = .READ }) catch return ParseError.OutOfMemory,
        .public_read_write => {
            extra.append(allocator, .{ .kind = .group, .target = storage.group_all_users, .perm = .READ }) catch return ParseError.OutOfMemory;
            extra.append(allocator, .{ .kind = .group, .target = storage.group_all_users, .perm = .WRITE }) catch return ParseError.OutOfMemory;
        },
        .authenticated_read => extra.append(allocator, .{ .kind = .group, .target = storage.group_authenticated_users, .perm = .READ }) catch return ParseError.OutOfMemory,
        .log_delivery_write => {
            extra.append(allocator, .{ .kind = .group, .target = storage.group_log_delivery, .perm = .WRITE }) catch return ParseError.OutOfMemory;
            extra.append(allocator, .{ .kind = .group, .target = storage.group_log_delivery, .perm = .READ_ACP }) catch return ParseError.OutOfMemory;
        },
        // bucket-owner-* and aws-exec-read: emulator has no distinct
        // bucket owner / aws-exec principal, so we degrade to "private"
        // (Owner FULL_CONTROL only). Documented divergence.
        .bucket_owner_read, .bucket_owner_full_control, .aws_exec_read => {},
    }
    return buildAcl(allocator, extra.items);
}

const GrantSpec = struct {
    kind: storage.GranteeKind,
    target: []const u8, // id (canonical) or uri (group) or email
    perm: storage.Permission,
};

fn buildAcl(allocator: Allocator, extras: []const GrantSpec) ParseError!storage.Acl {
    const total = 1 + extras.len;
    const grants = allocator.alloc(storage.Grant, total) catch return ParseError.OutOfMemory;
    var made: usize = 0;
    errdefer {
        for (grants[0..made]) |g| {
            allocator.free(g.grantee.id);
            allocator.free(g.grantee.display_name);
            allocator.free(g.grantee.uri);
            allocator.free(g.grantee.email_address);
        }
        allocator.free(grants);
    }

    // Owner FULL_CONTROL (always present).
    grants[0] = .{
        .grantee = .{
            .kind = .canonical_user,
            .id = allocator.dupe(u8, storage.default_owner_id) catch return ParseError.OutOfMemory,
            .display_name = allocator.dupe(u8, storage.default_owner_display_name) catch return ParseError.OutOfMemory,
            .uri = allocator.dupe(u8, "") catch return ParseError.OutOfMemory,
            .email_address = allocator.dupe(u8, "") catch return ParseError.OutOfMemory,
        },
        .permission = .FULL_CONTROL,
    };
    made = 1;

    for (extras, 0..) |e, i| {
        var id_s: []const u8 = "";
        var uri_s: []const u8 = "";
        var em_s: []const u8 = "";
        switch (e.kind) {
            .canonical_user => id_s = e.target,
            .group => uri_s = e.target,
            .amazon_customer_by_email => em_s = e.target,
        }
        grants[1 + i] = .{
            .grantee = .{
                .kind = e.kind,
                .id = allocator.dupe(u8, id_s) catch return ParseError.OutOfMemory,
                .display_name = allocator.dupe(u8, "") catch return ParseError.OutOfMemory,
                .uri = allocator.dupe(u8, uri_s) catch return ParseError.OutOfMemory,
                .email_address = allocator.dupe(u8, em_s) catch return ParseError.OutOfMemory,
            },
            .permission = e.perm,
        };
        made += 1;
    }

    const owner_id = allocator.dupe(u8, storage.default_owner_id) catch return ParseError.OutOfMemory;
    errdefer allocator.free(owner_id);
    const owner_dn = allocator.dupe(u8, storage.default_owner_display_name) catch return ParseError.OutOfMemory;
    return .{
        .owner = .{ .id = owner_id, .display_name = owner_dn },
        .grants = grants,
    };
}

/// Free an Acl whose owner + grant strings were duped with `allocator`.
pub fn freeAclOwned(allocator: Allocator, acl: storage.Acl) void {
    allocator.free(acl.owner.id);
    allocator.free(acl.owner.display_name);
    for (acl.grants) |g| {
        allocator.free(g.grantee.id);
        allocator.free(g.grantee.display_name);
        allocator.free(g.grantee.uri);
        allocator.free(g.grantee.email_address);
    }
    allocator.free(acl.grants);
}

/// Append a Grant slice into an existing Acl, returning a fresh Acl whose
/// grants slice owns every entry (originals are freed). Used by the
/// service layer to fold `x-amz-grant-*` grants into the canned ACL.
pub fn mergeGrants(allocator: Allocator, base: storage.Acl, extra: []storage.Grant) ParseError!storage.Acl {
    const total = base.grants.len + extra.len;
    const out = allocator.alloc(storage.Grant, total) catch return ParseError.OutOfMemory;
    @memcpy(out[0..base.grants.len], base.grants);
    @memcpy(out[base.grants.len..], extra);
    allocator.free(base.grants);
    allocator.free(extra);
    return .{ .owner = base.owner, .grants = out };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parseBody: canonical-user Grant" {
    const body =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<AccessControlPolicy>
        \\  <Owner>
        \\    <ID>0123abc</ID>
        \\    <DisplayName>owner</DisplayName>
        \\  </Owner>
        \\  <AccessControlList>
        \\    <Grant>
        \\      <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="CanonicalUser">
        \\        <ID>0123abc</ID>
        \\        <DisplayName>owner</DisplayName>
        \\      </Grantee>
        \\      <Permission>FULL_CONTROL</Permission>
        \\    </Grant>
        \\  </AccessControlList>
        \\</AccessControlPolicy>
    ;
    const acl = try parseBody(testing.allocator, body);
    defer freeAclOwned(testing.allocator, acl);
    try testing.expectEqualStrings("0123abc", acl.owner.id);
    try testing.expectEqual(@as(usize, 1), acl.grants.len);
    try testing.expectEqual(storage.Permission.FULL_CONTROL, acl.grants[0].permission);
    try testing.expectEqual(storage.GranteeKind.canonical_user, acl.grants[0].grantee.kind);
}

test "parseBody: group Grantee" {
    const body =
        \\<AccessControlPolicy>
        \\  <Owner><ID>o</ID></Owner>
        \\  <AccessControlList>
        \\    <Grant>
        \\      <Grantee xsi:type="Group">
        \\        <URI>http://acs.amazonaws.com/groups/global/AllUsers</URI>
        \\      </Grantee>
        \\      <Permission>READ</Permission>
        \\    </Grant>
        \\  </AccessControlList>
        \\</AccessControlPolicy>
    ;
    const acl = try parseBody(testing.allocator, body);
    defer freeAclOwned(testing.allocator, acl);
    try testing.expectEqual(storage.GranteeKind.group, acl.grants[0].grantee.kind);
    try testing.expectEqualStrings("http://acs.amazonaws.com/groups/global/AllUsers", acl.grants[0].grantee.uri);
}

test "parseBody: malformed → MalformedAcl" {
    try testing.expectError(ParseError.MalformedAcl, parseBody(testing.allocator, "<AccessControlPolicy><Owner"));
}

test "parseBody: missing Owner ID → MalformedAcl" {
    try testing.expectError(ParseError.MalformedAcl, parseBody(testing.allocator, "<AccessControlPolicy><Owner></Owner></AccessControlPolicy>"));
}

test "parseGrantHeader: single id grantee" {
    const grants = try parseGrantHeader(testing.allocator, "id=\"abc123\"", .READ);
    defer {
        for (grants) |g| {
            testing.allocator.free(g.grantee.id);
            testing.allocator.free(g.grantee.display_name);
            testing.allocator.free(g.grantee.uri);
            testing.allocator.free(g.grantee.email_address);
        }
        testing.allocator.free(grants);
    }
    try testing.expectEqual(@as(usize, 1), grants.len);
    try testing.expectEqualStrings("abc123", grants[0].grantee.id);
    try testing.expectEqual(storage.Permission.READ, grants[0].permission);
}

test "parseGrantHeader: comma-separated multi-grantee" {
    const grants = try parseGrantHeader(testing.allocator, "id=\"abc\", uri=\"http://acs.amazonaws.com/groups/global/AllUsers\"", .WRITE);
    defer {
        for (grants) |g| {
            testing.allocator.free(g.grantee.id);
            testing.allocator.free(g.grantee.display_name);
            testing.allocator.free(g.grantee.uri);
            testing.allocator.free(g.grantee.email_address);
        }
        testing.allocator.free(grants);
    }
    try testing.expectEqual(@as(usize, 2), grants.len);
    try testing.expectEqual(storage.GranteeKind.canonical_user, grants[0].grantee.kind);
    try testing.expectEqual(storage.GranteeKind.group, grants[1].grantee.kind);
}

test "parseGrantHeader: unknown key → MalformedAcl" {
    try testing.expectError(ParseError.MalformedAcl, parseGrantHeader(testing.allocator, "notreal=\"x\"", .READ));
}

test "cannedToAcl: private = Owner FULL_CONTROL only" {
    const acl = try cannedToAcl(testing.allocator, .private);
    defer freeAclOwned(testing.allocator, acl);
    try testing.expectEqual(@as(usize, 1), acl.grants.len);
    try testing.expectEqual(storage.Permission.FULL_CONTROL, acl.grants[0].permission);
}

test "cannedToAcl: public-read = Owner FULL_CONTROL + AllUsers READ" {
    const acl = try cannedToAcl(testing.allocator, .public_read);
    defer freeAclOwned(testing.allocator, acl);
    try testing.expectEqual(@as(usize, 2), acl.grants.len);
    try testing.expectEqual(storage.GranteeKind.group, acl.grants[1].grantee.kind);
    try testing.expectEqualStrings(storage.group_all_users, acl.grants[1].grantee.uri);
    try testing.expectEqual(storage.Permission.READ, acl.grants[1].permission);
}

test "cannedToAcl: public-read-write = Owner + AllUsers READ + AllUsers WRITE" {
    const acl = try cannedToAcl(testing.allocator, .public_read_write);
    defer freeAclOwned(testing.allocator, acl);
    try testing.expectEqual(@as(usize, 3), acl.grants.len);
}
