//! WebsiteConfiguration XML parser + renderer (M11).
//!
//! Mutually exclusive top-level shapes:
//!   <WebsiteConfiguration>
//!     <RedirectAllRequestsTo>
//!       <HostName>example.com</HostName>
//!       <Protocol>https</Protocol>
//!     </RedirectAllRequestsTo>
//!   </WebsiteConfiguration>
//!
//! OR
//!
//!   <WebsiteConfiguration>
//!     <IndexDocument><Suffix>index.html</Suffix></IndexDocument>
//!     <ErrorDocument><Key>error.html</Key></ErrorDocument>
//!     <RoutingRules>
//!       <RoutingRule>
//!         <Condition>...</Condition>
//!         <Redirect>...</Redirect>
//!       </RoutingRule>
//!     </RoutingRules>
//!   </WebsiteConfiguration>

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

pub fn parseBody(allocator: Allocator, body: []const u8) ParseError!storage.WebsiteConfig {
    var static_reader: xml_lib.Reader.Static = .init(allocator, body, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var out: storage.WebsiteConfig = .{};
    var routing_rules: std.ArrayList(storage.RoutingRule) = .empty;
    errdefer {
        for (routing_rules.items) |r| freeRoutingRule(allocator, r);
        routing_rules.deinit(allocator);
    }
    errdefer freePartial(allocator, &out);

    // RedirectAllRequestsTo state
    var in_redirect_all = false;
    var ra_host: ?[]u8 = null;
    var ra_protocol: ?storage.Protocol = null;
    errdefer if (ra_host) |s| allocator.free(s);

    // IndexDocument / ErrorDocument state
    var in_index = false;
    var in_error = false;

    // RoutingRule state
    var in_rule = false;
    var in_condition = false;
    var in_redirect = false;
    var rc: ?storage.RoutingCondition = null;
    var rr_redirect: storage.RoutingRedirect = .{};
    errdefer {
        if (rc) |c| {
            allocator.free(c.key_prefix_equals);
            allocator.free(c.http_error_code_returned_equals);
        }
        allocator.free(rr_redirect.host_name);
        allocator.free(rr_redirect.http_redirect_code);
        allocator.free(rr_redirect.replace_key_prefix_with);
        allocator.free(rr_redirect.replace_key_with);
    }

    while (true) {
        const node = reader.read() catch return ParseError.MalformedXml;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "RedirectAllRequestsTo")) {
                    in_redirect_all = true;
                } else if (std.mem.eql(u8, name, "IndexDocument")) {
                    in_index = true;
                } else if (std.mem.eql(u8, name, "ErrorDocument")) {
                    in_error = true;
                } else if (std.mem.eql(u8, name, "RoutingRule")) {
                    in_rule = true;
                    rc = null;
                    rr_redirect = .{
                        .host_name = allocator.dupe(u8, "") catch return ParseError.OutOfMemory,
                        .http_redirect_code = allocator.dupe(u8, "") catch return ParseError.OutOfMemory,
                        .replace_key_prefix_with = allocator.dupe(u8, "") catch return ParseError.OutOfMemory,
                        .replace_key_with = allocator.dupe(u8, "") catch return ParseError.OutOfMemory,
                    };
                } else if (in_rule and std.mem.eql(u8, name, "Condition")) {
                    in_condition = true;
                    rc = .{
                        .key_prefix_equals = allocator.dupe(u8, "") catch return ParseError.OutOfMemory,
                        .http_error_code_returned_equals = allocator.dupe(u8, "") catch return ParseError.OutOfMemory,
                    };
                } else if (in_rule and std.mem.eql(u8, name, "Redirect")) {
                    in_redirect = true;
                } else if (in_redirect_all and std.mem.eql(u8, name, "HostName")) {
                    ra_host = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                } else if (in_redirect_all and std.mem.eql(u8, name, "Protocol")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    ra_protocol = storage.protocolFromString(txt) catch return ParseError.MalformedXml;
                } else if (in_index and std.mem.eql(u8, name, "Suffix")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    out.index_document = .{ .suffix = txt };
                } else if (in_error and std.mem.eql(u8, name, "Key")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    out.error_document = .{ .key = txt };
                } else if (in_condition and std.mem.eql(u8, name, "KeyPrefixEquals")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    if (rc) |*c| {
                        allocator.free(c.key_prefix_equals);
                        c.key_prefix_equals = txt;
                    }
                } else if (in_condition and std.mem.eql(u8, name, "HttpErrorCodeReturnedEquals")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    if (rc) |*c| {
                        allocator.free(c.http_error_code_returned_equals);
                        c.http_error_code_returned_equals = txt;
                    }
                } else if (in_redirect and std.mem.eql(u8, name, "HostName")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    allocator.free(rr_redirect.host_name);
                    rr_redirect.host_name = txt;
                } else if (in_redirect and std.mem.eql(u8, name, "Protocol")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    rr_redirect.protocol = storage.protocolFromString(txt) catch return ParseError.MalformedXml;
                } else if (in_redirect and std.mem.eql(u8, name, "HttpRedirectCode")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    allocator.free(rr_redirect.http_redirect_code);
                    rr_redirect.http_redirect_code = txt;
                } else if (in_redirect and std.mem.eql(u8, name, "ReplaceKeyPrefixWith")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    allocator.free(rr_redirect.replace_key_prefix_with);
                    rr_redirect.replace_key_prefix_with = txt;
                } else if (in_redirect and std.mem.eql(u8, name, "ReplaceKeyWith")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    allocator.free(rr_redirect.replace_key_with);
                    rr_redirect.replace_key_with = txt;
                }
            },
            .element_end => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "RedirectAllRequestsTo")) {
                    in_redirect_all = false;
                    const host = ra_host orelse return ParseError.MalformedXml;
                    out.redirect_all = .{ .host_name = host, .protocol = ra_protocol };
                    ra_host = null;
                } else if (std.mem.eql(u8, name, "IndexDocument")) {
                    in_index = false;
                } else if (std.mem.eql(u8, name, "ErrorDocument")) {
                    in_error = false;
                } else if (std.mem.eql(u8, name, "Condition")) {
                    in_condition = false;
                } else if (std.mem.eql(u8, name, "Redirect")) {
                    in_redirect = false;
                } else if (std.mem.eql(u8, name, "RoutingRule")) {
                    in_rule = false;
                    const rule: storage.RoutingRule = .{ .condition = rc, .redirect = rr_redirect };
                    routing_rules.append(allocator, rule) catch {
                        freeRoutingRule(allocator, rule);
                        return ParseError.OutOfMemory;
                    };
                    rc = null;
                    rr_redirect = .{};
                }
            },
            else => {},
        }
    }

    out.routing_rules = routing_rules.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
    return out;
}

