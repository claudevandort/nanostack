//! LifecycleConfiguration XML parser + renderer (M11).
//!
//! Body shape:
//!     <LifecycleConfiguration>
//!       <Rule>
//!         <ID>optional</ID>
//!         <Status>Enabled</Status>
//!         <Filter>...</Filter>             (or legacy <Prefix>)
//!         <Transition>...</Transition>
//!         <Expiration>...</Expiration>
//!         <NoncurrentVersionTransition>...</NoncurrentVersionTransition>
//!         <NoncurrentVersionExpiration>...</NoncurrentVersionExpiration>
//!         <AbortIncompleteMultipartUpload>
//!           <DaysAfterInitiation>7</DaysAfterInitiation>
//!         </AbortIncompleteMultipartUpload>
//!       </Rule>
//!     </LifecycleConfiguration>

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

const ParseCtx = struct {
    allocator: Allocator,
    rules: std.ArrayList(storage.LifecycleRule),
    // Per-rule scratch
    rule_id: []u8,
    rule_status: ?storage.LifecycleStatus,
    rule_prefix: []u8,
    rule_filter: ?storage.LifecycleFilter,
    transitions: std.ArrayList(storage.Transition),
    expiration: ?storage.Expiration,
    nc_transitions: std.ArrayList(storage.Transition),
    nc_expiration: ?storage.Expiration,
    abort_days: ?u32,
};

