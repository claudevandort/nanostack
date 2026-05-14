//! `<PolicyStatus>` body renderer for GetBucketPolicyStatus (M13).
//! Render-only; the op is GET, no body parsing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml_out = @import("xml.zig");

const xmlns_attr: xml_out.Attr = .{ .name = "xmlns", .value = "http://s3.amazonaws.com/doc/2006-03-01/" };

pub fn render(allocator: Allocator, is_public: bool) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const is_public_el = try arena.create(xml_out.Element);
    is_public_el.* = .{ .name = "IsPublic", .text = if (is_public) "true" else "false" };

    const root: xml_out.Element = .{
        .name = "PolicyStatus",
        .attrs = &.{xmlns_attr},
        .children = try arena.dupe(xml_out.Node, &.{.{ .element = is_public_el }}),
    };
    return xml_out.renderToOwnedSlice(allocator, &root);
}

const testing = std.testing;

test "render: true" {
    const body = try render(testing.allocator, true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<IsPublic>true</IsPublic>") != null);
}

test "render: false" {
    const body = try render(testing.allocator, false);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<IsPublic>false</IsPublic>") != null);
}
