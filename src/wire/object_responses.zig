//! S3 object-operation response bodies.
//!
//! M3 only ships one body shape here: `DeleteResult` from DeleteObjects.
//! The other object operations have either an empty body (PutObject,
//! DeleteObject, HeadObject) or the raw object bytes (GetObject).

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml.zig");
const storage = @import("../storage/mod.zig");
const s3_responses = @import("s3_responses.zig");

/// Render the `<DeleteResult>` body for a `DeleteObjects` response.
/// Caller owns the returned slice.
pub fn renderDeleteResult(allocator: Allocator, result: storage.DeleteResult) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Pre-allocate the children list (sum of deleted + errors).
    const deleted_count = if (result.quiet) 0 else result.deleted.len;
    var children = try arena.alloc(xml.Node, deleted_count + result.errors.len);
    var ci: usize = 0;

    if (!result.quiet) {
        for (result.deleted) |d| {
            // Build children: Key (always), VersionId (when set), DeleteMarker
            // (when set), DeleteMarkerVersionId (when set). AWS-exact order.
            var inner: std.ArrayList(xml.Node) = .empty;
            defer inner.deinit(arena);

            const key_el = try arena.create(xml.Element);
            key_el.* = .{ .name = "Key", .text = d.key };
            try inner.append(arena, .{ .element = key_el });

            if (d.version_id) |v| {
                const ver_el = try arena.create(xml.Element);
                ver_el.* = .{ .name = "VersionId", .text = v };
                try inner.append(arena, .{ .element = ver_el });
            }
            if (d.delete_marker) {
                const dm_el = try arena.create(xml.Element);
                dm_el.* = .{ .name = "DeleteMarker", .text = "true" };
                try inner.append(arena, .{ .element = dm_el });
                if (d.delete_marker_version_id) |v| {
                    const dmvid_el = try arena.create(xml.Element);
                    dmvid_el.* = .{ .name = "DeleteMarkerVersionId", .text = v };
                    try inner.append(arena, .{ .element = dmvid_el });
                }
            }

            const wrapper = try arena.create(xml.Element);
            wrapper.* = .{
                .name = "Deleted",
                .children = try arena.dupe(xml.Node, inner.items),
            };
            children[ci] = .{ .element = wrapper };
            ci += 1;
        }
    }

    for (result.errors) |e| {
        const key_el = try arena.create(xml.Element);
        key_el.* = .{ .name = "Key", .text = e.key };
        const code_el = try arena.create(xml.Element);
        code_el.* = .{ .name = "Code", .text = e.code };
        const msg_el = try arena.create(xml.Element);
        msg_el.* = .{ .name = "Message", .text = e.message };
        const wrapper = try arena.create(xml.Element);
        wrapper.* = .{
            .name = "Error",
            .children = try arena.dupe(xml.Node, &.{
                .{ .element = key_el },
                .{ .element = code_el },
                .{ .element = msg_el },
            }),
        };
        children[ci] = .{ .element = wrapper };
        ci += 1;
    }

    const root: xml.Element = .{
        .name = "DeleteResult",
        .attrs = &.{.{ .name = "xmlns", .value = "http://s3.amazonaws.com/doc/2006-03-01/" }},
        .children = children[0..ci],
    };
    return xml.renderToOwnedSlice(allocator, &root);
}

/// Render `<CopyObjectResult>` for a successful CopyObject. `etag` must
/// include the surrounding double quotes (the stored form). `LastModified`
/// uses ISO 8601 (the AWS XML body convention) — distinct from the HTTP
/// `Last-Modified` header which is RFC 7231.
pub fn renderCopyObjectResult(allocator: Allocator, etag: []const u8, last_modified_unix: i64) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lm = try s3_responses.formatIso8601(arena, last_modified_unix);
    var lm_el: xml.Element = .{ .name = "LastModified", .text = lm };
    var etag_el: xml.Element = .{ .name = "ETag", .text = etag };

    const root: xml.Element = .{
        .name = "CopyObjectResult",
        .attrs = &.{.{ .name = "xmlns", .value = "http://s3.amazonaws.com/doc/2006-03-01/" }},
        .children = &.{
            .{ .element = &lm_el },
            .{ .element = &etag_el },
        },
    };
    return xml.renderToOwnedSlice(allocator, &root);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "renderDeleteResult: two deleted, one error" {
    const result: storage.DeleteResult = .{
        .deleted = @constCast(&[_]storage.DeletedKey{
            .{ .key = "a" },
            .{ .key = "b" },
        }),
        .errors = @constCast(&[_]storage.DeleteError{
            .{ .key = "c", .code = "AccessDenied", .message = "nope" },
        }),
    };
    const body = try renderDeleteResult(testing.allocator, result);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<DeleteResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" ++
            "<Deleted><Key>a</Key></Deleted>" ++
            "<Deleted><Key>b</Key></Deleted>" ++
            "<Error><Key>c</Key><Code>AccessDenied</Code><Message>nope</Message></Error>" ++
            "</DeleteResult>",
        body,
    );
}

test "renderCopyObjectResult: fixed epoch" {
    // 2026-05-15T13:00:00Z = 1778850000
    const body = try renderCopyObjectResult(testing.allocator, "\"deadbeef\"", 1778850000);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<CopyObjectResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" ++
            "<LastModified>2026-05-15T13:00:00.000Z</LastModified>" ++
            "<ETag>\"deadbeef\"</ETag>" ++
            "</CopyObjectResult>",
        body,
    );
}

test "renderDeleteResult: VersionId + DeleteMarker echoed when present" {
    const result: storage.DeleteResult = .{
        .deleted = @constCast(&[_]storage.DeletedKey{
            .{ .key = "a", .version_id = "v1" },
            .{ .key = "b", .delete_marker = true, .delete_marker_version_id = "dmv1" },
        }),
        .errors = &[_]storage.DeleteError{},
    };
    const body = try renderDeleteResult(testing.allocator, result);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<DeleteResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" ++
            "<Deleted><Key>a</Key><VersionId>v1</VersionId></Deleted>" ++
            "<Deleted><Key>b</Key><DeleteMarker>true</DeleteMarker><DeleteMarkerVersionId>dmv1</DeleteMarkerVersionId></Deleted>" ++
            "</DeleteResult>",
        body,
    );
}

test "renderDeleteResult: quiet mode suppresses Deleted entries" {
    const result: storage.DeleteResult = .{
        .deleted = @constCast(&[_]storage.DeletedKey{
            .{ .key = "a" },
        }),
        .errors = @constCast(&[_]storage.DeleteError{
            .{ .key = "b", .code = "AccessDenied", .message = "nope" },
        }),
        .quiet = true,
    };
    const body = try renderDeleteResult(testing.allocator, result);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<DeleteResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" ++
            "<Error><Key>b</Key><Code>AccessDenied</Code><Message>nope</Message></Error>" ++
            "</DeleteResult>",
        body,
    );
}
