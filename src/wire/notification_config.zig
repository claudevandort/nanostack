//! NotificationConfiguration XML parser + renderer (M11).
//!
//! Body shape (any of TopicConfiguration / QueueConfiguration /
//! CloudFunctionConfiguration may appear multiple times):
//!     <NotificationConfiguration>
//!       <TopicConfiguration>
//!         <Id>optional</Id>
//!         <Topic>arn:aws:sns:...</Topic>
//!         <Event>s3:ObjectCreated:Put</Event>
//!         <Filter>...</Filter>
//!       </TopicConfiguration>
//!       <QueueConfiguration>
//!         <Id>optional</Id>
//!         <Queue>arn:aws:sqs:...</Queue>
//!         <Event>s3:ObjectCreated:*</Event>
//!       </QueueConfiguration>
//!       <CloudFunctionConfiguration>
//!         <Id>optional</Id>
//!         <CloudFunction>arn:aws:lambda:...</CloudFunction>
//!         <Event>...</Event>
//!       </CloudFunctionConfiguration>
//!     </NotificationConfiguration>

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

pub fn parseBody(allocator: Allocator, body: []const u8) ParseError!storage.NotificationConfig {
    var static_reader: xml_lib.Reader.Static = .init(allocator, body, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var entries: std.ArrayList(storage.NotificationConfigEntry) = .empty;
    errdefer {
        for (entries.items) |e| freeEntry(allocator, e);
        entries.deinit(allocator);
    }

    var current_target: ?storage.NotificationTarget = null;
    var current_id: ?[]u8 = null;
    var current_arn: ?[]u8 = null;
    var current_events: std.ArrayList(storage.S3EventName) = .empty;
    var current_filter: ?storage.NotificationFilter = null;
    var in_filter = false;
    var filter_rules: std.ArrayList(storage.NotificationFilterRule) = .empty;
    var pending_rule_name: ?[]u8 = null;
    errdefer {
        if (current_id) |s| allocator.free(s);
        if (current_arn) |s| allocator.free(s);
        current_events.deinit(allocator);
        if (current_filter) |f| {
            for (f.filter_rules) |r| {
                allocator.free(r.name);
                allocator.free(r.value);
            }
            allocator.free(f.filter_rules);
        }
        for (filter_rules.items) |r| {
            allocator.free(r.name);
            allocator.free(r.value);
        }
        filter_rules.deinit(allocator);
        if (pending_rule_name) |s| allocator.free(s);
    }

    while (true) {
        const node = reader.read() catch return ParseError.MalformedXml;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "TopicConfiguration")) {
                    current_target = .topic;
                    current_events = .empty;
                } else if (std.mem.eql(u8, name, "QueueConfiguration")) {
                    current_target = .queue;
                    current_events = .empty;
                } else if (std.mem.eql(u8, name, "CloudFunctionConfiguration")) {
                    current_target = .lambda;
                    current_events = .empty;
                } else if (current_target != null and std.mem.eql(u8, name, "Id")) {
                    current_id = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                } else if (current_target != null and (std.mem.eql(u8, name, "Topic") or std.mem.eql(u8, name, "Queue") or std.mem.eql(u8, name, "CloudFunction"))) {
                    current_arn = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                } else if (current_target != null and std.mem.eql(u8, name, "Event")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    const ev = storage.s3EventFromString(txt) catch return ParseError.MalformedXml;
                    current_events.append(allocator, ev) catch return ParseError.OutOfMemory;
                } else if (current_target != null and std.mem.eql(u8, name, "Filter")) {
                    in_filter = true;
                    filter_rules = .empty;
                } else if (in_filter and std.mem.eql(u8, name, "S3Key")) {
                    // AWS wraps FilterRules in <S3Key>; we treat the wrapper
                    // as transparent (already in_filter) and let inner
                    // <Name>/<Value> elements match.
                } else if (in_filter and std.mem.eql(u8, name, "Name")) {
                    pending_rule_name = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                } else if (in_filter and std.mem.eql(u8, name, "Value")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    const nm = pending_rule_name orelse {
                        allocator.free(txt);
                        return ParseError.MalformedXml;
                    };
                    filter_rules.append(allocator, .{ .name = nm, .value = txt }) catch {
                        allocator.free(nm);
                        allocator.free(txt);
                        return ParseError.OutOfMemory;
                    };
                    pending_rule_name = null;
                }
            },
            .element_end => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "Filter")) {
                    in_filter = false;
                    const rules = filter_rules.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
                    current_filter = .{ .filter_rules = rules };
                    filter_rules = .empty;
                } else if (std.mem.eql(u8, name, "TopicConfiguration") or std.mem.eql(u8, name, "QueueConfiguration") or std.mem.eql(u8, name, "CloudFunctionConfiguration")) {
                    const target = current_target orelse return ParseError.MalformedXml;
                    const arn = current_arn orelse return ParseError.MalformedXml;
                    const events = current_events.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
                    const entry: storage.NotificationConfigEntry = .{
                        .target = target,
                        .id = current_id orelse (allocator.dupe(u8, "") catch return ParseError.OutOfMemory),
                        .arn = arn,
                        .events = events,
                        .filter = current_filter,
                    };
                    entries.append(allocator, entry) catch {
                        freeEntry(allocator, entry);
                        return ParseError.OutOfMemory;
                    };
                    current_target = null;
                    current_id = null;
                    current_arn = null;
                    current_events = .empty;
                    current_filter = null;
                }
            },
            else => {},
        }
    }

    return .{ .entries = entries.toOwnedSlice(allocator) catch return ParseError.OutOfMemory };
}

