//! ReplicationConfiguration XML parser + renderer (M13).
//!
//! Body shape:
//!     <ReplicationConfiguration>
//!       <Role>arn:aws:iam::...:role/repl</Role>
//!       <Rule>
//!         <ID>r1</ID>
//!         <Status>Enabled</Status>
//!         <Prefix>logs/</Prefix>
//!         <Destination>
//!           <Bucket>arn:aws:s3:::dest</Bucket>
//!           <StorageClass>STANDARD</StorageClass>
//!         </Destination>
//!       </Rule>
//!     </ReplicationConfiguration>

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml_lib = @import("xml");
const xml_out = @import("xml.zig");
const storage = @import("../storage/mod.zig");

const xmlns_attr: xml_out.Attr = .{ .name = "xmlns", .value = "http://s3.amazonaws.com/doc/2006-03-01/" };

pub const ParseError = error{
    MalformedXml,
    OutOfMemory,
};

pub fn parseBody(allocator: Allocator, body: []const u8) ParseError!storage.ReplicationConfig {
    var static_reader: xml_lib.Reader.Static = .init(allocator, body, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var role: []const u8 = "";
    var rules: std.ArrayList(storage.ReplicationRule) = .empty;
    errdefer {
        if (role.len > 0) allocator.free(role);
        for (rules.items) |r| freeRule(allocator, r);
        rules.deinit(allocator);
    }

    var in_rule = false;
    var in_destination = false;
    var r_id: []const u8 = "";
    var r_status: ?storage.ReplicationStatus = null;
    var r_prefix: []const u8 = "";
    var d_bucket: []const u8 = "";
    var d_storage_class: []const u8 = "";
    errdefer {
        if (r_id.len > 0) allocator.free(r_id);
        if (r_prefix.len > 0) allocator.free(r_prefix);
        if (d_bucket.len > 0) allocator.free(d_bucket);
        if (d_storage_class.len > 0) allocator.free(d_storage_class);
    }

    while (true) {
        const node = reader.read() catch return ParseError.MalformedXml;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "Role")) {
                    role = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                } else if (std.mem.eql(u8, name, "Rule")) {
                    in_rule = true;
                    r_id = "";
                    r_status = null;
                    r_prefix = "";
                    d_bucket = "";
                    d_storage_class = "";
                } else if (in_rule and std.mem.eql(u8, name, "ID")) {
                    r_id = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                } else if (in_rule and std.mem.eql(u8, name, "Status")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    r_status = storage.replicationStatusFromString(txt) catch return ParseError.MalformedXml;
                } else if (in_rule and !in_destination and std.mem.eql(u8, name, "Prefix")) {
                    r_prefix = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                } else if (in_rule and std.mem.eql(u8, name, "Destination")) {
                    in_destination = true;
                } else if (in_destination and std.mem.eql(u8, name, "Bucket")) {
                    d_bucket = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                } else if (in_destination and std.mem.eql(u8, name, "StorageClass")) {
                    d_storage_class = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                }
            },
            .element_end => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "Destination")) {
                    in_destination = false;
                } else if (std.mem.eql(u8, name, "Rule")) {
                    in_rule = false;
                    const status = r_status orelse return ParseError.MalformedXml;
                    const rule: storage.ReplicationRule = .{
                        .id = r_id,
                        .status = status,
                        .prefix = r_prefix,
                        .destination = .{
                            .bucket = d_bucket,
                            .storage_class = d_storage_class,
                        },
                    };
                    rules.append(allocator, rule) catch {
                        freeRule(allocator, rule);
                        return ParseError.OutOfMemory;
                    };
                    r_id = "";
                    r_prefix = "";
                    d_bucket = "";
                    d_storage_class = "";
                }
            },
            else => {},
        }
    }

    if (role.len == 0) return ParseError.MalformedXml;
    return .{
        .role = role,
        .rules = rules.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
    };
}

