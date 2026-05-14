//! GetObjectAttributes XML response renderer (M11).
//!
//! Body shape (only the selected attributes are included):
//!     <GetObjectAttributesOutput>
//!       <ETag>"..."</ETag>
//!       <Checksum>...</Checksum>
//!       <ObjectParts><PartsCount>N</PartsCount></ObjectParts>
//!       <StorageClass>STANDARD</StorageClass>
//!       <ObjectSize>1234</ObjectSize>
//!     </GetObjectAttributesOutput>
//!
//! The selector is the `x-amz-object-attributes` request header,
//! comma-separated.

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml_out = @import("xml.zig");

const xmlns_attr: xml_out.Attr = .{ .name = "xmlns", .value = "http://s3.amazonaws.com/doc/2006-03-01/" };

pub const Selected = struct {
    etag: bool = false,
    checksum: bool = false,
    object_parts: bool = false,
    storage_class: bool = false,
    object_size: bool = false,

    pub fn parseHeader(value: []const u8) Selected {
        var out: Selected = .{};
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |raw| {
            const tok = std.mem.trim(u8, raw, " \t");
            if (std.mem.eql(u8, tok, "ETag")) {
                out.etag = true;
            } else if (std.mem.eql(u8, tok, "Checksum")) {
                out.checksum = true;
            } else if (std.mem.eql(u8, tok, "ObjectParts")) {
                out.object_parts = true;
            } else if (std.mem.eql(u8, tok, "StorageClass")) {
                out.storage_class = true;
            } else if (std.mem.eql(u8, tok, "ObjectSize")) {
                out.object_size = true;
            }
        }
        return out;
    }

    pub fn anySelected(self: Selected) bool {
        return self.etag or self.checksum or self.object_parts or self.storage_class or self.object_size;
    }
};

pub const Attrs = struct {
    etag: []const u8 = "",      // includes surrounding quotes
    storage_class: []const u8 = "STANDARD",
    object_size: u64 = 0,
    /// Total parts count when the object came from a multipart upload.
    /// `null` for non-multipart objects — the selector still works but
    /// `<ObjectParts/>` is emitted empty.
    parts_count: ?u32 = null,
};

pub fn render(allocator: Allocator, sel: Selected, a: Attrs) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var children: std.ArrayList(xml_out.Node) = .empty;
    if (sel.etag and a.etag.len > 0) {
        const e = try arena.create(xml_out.Element);
        e.* = .{ .name = "ETag", .text = a.etag };
        try children.append(arena, .{ .element = e });
    }
    if (sel.checksum) {
        // We don't compute checksums (no Checksum metadata yet); emit empty.
        const e = try arena.create(xml_out.Element);
        e.* = .{ .name = "Checksum" };
        try children.append(arena, .{ .element = e });
    }
    if (sel.object_parts) {
        var kids: std.ArrayList(xml_out.Node) = .empty;
        if (a.parts_count) |n| {
            const e = try arena.create(xml_out.Element);
            e.* = .{ .name = "PartsCount", .text = try std.fmt.allocPrint(arena, "{d}", .{n}) };
            try kids.append(arena, .{ .element = e });
        }
        const op_el = try arena.create(xml_out.Element);
        op_el.* = .{ .name = "ObjectParts", .children = kids.items };
        try children.append(arena, .{ .element = op_el });
    }
    if (sel.storage_class) {
        const e = try arena.create(xml_out.Element);
        e.* = .{ .name = "StorageClass", .text = a.storage_class };
        try children.append(arena, .{ .element = e });
    }
    if (sel.object_size) {
        const e = try arena.create(xml_out.Element);
        e.* = .{ .name = "ObjectSize", .text = try std.fmt.allocPrint(arena, "{d}", .{a.object_size}) };
        try children.append(arena, .{ .element = e });
    }

    const root: xml_out.Element = .{
        .name = "GetObjectAttributesOutput",
        .attrs = &.{xmlns_attr},
        .children = children.items,
    };
    return xml_out.renderToOwnedSlice(allocator, &root);
}

/// Parse the part count from a multipart ETag suffix (`"<hex>-N"`).
/// Returns null for non-multipart ETags.
pub fn partsCountFromEtag(etag_quoted: []const u8) ?u32 {
    const stripped = std.mem.trim(u8, etag_quoted, "\"");
    const dash = std.mem.lastIndexOfScalar(u8, stripped, '-') orelse return null;
    if (dash == 0 or dash == stripped.len - 1) return null;
    return std.fmt.parseInt(u32, stripped[dash + 1 ..], 10) catch null;
}

const testing = std.testing;

test "Selected.parseHeader: subset" {
    const sel = Selected.parseHeader("ETag, ObjectSize, StorageClass");
    try testing.expect(sel.etag);
    try testing.expect(sel.object_size);
    try testing.expect(sel.storage_class);
    try testing.expect(!sel.checksum);
    try testing.expect(!sel.object_parts);
}

test "render: ETag + ObjectSize" {
    const sel: Selected = .{ .etag = true, .object_size = true };
    const a: Attrs = .{ .etag = "\"abc123\"", .object_size = 1024 };
    const body = try render(testing.allocator, sel, a);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<ETag>\"abc123\"</ETag>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<ObjectSize>1024</ObjectSize>") != null);
}

test "render: ObjectParts with count" {
    const sel: Selected = .{ .object_parts = true };
    const a: Attrs = .{ .parts_count = 4 };
    const body = try render(testing.allocator, sel, a);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<ObjectParts><PartsCount>4</PartsCount></ObjectParts>") != null);
}

test "partsCountFromEtag" {
    try testing.expectEqual(@as(?u32, 5), partsCountFromEtag("\"abc-5\""));
    try testing.expectEqual(@as(?u32, null), partsCountFromEtag("\"abc\""));
    try testing.expectEqual(@as(?u32, null), partsCountFromEtag(""));
}
