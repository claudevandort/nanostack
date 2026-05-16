//! S3 success response bodies.
//!
//! M1 ships one: `ListAllMyBucketsResult`. Future milestones add more here
//! (ListObjectsV2, CompleteMultipartUploadResult, etc.).

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml.zig");
const storage = @import("../storage/mod.zig");

/// Input to renderListAllMyBucketsResult. Supports the 2023 paging fields
/// (drift #22): `prefix` is echoed when set; `continuation_token` is the
/// NEXT-page token (absent when the listing isn't truncated).
pub const ListBucketsInput = struct {
    owner_id: []const u8,
    display_name: []const u8,
    buckets: []const storage.Bucket,
    prefix: ?[]const u8 = null,
    continuation_token: ?[]const u8 = null,
};

/// Render the ListBuckets response body. Caller owns the returned slice.
pub fn renderListAllMyBucketsResult(allocator: Allocator, in: ListBucketsInput) ![]u8 {
    // Build child element backing storage on a single arena so we don't
    // have to free a hundred tiny allocations on the happy path.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var owner_id_el: xml.Element = .{ .name = "ID", .text = in.owner_id };
    var owner_display_el: xml.Element = .{ .name = "DisplayName", .text = in.display_name };
    var owner_el: xml.Element = .{
        .name = "Owner",
        .children = try arena.dupe(xml.Node, &.{
            .{ .element = &owner_id_el },
            .{ .element = &owner_display_el },
        }),
    };

    // For each bucket build <Bucket><Name>...</Name><CreationDate>...</CreationDate><BucketRegion>...</BucketRegion></Bucket>.
    // AWS 2023 addition: BucketRegion lets newer SDKs route cross-region
    // requests without an extra HeadBucket. Drift table row 11.
    var bucket_nodes = try arena.alloc(xml.Node, in.buckets.len);
    for (in.buckets, 0..) |b, i| {
        const date_str = try formatIso8601(arena, b.created_unix);
        const name_el = try arena.create(xml.Element);
        name_el.* = .{ .name = "Name", .text = b.name };
        const date_el = try arena.create(xml.Element);
        date_el.* = .{ .name = "CreationDate", .text = date_str };
        const region_el = try arena.create(xml.Element);
        region_el.* = .{ .name = "BucketRegion", .text = b.region };
        const bucket_el = try arena.create(xml.Element);
        bucket_el.* = .{
            .name = "Bucket",
            .children = try arena.dupe(xml.Node, &.{
                .{ .element = name_el },
                .{ .element = date_el },
                .{ .element = region_el },
            }),
        };
        bucket_nodes[i] = .{ .element = bucket_el };
    }
    var buckets_el: xml.Element = .{ .name = "Buckets", .children = bucket_nodes };

    // Build child list: owner + buckets, plus optional Prefix + ContinuationToken.
    var children: std.ArrayList(xml.Node) = .empty;
    try children.append(arena, .{ .element = &owner_el });
    try children.append(arena, .{ .element = &buckets_el });

    var prefix_el: xml.Element = undefined;
    if (in.prefix) |p| {
        prefix_el = .{ .name = "Prefix", .text = p };
        try children.append(arena, .{ .element = &prefix_el });
    }

    var token_el: xml.Element = undefined;
    if (in.continuation_token) |t| {
        token_el = .{ .name = "ContinuationToken", .text = t };
        try children.append(arena, .{ .element = &token_el });
    }

    const root: xml.Element = .{
        .name = "ListAllMyBucketsResult",
        .attrs = &.{.{ .name = "xmlns", .value = "http://s3.amazonaws.com/doc/2006-03-01/" }},
        .children = children.items,
    };

    return xml.renderToOwnedSlice(allocator, &root);
}

/// Format unix seconds as an RFC 7231 / IMF-fixdate HTTP-date suitable for
/// HTTP headers like `Last-Modified` and `Date`:
///   `Mon, 02 Jan 2006 15:04:05 GMT`
///
/// AWS SDKs reject ISO 8601 in those headers — they're expected to be
/// HTTP-date per RFC 9110 §5.6.7. The `CreationDate` XML element in the
/// ListBuckets body is *different* and uses `formatIso8601`.
pub fn formatHttpDate(allocator: Allocator, unix_seconds: i64) ![]u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(unix_seconds) };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const day_secs = es.getDaySeconds();

    // 1970-01-01 was a Thursday → day_of_week = (day + 4) mod 7 with 0=Sun.
    const dow_index: usize = @intCast((@as(u64, ed.day) + 4) % 7);
    const month_index: usize = @intFromEnum(md.month) - 1;

    const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    return std.fmt.allocPrint(allocator, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        day_names[dow_index],
        @as(u32, md.day_index) + 1,
        month_names[month_index],
        @as(u32, yd.year),
        @as(u32, day_secs.getHoursIntoDay()),
        @as(u32, day_secs.getMinutesIntoHour()),
        @as(u32, day_secs.getSecondsIntoMinute()),
    });
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

test "formatHttpDate: epoch (Thursday 1 Jan 1970)" {
    const got = try formatHttpDate(testing.allocator, 0);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", got);
}

test "formatHttpDate: 2026-05-15T13:00:00Z (Friday)" {
    const got = try formatHttpDate(testing.allocator, 1778850000);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Fri, 15 May 2026 13:00:00 GMT", got);
}

test "formatIso8601: unix epoch" {
    const got = try formatIso8601(testing.allocator, 0);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", got);
}

test "renderListAllMyBucketsResult: empty" {
    const got = try renderListAllMyBucketsResult(testing.allocator, .{
        .owner_id = "owner-id",
        .display_name = "Owner Name",
        .buckets = &.{},
    });
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
    const got = try renderListAllMyBucketsResult(testing.allocator, .{
        .owner_id = "test",
        .display_name = "nanostack",
        .buckets = &buckets,
    });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<ListAllMyBucketsResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" ++
            "<Owner><ID>test</ID><DisplayName>nanostack</DisplayName></Owner>" ++
            "<Buckets>" ++
            "<Bucket><Name>alpha</Name><CreationDate>1970-01-01T00:00:00.000Z</CreationDate><BucketRegion>us-east-1</BucketRegion></Bucket>" ++
            "</Buckets>" ++
            "</ListAllMyBucketsResult>",
        got,
    );
}

test "renderListAllMyBucketsResult: with Prefix + ContinuationToken" {
    const buckets = [_]storage.Bucket{
        .{ .name = "alpha", .region = "us-east-1", .created_unix = 0 },
    };
    const got = try renderListAllMyBucketsResult(testing.allocator, .{
        .owner_id = "test",
        .display_name = "nanostack",
        .buckets = &buckets,
        .prefix = "al",
        .continuation_token = "alpha",
    });
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "<Prefix>al</Prefix>") != null);
    try testing.expect(std.mem.indexOf(u8, got, "<ContinuationToken>alpha</ContinuationToken>") != null);
}
