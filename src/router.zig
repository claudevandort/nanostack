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
    put_object,
    get_object,
    head_object,
    delete_object,
    delete_objects,
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
/// (port allowed). `path` begins with `/`. `query` is the raw query string
/// (no leading `?`).
pub fn parse(method: []const u8, host: []const u8, path: []const u8, query: []const u8) Parsed {
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
        .op = resolveOp(method, bucket, key, query),
        .bucket = bucket,
        .key = key,
    };
}

fn resolveOp(method: []const u8, bucket: ?[]const u8, key: ?[]const u8, query: []const u8) Operation {
    const has_bucket = bucket != null;
    const has_key = key != null;

    if (has_key) {
        if (eql(method, "PUT")) return .put_object;
        if (eql(method, "GET")) return .get_object;
        if (eql(method, "HEAD")) return .head_object;
        if (eql(method, "DELETE")) return .delete_object;
        return .unknown;
    }

    if (eql(method, "POST") and has_bucket and hasQueryParam(query, "delete")) return .delete_objects;

    if (eql(method, "GET") and !has_bucket) return .list_buckets;
    if (eql(method, "PUT") and has_bucket) return .create_bucket;
    if (eql(method, "DELETE") and has_bucket) return .delete_bucket;
    if (eql(method, "HEAD") and has_bucket) return .head_bucket;

    return .unknown;
}

/// Does the raw query string contain a parameter named `name`? Matches
/// `name`, `name=`, `name=anything`. Used for AWS-style query toggles
/// like `?delete`, `?lifecycle`, etc.
fn hasQueryParam(query: []const u8, name: []const u8) bool {
    if (query.len == 0) return false;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        if (std.mem.eql(u8, pair[0..eq], name)) return true;
    }
    return false;
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
    const p = parse("GET", "127.0.0.1", "/", "");
    try testing.expectEqual(Operation.list_buckets, p.op);
    try testing.expectEqual(@as(?[]const u8, null), p.bucket);
    try testing.expectEqual(@as(?[]const u8, null), p.key);
}

test "path-style: PUT /mybucket → create_bucket" {
    const p = parse("PUT", "localhost:4566", "/mybucket", "");
    try testing.expectEqual(Operation.create_bucket, p.op);
    try testing.expectEqualStrings("mybucket", p.bucket.?);
}

test "path-style: DELETE /mybucket → delete_bucket" {
    const p = parse("DELETE", "localhost", "/mybucket", "");
    try testing.expectEqual(Operation.delete_bucket, p.op);
    try testing.expectEqualStrings("mybucket", p.bucket.?);
}

test "path-style: HEAD /mybucket → head_bucket" {
    const p = parse("HEAD", "localhost", "/mybucket", "");
    try testing.expectEqual(Operation.head_bucket, p.op);
    try testing.expectEqualStrings("mybucket", p.bucket.?);
}

test "path-style: PUT /bucket/key → put_object" {
    const p = parse("PUT", "localhost", "/bucket/key", "");
    try testing.expectEqual(Operation.put_object, p.op);
    try testing.expectEqualStrings("bucket", p.bucket.?);
    try testing.expectEqualStrings("key", p.key.?);
}

test "path-style: GET /bucket/key → get_object" {
    const p = parse("GET", "localhost", "/bucket/key", "");
    try testing.expectEqual(Operation.get_object, p.op);
    try testing.expectEqualStrings("key", p.key.?);
}

test "path-style: HEAD /bucket/key → head_object" {
    const p = parse("HEAD", "localhost", "/bucket/key", "");
    try testing.expectEqual(Operation.head_object, p.op);
}

test "path-style: DELETE /bucket/key → delete_object" {
    const p = parse("DELETE", "localhost", "/bucket/key", "");
    try testing.expectEqual(Operation.delete_object, p.op);
}

test "path-style: POST /bucket?delete → delete_objects" {
    const p = parse("POST", "localhost", "/bucket", "delete");
    try testing.expectEqual(Operation.delete_objects, p.op);
    try testing.expectEqualStrings("bucket", p.bucket.?);
}

test "path-style: POST /bucket?delete=&foo=bar → delete_objects (extra params OK)" {
    const p = parse("POST", "localhost", "/bucket", "delete=&foo=bar");
    try testing.expectEqual(Operation.delete_objects, p.op);
}

test "path-style: POST /bucket without ?delete → unknown" {
    const p = parse("POST", "localhost", "/bucket", "");
    try testing.expectEqual(Operation.unknown, p.op);
}

test "path-style: POST / → unknown" {
    const p = parse("POST", "localhost", "/", "");
    try testing.expectEqual(Operation.unknown, p.op);
}

test "virtual-hosted: GET / on bucket host → unknown (ListObjects is M4)" {
    const p = parse("GET", "mybucket.s3.us-east-1.amazonaws.com", "/", "");
    try testing.expectEqualStrings("mybucket", p.bucket.?);
    try testing.expectEqual(Operation.unknown, p.op);
}

test "virtual-hosted: PUT / on bucket host → create_bucket" {
    const p = parse("PUT", "mybucket.s3.amazonaws.com", "/", "");
    try testing.expectEqual(Operation.create_bucket, p.op);
    try testing.expectEqualStrings("mybucket", p.bucket.?);
}

test "virtual-hosted: HEAD / on bucket host → head_bucket" {
    const p = parse("HEAD", "mybucket.s3.amazonaws.com", "/", "");
    try testing.expectEqual(Operation.head_bucket, p.op);
    try testing.expectEqualStrings("mybucket", p.bucket.?);
}

test "virtual-hosted: GET /obj on bucket host → get_object" {
    const p = parse("GET", "mybucket.s3.us-east-1.amazonaws.com", "/foo", "");
    try testing.expectEqualStrings("mybucket", p.bucket.?);
    try testing.expectEqualStrings("foo", p.key.?);
    try testing.expectEqual(Operation.get_object, p.op);
}
