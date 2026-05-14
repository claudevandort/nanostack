//! CORS configuration XML parser + renderer (M11).
//!
//! Body shape:
//!     <CORSConfiguration>
//!       <CORSRule>
//!         <ID>optional</ID>
//!         <AllowedMethod>GET</AllowedMethod>
//!         <AllowedMethod>PUT</AllowedMethod>
//!         <AllowedOrigin>*</AllowedOrigin>
//!         <AllowedHeader>*</AllowedHeader>
//!         <ExposeHeader>x-amz-version-id</ExposeHeader>
//!         <MaxAgeSeconds>3000</MaxAgeSeconds>
//!       </CORSRule>
//!     </CORSConfiguration>

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

pub fn parseBody(allocator: Allocator, body: []const u8) ParseError!storage.CorsConfig {
    var static_reader: xml_lib.Reader.Static = .init(allocator, body, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var rules: std.ArrayList(storage.CorsRule) = .empty;
    errdefer {
        for (rules.items) |r| freeRule(allocator, r);
        rules.deinit(allocator);
    }

    var in_rule = false;
    var r_id: ?[]u8 = null;
    var r_methods: std.ArrayList(storage.HttpMethod) = .empty;
    var r_origins: std.ArrayList([]const u8) = .empty;
    var r_headers: std.ArrayList([]const u8) = .empty;
    var r_expose: std.ArrayList([]const u8) = .empty;
    var r_max_age: ?u32 = null;
    errdefer {
        if (r_id) |s| allocator.free(s);
        r_methods.deinit(allocator);
        for (r_origins.items) |s| allocator.free(s);
        r_origins.deinit(allocator);
        for (r_headers.items) |s| allocator.free(s);
        r_headers.deinit(allocator);
        for (r_expose.items) |s| allocator.free(s);
        r_expose.deinit(allocator);
    }

    while (true) {
        const node = reader.read() catch return ParseError.MalformedXml;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "CORSRule")) {
                    in_rule = true;
                    r_id = null;
                    r_methods = .empty;
                    r_origins = .empty;
                    r_headers = .empty;
                    r_expose = .empty;
                    r_max_age = null;
                } else if (in_rule and std.mem.eql(u8, name, "ID")) {
                    r_id = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                } else if (in_rule and std.mem.eql(u8, name, "AllowedMethod")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    const m = storage.httpMethodFromString(txt) catch return ParseError.MalformedXml;
                    r_methods.append(allocator, m) catch return ParseError.OutOfMemory;
                } else if (in_rule and std.mem.eql(u8, name, "AllowedOrigin")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    r_origins.append(allocator, txt) catch {
                        allocator.free(txt);
                        return ParseError.OutOfMemory;
                    };
                } else if (in_rule and std.mem.eql(u8, name, "AllowedHeader")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    r_headers.append(allocator, txt) catch {
                        allocator.free(txt);
                        return ParseError.OutOfMemory;
                    };
                } else if (in_rule and std.mem.eql(u8, name, "ExposeHeader")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    r_expose.append(allocator, txt) catch {
                        allocator.free(txt);
                        return ParseError.OutOfMemory;
                    };
                } else if (in_rule and std.mem.eql(u8, name, "MaxAgeSeconds")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    r_max_age = std.fmt.parseInt(u32, txt, 10) catch return ParseError.MalformedXml;
                }
            },
            .element_end => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "CORSRule")) {
                    in_rule = false;
                    const rule: storage.CorsRule = .{
                        .id = r_id orelse (allocator.dupe(u8, "") catch return ParseError.OutOfMemory),
                        .allowed_methods = r_methods.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
                        .allowed_origins = r_origins.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
                        .allowed_headers = r_headers.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
                        .expose_headers = r_expose.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
                        .max_age_seconds = r_max_age,
                    };
                    rules.append(allocator, rule) catch {
                        freeRule(allocator, rule);
                        return ParseError.OutOfMemory;
                    };
                    r_id = null;
                    r_methods = .empty;
                    r_origins = .empty;
                    r_headers = .empty;
                    r_expose = .empty;
                    r_max_age = null;
                }
            },
            else => {},
        }
    }

    return .{ .rules = rules.toOwnedSlice(allocator) catch return ParseError.OutOfMemory };
}