pub fn render(allocator: Allocator, cfg: storage.WebsiteConfig) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var children: std.ArrayList(xml_out.Node) = .empty;

    if (cfg.redirect_all) |r| {
        var kids: std.ArrayList(xml_out.Node) = .empty;
        const host_el = try arena.create(xml_out.Element);
        host_el.* = .{ .name = "HostName", .text = r.host_name };
        try kids.append(arena, .{ .element = host_el });
        if (r.protocol) |p| {
            const p_el = try arena.create(xml_out.Element);
            p_el.* = .{ .name = "Protocol", .text = storage.protocolToString(p) };
            try kids.append(arena, .{ .element = p_el });
        }
        const ra_el = try arena.create(xml_out.Element);
        ra_el.* = .{ .name = "RedirectAllRequestsTo", .children = kids.items };
        try children.append(arena, .{ .element = ra_el });
    }
    if (cfg.index_document) |i| {
        const sfx_el = try arena.create(xml_out.Element);
        sfx_el.* = .{ .name = "Suffix", .text = i.suffix };
        const idx_el = try arena.create(xml_out.Element);
        idx_el.* = .{ .name = "IndexDocument", .children = try arena.dupe(xml_out.Node, &.{.{ .element = sfx_el }}) };
        try children.append(arena, .{ .element = idx_el });
    }
    if (cfg.error_document) |e| {
        const key_el = try arena.create(xml_out.Element);
        key_el.* = .{ .name = "Key", .text = e.key };
        const err_el = try arena.create(xml_out.Element);
        err_el.* = .{ .name = "ErrorDocument", .children = try arena.dupe(xml_out.Node, &.{.{ .element = key_el }}) };
        try children.append(arena, .{ .element = err_el });
    }
    if (cfg.routing_rules.len > 0) {
        var rule_nodes = try arena.alloc(xml_out.Node, cfg.routing_rules.len);
        for (cfg.routing_rules, 0..) |r, i| {
            var rkids: std.ArrayList(xml_out.Node) = .empty;
            if (r.condition) |c| {
                var ckids: std.ArrayList(xml_out.Node) = .empty;
                if (c.key_prefix_equals.len > 0) {
                    const e = try arena.create(xml_out.Element);
                    e.* = .{ .name = "KeyPrefixEquals", .text = c.key_prefix_equals };
                    try ckids.append(arena, .{ .element = e });
                }
                if (c.http_error_code_returned_equals.len > 0) {
                    const e = try arena.create(xml_out.Element);
                    e.* = .{ .name = "HttpErrorCodeReturnedEquals", .text = c.http_error_code_returned_equals };
                    try ckids.append(arena, .{ .element = e });
                }
                const cond_el = try arena.create(xml_out.Element);
                cond_el.* = .{ .name = "Condition", .children = ckids.items };
                try rkids.append(arena, .{ .element = cond_el });
            }
            var redkids: std.ArrayList(xml_out.Node) = .empty;
            if (r.redirect.host_name.len > 0) {
                const e = try arena.create(xml_out.Element);
                e.* = .{ .name = "HostName", .text = r.redirect.host_name };
                try redkids.append(arena, .{ .element = e });
            }
            if (r.redirect.protocol) |p| {
                const e = try arena.create(xml_out.Element);
                e.* = .{ .name = "Protocol", .text = storage.protocolToString(p) };
                try redkids.append(arena, .{ .element = e });
            }
            if (r.redirect.http_redirect_code.len > 0) {
                const e = try arena.create(xml_out.Element);
                e.* = .{ .name = "HttpRedirectCode", .text = r.redirect.http_redirect_code };
                try redkids.append(arena, .{ .element = e });
            }
            if (r.redirect.replace_key_prefix_with.len > 0) {
                const e = try arena.create(xml_out.Element);
                e.* = .{ .name = "ReplaceKeyPrefixWith", .text = r.redirect.replace_key_prefix_with };
                try redkids.append(arena, .{ .element = e });
            }
            if (r.redirect.replace_key_with.len > 0) {
                const e = try arena.create(xml_out.Element);
                e.* = .{ .name = "ReplaceKeyWith", .text = r.redirect.replace_key_with };
                try redkids.append(arena, .{ .element = e });
            }
            const red_el = try arena.create(xml_out.Element);
            red_el.* = .{ .name = "Redirect", .children = redkids.items };
            try rkids.append(arena, .{ .element = red_el });
            const rule_el = try arena.create(xml_out.Element);
            rule_el.* = .{ .name = "RoutingRule", .children = rkids.items };
            rule_nodes[i] = .{ .element = rule_el };
        }
        const rules_el = try arena.create(xml_out.Element);
        rules_el.* = .{ .name = "RoutingRules", .children = rule_nodes };
        try children.append(arena, .{ .element = rules_el });
    }

    const root: xml_out.Element = .{
        .name = "WebsiteConfiguration",
        .attrs = &.{xmlns_attr},
        .children = children.items,
    };
    return xml_out.renderToOwnedSlice(allocator, &root);
}

