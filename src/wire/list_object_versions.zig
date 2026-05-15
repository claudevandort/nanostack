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
const url_encode = @import("url_encode.zig");
const list_objects = @import("list_objects.zig");

pub const OwnerInfo = list_objects.OwnerInfo;

const xmlns_attr: xml.Attr = .{ .name = "xmlns", .value = "http://s3.amazonaws.com/doc/2006-03-01/" };

/// Percent-encode `raw` when `encoding_type == "url"`. AWS-exact handling
/// of the listing `encoding-type=url` query param. Drift table row 8.
fn maybeEncode(arena: Allocator, raw: []const u8, encoding_type: ?[]const u8) ![]const u8 {
    if (encoding_type) |et| {
        if (std.mem.eql(u8, et, "url")) {
            return try url_encode.percentEncode(arena, raw);
        }
    }
    return raw;
}

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
    owner: OwnerInfo,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var children: std.ArrayList(xml.Node) = .empty;

    try appendText(arena, &children, "Name", bucket);
    try appendText(arena, &children, "Prefix", try maybeEncode(arena, echo.prefix, echo.encoding_type));
    try appendText(arena, &children, "KeyMarker", try maybeEncode(arena, echo.key_marker, echo.encoding_type));
    // VersionIdMarker is an opaque server token — not user data; skip encoding.
    try appendText(arena, &children, "VersionIdMarker", echo.version_id_marker);
    if (result.is_truncated) {
        try appendText(arena, &children, "NextKeyMarker", try maybeEncode(arena, result.next_key_marker, echo.encoding_type));
        try appendText(arena, &children, "NextVersionIdMarker", result.next_version_id_marker);
    }
    const max_str = try std.fmt.allocPrint(arena, "{d}", .{echo.max_keys});
    try appendText(arena, &children, "MaxKeys", max_str);
    // AWS-exact: emit Delimiter unconditionally (Prefix already is). Drift row 9.
    try appendText(arena, &children, "Delimiter", try maybeEncode(arena, echo.delimiter, echo.encoding_type));
    if (echo.encoding_type) |et| try appendText(arena, &children, "EncodingType", et);
    try appendText(arena, &children, "IsTruncated", if (result.is_truncated) "true" else "false");

    for (result.versions) |v| {
        try children.append(arena, .{ .element = try renderVersionEntry(arena, v, echo.encoding_type, owner) });
    }
    for (result.common_prefixes) |cp| {
        try children.append(arena, .{ .element = try renderCommonPrefix(arena, cp, echo.encoding_type) });
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

fn renderVersionEntry(arena: Allocator, v: storage.ObjectVersion, encoding_type: ?[]const u8, owner: OwnerInfo) !*xml.Element {
    const lm = try s3_responses.formatIso8601(arena, v.last_modified_unix);
    const size_str = try std.fmt.allocPrint(arena, "{d}", .{v.size});

    const key_el = try arena.create(xml.Element);
    key_el.* = .{ .name = "Key", .text = try maybeEncode(arena, v.key, encoding_type) };
    const vid_el = try arena.create(xml.Element);
    vid_el.* = .{ .name = "VersionId", .text = v.version_id };
    const latest_el = try arena.create(xml.Element);
    latest_el.* = .{ .name = "IsLatest", .text = if (v.is_latest) "true" else "false" };
    const lm_el = try arena.create(xml.Element);
    lm_el.* = .{ .name = "LastModified", .text = lm };

    // AWS-exact: every <Version> and <DeleteMarker> carries an <Owner> block.
    // Drift table row 7.
    const id_el = try arena.create(xml.Element);
    id_el.* = .{ .name = "ID", .text = owner.id };
    const dn_el = try arena.create(xml.Element);
    dn_el.* = .{ .name = "DisplayName", .text = owner.display_name };
    const owner_el = try arena.create(xml.Element);
    owner_el.* = .{
        .name = "Owner",
        .children = try arena.dupe(xml.Node, &.{
            .{ .element = id_el },
            .{ .element = dn_el },
        }),
    };

    const wrapper = try arena.create(xml.Element);
    if (v.is_delete_marker) {
        wrapper.* = .{
            .name = "DeleteMarker",
            .children = try arena.dupe(xml.Node, &.{
                .{ .element = key_el },
                .{ .element = vid_el },
                .{ .element = latest_el },
                .{ .element = lm_el },
                .{ .element = owner_el },
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
                .{ .element = owner_el },
            }),
        };
    }
    return wrapper;
}

fn renderCommonPrefix(arena: Allocator, prefix: []const u8, encoding_type: ?[]const u8) !*xml.Element {
    const text_el = try arena.create(xml.Element);
    text_el.* = .{ .name = "Prefix", .text = try maybeEncode(arena, prefix, encoding_type) };
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
    const body = try renderListVersionsResult(testing.allocator, "buk", .{}, result, .{ .id = "test", .display_name = "nanostack" });
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
    const body = try renderListVersionsResult(testing.allocator, "buk", .{}, result, .{ .id = "test", .display_name = "nanostack" });
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<Version>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<DeleteMarker>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<VersionId>v1</VersionId>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<VersionId>v2</VersionId>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<IsLatest>true</IsLatest>") != null);
    // Owner must be emitted on both <Version> and <DeleteMarker> (drift row 7).
    try testing.expect(std.mem.indexOf(u8, body, "<Owner><ID>test</ID><DisplayName>nanostack</DisplayName></Owner>") != null);
}