pub fn parseBody(allocator: Allocator, body: []const u8) ParseError!storage.LifecycleConfig {
    var static_reader: xml_lib.Reader.Static = .init(allocator, body, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var rules: std.ArrayList(storage.LifecycleRule) = .empty;
    errdefer {
        for (rules.items) |r| freeRule(allocator, r);
        rules.deinit(allocator);
    }

    // Per-rule scratch — initialized on <Rule>, drained on </Rule>.
    var in_rule = false;
    var r_id: []u8 = try allocator.dupe(u8, "");
    var r_status: ?storage.LifecycleStatus = null;
    var r_prefix: []u8 = try allocator.dupe(u8, "");
    var r_filter: ?storage.LifecycleFilter = null;
    var transitions: std.ArrayList(storage.Transition) = .empty;
    var expiration: ?storage.Expiration = null;
    var nc_transitions: std.ArrayList(storage.Transition) = .empty;
    var nc_expiration: ?storage.Expiration = null;
    var abort_days: ?u32 = null;
    errdefer {
        allocator.free(r_id);
        allocator.free(r_prefix);
        if (r_filter) |f| {
            allocator.free(f.prefix);
            if (f.tag) |t| {
                allocator.free(t.key);
                allocator.free(t.value);
            }
        }
        for (transitions.items) |t| allocator.free(t.date_iso8601);
        transitions.deinit(allocator);
        if (expiration) |e| allocator.free(e.date_iso8601);
        for (nc_transitions.items) |t| allocator.free(t.date_iso8601);
        nc_transitions.deinit(allocator);
        if (nc_expiration) |e| allocator.free(e.date_iso8601);
    }

    // Inner-element state
    var in_filter = false;
    var in_transition = false;
    var t_days: ?u32 = null;
    var t_date: []u8 = try allocator.dupe(u8, "");
    var t_class: ?storage.StorageClass = null;
    errdefer allocator.free(t_date);

    var in_expiration = false;
    var e_days: ?u32 = null;
    var e_date: []u8 = try allocator.dupe(u8, "");
    var e_marker: ?bool = null;
    errdefer allocator.free(e_date);

    var in_nc_transition = false;
    var nct_days: ?u32 = null;
    var nct_class: ?storage.StorageClass = null;

    var in_nc_expiration = false;
    var nce_days: ?u32 = null;

    var in_abort = false;

    // Filter state
    var f_prefix: []u8 = try allocator.dupe(u8, "");
    var f_tag_key: ?[]u8 = null;
    var f_tag_value: ?[]u8 = null;
    var f_size_gt: ?u64 = null;
    var f_size_lt: ?u64 = null;
    errdefer {
        allocator.free(f_prefix);
        if (f_tag_key) |s| allocator.free(s);
        if (f_tag_value) |s| allocator.free(s);
    }
    var in_tag = false;

    while (true) {
        const node = reader.read() catch return ParseError.MalformedXml;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "Rule")) {
                    in_rule = true;
                } else if (in_rule and std.mem.eql(u8, name, "ID")) {
                    allocator.free(r_id);
                    r_id = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                } else if (in_rule and std.mem.eql(u8, name, "Status")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    r_status = storage.lifecycleStatusFromString(txt) catch return ParseError.MalformedXml;
                } else if (in_rule and std.mem.eql(u8, name, "Prefix") and !in_filter) {
                    allocator.free(r_prefix);
                    r_prefix = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                } else if (in_rule and std.mem.eql(u8, name, "Filter")) {
                    in_filter = true;
                    allocator.free(f_prefix);
                    f_prefix = try allocator.dupe(u8, "");
                    f_tag_key = null;
                    f_tag_value = null;
                    f_size_gt = null;
                    f_size_lt = null;
                } else if (in_filter and std.mem.eql(u8, name, "Prefix")) {
                    allocator.free(f_prefix);
                    f_prefix = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                } else if (in_filter and std.mem.eql(u8, name, "Tag")) {
                    in_tag = true;
                } else if (in_tag and std.mem.eql(u8, name, "Key")) {
                    f_tag_key = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                } else if (in_tag and std.mem.eql(u8, name, "Value")) {
                    f_tag_value = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                } else if (in_filter and std.mem.eql(u8, name, "ObjectSizeGreaterThan")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    f_size_gt = std.fmt.parseInt(u64, txt, 10) catch return ParseError.MalformedXml;
                } else if (in_filter and std.mem.eql(u8, name, "ObjectSizeLessThan")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    f_size_lt = std.fmt.parseInt(u64, txt, 10) catch return ParseError.MalformedXml;
                } else if (in_rule and std.mem.eql(u8, name, "Transition")) {
                    in_transition = true;
                    t_days = null;
                    allocator.free(t_date);
                    t_date = try allocator.dupe(u8, "");
                    t_class = null;
                } else if (in_transition and std.mem.eql(u8, name, "Days")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    t_days = std.fmt.parseInt(u32, txt, 10) catch return ParseError.MalformedXml;
                } else if (in_transition and std.mem.eql(u8, name, "Date")) {
                    allocator.free(t_date);
                    t_date = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                } else if (in_transition and std.mem.eql(u8, name, "StorageClass")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    t_class = storage.storageClassFromString(txt) catch return ParseError.MalformedXml;
                } else if (in_rule and std.mem.eql(u8, name, "Expiration")) {
                    in_expiration = true;
                    e_days = null;
                    allocator.free(e_date);
                    e_date = try allocator.dupe(u8, "");
                    e_marker = null;
                } else if (in_expiration and std.mem.eql(u8, name, "Days")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    e_days = std.fmt.parseInt(u32, txt, 10) catch return ParseError.MalformedXml;
                } else if (in_expiration and std.mem.eql(u8, name, "Date")) {
                    allocator.free(e_date);
                    e_date = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                } else if (in_expiration and std.mem.eql(u8, name, "ExpiredObjectDeleteMarker")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    e_marker = std.mem.eql(u8, txt, "true");
                } else if (in_rule and std.mem.eql(u8, name, "NoncurrentVersionTransition")) {
                    in_nc_transition = true;
                    nct_days = null;
                    nct_class = null;
                } else if (in_nc_transition and std.mem.eql(u8, name, "NoncurrentDays")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    nct_days = std.fmt.parseInt(u32, txt, 10) catch return ParseError.MalformedXml;
                } else if (in_nc_transition and std.mem.eql(u8, name, "StorageClass")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    nct_class = storage.storageClassFromString(txt) catch return ParseError.MalformedXml;
                } else if (in_rule and std.mem.eql(u8, name, "NoncurrentVersionExpiration")) {
                    in_nc_expiration = true;
                    nce_days = null;
                } else if (in_nc_expiration and std.mem.eql(u8, name, "NoncurrentDays")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    nce_days = std.fmt.parseInt(u32, txt, 10) catch return ParseError.MalformedXml;
                } else if (in_rule and std.mem.eql(u8, name, "AbortIncompleteMultipartUpload")) {
                    in_abort = true;
                } else if (in_abort and std.mem.eql(u8, name, "DaysAfterInitiation")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    abort_days = std.fmt.parseInt(u32, txt, 10) catch return ParseError.MalformedXml;
                }
            },
            .element_end => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "Filter")) {
                    in_filter = false;
                    var tag: ?storage.Tag = null;
                    if (f_tag_key) |k| {
                        tag = .{
                            .key = k,
                            .value = f_tag_value orelse (allocator.dupe(u8, "") catch return ParseError.OutOfMemory),
                        };
                    } else if (f_tag_value) |v| allocator.free(v);
                    r_filter = .{
                        .prefix = f_prefix,
                        .tag = tag,
                        .object_size_greater_than = f_size_gt,
                        .object_size_less_than = f_size_lt,
                    };
                    f_prefix = try allocator.dupe(u8, "");
                    f_tag_key = null;
                    f_tag_value = null;
                } else if (std.mem.eql(u8, name, "Tag")) {
                    in_tag = false;
                } else if (std.mem.eql(u8, name, "Transition")) {
                    in_transition = false;
                    const sc = t_class orelse return ParseError.MalformedXml;
                    transitions.append(allocator, .{ .days = t_days, .date_iso8601 = t_date, .storage_class = sc }) catch {
                        allocator.free(t_date);
                        return ParseError.OutOfMemory;
                    };
                    t_date = try allocator.dupe(u8, "");
                } else if (std.mem.eql(u8, name, "Expiration")) {
                    in_expiration = false;
                    expiration = .{
                        .days = e_days,
                        .date_iso8601 = e_date,
                        .expired_object_delete_marker = e_marker,
                    };
                    e_date = try allocator.dupe(u8, "");
                } else if (std.mem.eql(u8, name, "NoncurrentVersionTransition")) {
                    in_nc_transition = false;
                    const sc = nct_class orelse return ParseError.MalformedXml;
                    nc_transitions.append(allocator, .{ .days = nct_days, .date_iso8601 = try allocator.dupe(u8, ""), .storage_class = sc }) catch return ParseError.OutOfMemory;
                } else if (std.mem.eql(u8, name, "NoncurrentVersionExpiration")) {
                    in_nc_expiration = false;
                    nc_expiration = .{
                        .days = nce_days,
                        .date_iso8601 = try allocator.dupe(u8, ""),
                        .expired_object_delete_marker = null,
                    };
                } else if (std.mem.eql(u8, name, "AbortIncompleteMultipartUpload")) {
                    in_abort = false;
                } else if (std.mem.eql(u8, name, "Rule")) {
                    in_rule = false;
                    const status = r_status orelse return ParseError.MalformedXml;
                    const rule: storage.LifecycleRule = .{
                        .id = r_id,
                        .status = status,
                        .filter = r_filter,
                        .prefix = r_prefix,
                        .transitions = transitions.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
                        .expiration = expiration,
                        .noncurrent_version_transitions = nc_transitions.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
                        .noncurrent_version_expiration = nc_expiration,
                        .abort_incomplete_multipart_upload_days = abort_days,
                    };
                    rules.append(allocator, rule) catch {
                        freeRule(allocator, rule);
                        return ParseError.OutOfMemory;
                    };
                    r_id = try allocator.dupe(u8, "");
                    r_status = null;
                    r_prefix = try allocator.dupe(u8, "");
                    r_filter = null;
                    transitions = .empty;
                    expiration = null;
                    nc_transitions = .empty;
                    nc_expiration = null;
                    abort_days = null;
                }
            },
            else => {},
        }
    }

    // Free leftover scratch (only the per-rule scratch that was re-initialized).
    allocator.free(r_id);
    allocator.free(r_prefix);
    if (r_filter) |f| {
        allocator.free(f.prefix);
        if (f.tag) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
    }
    for (transitions.items) |t| allocator.free(t.date_iso8601);
    transitions.deinit(allocator);
    if (expiration) |e| allocator.free(e.date_iso8601);
    for (nc_transitions.items) |t| allocator.free(t.date_iso8601);
    nc_transitions.deinit(allocator);
    if (nc_expiration) |e| allocator.free(e.date_iso8601);
    allocator.free(t_date);
    allocator.free(e_date);
    allocator.free(f_prefix);
    if (f_tag_key) |s| allocator.free(s);
    if (f_tag_value) |s| allocator.free(s);

    return .{ .rules = rules.toOwnedSlice(allocator) catch return ParseError.OutOfMemory };
}

