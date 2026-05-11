//! Request routing — extract `(operation, bucket, key)` from a request.
//!
//! M1 maps the four bucket operations. Anything else resolves to
//! `.unknown` which the service layer maps to `NotImplemented`. Object
//! ops join the table in M3.

const std = @import("std");

pub const Operation = enum {
    create_bucket,
    delete_bucket,
    head_bucket,
    list_buckets,
    unknown,
};

pub const Parsed = struct {
    op: Operation,
    /// May be null for service-level calls (e.g. ListBuckets).
    bucket: ?[]const u8,
    /// May be null for bucket-level calls (e.g. CreateBucket, HeadBucket).
    key: ?[]const u8,
};

/// Parse a request. `method` is the request method as the literal string
/// the SDK sent (uppercase). `host` is the value of the `Host` header
/// (port allowed). `path` begins with `/`.
pub fn parse(method: []const u8, host: []const u8, path: []const u8) Parsed {
    const host_only = if (std.mem.indexOfScalar(u8, host, ':')) |i| host[0..i] else host;

    var bucket: ?[]const u8 = null;
    var key: ?[]const u8 = null;

    if (virtualHostBucket(host_only)) |b| {
        bucket = b;
        key = pathToKey(path);
    } else if (path.len > 1) {
        const rest = path[1..]; // drop leading '/'
        if (std.mem.indexOfScalar(u8, rest, '/')) |sep| {
            const head = rest[0..sep];
            const tail = rest[sep + 1 ..];
            bucket = if (head.len == 0) null else head;
            key = if (tail.len == 0) null else tail;
        } else {
            bucket = if (rest.len == 0) null else rest;
        }
    }

    return .{
        .op = resolveOp(method, bucket, key),
        .bucket = bucket,
        .key = key,
    };
}

fn resolveOp(method: []const u8, bucket: ?[]const u8, key: ?[]const u8) Operation {
    const has_bucket = bucket != null;
    const has_key = key != null;

    if (has_key) return .unknown; // object ops land in M3

    if (eql(method, "GET") and !has_bucket) return .list_buckets;
    if (eql(method, "PUT") and has_bucket) return .create_bucket;
    if (eql(method, "DELETE") and has_bucket) return .delete_bucket;
    if (eql(method, "HEAD") and has_bucket) return .head_bucket;

    return .unknown;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn virtualHostBucket(host: []const u8) ?[]const u8 {
    const reserved = [_][]const u8{ "localhost", "127.0.0.1", "0.0.0.0" };
    for (reserved) |r| {
        if (std.mem.eql(u8, host, r)) return null;
    }
    const dot = std.mem.indexOfScalar(u8, host, '.') orelse return null;
    if (dot == 0) return null;
    return host[0..dot];
}

fn pathToKey(path: []const u8) ?[]const u8 {
    if (path.len <= 1) return null;
    return path[1..];
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "path-style: GET / → list_buckets" {
    const p = parse("GET", "127.0.0.1", "/");
    try testing.expectEqual(Operation.list_buckets, p.op);
    try testing.expectEqual(@as(?[]const u8, null), p.bucket);
    try testing.expectEqual(@as(?[]const u8, null), p.key);
}

test "path-style: PUT /mybucket → create_bucket" {
    const p = parse("PUT", "localhost:4566", "/mybucket");
    try testing.expectEqual(Operation.create_bucket, p.op);
    try testing.expectEqualStrings("mybucket", p.bucket.?);
}

test "path-style: DELETE /mybucket → delete_bucket" {
    const p = parse("DELETE", "localhost", "/mybucket");
    try testing.expectEqual(Operation.delete_bucket, p.op);
    try testing.expectEqualStrings("mybucket", p.bucket.?);
}

test "path-style: HEAD /mybucket → head_bucket" {
    const p = parse("HEAD", "localhost", "/mybucket");
    try testing.expectEqual(Operation.head_bucket, p.op);
    try testing.expectEqualStrings("mybucket", p.bucket.?);
}

test "path-style: PUT /bucket/key → unknown (object op, M3)" {
    const p = parse("PUT", "localhost", "/bucket/key");
    try testing.expectEqual(Operation.unknown, p.op);
    try testing.expectEqualStrings("bucket", p.bucket.?);
    try testing.expectEqualStrings("key", p.key.?);
}

test "path-style: POST / → unknown" {
    const p = parse("POST", "localhost", "/");
    try testing.expectEqual(Operation.unknown, p.op);
}

test "virtual-hosted: GET / on bucket host → unknown (object op shape)" {
    // GET on a bucket host with no path is ListObjects (M4), not ListBuckets.
    const p = parse("GET", "mybucket.s3.us-east-1.amazonaws.com", "/");
    try testing.expectEqualStrings("mybucket", p.bucket.?);
    try testing.expectEqual(Operation.unknown, p.op);
}

test "virtual-hosted: PUT / on bucket host → create_bucket" {
    const p = parse("PUT", "mybucket.s3.amazonaws.com", "/");
    try testing.expectEqual(Operation.create_bucket, p.op);
    try testing.expectEqualStrings("mybucket", p.bucket.?);
}

test "virtual-hosted: HEAD / on bucket host → head_bucket" {
    const p = parse("HEAD", "mybucket.s3.amazonaws.com", "/");
    try testing.expectEqual(Operation.head_bucket, p.op);
    try testing.expectEqualStrings("mybucket", p.bucket.?);
}

test "virtual-hosted: GET /obj on bucket host → unknown (object op)" {
    const p = parse("GET", "mybucket.s3.us-east-1.amazonaws.com", "/foo");
    try testing.expectEqualStrings("mybucket", p.bucket.?);
    try testing.expectEqualStrings("foo", p.key.?);
    try testing.expectEqual(Operation.unknown, p.op);
}