pub fn render(allocator: Allocator, cfg: storage.CorsConfig) ![]u8 {
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
        for (r.allowed_methods) |m| {
            const e = try arena.create(xml_out.Element);
            e.* = .{ .name = "AllowedMethod", .text = storage.httpMethodToString(m) };
            try children.append(arena, .{ .element = e });
        }
        for (r.allowed_origins) |o| {
            const e = try arena.create(xml_out.Element);
            e.* = .{ .name = "AllowedOrigin", .text = o };
            try children.append(arena, .{ .element = e });
        }
        for (r.allowed_headers) |h| {
            const e = try arena.create(xml_out.Element);
            e.* = .{ .name = "AllowedHeader", .text = h };
            try children.append(arena, .{ .element = e });
        }
        for (r.expose_headers) |h| {
            const e = try arena.create(xml_out.Element);
            e.* = .{ .name = "ExposeHeader", .text = h };
            try children.append(arena, .{ .element = e });
        }
        if (r.max_age_seconds) |ma| {
            const e = try arena.create(xml_out.Element);
            const buf = try std.fmt.allocPrint(arena, "{d}", .{ma});
            e.* = .{ .name = "MaxAgeSeconds", .text = buf };
            try children.append(arena, .{ .element = e });
        }
        const rule_el = try arena.create(xml_out.Element);
        rule_el.* = .{ .name = "CORSRule", .children = children.items };
        rule_nodes[i] = .{ .element = rule_el };
    }

    const root: xml_out.Element = .{
        .name = "CORSConfiguration",
        .attrs = &.{xmlns_attr},
        .children = rule_nodes,
    };
    return xml_out.renderToOwnedSlice(allocator, &root);
}

fn freeRule(allocator: Allocator, r: storage.CorsRule) void {
    allocator.free(r.id);
    allocator.free(r.allowed_methods);
    for (r.allowed_origins) |s| allocator.free(s);
    allocator.free(r.allowed_origins);
    for (r.allowed_headers) |s| allocator.free(s);
    allocator.free(r.allowed_headers);
    for (r.expose_headers) |s| allocator.free(s);
    allocator.free(r.expose_headers);
}

pub fn freeOwned(allocator: Allocator, cfg: storage.CorsConfig) void {
    for (cfg.rules) |r| freeRule(allocator, r);
    allocator.free(cfg.rules);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parseBody: minimal rule" {
    const body =
        \\<CORSConfiguration>
        \\  <CORSRule>
        \\    <AllowedMethod>GET</AllowedMethod>
        \\    <AllowedOrigin>*</AllowedOrigin>
        \\  </CORSRule>
        \\</CORSConfiguration>
    ;
    const cfg = try parseBody(testing.allocator, body);
    defer freeOwned(testing.allocator, cfg);
    try testing.expectEqual(@as(usize, 1), cfg.rules.len);
    try testing.expectEqual(storage.HttpMethod.GET, cfg.rules[0].allowed_methods[0]);
    try testing.expectEqualStrings("*", cfg.rules[0].allowed_origins[0]);
}

test "parseBody: full rule with MaxAgeSeconds" {
    const body =
        \\<CORSConfiguration><CORSRule>
        \\<ID>r1</ID>
        \\<AllowedMethod>GET</AllowedMethod><AllowedMethod>PUT</AllowedMethod>
        \\<AllowedOrigin>https://example.com</AllowedOrigin>
        \\<AllowedHeader>*</AllowedHeader>
        \\<ExposeHeader>x-amz-version-id</ExposeHeader>
        \\<MaxAgeSeconds>3000</MaxAgeSeconds>
        \\</CORSRule></CORSConfiguration>
    ;
    const cfg = try parseBody(testing.allocator, body);
    defer freeOwned(testing.allocator, cfg);
    try testing.expectEqualStrings("r1", cfg.rules[0].id);
    try testing.expectEqual(@as(?u32, 3000), cfg.rules[0].max_age_seconds);
    try testing.expectEqual(@as(usize, 2), cfg.rules[0].allowed_methods.len);
}

test "parseBody: unknown method → MalformedXml" {
    const body = "<CORSConfiguration><CORSRule><AllowedMethod>PATCH</AllowedMethod></CORSRule></CORSConfiguration>";
    try testing.expectError(ParseError.MalformedXml, parseBody(testing.allocator, body));
}

test "render: round-trip" {
    const methods = [_]storage.HttpMethod{.GET};
    const origins = [_][]const u8{"*"};
    const rules = [_]storage.CorsRule{
        .{ .allowed_methods = &methods, .allowed_origins = &origins },
    };
    const cfg: storage.CorsConfig = .{ .rules = &rules };
    const body = try render(testing.allocator, cfg);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<AllowedMethod>GET</AllowedMethod>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<AllowedOrigin>*</AllowedOrigin>") != null);
}