pub fn render(allocator: Allocator, cfg: storage.NotificationConfig) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var entry_nodes = try arena.alloc(xml_out.Node, cfg.entries.len);
    for (cfg.entries, 0..) |e, i| {
        var children: std.ArrayList(xml_out.Node) = .empty;
        if (e.id.len > 0) {
            const id_el = try arena.create(xml_out.Element);
            id_el.* = .{ .name = "Id", .text = e.id };
            try children.append(arena, .{ .element = id_el });
        }
        const arn_name: []const u8 = switch (e.target) {
            .topic => "Topic",
            .queue => "Queue",
            .lambda => "CloudFunction",
        };
        const arn_el = try arena.create(xml_out.Element);
        arn_el.* = .{ .name = arn_name, .text = e.arn };
        try children.append(arena, .{ .element = arn_el });
        for (e.events) |ev| {
            const ev_el = try arena.create(xml_out.Element);
            ev_el.* = .{ .name = "Event", .text = storage.s3EventToString(ev) };
            try children.append(arena, .{ .element = ev_el });
        }
        if (e.filter) |f| {
            var rule_nodes = try arena.alloc(xml_out.Node, f.filter_rules.len);
            for (f.filter_rules, 0..) |r, ri| {
                const n_el = try arena.create(xml_out.Element);
                n_el.* = .{ .name = "Name", .text = r.name };
                const v_el = try arena.create(xml_out.Element);
                v_el.* = .{ .name = "Value", .text = r.value };
                const fr_el = try arena.create(xml_out.Element);
                fr_el.* = .{ .name = "FilterRule", .children = try arena.dupe(xml_out.Node, &.{
                    .{ .element = n_el },
                    .{ .element = v_el },
                }) };
                rule_nodes[ri] = .{ .element = fr_el };
            }
            const s3key_el = try arena.create(xml_out.Element);
            s3key_el.* = .{ .name = "S3Key", .children = rule_nodes };
            const filter_el = try arena.create(xml_out.Element);
            filter_el.* = .{ .name = "Filter", .children = try arena.dupe(xml_out.Node, &.{.{ .element = s3key_el }}) };
            try children.append(arena, .{ .element = filter_el });
        }
        const wrap_name: []const u8 = switch (e.target) {
            .topic => "TopicConfiguration",
            .queue => "QueueConfiguration",
            .lambda => "CloudFunctionConfiguration",
        };
        const wrap_el = try arena.create(xml_out.Element);
        wrap_el.* = .{ .name = wrap_name, .children = children.items };
        entry_nodes[i] = .{ .element = wrap_el };
    }

    const root: xml_out.Element = .{
        .name = "NotificationConfiguration",
        .attrs = &.{xmlns_attr},
        .children = entry_nodes,
    };
    return xml_out.renderToOwnedSlice(allocator, &root);
}

fn freeEntry(allocator: Allocator, e: storage.NotificationConfigEntry) void {
    allocator.free(e.id);
    allocator.free(e.arn);
    allocator.free(e.events);
    if (e.filter) |f| {
        for (f.filter_rules) |r| {
            allocator.free(r.name);
            allocator.free(r.value);
        }
        allocator.free(f.filter_rules);
    }
}

pub fn freeOwned(allocator: Allocator, cfg: storage.NotificationConfig) void {
    for (cfg.entries) |e| freeEntry(allocator, e);
    allocator.free(cfg.entries);
}

const testing = std.testing;

test "parseBody: Topic config" {
    const body =
        \\<NotificationConfiguration>
        \\  <TopicConfiguration>
        \\    <Id>topic1</Id>
        \\    <Topic>arn:aws:sns:us-east-1:1234:topic</Topic>
        \\    <Event>s3:ObjectCreated:Put</Event>
        \\  </TopicConfiguration>
        \\</NotificationConfiguration>
    ;
    const cfg = try parseBody(testing.allocator, body);
    defer freeOwned(testing.allocator, cfg);
    try testing.expectEqual(storage.NotificationTarget.topic, cfg.entries[0].target);
    try testing.expectEqualStrings("arn:aws:sns:us-east-1:1234:topic", cfg.entries[0].arn);
    try testing.expectEqual(storage.S3EventName.s3_ObjectCreated_Put, cfg.entries[0].events[0]);
}

test "parseBody: Queue with filter" {
    const body =
        \\<NotificationConfiguration><QueueConfiguration>
        \\<Queue>arn:aws:sqs:us-east-1:1:q</Queue>
        \\<Event>s3:ObjectCreated:*</Event>
        \\<Filter><FilterRule><Name>prefix</Name><Value>uploads/</Value></FilterRule></Filter>
        \\</QueueConfiguration></NotificationConfiguration>
    ;
    const cfg = try parseBody(testing.allocator, body);
    defer freeOwned(testing.allocator, cfg);
    try testing.expectEqual(storage.NotificationTarget.queue, cfg.entries[0].target);
    try testing.expectEqualStrings("prefix", cfg.entries[0].filter.?.filter_rules[0].name);
    try testing.expectEqualStrings("uploads/", cfg.entries[0].filter.?.filter_rules[0].value);
}

test "parseBody: empty config" {
    const cfg = try parseBody(testing.allocator, "<NotificationConfiguration/>");
    defer freeOwned(testing.allocator, cfg);
    try testing.expectEqual(@as(usize, 0), cfg.entries.len);
}

test "render: empty" {
    const cfg: storage.NotificationConfig = .{ .entries = &.{} };
    const body = try render(testing.allocator, cfg);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "NotificationConfiguration") != null);
}
