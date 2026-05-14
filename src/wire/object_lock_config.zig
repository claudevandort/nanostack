//! ObjectLockConfiguration XML parser + renderer (M12).
//!
//! Body shape:
//!     <ObjectLockConfiguration>
//!       <ObjectLockEnabled>Enabled</ObjectLockEnabled>
//!       <Rule>
//!         <DefaultRetention>
//!           <Mode>GOVERNANCE</Mode>
//!           <Days>30</Days>
//!         </DefaultRetention>
//!       </Rule>
//!     </ObjectLockConfiguration>

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

pub fn parseBody(allocator: Allocator, body: []const u8) ParseError!storage.ObjectLockConfig {
    var static_reader: xml_lib.Reader.Static = .init(allocator, body, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var enabled = false;
    var in_rule = false;
    var in_default = false;
    var def_mode: ?storage.RetentionMode = null;
    var def_days: ?u32 = null;
    var def_years: ?u32 = null;

    while (true) {
        const node = reader.read() catch return ParseError.MalformedXml;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "ObjectLockEnabled")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    enabled = std.mem.eql(u8, txt, "Enabled");
                } else if (std.mem.eql(u8, name, "Rule")) {
                    in_rule = true;
                } else if (in_rule and std.mem.eql(u8, name, "DefaultRetention")) {
                    in_default = true;
                } else if (in_default and std.mem.eql(u8, name, "Mode")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    def_mode = storage.retentionModeFromString(txt) catch return ParseError.MalformedXml;
                } else if (in_default and std.mem.eql(u8, name, "Days")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    def_days = std.fmt.parseInt(u32, txt, 10) catch return ParseError.MalformedXml;
                } else if (in_default and std.mem.eql(u8, name, "Years")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    def_years = std.fmt.parseInt(u32, txt, 10) catch return ParseError.MalformedXml;
                }
            },
            .element_end => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "DefaultRetention")) in_default = false;
                if (std.mem.eql(u8, name, "Rule")) in_rule = false;
            },
            else => {},
        }
    }

    var rule: ?storage.ObjectLockRule = null;
    if (def_mode != null) {
        rule = .{ .default_retention = .{ .mode = def_mode.?, .days = def_days, .years = def_years } };
    }
    return .{ .object_lock_enabled = enabled, .rule = rule };
}

pub fn render(allocator: Allocator, cfg: storage.ObjectLockConfig) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var children: std.ArrayList(xml_out.Node) = .empty;
    const enabled_el = try arena.create(xml_out.Element);
    enabled_el.* = .{ .name = "ObjectLockEnabled", .text = if (cfg.object_lock_enabled) "Enabled" else "Disabled" };
    try children.append(arena, .{ .element = enabled_el });

    if (cfg.rule) |r| {
        if (r.default_retention) |def| {
            var def_kids: std.ArrayList(xml_out.Node) = .empty;
            const mode_el = try arena.create(xml_out.Element);
            mode_el.* = .{ .name = "Mode", .text = storage.retentionModeToString(def.mode) };
            try def_kids.append(arena, .{ .element = mode_el });
            if (def.days) |d| {
                const e = try arena.create(xml_out.Element);
                e.* = .{ .name = "Days", .text = try std.fmt.allocPrint(arena, "{d}", .{d}) };
                try def_kids.append(arena, .{ .element = e });
            }
            if (def.years) |y| {
                const e = try arena.create(xml_out.Element);
                e.* = .{ .name = "Years", .text = try std.fmt.allocPrint(arena, "{d}", .{y}) };
                try def_kids.append(arena, .{ .element = e });
            }
            const def_el = try arena.create(xml_out.Element);
            def_el.* = .{ .name = "DefaultRetention", .children = def_kids.items };
            const rule_el = try arena.create(xml_out.Element);
            rule_el.* = .{ .name = "Rule", .children = try arena.dupe(xml_out.Node, &.{.{ .element = def_el }}) };
            try children.append(arena, .{ .element = rule_el });
        }
    }

    const root: xml_out.Element = .{
        .name = "ObjectLockConfiguration",
        .attrs = &.{xmlns_attr},
        .children = children.items,
    };
    return xml_out.renderToOwnedSlice(allocator, &root);
}

const testing = std.testing;

test "parseBody: enabled + GOVERNANCE Days" {
    const body =
        \\<ObjectLockConfiguration>
        \\  <ObjectLockEnabled>Enabled</ObjectLockEnabled>
        \\  <Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Days>7</Days></DefaultRetention></Rule>
        \\</ObjectLockConfiguration>
    ;
    const cfg = try parseBody(testing.allocator, body);
    try testing.expect(cfg.object_lock_enabled);
    try testing.expectEqual(storage.RetentionMode.GOVERNANCE, cfg.rule.?.default_retention.?.mode);
    try testing.expectEqual(@as(?u32, 7), cfg.rule.?.default_retention.?.days);
}

test "parseBody: enabled, no rule" {
    const body = "<ObjectLockConfiguration><ObjectLockEnabled>Enabled</ObjectLockEnabled></ObjectLockConfiguration>";
    const cfg = try parseBody(testing.allocator, body);
    try testing.expect(cfg.object_lock_enabled);
    try testing.expect(cfg.rule == null);
}

test "render: enabled + COMPLIANCE Days" {
    const cfg: storage.ObjectLockConfig = .{
        .object_lock_enabled = true,
        .rule = .{ .default_retention = .{ .mode = .COMPLIANCE, .days = 30 } },
    };
    const body = try render(testing.allocator, cfg);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<Mode>COMPLIANCE</Mode>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<Days>30</Days>") != null);
}
