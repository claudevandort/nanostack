//! XML emitters for the seven multipart-upload operations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml.zig");
const storage = @import("../storage/mod.zig");
const s3_responses = @import("s3_responses.zig");

const xmlns_attr: xml.Attr = .{ .name = "xmlns", .value = "http://s3.amazonaws.com/doc/2006-03-01/" };

pub fn renderInitiateMultipartUploadResult(allocator: Allocator, bucket: []const u8, key: []const u8, upload_id: []const u8) ![]u8 {
    var bucket_el: xml.Element = .{ .name = "Bucket", .text = bucket };
    var key_el: xml.Element = .{ .name = "Key", .text = key };
    var id_el: xml.Element = .{ .name = "UploadId", .text = upload_id };
    const root: xml.Element = .{
        .name = "InitiateMultipartUploadResult",
        .attrs = &.{xmlns_attr},
        .children = &.{
            .{ .element = &bucket_el },
            .{ .element = &key_el },
            .{ .element = &id_el },
        },
    };
    return xml.renderToOwnedSlice(allocator, &root);
}

pub fn renderCompleteMultipartUploadResult(allocator: Allocator, location: []const u8, bucket: []const u8, key: []const u8, etag: []const u8) ![]u8 {
    var loc_el: xml.Element = .{ .name = "Location", .text = location };
    var bucket_el: xml.Element = .{ .name = "Bucket", .text = bucket };
    var key_el: xml.Element = .{ .name = "Key", .text = key };
    var etag_el: xml.Element = .{ .name = "ETag", .text = etag };
    const root: xml.Element = .{
        .name = "CompleteMultipartUploadResult",
        .attrs = &.{xmlns_attr},
        .children = &.{
            .{ .element = &loc_el },
            .{ .element = &bucket_el },
            .{ .element = &key_el },
            .{ .element = &etag_el },
        },
    };
    return xml.renderToOwnedSlice(allocator, &root);
}

pub fn renderCopyPartResult(allocator: Allocator, etag: []const u8, last_modified_unix: i64) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lm = try s3_responses.formatIso8601(arena, last_modified_unix);
    var lm_el: xml.Element = .{ .name = "LastModified", .text = lm };
    var etag_el: xml.Element = .{ .name = "ETag", .text = etag };
    const root: xml.Element = .{
        .name = "CopyPartResult",
        .attrs = &.{xmlns_attr},
        .children = &.{
            .{ .element = &lm_el },
            .{ .element = &etag_el },
        },
    };
    return xml.renderToOwnedSlice(allocator, &root);
}

pub const ListMultipartUploadsEcho = struct {
    prefix: []const u8 = "",
    delimiter: []const u8 = "",
    key_marker: []const u8 = "",
    upload_id_marker: []const u8 = "",
    max_uploads: u32 = 1000,
    encoding_type: ?[]const u8 = null,
};

pub fn renderListMultipartUploadsResult(
    allocator: Allocator,
    bucket: []const u8,
    echo: ListMultipartUploadsEcho,
    result: storage.ListMultipartUploadsOutput,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var children: std.ArrayList(xml.Node) = .empty;

    try appendText(arena, &children, "Bucket", bucket);
    try appendText(arena, &children, "KeyMarker", echo.key_marker);
    try appendText(arena, &children, "UploadIdMarker", echo.upload_id_marker);
    if (result.is_truncated) {
        try appendText(arena, &children, "NextKeyMarker", result.next_key_marker);
        try appendText(arena, &children, "NextUploadIdMarker", result.next_upload_id_marker);
    }
    // AWS-exact: emit Prefix and Delimiter unconditionally, even when empty.
    // Drift table row 9.
    try appendText(arena, &children, "Delimiter", echo.delimiter);
    try appendText(arena, &children, "Prefix", echo.prefix);
    const max_str = try std.fmt.allocPrint(arena, "{d}", .{echo.max_uploads});
    try appendText(arena, &children, "MaxUploads", max_str);
    if (echo.encoding_type) |et| try appendText(arena, &children, "EncodingType", et);
    try appendText(arena, &children, "IsTruncated", if (result.is_truncated) "true" else "false");

    for (result.uploads) |u| {
        try children.append(arena, .{ .element = try renderUpload(arena, u) });
    }
    for (result.common_prefixes) |cp| {
        try children.append(arena, .{ .element = try renderCommonPrefix(arena, cp) });
    }

    const root: xml.Element = .{
        .name = "ListMultipartUploadsResult",
        .attrs = &.{xmlns_attr},
        .children = children.items,
    };
    return xml.renderToOwnedSlice(allocator, &root);
}

pub const ListPartsEcho = struct {
    bucket: []const u8,
    key: []const u8,
    upload_id: []const u8,
    part_number_marker: u32 = 0,
    max_parts: u32 = 1000,
};