fn freeRoutingRule(allocator: Allocator, r: storage.RoutingRule) void {
    if (r.condition) |c| {
        allocator.free(c.key_prefix_equals);
        allocator.free(c.http_error_code_returned_equals);
    }
    allocator.free(r.redirect.host_name);
    allocator.free(r.redirect.http_redirect_code);
    allocator.free(r.redirect.replace_key_prefix_with);
    allocator.free(r.redirect.replace_key_with);
}

fn freePartial(allocator: Allocator, cfg: *storage.WebsiteConfig) void {
    if (cfg.redirect_all) |r| allocator.free(r.host_name);
    if (cfg.index_document) |i| allocator.free(i.suffix);
    if (cfg.error_document) |e| allocator.free(e.key);
}

pub fn freeOwned(allocator: Allocator, cfg: storage.WebsiteConfig) void {
    if (cfg.redirect_all) |r| allocator.free(r.host_name);
    if (cfg.index_document) |i| allocator.free(i.suffix);
    if (cfg.error_document) |e| allocator.free(e.key);
    for (cfg.routing_rules) |r| freeRoutingRule(allocator, r);
    allocator.free(cfg.routing_rules);
}

const testing = std.testing;

test "parseBody: Index + Error" {
    const body =
        \\<WebsiteConfiguration>
        \\  <IndexDocument><Suffix>index.html</Suffix></IndexDocument>
        \\  <ErrorDocument><Key>404.html</Key></ErrorDocument>
        \\</WebsiteConfiguration>
    ;
    const cfg = try parseBody(testing.allocator, body);
    defer freeOwned(testing.allocator, cfg);
    try testing.expectEqualStrings("index.html", cfg.index_document.?.suffix);
    try testing.expectEqualStrings("404.html", cfg.error_document.?.key);
}

test "parseBody: RedirectAllRequestsTo" {
    const body = "<WebsiteConfiguration><RedirectAllRequestsTo><HostName>example.com</HostName><Protocol>https</Protocol></RedirectAllRequestsTo></WebsiteConfiguration>";
    const cfg = try parseBody(testing.allocator, body);
    defer freeOwned(testing.allocator, cfg);
    try testing.expectEqualStrings("example.com", cfg.redirect_all.?.host_name);
    try testing.expectEqual(storage.Protocol.https, cfg.redirect_all.?.protocol.?);
}

test "render: Index round-trip" {
    const cfg: storage.WebsiteConfig = .{
        .index_document = .{ .suffix = "index.html" },
    };
    const body = try render(testing.allocator, cfg);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<Suffix>index.html</Suffix>") != null);
}
