//! S3 `ListObjects` and `ListObjectsV2` response bodies.
//!
//! V1: `GET /bucket` — `<ListBucketResult>` with `<Marker>` / `<NextMarker>`.
//! V2: `GET /bucket?list-type=2` — same root tag, but with
//!     `<KeyCount>`, `<ContinuationToken>` / `<NextContinuationToken>`,
//!     `<StartAfter>`, optional `<Owner>` per content.
//!
//! `LastModified` in the body uses ISO 8601 (AWS XML convention) — the
//! HTTP `Last-Modified` header uses a different format (handled in M3).

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml.zig");
const storage = @import("../storage/mod.zig");
const s3_responses = @import("s3_responses.zig");

const xmlns_attr: xml.Attr = .{ .name = "xmlns", .value = "http://s3.amazonaws.com/doc/2006-03-01/" };

/// Echo of the request's query parameters; used for the response
/// `<Prefix>`, `<Delimiter>`, etc. fields.
pub const RequestEcho = struct {
    prefix: []const u8 = "",
    delimiter: []const u8 = "",
    max_keys: u32 = 1000,
    encoding_type: ?[]const u8 = null,

    // V1-only:
    marker: []const u8 = "",

    // V2-only:
    continuation_token: ?[]const u8 = null,
    start_after: ?[]const u8 = null,
    fetch_owner: bool = false,
};

pub const OwnerInfo = struct {
    id: []const u8,
    display_name: []const u8,
};

pub fn renderListObjectsV1(
    allocator: Allocator,
    bucket: []const u8,
    echo: RequestEcho,
    result: storage.ListObjectsOutput,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var children: std.ArrayList(xml.Node) = .empty;

    try appendTextChild(arena, &children, "Name", bucket);
    try appendTextChild(arena, &children, "Prefix", echo.prefix);
    try appendTextChild(arena, &children, "Marker", echo.marker);
    if (result.is_truncated and echo.delimiter.len > 0) {
        try appendTextChild(arena, &children, "NextMarker", result.next_key);
    }
    const max_keys_str = try std.fmt.allocPrint(arena, "{d}", .{echo.max_keys});
    try appendTextChild(arena, &children, "MaxKeys", max_keys_str);
    // AWS-exact: emit Delimiter unconditionally (even empty). Drift table row 9.
    try appendTextChild(arena, &children, "Delimiter", echo.delimiter);
    if (echo.encoding_type) |et| {
        try appendTextChild(arena, &children, "EncodingType", et);
    }
    try appendTextChild(arena, &children, "IsTruncated", if (result.is_truncated) "true" else "false");

    for (result.contents) |obj| {
        try children.append(arena, .{ .element = try renderContent(arena, obj, null) });
    }
    for (result.common_prefixes) |cp| {
        try children.append(arena, .{ .element = try renderCommonPrefix(arena, cp) });
    }

    const root: xml.Element = .{
        .name = "ListBucketResult",
        .attrs = &.{xmlns_attr},
        .children = children.items,
    };
    return xml.renderToOwnedSlice(allocator, &root);
}

pub fn renderListObjectsV2(
    allocator: Allocator,
    bucket: []const u8,
    echo: RequestEcho,
    result: storage.ListObjectsOutput,
    owner: ?OwnerInfo,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var children: std.ArrayList(xml.Node) = .empty;

    try appendTextChild(arena, &children, "Name", bucket);
    try appendTextChild(arena, &children, "Prefix", echo.prefix);
    if (echo.continuation_token) |t| {
        try appendTextChild(arena, &children, "ContinuationToken", t);
    }
    if (result.is_truncated) {
        const token = try encodeContinuationToken(arena, result.next_key);
        try appendTextChild(arena, &children, "NextContinuationToken", token);
    }
    if (echo.start_after) |sa| {
        try appendTextChild(arena, &children, "StartAfter", sa);
    }
    // AWS-exact: emit Delimiter unconditionally (even empty). Drift table row 9.
    try appendTextChild(arena, &children, "Delimiter", echo.delimiter);
    const max_keys_str = try std.fmt.allocPrint(arena, "{d}", .{echo.max_keys});
    try appendTextChild(arena, &children, "MaxKeys", max_keys_str);
    if (echo.encoding_type) |et| {
        try appendTextChild(arena, &children, "EncodingType", et);
    }

    const key_count = result.contents.len + result.common_prefixes.len;
    const kc_str = try std.fmt.allocPrint(arena, "{d}", .{key_count});
    try appendTextChild(arena, &children, "KeyCount", kc_str);
    try appendTextChild(arena, &children, "IsTruncated", if (result.is_truncated) "true" else "false");

    const inject_owner: ?OwnerInfo = if (echo.fetch_owner) owner else null;
    for (result.contents) |obj| {
        try children.append(arena, .{ .element = try renderContent(arena, obj, inject_owner) });
    }
    for (result.common_prefixes) |cp| {
        try children.append(arena, .{ .element = try renderCommonPrefix(arena, cp) });
    }

    const root: xml.Element = .{
        .name = "ListBucketResult",
        .attrs = &.{xmlns_attr},
        .children = children.items,
    };
    return xml.renderToOwnedSlice(allocator, &root);
}

