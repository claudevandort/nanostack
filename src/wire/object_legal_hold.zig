//! Object legal hold XML parser + renderer (M12).
//!
//! Body shape: <LegalHold><Status>ON</Status></LegalHold>

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

pub fn parseBody(allocator: Allocator, body: []const u8) ParseError!storage.LegalHoldStatus {
    var static_reader: xml_lib.Reader.Static = .init(allocator, body, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    while (true) {
        const node = reader.read() catch return ParseError.MalformedXml;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "Status")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    return storage.legalHoldFromString(txt) catch return ParseError.MalformedXml;
                }
            },
            else => {},
        }
    }
    return ParseError.MalformedXml;
}

pub fn render(allocator: Allocator, status: storage.LegalHoldStatus) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const status_el = try arena.create(xml_out.Element);
    status_el.* = .{ .name = "Status", .text = storage.legalHoldToString(status) };

    const root: xml_out.Element = .{
        .name = "LegalHold",
        .attrs = &.{xmlns_attr},
        .children = try arena.dupe(xml_out.Node, &.{.{ .element = status_el }}),
    };
    return xml_out.renderToOwnedSlice(allocator, &root);
}

const testing = std.testing;

test "parseBody: ON" {
    const status = try parseBody(testing.allocator, "<LegalHold><Status>ON</Status></LegalHold>");
    try testing.expectEqual(storage.LegalHoldStatus.ON, status);
}

test "parseBody: OFF" {
    const status = try parseBody(testing.allocator, "<LegalHold><Status>OFF</Status></LegalHold>");
    try testing.expectEqual(storage.LegalHoldStatus.OFF, status);
}

test "render: ON" {
    const body = try render(testing.allocator, .ON);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<Status>ON</Status>") != null);
}
