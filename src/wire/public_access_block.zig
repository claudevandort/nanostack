//! PublicAccessBlockConfiguration XML parser + renderer (M10).
//!
//! Body shape:
//!     <PublicAccessBlockConfiguration>
//!       <BlockPublicAcls>true</BlockPublicAcls>
//!       <IgnorePublicAcls>true</IgnorePublicAcls>
//!       <BlockPublicPolicy>true</BlockPublicPolicy>
//!       <RestrictPublicBuckets>true</RestrictPublicBuckets>
//!     </PublicAccessBlockConfiguration>

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml_lib = @import("xml");
const xml_out = @import("xml.zig");
const storage = @import("../storage/mod.zig");

const xmlns_attr: xml_out.Attr = .{ .name = "xmlns", .value = "http://s3.amazonaws.com/doc/2006-03-01/" };

pub const ParseError = error{
    MalformedAcl,
    OutOfMemory,
};

pub fn parse(allocator: Allocator, body: []const u8) ParseError!storage.PublicAccessBlockConfig {
    var static_reader: xml_lib.Reader.Static = .init(allocator, body, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var out: storage.PublicAccessBlockConfig = .{};
    while (true) {
        const node = reader.read() catch return ParseError.MalformedAcl;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "BlockPublicAcls")) {
                    out.block_public_acls = try readBool(allocator, reader);
                } else if (std.mem.eql(u8, name, "IgnorePublicAcls")) {
                    out.ignore_public_acls = try readBool(allocator, reader);
                } else if (std.mem.eql(u8, name, "BlockPublicPolicy")) {
                    out.block_public_policy = try readBool(allocator, reader);
                } else if (std.mem.eql(u8, name, "RestrictPublicBuckets")) {
                    out.restrict_public_buckets = try readBool(allocator, reader);
                }
            },
            else => {},
        }
    }
    return out;
}

fn readBool(allocator: Allocator, reader: *xml_lib.Reader) ParseError!bool {
    const text = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedAcl;
    defer allocator.free(text);
    return std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "TRUE") or std.mem.eql(u8, text, "True") or std.mem.eql(u8, text, "1");
}

pub fn render(allocator: Allocator, pab: storage.PublicAccessBlockConfig) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bpa = try arena.create(xml_out.Element);
    bpa.* = .{ .name = "BlockPublicAcls", .text = if (pab.block_public_acls) "true" else "false" };
    const ipa = try arena.create(xml_out.Element);
    ipa.* = .{ .name = "IgnorePublicAcls", .text = if (pab.ignore_public_acls) "true" else "false" };
    const bpp = try arena.create(xml_out.Element);
    bpp.* = .{ .name = "BlockPublicPolicy", .text = if (pab.block_public_policy) "true" else "false" };
    const rpb = try arena.create(xml_out.Element);
    rpb.* = .{ .name = "RestrictPublicBuckets", .text = if (pab.restrict_public_buckets) "true" else "false" };

    const root: xml_out.Element = .{
        .name = "PublicAccessBlockConfiguration",
        .attrs = &.{xmlns_attr},
        .children = &.{
            .{ .element = bpa },
            .{ .element = ipa },
            .{ .element = bpp },
            .{ .element = rpb },
        },
    };
    return xml_out.renderToOwnedSlice(allocator, &root);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parse: all true round-trip" {
    const body =
        \\<PublicAccessBlockConfiguration>
        \\  <BlockPublicAcls>true</BlockPublicAcls>
        \\  <IgnorePublicAcls>true</IgnorePublicAcls>
        \\  <BlockPublicPolicy>true</BlockPublicPolicy>
        \\  <RestrictPublicBuckets>true</RestrictPublicBuckets>
        \\</PublicAccessBlockConfiguration>
    ;
    const pab = try parse(testing.allocator, body);
    try testing.expect(pab.block_public_acls);
    try testing.expect(pab.ignore_public_acls);
    try testing.expect(pab.block_public_policy);
    try testing.expect(pab.restrict_public_buckets);
}

test "parse: missing fields default to false" {
    const pab = try parse(testing.allocator, "<PublicAccessBlockConfiguration></PublicAccessBlockConfiguration>");
    try testing.expect(!pab.block_public_acls);
    try testing.expect(!pab.ignore_public_acls);
    try testing.expect(!pab.block_public_policy);
    try testing.expect(!pab.restrict_public_buckets);
}

test "render: mixed values" {
    const body = try render(testing.allocator, .{ .block_public_acls = true, .restrict_public_buckets = true });
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<BlockPublicAcls>true</BlockPublicAcls>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<IgnorePublicAcls>false</IgnorePublicAcls>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<RestrictPublicBuckets>true</RestrictPublicBuckets>") != null);
}
