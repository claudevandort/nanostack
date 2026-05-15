//! `<ListVersionsResult>` XML emitter for the M8 `ListObjectVersions` op.
//!
//! Shape per AWS:
//!   <ListVersionsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
//!     <Name>bucket</Name>
//!     <Prefix>…</Prefix>
//!     <KeyMarker>…</KeyMarker>
//!     <VersionIdMarker>…</VersionIdMarker>
//!     <NextKeyMarker>…</NextKeyMarker>            ← when truncated
//!     <NextVersionIdMarker>…</NextVersionIdMarker> ← when truncated
//!     <MaxKeys>1000</MaxKeys>
//!     <Delimiter>…</Delimiter>                     ← when set
//!     <IsTruncated>true|false</IsTruncated>
//!     <Version>…</Version>* / <DeleteMarker>…</DeleteMarker>*
//!     <CommonPrefixes><Prefix>…</Prefix></CommonPrefixes>*
//!   </ListVersionsResult>

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml.zig");
const storage = @import("../storage/mod.zig");
const s3_responses = @import("s3_responses.zig");

const xmlns_attr: xml.Attr = .{ .name = "xmlns", .value = "http://s3.amazonaws.com/doc/2006-03-01/" };

pub const Echo = struct {
    prefix: []const u8 = "",
    delimiter: []const u8 = "",
    key_marker: []const u8 = "",
    version_id_marker: []const u8 = "",
    max_keys: u32 = 1000,
    encoding_type: ?[]const u8 = null,
};

pub fn renderListVersionsResult(
    allocator: Allocator,
    bucket: []const u8,
    echo: Echo,
    result: storage.ListObjectVersionsOutput,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var children: std.ArrayList(xml.Node) = .empty;

    try appendText(arena, &children, "Name", bucket);
    try appendText(arena, &children, "Prefix", echo.prefix);
    try appendText(arena, &children, "KeyMarker", echo.key_marker);
    try appendText(arena, &children, "VersionIdMarker", echo.version_id_marker);
    if (result.is_truncated) {
        try appendText(arena, &children, "NextKeyMarker", result.next_key_marker);
        try appendText(arena, &children, "NextVersionIdMarker", result.next_version_id_marker);
    }
    const max_str = try std.fmt.allocPrint(arena, "{d}", .{echo.max_keys});
    try appendText(arena, &children, "MaxKeys", max_str);
    // AWS-exact: emit Delimiter unconditionally (Prefix already is). Drift row 9.
    try appendText(arena, &children, "Delimiter", echo.delimiter);
    if (echo.encoding_type) |et| try appendText(arena, &children, "EncodingType", et);
    try appendText(arena, &children, "IsTruncated", if (result.is_truncated) "true" else "false");

    for (result.versions) |v| {
        try children.append(arena, .{ .element = try renderVersionEntry(arena, v) });
    }
    for (result.common_prefixes) |cp| {
        try children.append(arena, .{ .element = try renderCommonPrefix(arena, cp) });
    }

    const root: xml.Element = .{
        .name = "ListVersionsResult",
        .attrs = &.{xmlns_attr},
        .children = children.items,
    };
    return xml.renderToOwnedSlice(allocator, &root);
}

// ---------------------------------------------------------------------------
// Helpers

fn appendText(arena: Allocator, list: *std.ArrayList(xml.Node), name: []const u8, text: []const u8) !void {
    const el = try arena.create(xml.Element);
    el.* = .{ .name = name, .text = text };
    try list.append(arena, .{ .element = el });
}

fn renderVersionEntry(arena: Allocator, v: storage.ObjectVersion) !*xml.Element {
    const lm = try s3_responses.formatIso8601(arena, v.last_modified_unix);
    const size_str = try std.fmt.allocPrint(arena, "{d}", .{v.size});

    const key_el = try arena.create(xml.Element);
    key_el.* = .{ .name = "Key", .text = v.key };
    const vid_el = try arena.create(xml.Element);
    vid_el.* = .{ .name = "VersionId", .text = v.version_id };
    const latest_el = try arena.create(xml.Element);
    latest_el.* = .{ .name = "IsLatest", .text = if (v.is_latest) "true" else "false" };
    const lm_el = try arena.create(xml.Element);
    lm_el.* = .{ .name = "LastModified", .text = lm };

    const wrapper = try arena.create(xml.Element);
    if (v.is_delete_marker) {
        wrapper.* = .{
            .name = "DeleteMarker",
            .children = try arena.dupe(xml.Node, &.{
                .{ .element = key_el },
                .{ .element = vid_el },
                .{ .element = latest_el },
                .{ .element = lm_el },
            }),
        };
    } else {
        const etag_el = try arena.create(xml.Element);
        etag_el.* = .{ .name = "ETag", .text = v.etag };
        const size_el = try arena.create(xml.Element);
        size_el.* = .{ .name = "Size", .text = size_str };
        const sc_el = try arena.create(xml.Element);
        sc_el.* = .{ .name = "StorageClass", .text = "STANDARD" };
        wrapper.* = .{
            .name = "Version",
            .children = try arena.dupe(xml.Node, &.{
                .{ .element = key_el },
                .{ .element = vid_el },
                .{ .element = latest_el },
                .{ .element = lm_el },
                .{ .element = etag_el },
                .{ .element = size_el },
                .{ .element = sc_el },
            }),
        };
    }
    return wrapper;
}

fn renderCommonPrefix(arena: Allocator, prefix: []const u8) !*xml.Element {
    const text_el = try arena.create(xml.Element);
    text_el.* = .{ .name = "Prefix", .text = prefix };
    const wrapper = try arena.create(xml.Element);
    wrapper.* = .{
        .name = "CommonPrefixes",
        .children = try arena.dupe(xml.Node, &.{.{ .element = text_el }}),
    };
    return wrapper;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "render empty result" {
    const result: storage.ListObjectVersionsOutput = .{
        .versions = &.{},
        .common_prefixes = &.{},
        .is_truncated = false,
        .next_key_marker = "",
        .next_version_id_marker = "",
    };
    const body = try renderListVersionsResult(testing.allocator, "buk", .{}, result);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<Name>buk</Name>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<IsTruncated>false</IsTruncated>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<MaxKeys>1000</MaxKeys>") != null);
}

test "render one version + one delete marker" {
    var versions = [_]storage.ObjectVersion{
        .{ .key = "k", .version_id = "v1", .is_latest = false, .is_delete_marker = false, .last_modified_unix = 0, .etag = "\"a\"", .size = 5 },
        .{ .key = "k", .version_id = "v2", .is_latest = true, .is_delete_marker = true, .last_modified_unix = 100 },
    };
    const result: storage.ListObjectVersionsOutput = .{
        .versions = &versions,
        .common_prefixes = &.{},
        .is_truncated = false,
        .next_key_marker = "",
        .next_version_id_marker = "",
    };
    const body = try renderListVersionsResult(testing.allocator, "buk", .{}, result);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<Version>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<DeleteMarker>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<VersionId>v1</VersionId>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<VersionId>v2</VersionId>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<IsLatest>true</IsLatest>") != null);
}
