//! `<AccessControlPolicy>` body emitter for GetBucketAcl / GetObjectAcl
//! (M10).

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml.zig");
const storage = @import("../storage/mod.zig");

const xmlns_attr: xml.Attr = .{ .name = "xmlns", .value = "http://s3.amazonaws.com/doc/2006-03-01/" };

pub fn renderAccessControlPolicy(allocator: Allocator, acl: storage.Acl) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Owner.
    const owner_id_el = try arena.create(xml.Element);
    owner_id_el.* = .{ .name = "ID", .text = acl.owner.id };
    var owner_children: std.ArrayList(xml.Node) = .empty;
    try owner_children.append(arena, .{ .element = owner_id_el });
    if (acl.owner.display_name.len > 0) {
        const dn_el = try arena.create(xml.Element);
        dn_el.* = .{ .name = "DisplayName", .text = acl.owner.display_name };
        try owner_children.append(arena, .{ .element = dn_el });
    }
    const owner_el = try arena.create(xml.Element);
    owner_el.* = .{ .name = "Owner", .children = owner_children.items };

    // AccessControlList → Grants. AWS-exact: emit `xmlns:xsi` on each
    // <Grantee> (not on the root) so SDK XML parsers that look for the
    // namespace at the element level can find it.
    var grant_nodes = try arena.alloc(xml.Node, acl.grants.len);
    for (acl.grants, 0..) |g, i| {
        const grantee_el = try arena.create(xml.Element);
        const type_attr: []xml.Attr = blk: {
            const t = try arena.alloc(xml.Attr, 2);
            t[0] = .{ .name = "xmlns:xsi", .value = "http://www.w3.org/2001/XMLSchema-instance" };
            t[1] = .{ .name = "xsi:type", .value = switch (g.grantee.kind) {
                .canonical_user => "CanonicalUser",
                .group => "Group",
                .amazon_customer_by_email => "AmazonCustomerByEmail",
            } };
            break :blk t;
        };
        var grantee_children: std.ArrayList(xml.Node) = .empty;
        switch (g.grantee.kind) {
            .canonical_user => {
                const id_el = try arena.create(xml.Element);
                id_el.* = .{ .name = "ID", .text = g.grantee.id };
                try grantee_children.append(arena, .{ .element = id_el });
                if (g.grantee.display_name.len > 0) {
                    const dn_el = try arena.create(xml.Element);
                    dn_el.* = .{ .name = "DisplayName", .text = g.grantee.display_name };
                    try grantee_children.append(arena, .{ .element = dn_el });
                }
            },
            .group => {
                const uri_el = try arena.create(xml.Element);
                uri_el.* = .{ .name = "URI", .text = g.grantee.uri };
                try grantee_children.append(arena, .{ .element = uri_el });
            },
            .amazon_customer_by_email => {
                const em_el = try arena.create(xml.Element);
                em_el.* = .{ .name = "EmailAddress", .text = g.grantee.email_address };
                try grantee_children.append(arena, .{ .element = em_el });
            },
        }
        grantee_el.* = .{ .name = "Grantee", .attrs = type_attr, .children = grantee_children.items };

        const perm_el = try arena.create(xml.Element);
        perm_el.* = .{ .name = "Permission", .text = storage.permissionToXml(g.permission) };

        const grant_el = try arena.create(xml.Element);
        grant_el.* = .{ .name = "Grant", .children = try arena.dupe(xml.Node, &.{
            .{ .element = grantee_el },
            .{ .element = perm_el },
        }) };
        grant_nodes[i] = .{ .element = grant_el };
    }
    var acl_list_el: xml.Element = .{ .name = "AccessControlList", .children = grant_nodes };

    const root: xml.Element = .{
        .name = "AccessControlPolicy",
        .attrs = &.{xmlns_attr},
        .children = &.{
            .{ .element = owner_el },
            .{ .element = &acl_list_el },
        },
    };
    return xml.renderToOwnedSlice(allocator, &root);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "renderAccessControlPolicy: private (Owner FULL_CONTROL)" {
    const grants = [_]storage.Grant{
        .{
            .grantee = .{
                .kind = .canonical_user,
                .id = "abc",
                .display_name = "owner",
            },
            .permission = .FULL_CONTROL,
        },
    };
    const acl: storage.Acl = .{
        .owner = .{ .id = "abc", .display_name = "owner" },
        .grants = &grants,
    };
    const body = try renderAccessControlPolicy(testing.allocator, acl);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<AccessControlPolicy") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<ID>abc</ID>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<Permission>FULL_CONTROL</Permission>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "xsi:type=\"CanonicalUser\"") != null);
}

test "renderAccessControlPolicy: group Grantee" {
    const grants = [_]storage.Grant{
        .{
            .grantee = .{
                .kind = .group,
                .uri = "http://acs.amazonaws.com/groups/global/AllUsers",
            },
            .permission = .READ,
        },
    };
    const acl: storage.Acl = .{
        .owner = .{ .id = "o" },
        .grants = &grants,
    };
    const body = try renderAccessControlPolicy(testing.allocator, acl);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "xsi:type=\"Group\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<URI>http://acs.amazonaws.com/groups/global/AllUsers</URI>") != null);
}