pub fn render(allocator: Allocator, cfg: storage.LifecycleConfig) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rule_nodes = try arena.alloc(xml_out.Node, cfg.rules.len);
    for (cfg.rules, 0..) |r, i| {
        var children: std.ArrayList(xml_out.Node) = .empty;
        if (r.id.len > 0) {
            const e = try arena.create(xml_out.Element);
            e.* = .{ .name = "ID", .text = r.id };
            try children.append(arena, .{ .element = e });
        }
        if (r.filter) |f| {
            var kids: std.ArrayList(xml_out.Node) = .empty;
            if (f.prefix.len > 0) {
                const e = try arena.create(xml_out.Element);
                e.* = .{ .name = "Prefix", .text = f.prefix };
                try kids.append(arena, .{ .element = e });
            }
            if (f.tag) |t| {
                const k_el = try arena.create(xml_out.Element);
                k_el.* = .{ .name = "Key", .text = t.key };
                const v_el = try arena.create(xml_out.Element);
                v_el.* = .{ .name = "Value", .text = t.value };
                const tag_el = try arena.create(xml_out.Element);
                tag_el.* = .{ .name = "Tag", .children = try arena.dupe(xml_out.Node, &.{
                    .{ .element = k_el },
                    .{ .element = v_el },
                }) };
                try kids.append(arena, .{ .element = tag_el });
            }
            if (f.object_size_greater_than) |s| {
                const e = try arena.create(xml_out.Element);
                e.* = .{ .name = "ObjectSizeGreaterThan", .text = try std.fmt.allocPrint(arena, "{d}", .{s}) };
                try kids.append(arena, .{ .element = e });
            }
            if (f.object_size_less_than) |s| {
                const e = try arena.create(xml_out.Element);
                e.* = .{ .name = "ObjectSizeLessThan", .text = try std.fmt.allocPrint(arena, "{d}", .{s}) };
                try kids.append(arena, .{ .element = e });
            }
            const filter_el = try arena.create(xml_out.Element);
            filter_el.* = .{ .name = "Filter", .children = kids.items };
            try children.append(arena, .{ .element = filter_el });
        } else if (r.prefix.len > 0) {
            const e = try arena.create(xml_out.Element);
            e.* = .{ .name = "Prefix", .text = r.prefix };
            try children.append(arena, .{ .element = e });
        }
        const status_el = try arena.create(xml_out.Element);
        status_el.* = .{ .name = "Status", .text = @tagName(r.status) };
        try children.append(arena, .{ .element = status_el });
        for (r.transitions) |t| {
            var kids: std.ArrayList(xml_out.Node) = .empty;
            if (t.days) |d| {
                const e = try arena.create(xml_out.Element);
                e.* = .{ .name = "Days", .text = try std.fmt.allocPrint(arena, "{d}", .{d}) };
                try kids.append(arena, .{ .element = e });
            }
            if (t.date_iso8601.len > 0) {
                const e = try arena.create(xml_out.Element);
                e.* = .{ .name = "Date", .text = t.date_iso8601 };
                try kids.append(arena, .{ .element = e });
            }
            const sc_el = try arena.create(xml_out.Element);
            sc_el.* = .{ .name = "StorageClass", .text = @tagName(t.storage_class) };
            try kids.append(arena, .{ .element = sc_el });
            const tr_el = try arena.create(xml_out.Element);
            tr_el.* = .{ .name = "Transition", .children = kids.items };
            try children.append(arena, .{ .element = tr_el });
        }
        if (r.expiration) |e| {
            var kids: std.ArrayList(xml_out.Node) = .empty;
            if (e.days) |d| {
                const el = try arena.create(xml_out.Element);
                el.* = .{ .name = "Days", .text = try std.fmt.allocPrint(arena, "{d}", .{d}) };
                try kids.append(arena, .{ .element = el });
            }
            if (e.date_iso8601.len > 0) {
                const el = try arena.create(xml_out.Element);
                el.* = .{ .name = "Date", .text = e.date_iso8601 };
                try kids.append(arena, .{ .element = el });
            }
            if (e.expired_object_delete_marker) |b| {
                const el = try arena.create(xml_out.Element);
                el.* = .{ .name = "ExpiredObjectDeleteMarker", .text = if (b) "true" else "false" };
                try kids.append(arena, .{ .element = el });
            }
            const exp_el = try arena.create(xml_out.Element);
            exp_el.* = .{ .name = "Expiration", .children = kids.items };
            try children.append(arena, .{ .element = exp_el });
        }
        for (r.noncurrent_version_transitions) |t| {
            var kids: std.ArrayList(xml_out.Node) = .empty;
            if (t.days) |d| {
                const e = try arena.create(xml_out.Element);
                e.* = .{ .name = "NoncurrentDays", .text = try std.fmt.allocPrint(arena, "{d}", .{d}) };
                try kids.append(arena, .{ .element = e });
            }
            const sc_el = try arena.create(xml_out.Element);
            sc_el.* = .{ .name = "StorageClass", .text = @tagName(t.storage_class) };
            try kids.append(arena, .{ .element = sc_el });
            const tr_el = try arena.create(xml_out.Element);
            tr_el.* = .{ .name = "NoncurrentVersionTransition", .children = kids.items };
            try children.append(arena, .{ .element = tr_el });
        }
        if (r.noncurrent_version_expiration) |e| {
            var kids: std.ArrayList(xml_out.Node) = .empty;
            if (e.days) |d| {
                const el = try arena.create(xml_out.Element);
                el.* = .{ .name = "NoncurrentDays", .text = try std.fmt.allocPrint(arena, "{d}", .{d}) };
                try kids.append(arena, .{ .element = el });
            }
            const exp_el = try arena.create(xml_out.Element);
            exp_el.* = .{ .name = "NoncurrentVersionExpiration", .children = kids.items };
            try children.append(arena, .{ .element = exp_el });
        }
        if (r.abort_incomplete_multipart_upload_days) |d| {
            const days_el = try arena.create(xml_out.Element);
            days_el.* = .{ .name = "DaysAfterInitiation", .text = try std.fmt.allocPrint(arena, "{d}", .{d}) };
            const abort_el = try arena.create(xml_out.Element);
            abort_el.* = .{ .name = "AbortIncompleteMultipartUpload", .children = try arena.dupe(xml_out.Node, &.{.{ .element = days_el }}) };
            try children.append(arena, .{ .element = abort_el });
        }
        const rule_el = try arena.create(xml_out.Element);
        rule_el.* = .{ .name = "Rule", .children = children.items };
        rule_nodes[i] = .{ .element = rule_el };
    }

    const root: xml_out.Element = .{
        .name = "LifecycleConfiguration",
        .attrs = &.{xmlns_attr},
        .children = rule_nodes,
    };
    return xml_out.renderToOwnedSlice(allocator, &root);
}

