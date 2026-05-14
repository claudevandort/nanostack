//! OwnershipControls XML parser + renderer (M10).
//!
//! Body shape:
//!     <OwnershipControls>
//!       <Rule><ObjectOwnership>BucketOwnerEnforced</ObjectOwnership></Rule>
//!     </OwnershipControls>
//!
//! We only persist the first Rule's ObjectOwnership value; AWS allows
//! multiple rules but in practice always one per bucket.

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

pub fn parse(allocator: Allocator, body: []const u8) ParseError!storage.OwnershipControl {
    var static_reader: xml_lib.Reader.Static = .init(allocator, body, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    while (true) {
        const node = reader.read() catch return ParseError.MalformedAcl;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "ObjectOwnership")) {
                    const text = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedAcl;
                    defer allocator.free(text);
                    return storage.ownershipControlFromString(text) catch return ParseError.MalformedAcl;
                }
            },
            else => {},
        }
    }
    return ParseError.MalformedAcl;
}

pub fn render(allocator: Allocator, oc: storage.OwnershipControl) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const oo_el = try arena.create(xml_out.Element);
    oo_el.* = .{ .name = "ObjectOwnership", .text = storage.ownershipControlToString(oc) };
    const rule_el = try arena.create(xml_out.Element);
    rule_el.* = .{ .name = "Rule", .children = try arena.dupe(xml_out.Node, &.{.{ .element = oo_el }}) };

    const root: xml_out.Element = .{
        .name = "OwnershipControls",
        .attrs = &.{xmlns_attr},
        .children = &.{.{ .element = rule_el }},
    };
    return xml_out.renderToOwnedSlice(allocator, &root);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parse: BucketOwnerEnforced" {
    const body = "<OwnershipControls><Rule><ObjectOwnership>BucketOwnerEnforced</ObjectOwnership></Rule></OwnershipControls>";
    const oc = try parse(testing.allocator, body);
    try testing.expectEqual(storage.OwnershipControl.BucketOwnerEnforced, oc);
}

test "parse: unknown value → MalformedAcl" {
    const body = "<OwnershipControls><Rule><ObjectOwnership>Frobnicate</ObjectOwnership></Rule></OwnershipControls>";
    try testing.expectError(ParseError.MalformedAcl, parse(testing.allocator, body));
}

test "parse: empty → MalformedAcl" {
    try testing.expectError(ParseError.MalformedAcl, parse(testing.allocator, "<OwnershipControls/>"));
}

test "render: ObjectWriter round-trip" {
    const body = try render(testing.allocator, .ObjectWriter);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<ObjectOwnership>ObjectWriter</ObjectOwnership>") != null);
}