pub fn renderListPartsResult(
    allocator: Allocator,
    echo: ListPartsEcho,
    result: storage.ListPartsOutput,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var children: std.ArrayList(xml.Node) = .empty;

    try appendText(arena, &children, "Bucket", echo.bucket);
    try appendText(arena, &children, "Key", echo.key);
    try appendText(arena, &children, "UploadId", echo.upload_id);
    const pm_str = try std.fmt.allocPrint(arena, "{d}", .{echo.part_number_marker});
    try appendText(arena, &children, "PartNumberMarker", pm_str);
    if (result.is_truncated) {
        const npm = try std.fmt.allocPrint(arena, "{d}", .{result.next_part_number_marker});
        try appendText(arena, &children, "NextPartNumberMarker", npm);
    }
    const max_str = try std.fmt.allocPrint(arena, "{d}", .{echo.max_parts});
    try appendText(arena, &children, "MaxParts", max_str);
    try appendText(arena, &children, "IsTruncated", if (result.is_truncated) "true" else "false");

    for (result.parts) |p| {
        try children.append(arena, .{ .element = try renderPart(arena, p) });
    }

    const root: xml.Element = .{
        .name = "ListPartsResult",
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

fn renderUpload(arena: Allocator, u: storage.MultipartUploadInfo) !*xml.Element {
    const initiated = try s3_responses.formatIso8601(arena, u.initiated_unix);
    var key_el: xml.Element = .{ .name = "Key", .text = u.key };
    var id_el: xml.Element = .{ .name = "UploadId", .text = u.upload_id };
    var init_el: xml.Element = .{ .name = "Initiated", .text = initiated };
    var sc_el: xml.Element = .{ .name = "StorageClass", .text = "STANDARD" };
    const wrapper = try arena.create(xml.Element);
    wrapper.* = .{
        .name = "Upload",
        .children = try arena.dupe(xml.Node, &.{
            .{ .element = &key_el },
            .{ .element = &id_el },
            .{ .element = &init_el },
            .{ .element = &sc_el },
        }),
    };
    // Element children point to stack copies — we need to put them on the arena.
    // Repack with arena-owned children.
    const key_arena = try arena.create(xml.Element);
    key_arena.* = key_el;
    const id_arena = try arena.create(xml.Element);
    id_arena.* = id_el;
    const init_arena = try arena.create(xml.Element);
    init_arena.* = init_el;
    const sc_arena = try arena.create(xml.Element);
    sc_arena.* = sc_el;
    wrapper.children = try arena.dupe(xml.Node, &.{
        .{ .element = key_arena },
        .{ .element = id_arena },
        .{ .element = init_arena },
        .{ .element = sc_arena },
    });
    return wrapper;
}

fn renderPart(arena: Allocator, p: storage.PartInfo) !*xml.Element {
    const num_str = try std.fmt.allocPrint(arena, "{d}", .{p.part_number});
    const lm = try s3_responses.formatIso8601(arena, p.last_modified_unix);
    const size_str = try std.fmt.allocPrint(arena, "{d}", .{p.size});

    const num_el = try arena.create(xml.Element);
    num_el.* = .{ .name = "PartNumber", .text = num_str };
    const lm_el = try arena.create(xml.Element);
    lm_el.* = .{ .name = "LastModified", .text = lm };
    const etag_el = try arena.create(xml.Element);
    etag_el.* = .{ .name = "ETag", .text = p.etag };
    const size_el = try arena.create(xml.Element);
    size_el.* = .{ .name = "Size", .text = size_str };

    const wrapper = try arena.create(xml.Element);
    wrapper.* = .{
        .name = "Part",
        .children = try arena.dupe(xml.Node, &.{
            .{ .element = num_el },
            .{ .element = lm_el },
            .{ .element = etag_el },
            .{ .element = size_el },
        }),
    };
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

test "renderInitiateMultipartUploadResult: fixed values" {
    const body = try renderInitiateMultipartUploadResult(testing.allocator, "buk", "k", "uid-1234");
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<UploadId>uid-1234</UploadId>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<Bucket>buk</Bucket>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<Key>k</Key>") != null);
}

test "renderCompleteMultipartUploadResult: fixed values" {
    const body = try renderCompleteMultipartUploadResult(testing.allocator, "http://h/buk/k", "buk", "k", "\"abc-3\"");
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<Location>http://h/buk/k</Location>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<ETag>\"abc-3\"</ETag>") != null);
}

test "renderListPartsResult: ordered parts + size + etag" {
    var parts = [_]storage.PartInfo{
        .{ .part_number = 1, .size = 1024, .etag = "\"a\"", .last_modified_unix = 0 },
        .{ .part_number = 2, .size = 2048, .etag = "\"b\"", .last_modified_unix = 0 },
    };
    const result: storage.ListPartsOutput = .{ .parts = &parts, .is_truncated = false, .next_part_number_marker = 0 };
    const body = try renderListPartsResult(testing.allocator, .{
        .bucket = "buk",
        .key = "k",
        .upload_id = "u",
    }, result);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<PartNumber>1</PartNumber>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<Size>1024</Size>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<MaxParts>1000</MaxParts>") != null);
}

test "renderListMultipartUploadsResult: one upload" {
    var uploads = [_]storage.MultipartUploadInfo{
        .{ .key = "k1", .upload_id = "u1", .initiated_unix = 0 },
    };
    const result: storage.ListMultipartUploadsOutput = .{
        .uploads = &uploads,
        .common_prefixes = &.{},
        .is_truncated = false,
        .next_key_marker = "",
        .next_upload_id_marker = "",
    };
    const body = try renderListMultipartUploadsResult(testing.allocator, "buk", .{}, result);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<Upload>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<UploadId>u1</UploadId>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<IsTruncated>false</IsTruncated>") != null);
}

test "renderCopyPartResult: fixed values" {
    const body = try renderCopyPartResult(testing.allocator, "\"abc\"", 1778850000);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<LastModified>2026-05-15T13:00:00.000Z</LastModified>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<ETag>\"abc\"</ETag>") != null);
}
