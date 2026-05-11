//! Request routing — extract the S3 addressing tuple from a request.
//!
//! M0 returns just `(bucket, key)` from path-style and virtual-hosted-style
//! requests. M1 grows operation-id resolution; M2 layers SigV4 on top.

const std = @import("std");

pub const Parsed = struct {
    /// May be null for service-level calls (e.g. ListBuckets).
    bucket: ?[]const u8,
    /// May be null for bucket-level calls (e.g. CreateBucket, HeadBucket).
    key: ?[]const u8,
};

/// Parse a request. `host` is the value of the `Host` header (no port).
/// `path` is the URL path beginning with `/`.
pub fn parse(host: []const u8, path: []const u8) Parsed {
    // Strip any port from the host.
    const host_only = if (std.mem.indexOfScalar(u8, host, ':')) |i| host[0..i] else host;

    // Virtual-hosted-style: `<bucket>.s3.<region>.amazonaws.com` or `<bucket>.localhost`.
    // For our endpoint we treat anything that isn't bare `localhost` / `127.0.0.1` /
    // empty as `<bucket>.<rest>`.
    if (virtualHostBucket(host_only)) |bucket| {
        const key = pathToKey(path);
        return .{ .bucket = bucket, .key = key };
    }

    // Path-style: `/bucket[/key...]`.
    if (path.len <= 1) return .{ .bucket = null, .key = null };
    const rest = path[1..]; // drop leading '/'
    if (std.mem.indexOfScalar(u8, rest, '/')) |sep| {
        const bucket = rest[0..sep];
        const key_part = rest[sep + 1 ..];
        return .{
            .bucket = if (bucket.len == 0) null else bucket,
            .key = if (key_part.len == 0) null else key_part,
        };
    }
    return .{ .bucket = if (rest.len == 0) null else rest, .key = null };
}

fn virtualHostBucket(host: []const u8) ?[]const u8 {
    // Reserved local hostnames serve as path-style endpoints.
    const reserved = [_][]const u8{ "localhost", "127.0.0.1", "0.0.0.0" };
    for (reserved) |r| {
        if (std.mem.eql(u8, host, r)) return null;
    }
    // First label before the first dot is the bucket name; require at least one dot.
    const dot = std.mem.indexOfScalar(u8, host, '.') orelse return null;
    if (dot == 0) return null;
    return host[0..dot];
}

fn pathToKey(path: []const u8) ?[]const u8 {
    if (path.len <= 1) return null;
    return path[1..]; // drop leading '/'
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "path-style with bucket only" {
    const p = parse("localhost", "/mybucket");
    try testing.expectEqualStrings("mybucket", p.bucket.?);
    try testing.expectEqual(@as(?[]const u8, null), p.key);
}

test "path-style with bucket and key" {
    const p = parse("localhost:4566", "/mybucket/foo/bar.txt");
    try testing.expectEqualStrings("mybucket", p.bucket.?);
    try testing.expectEqualStrings("foo/bar.txt", p.key.?);
}

test "path-style service level" {
    const p = parse("127.0.0.1", "/");
    try testing.expectEqual(@as(?[]const u8, null), p.bucket);
    try testing.expectEqual(@as(?[]const u8, null), p.key);
}

test "virtual-hosted-style" {
    const p = parse("mybucket.s3.us-east-1.amazonaws.com", "/foo/bar.txt");
    try testing.expectEqualStrings("mybucket", p.bucket.?);
    try testing.expectEqualStrings("foo/bar.txt", p.key.?);
}

test "virtual-hosted-style bucket level" {
    const p = parse("mybucket.s3.amazonaws.com", "/");
    try testing.expectEqualStrings("mybucket", p.bucket.?);
    try testing.expectEqual(@as(?[]const u8, null), p.key);
}
