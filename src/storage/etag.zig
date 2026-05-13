//! Pure ETag helpers used by the storage backend.
//!
//! Originally lived in `mem.zig` because that was the first place needing
//! MD5; M5/M6 wired the same helpers into `fs.zig`. With the in-memory
//! backend gone they live here as plain pure functions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Md5 = std.crypto.hash.Md5;

/// Compute `"<md5-hex>"` (double-quoted) for the body. Caller owns.
pub fn computeEtag(allocator: Allocator, body: []const u8) ![]u8 {
    var digest: [16]u8 = undefined;
    Md5.hash(body, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var out = try allocator.alloc(u8, hex.len + 2);
    out[0] = '"';
    @memcpy(out[1 .. 1 + hex.len], &hex);
    out[out.len - 1] = '"';
    return out;
}

/// AWS-style multipart ETag: `"<hex>-N"` where the hex is MD5 of the
/// *concatenated binary* MD5 digests of each part (not their hex form).
pub fn computeMultipartEtag(allocator: Allocator, part_digests: []const [16]u8, part_count: u32) ![]u8 {
    const concat = try allocator.alloc(u8, part_digests.len * 16);
    defer allocator.free(concat);
    for (part_digests, 0..) |d, i| @memcpy(concat[i * 16 .. (i + 1) * 16], &d);
    var digest: [16]u8 = undefined;
    Md5.hash(concat, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "\"{s}-{d}\"", .{ hex, part_count });
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "computeEtag: known MD5 of 'hello'" {
    const etag = try computeEtag(testing.allocator, "hello");
    defer testing.allocator.free(etag);
    try testing.expectEqualStrings("\"5d41402abc4b2a76b9719d911017c592\"", etag);
}

test "computeMultipartEtag: three known parts" {
    // md5("A"*5MiB) etc. — we just validate the shape + suffix without
    // recomputing the upstream MD5 here. (Real values are exercised by
    // the bench + conformance suites.)
    const digests = [_][16]u8{
        .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    };
    const etag = try computeMultipartEtag(testing.allocator, &digests, 3);
    defer testing.allocator.free(etag);
    try testing.expect(std.mem.endsWith(u8, etag, "-3\""));
    try testing.expect(std.mem.startsWith(u8, etag, "\""));
}