// ---------------------------------------------------------------------------
// Continuation token (V2): base64-url of the last key seen.

pub fn encodeContinuationToken(allocator: Allocator, last_key: []const u8) ![]const u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(last_key.len));
    return enc.encode(out, last_key);
}

/// Returns the decoded last_key. Caller owns the returned slice.
pub fn decodeContinuationToken(allocator: Allocator, token: []const u8) ![]u8 {
    const dec = std.base64.url_safe_no_pad.Decoder;
    const size = try dec.calcSizeForSlice(token);
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    try dec.decode(out, token);
    return out;
}

// ---------------------------------------------------------------------------
// Helpers

fn appendTextChild(arena: Allocator, list: *std.ArrayList(xml.Node), name: []const u8, text: []const u8) !void {
    const el = try arena.create(xml.Element);
    el.* = .{ .name = name, .text = text };
    try list.append(arena, .{ .element = el });
}

fn renderContent(arena: Allocator, obj: storage.Object, owner: ?OwnerInfo) !*xml.Element {
    const last_modified = try s3_responses.formatIso8601(arena, obj.last_modified_unix);
    const size_str = try std.fmt.allocPrint(arena, "{d}", .{obj.size});

    var nodes: std.ArrayList(xml.Node) = .empty;

    const key_el = try arena.create(xml.Element);
    key_el.* = .{ .name = "Key", .text = obj.key };
    try nodes.append(arena, .{ .element = key_el });

    const lm_el = try arena.create(xml.Element);
    lm_el.* = .{ .name = "LastModified", .text = last_modified };
    try nodes.append(arena, .{ .element = lm_el });

    const etag_el = try arena.create(xml.Element);
    etag_el.* = .{ .name = "ETag", .text = obj.etag };
    try nodes.append(arena, .{ .element = etag_el });

    const size_el = try arena.create(xml.Element);
    size_el.* = .{ .name = "Size", .text = size_str };
    try nodes.append(arena, .{ .element = size_el });

    const sc_el = try arena.create(xml.Element);
    sc_el.* = .{ .name = "StorageClass", .text = "STANDARD" };
    try nodes.append(arena, .{ .element = sc_el });

    if (owner) |o| {
        const id_el = try arena.create(xml.Element);
        id_el.* = .{ .name = "ID", .text = o.id };
        const dn_el = try arena.create(xml.Element);
        dn_el.* = .{ .name = "DisplayName", .text = o.display_name };
        const owner_el = try arena.create(xml.Element);
        owner_el.* = .{
            .name = "Owner",
            .children = try arena.dupe(xml.Node, &.{
                .{ .element = id_el },
                .{ .element = dn_el },
            }),
        };
        try nodes.append(arena, .{ .element = owner_el });
    }

    const wrapper = try arena.create(xml.Element);
    wrapper.* = .{ .name = "Contents", .children = nodes.items };
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

test "encodeContinuationToken / decodeContinuationToken round trip" {
    const t = try encodeContinuationToken(testing.allocator, "foo/bar.txt");
    defer testing.allocator.free(t);
    const back = try decodeContinuationToken(testing.allocator, t);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("foo/bar.txt", back);
}

test "renderListObjectsV1: empty result" {
    const result: storage.ListObjectsOutput = .{
        .contents = &.{},
        .common_prefixes = &.{},
        .is_truncated = false,
        .next_key = "",
    };
    const body = try renderListObjectsV1(testing.allocator, "buk", .{ .prefix = "", .marker = "" }, result);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<IsTruncated>false</IsTruncated>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<Name>buk</Name>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<MaxKeys>1000</MaxKeys>") != null);
}

test "renderListObjectsV2: KeyCount + NextContinuationToken when truncated" {
    var contents = [_]storage.Object{
        .{
            .key = "a",
            .size = 1,
            .etag = "\"x\"",
            .content_type = "text/plain",
            .last_modified_unix = 0,
            .user_metadata = &.{},
        },
    };
    const cp_a = [_][]const u8{"b/"};
    const result: storage.ListObjectsOutput = .{
        .contents = &contents,
        .common_prefixes = @constCast(&cp_a),
        .is_truncated = true,
        .next_key = "b/last",
    };
    const body = try renderListObjectsV2(testing.allocator, "buk", .{
        .delimiter = "/",
        .max_keys = 2,
    }, result, null);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<KeyCount>2</KeyCount>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<NextContinuationToken>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<Delimiter>/</Delimiter>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<Key>a</Key>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<CommonPrefixes><Prefix>b/</Prefix></CommonPrefixes>") != null);
}

test "renderListObjectsV2: fetch-owner emits Owner per content" {
    var contents = [_]storage.Object{
        .{
            .key = "a",
            .size = 1,
            .etag = "\"x\"",
            .content_type = "text/plain",
            .last_modified_unix = 0,
            .user_metadata = &.{},
        },
    };
    const result: storage.ListObjectsOutput = .{
        .contents = &contents,
        .common_prefixes = &.{},
        .is_truncated = false,
        .next_key = "",
    };
    const body = try renderListObjectsV2(testing.allocator, "buk", .{
        .fetch_owner = true,
    }, result, .{ .id = "user-id", .display_name = "User" });
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<Owner><ID>user-id</ID><DisplayName>User</DisplayName></Owner>") != null);
}
