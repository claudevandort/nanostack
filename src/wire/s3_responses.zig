//! S3 success response bodies.
//!
//! M1 ships one: `ListAllMyBucketsResult`. Future milestones add more here
//! (ListObjectsV2, CompleteMultipartUploadResult, etc.).

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml.zig");
const storage = @import("../storage/mod.zig");

/// Render the ListBuckets response body. Caller owns the returned slice.
///
/// `owner_id` is the canonical user ID; we use the configured access key.
/// `display_name` is the human-friendly owner name.
pub fn renderListAllMyBucketsResult(
    allocator: Allocator,
    owner_id: []const u8,
    display_name: []const u8,
    buckets: []const storage.Bucket,
) ![]u8 {
    // Build child element backing storage on a single arena so we don't
    // have to free a hundred tiny allocations on the happy path.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var owner_id_el: xml.Element = .{ .name = "ID", .text = owner_id };
    var owner_display_el: xml.Element = .{ .name = "DisplayName", .text = display_name };
    var owner_el: xml.Element = .{
        .name = "Owner",
        .children = try arena.dupe(xml.Node, &.{
            .{ .element = &owner_id_el },
            .{ .element = &owner_display_el },
        }),
    };

    // For each bucket build <Bucket><Name>...</Name><CreationDate>...</CreationDate></Bucket>.
    var bucket_nodes = try arena.alloc(xml.Node, buckets.len);
    for (buckets, 0..) |b, i| {
        const date_str = try formatIso8601(arena, b.created_unix);
        const name_el = try arena.create(xml.Element);
        name_el.* = .{ .name = "Name", .text = b.name };
        const date_el = try arena.create(xml.Element);
        date_el.* = .{ .name = "CreationDate", .text = date_str };
        const bucket_el = try arena.create(xml.Element);
        bucket_el.* = .{
            .name = "Bucket",
            .children = try arena.dupe(xml.Node, &.{
                .{ .element = name_el },
                .{ .element = date_el },
            }),
        };
        bucket_nodes[i] = .{ .element = bucket_el };
    }
    var buckets_el: xml.Element = .{ .name = "Buckets", .children = bucket_nodes };

    const root: xml.Element = .{
        .name = "ListAllMyBucketsResult",
        .attrs = &.{.{ .name = "xmlns", .value = "http://s3.amazonaws.com/doc/2006-03-01/" }},
        .children = try arena.dupe(xml.Node, &.{
            .{ .element = &owner_el },
            .{ .element = &buckets_el },
        }),
    };

    return xml.renderToOwnedSlice(allocator, &root);
}

/// Format unix seconds as `YYYY-MM-DDTHH:MM:SS.000Z` (AWS uses millisecond
/// precision; we always write `.000`).
pub fn formatIso8601(allocator: Allocator, unix_seconds: i64) ![]u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(unix_seconds) };
    const ed = es.getEpochDay();
    const day_secs = es.getDaySeconds();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        @as(u32, yd.year),
        @as(u32, @intFromEnum(md.month)),
        @as(u32, md.day_index) + 1,
        @as(u32, day_secs.getHoursIntoDay()),
        @as(u32, day_secs.getMinutesIntoHour()),
        @as(u32, day_secs.getSecondsIntoMinute()),
    });
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "formatIso8601: known epoch" {
    // 2026-05-15T13:00:00 UTC = 1778850000
    const got = try formatIso8601(testing.allocator, 1778850000);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("2026-05-15T13:00:00.000Z", got);
}

test "formatIso8601: unix epoch" {
    const got = try formatIso8601(testing.allocator, 0);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", got);
}

test "renderListAllMyBucketsResult: empty" {
    const got = try renderListAllMyBucketsResult(testing.allocator, "owner-id", "Owner Name", &.{});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<ListAllMyBucketsResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" ++
            "<Owner><ID>owner-id</ID><DisplayName>Owner Name</DisplayName></Owner>" ++
            "<Buckets/>" ++
            "</ListAllMyBucketsResult>",
        got,
    );
}

test "renderListAllMyBucketsResult: one bucket" {
    const buckets = [_]storage.Bucket{
        .{ .name = "alpha", .region = "us-east-1", .created_unix = 0 },
    };
    const got = try renderListAllMyBucketsResult(testing.allocator, "test", "nanostack", &buckets);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<ListAllMyBucketsResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" ++
            "<Owner><ID>test</ID><DisplayName>nanostack</DisplayName></Owner>" ++
            "<Buckets>" ++
            "<Bucket><Name>alpha</Name><CreationDate>1970-01-01T00:00:00.000Z</CreationDate></Bucket>" ++
            "</Buckets>" ++
            "</ListAllMyBucketsResult>",
        got,
    );
}