fn freeRule(allocator: Allocator, r: storage.LifecycleRule) void {
    allocator.free(r.id);
    allocator.free(r.prefix);
    if (r.filter) |f| {
        allocator.free(f.prefix);
        if (f.tag) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
    }
    for (r.transitions) |t| allocator.free(t.date_iso8601);
    allocator.free(r.transitions);
    if (r.expiration) |e| allocator.free(e.date_iso8601);
    for (r.noncurrent_version_transitions) |t| allocator.free(t.date_iso8601);
    allocator.free(r.noncurrent_version_transitions);
    if (r.noncurrent_version_expiration) |e| allocator.free(e.date_iso8601);
}

pub fn freeOwned(allocator: Allocator, cfg: storage.LifecycleConfig) void {
    for (cfg.rules) |r| freeRule(allocator, r);
    allocator.free(cfg.rules);
}

const testing = std.testing;

test "parseBody: single rule with Filter + Expiration" {
    const body =
        \\<LifecycleConfiguration>
        \\  <Rule>
        \\    <ID>r1</ID>
        \\    <Status>Enabled</Status>
        \\    <Filter><Prefix>tmp/</Prefix></Filter>
        \\    <Expiration><Days>7</Days></Expiration>
        \\  </Rule>
        \\</LifecycleConfiguration>
    ;
    const cfg = try parseBody(testing.allocator, body);
    defer freeOwned(testing.allocator, cfg);
    try testing.expectEqualStrings("r1", cfg.rules[0].id);
    try testing.expectEqual(storage.LifecycleStatus.Enabled, cfg.rules[0].status);
    try testing.expectEqualStrings("tmp/", cfg.rules[0].filter.?.prefix);
    try testing.expectEqual(@as(?u32, 7), cfg.rules[0].expiration.?.days);
}

test "parseBody: Transition + NoncurrentVersionExpiration" {
    const body =
        \\<LifecycleConfiguration><Rule>
        \\<Status>Enabled</Status>
        \\<Transition><Days>30</Days><StorageClass>GLACIER</StorageClass></Transition>
        \\<NoncurrentVersionExpiration><NoncurrentDays>90</NoncurrentDays></NoncurrentVersionExpiration>
        \\</Rule></LifecycleConfiguration>
    ;
    const cfg = try parseBody(testing.allocator, body);
    defer freeOwned(testing.allocator, cfg);
    try testing.expectEqual(storage.StorageClass.GLACIER, cfg.rules[0].transitions[0].storage_class);
    try testing.expectEqual(@as(?u32, 90), cfg.rules[0].noncurrent_version_expiration.?.days);
}

test "render: minimal round-trip" {
    const rules = [_]storage.LifecycleRule{.{ .status = .Enabled }};
    const cfg: storage.LifecycleConfig = .{ .rules = &rules };
    const body = try render(testing.allocator, cfg);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<Status>Enabled</Status>") != null);
}