pub fn render(allocator: Allocator, cfg: storage.ReplicationConfig) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var children: std.ArrayList(xml_out.Node) = .empty;
    const role_el = try arena.create(xml_out.Element);
    role_el.* = .{ .name = "Role", .text = cfg.role };
    try children.append(arena, .{ .element = role_el });

    for (cfg.rules) |r| {
        var rule_kids: std.ArrayList(xml_out.Node) = .empty;
        if (r.id.len > 0) {
            const e = try arena.create(xml_out.Element);
            e.* = .{ .name = "ID", .text = r.id };
            try rule_kids.append(arena, .{ .element = e });
        }
        const status_el = try arena.create(xml_out.Element);
        status_el.* = .{ .name = "Status", .text = @tagName(r.status) };
        try rule_kids.append(arena, .{ .element = status_el });
        if (r.prefix.len > 0) {
            const e = try arena.create(xml_out.Element);
            e.* = .{ .name = "Prefix", .text = r.prefix };
            try rule_kids.append(arena, .{ .element = e });
        }
        var dest_kids: std.ArrayList(xml_out.Node) = .empty;
        const b_el = try arena.create(xml_out.Element);
        b_el.* = .{ .name = "Bucket", .text = r.destination.bucket };
        try dest_kids.append(arena, .{ .element = b_el });
        if (r.destination.storage_class.len > 0) {
            const sc_el = try arena.create(xml_out.Element);
            sc_el.* = .{ .name = "StorageClass", .text = r.destination.storage_class };
            try dest_kids.append(arena, .{ .element = sc_el });
        }
        const dest_el = try arena.create(xml_out.Element);
        dest_el.* = .{ .name = "Destination", .children = dest_kids.items };
        try rule_kids.append(arena, .{ .element = dest_el });
        const rule_el = try arena.create(xml_out.Element);
        rule_el.* = .{ .name = "Rule", .children = rule_kids.items };
        try children.append(arena, .{ .element = rule_el });
    }

    const root: xml_out.Element = .{
        .name = "ReplicationConfiguration",
        .attrs = &.{xmlns_attr},
        .children = children.items,
    };
    return xml_out.renderToOwnedSlice(allocator, &root);
}

fn freeRule(allocator: Allocator, r: storage.ReplicationRule) void {
    if (r.id.len > 0) allocator.free(r.id);
    if (r.prefix.len > 0) allocator.free(r.prefix);
    if (r.destination.bucket.len > 0) allocator.free(r.destination.bucket);
    if (r.destination.storage_class.len > 0) allocator.free(r.destination.storage_class);
}

pub fn freeOwned(allocator: Allocator, cfg: storage.ReplicationConfig) void {
    if (cfg.role.len > 0) allocator.free(cfg.role);
    for (cfg.rules) |r| freeRule(allocator, r);
    allocator.free(cfg.rules);
}

const testing = std.testing;

test "parseBody: minimal rule" {
    const body =
        \\<ReplicationConfiguration>
        \\  <Role>arn:aws:iam::1:role/r</Role>
        \\  <Rule>
        \\    <ID>r1</ID>
        \\    <Status>Enabled</Status>
        \\    <Prefix>logs/</Prefix>
        \\    <Destination><Bucket>arn:aws:s3:::dest</Bucket></Destination>
        \\  </Rule>
        \\</ReplicationConfiguration>
    ;
    const cfg = try parseBody(testing.allocator, body);
    defer freeOwned(testing.allocator, cfg);
    try testing.expectEqualStrings("arn:aws:iam::1:role/r", cfg.role);
    try testing.expectEqual(@as(usize, 1), cfg.rules.len);
    try testing.expectEqualStrings("r1", cfg.rules[0].id);
    try testing.expectEqual(storage.ReplicationStatus.Enabled, cfg.rules[0].status);
    try testing.expectEqualStrings("arn:aws:s3:::dest", cfg.rules[0].destination.bucket);
}

test "render: minimal round-trip" {
    const rules = [_]storage.ReplicationRule{
        .{ .id = "r1", .status = .Enabled, .prefix = "x/", .destination = .{ .bucket = "arn:aws:s3:::d" } },
    };
    const cfg: storage.ReplicationConfig = .{ .role = "arn:aws:iam::1:role/r", .rules = &rules };
    const body = try render(testing.allocator, cfg);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<Role>arn:aws:iam::1:role/r</Role>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<Status>Enabled</Status>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<Bucket>arn:aws:s3:::d</Bucket>") != null);
}
