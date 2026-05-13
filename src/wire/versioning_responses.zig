//! XML emitters for the bucket-versioning bucket-level operations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml.zig");
const storage = @import("../storage/mod.zig");

const xmlns_attr: xml.Attr = .{ .name = "xmlns", .value = "http://s3.amazonaws.com/doc/2006-03-01/" };

/// Render the `GetBucketVersioning` response body. For `none`, AWS
/// returns an empty `<VersioningConfiguration/>`.
pub fn renderGetBucketVersioning(allocator: Allocator, status: storage.VersioningStatus) ![]u8 {
    if (status == .none) {
        const root: xml.Element = .{
            .name = "VersioningConfiguration",
            .attrs = &.{xmlns_attr},
        };
        return xml.renderToOwnedSlice(allocator, &root);
    }
    var status_el: xml.Element = .{
        .name = "Status",
        .text = if (status == .enabled) "Enabled" else "Suspended",
    };
    const root: xml.Element = .{
        .name = "VersioningConfiguration",
        .attrs = &.{xmlns_attr},
        .children = &.{
            .{ .element = &status_el },
        },
    };
    return xml.renderToOwnedSlice(allocator, &root);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "render none → empty config" {
    const body = try renderGetBucketVersioning(testing.allocator, .none);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<VersioningConfiguration") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<Status>") == null);
}

test "render enabled" {
    const body = try renderGetBucketVersioning(testing.allocator, .enabled);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<Status>Enabled</Status>") != null);
}

test "render suspended" {
    const body = try renderGetBucketVersioning(testing.allocator, .suspended);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<Status>Suspended</Status>") != null);
}
