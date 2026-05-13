//! `<Tagging>` body emitter for the Get*Tagging responses (M9).

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml.zig");
const storage = @import("../storage/mod.zig");

const xmlns_attr: xml.Attr = .{ .name = "xmlns", .value = "http://s3.amazonaws.com/doc/2006-03-01/" };

pub fn renderTagging(allocator: Allocator, tags: []const storage.Tag) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tag_nodes = try arena.alloc(xml.Node, tags.len);
    for (tags, 0..) |t, i| {
        const key_el = try arena.create(xml.Element);
        key_el.* = .{ .name = "Key", .text = t.key };
        const val_el = try arena.create(xml.Element);
        val_el.* = .{ .name = "Value", .text = t.value };
        const tag_el = try arena.create(xml.Element);
        tag_el.* = .{
            .name = "Tag",
            .children = try arena.dupe(xml.Node, &.{
                .{ .element = key_el },
                .{ .element = val_el },
            }),
        };
        tag_nodes[i] = .{ .element = tag_el };
    }

    var tagset_el: xml.Element = .{
        .name = "TagSet",
        .children = tag_nodes,
    };

    const root: xml.Element = .{
        .name = "Tagging",
        .attrs = &.{xmlns_attr},
        .children = &.{
            .{ .element = &tagset_el },
        },
    };
    return xml.renderToOwnedSlice(allocator, &root);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "renderTagging: empty TagSet → self-closed" {
    const body = try renderTagging(testing.allocator, &.{});
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<TagSet/>") != null);
}

test "renderTagging: two tags" {
    const tags = [_]storage.Tag{
        .{ .key = "env", .value = "prod" },
        .{ .key = "team", .value = "alpha" },
    };
    const body = try renderTagging(testing.allocator, &tags);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<Tag><Key>env</Key><Value>prod</Value></Tag>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<Tag><Key>team</Key><Value>alpha</Value></Tag>") != null);
}
