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
    list_objects,
    list_objects_v2,
    create_multipart_upload,
    upload_part,
    complete_multipart_upload,
    abort_multipart_upload,
    list_parts,
    list_multipart_uploads,
    put_bucket_versioning,
    get_bucket_versioning,
    list_object_versions,
    put_bucket_tagging,
    get_bucket_tagging,
    delete_bucket_tagging,
    put_object_tagging,
    get_object_tagging,
    delete_object_tagging,
    put_bucket_acl,
    get_bucket_acl,
    put_object_acl,
    get_object_acl,
    put_bucket_policy,
    get_bucket_policy,
    delete_bucket_policy,
    put_bucket_ownership_controls,
    get_bucket_ownership_controls,
    delete_bucket_ownership_controls,
    put_public_access_block,
    get_public_access_block,
    delete_public_access_block,
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
        // Multipart routes on a keyed path. Their query toggles take
        // priority over the plain put/get/head/delete fall-throughs.
        if (eql(method, "POST") and hasQueryParam(query, "uploads")) return .create_multipart_upload;
        if (hasQueryParam(query, "uploadId")) {
            if (eql(method, "POST")) return .complete_multipart_upload;
            if (eql(method, "PUT")) return .upload_part;
            if (eql(method, "DELETE")) return .abort_multipart_upload;
            if (eql(method, "GET")) return .list_parts;
        }
        if (hasQueryParam(query, "tagging")) {
            if (eql(method, "PUT")) return .put_object_tagging;
            if (eql(method, "GET")) return .get_object_tagging;
            if (eql(method, "DELETE")) return .delete_object_tagging;
        }
        if (hasQueryParam(query, "acl")) {
            if (eql(method, "PUT")) return .put_object_acl;
            if (eql(method, "GET")) return .get_object_acl;
        }
        if (eql(method, "PUT")) return .put_object;
        if (eql(method, "GET")) return .get_object;
        if (eql(method, "HEAD")) return .head_object;
        if (eql(method, "DELETE")) return .delete_object;
        return .unknown;
    }

    if (eql(method, "POST") and has_bucket and hasQueryParam(query, "delete")) return .delete_objects;

    if (eql(method, "GET") and !has_bucket) return .list_buckets;
    if (eql(method, "GET") and has_bucket) {
        if (hasQueryParam(query, "versioning")) return .get_bucket_versioning;
        if (hasQueryParam(query, "versions")) return .list_object_versions;
        if (hasQueryParam(query, "tagging")) return .get_bucket_tagging;
        if (hasQueryParam(query, "acl")) return .get_bucket_acl;
        if (hasQueryParam(query, "policy")) return .get_bucket_policy;
        if (hasQueryParam(query, "ownershipControls")) return .get_bucket_ownership_controls;
        if (hasQueryParam(query, "publicAccessBlock")) return .get_public_access_block;
        if (hasQueryParam(query, "uploads")) return .list_multipart_uploads;
        if (queryParamEquals(query, "list-type", "2")) return .list_objects_v2;
        return .list_objects;
    }
    if (eql(method, "PUT") and has_bucket) {
        if (hasQueryParam(query, "versioning")) return .put_bucket_versioning;
        if (hasQueryParam(query, "tagging")) return .put_bucket_tagging;
        if (hasQueryParam(query, "acl")) return .put_bucket_acl;
        if (hasQueryParam(query, "policy")) return .put_bucket_policy;
        if (hasQueryParam(query, "ownershipControls")) return .put_bucket_ownership_controls;
        if (hasQueryParam(query, "publicAccessBlock")) return .put_public_access_block;
        return .create_bucket;
    }
    if (eql(method, "DELETE") and has_bucket) {
        if (hasQueryParam(query, "tagging")) return .delete_bucket_tagging;
        if (hasQueryParam(query, "policy")) return .delete_bucket_policy;
        if (hasQueryParam(query, "ownershipControls")) return .delete_bucket_ownership_controls;
        if (hasQueryParam(query, "publicAccessBlock")) return .delete_public_access_block;
        return .delete_bucket;
    }
    if (eql(method, "HEAD") and has_bucket) return .head_bucket;

    return .unknown;
}

/// Does the raw query string contain `name=value`? Case-sensitive.
fn queryParamEquals(query: []const u8, name: []const u8, value: []const u8) bool {
    if (query.len == 0) return false;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name) and std.mem.eql(u8, pair[eq + 1 ..], value)) return true;
    }
    return false;
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

test "virtual-hosted: GET / on bucket host → list_objects (v1)" {
    const p = parse("GET", "mybucket.s3.us-east-1.amazonaws.com", "/", "");
    try testing.expectEqualStrings("mybucket", p.bucket.?);
    try testing.expectEqual(Operation.list_objects, p.op);
}

test "path-style: GET /bucket → list_objects (v1)" {
    const p = parse("GET", "localhost", "/mybucket", "");
    try testing.expectEqual(Operation.list_objects, p.op);
    try testing.expectEqualStrings("mybucket", p.bucket.?);
}

test "path-style: GET /bucket?list-type=2 → list_objects_v2" {
    const p = parse("GET", "localhost", "/mybucket", "list-type=2");
    try testing.expectEqual(Operation.list_objects_v2, p.op);
}

test "path-style: GET /bucket?list-type=2&prefix=foo/ → list_objects_v2" {
    const p = parse("GET", "localhost", "/mybucket", "list-type=2&prefix=foo%2F");
    try testing.expectEqual(Operation.list_objects_v2, p.op);
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

test "multipart: POST /b/k?uploads → create_multipart_upload" {
    const p = parse("POST", "localhost", "/buk/k", "uploads");
    try testing.expectEqual(Operation.create_multipart_upload, p.op);
}

test "multipart: PUT /b/k?uploadId=X&partNumber=1 → upload_part" {
    const p = parse("PUT", "localhost", "/buk/k", "uploadId=abc&partNumber=1");
    try testing.expectEqual(Operation.upload_part, p.op);
}

test "multipart: POST /b/k?uploadId=X → complete_multipart_upload" {
    const p = parse("POST", "localhost", "/buk/k", "uploadId=abc");
    try testing.expectEqual(Operation.complete_multipart_upload, p.op);
}

test "multipart: DELETE /b/k?uploadId=X → abort_multipart_upload" {
    const p = parse("DELETE", "localhost", "/buk/k", "uploadId=abc");
    try testing.expectEqual(Operation.abort_multipart_upload, p.op);
}

test "multipart: GET /b/k?uploadId=X → list_parts" {
    const p = parse("GET", "localhost", "/buk/k", "uploadId=abc");
    try testing.expectEqual(Operation.list_parts, p.op);
}

test "versioning: PUT /b?versioning → put_bucket_versioning" {
    const p = parse("PUT", "localhost", "/buk", "versioning");
    try testing.expectEqual(Operation.put_bucket_versioning, p.op);
}

test "versioning: GET /b?versioning → get_bucket_versioning" {
    const p = parse("GET", "localhost", "/buk", "versioning");
    try testing.expectEqual(Operation.get_bucket_versioning, p.op);
}

test "versioning: GET /b?versions → list_object_versions" {
    const p = parse("GET", "localhost", "/buk", "versions");
    try testing.expectEqual(Operation.list_object_versions, p.op);
}

test "multipart: GET /b?uploads → list_multipart_uploads" {
    const p = parse("GET", "localhost", "/buk", "uploads");
    try testing.expectEqual(Operation.list_multipart_uploads, p.op);
}

test "tagging: PUT /b?tagging → put_bucket_tagging" {
    const p = parse("PUT", "localhost", "/buk", "tagging");
    try testing.expectEqual(Operation.put_bucket_tagging, p.op);
}

test "tagging: GET /b?tagging → get_bucket_tagging" {
    const p = parse("GET", "localhost", "/buk", "tagging");
    try testing.expectEqual(Operation.get_bucket_tagging, p.op);
}

test "tagging: DELETE /b?tagging → delete_bucket_tagging" {
    const p = parse("DELETE", "localhost", "/buk", "tagging");
    try testing.expectEqual(Operation.delete_bucket_tagging, p.op);
}

test "tagging: PUT /b/k?tagging → put_object_tagging" {
    const p = parse("PUT", "localhost", "/buk/k", "tagging");
    try testing.expectEqual(Operation.put_object_tagging, p.op);
}

test "tagging: GET /b/k?tagging → get_object_tagging" {
    const p = parse("GET", "localhost", "/buk/k", "tagging");
    try testing.expectEqual(Operation.get_object_tagging, p.op);
}

test "tagging: DELETE /b/k?tagging → delete_object_tagging" {
    const p = parse("DELETE", "localhost", "/buk/k", "tagging");
    try testing.expectEqual(Operation.delete_object_tagging, p.op);
}

test "tagging: PUT /b/k?tagging&versionId=X → put_object_tagging (versionId is a sub-resource handled in service layer)" {
    const p = parse("PUT", "localhost", "/buk/k", "tagging&versionId=abc");
    try testing.expectEqual(Operation.put_object_tagging, p.op);
}

test "acl: PUT /b?acl → put_bucket_acl" {
    const p = parse("PUT", "localhost", "/buk", "acl");
    try testing.expectEqual(Operation.put_bucket_acl, p.op);
}

test "acl: GET /b?acl → get_bucket_acl" {
    const p = parse("GET", "localhost", "/buk", "acl");
    try testing.expectEqual(Operation.get_bucket_acl, p.op);
}

test "acl: PUT /b/k?acl → put_object_acl" {
    const p = parse("PUT", "localhost", "/buk/k", "acl");
    try testing.expectEqual(Operation.put_object_acl, p.op);
}

test "acl: GET /b/k?acl&versionId=X → get_object_acl" {
    const p = parse("GET", "localhost", "/buk/k", "acl&versionId=v1");
    try testing.expectEqual(Operation.get_object_acl, p.op);
}

test "policy: PUT /b?policy → put_bucket_policy" {
    const p = parse("PUT", "localhost", "/buk", "policy");
    try testing.expectEqual(Operation.put_bucket_policy, p.op);
}

test "policy: GET /b?policy → get_bucket_policy" {
    const p = parse("GET", "localhost", "/buk", "policy");
    try testing.expectEqual(Operation.get_bucket_policy, p.op);
}

test "policy: DELETE /b?policy → delete_bucket_policy" {
    const p = parse("DELETE", "localhost", "/buk", "policy");
    try testing.expectEqual(Operation.delete_bucket_policy, p.op);
}

test "ownership: PUT /b?ownershipControls → put_bucket_ownership_controls" {
    const p = parse("PUT", "localhost", "/buk", "ownershipControls");
    try testing.expectEqual(Operation.put_bucket_ownership_controls, p.op);
}

test "ownership: GET /b?ownershipControls → get_bucket_ownership_controls" {
    const p = parse("GET", "localhost", "/buk", "ownershipControls");
    try testing.expectEqual(Operation.get_bucket_ownership_controls, p.op);
}

test "ownership: DELETE /b?ownershipControls → delete_bucket_ownership_controls" {
    const p = parse("DELETE", "localhost", "/buk", "ownershipControls");
    try testing.expectEqual(Operation.delete_bucket_ownership_controls, p.op);
}

test "publicAccessBlock: PUT /b?publicAccessBlock → put_public_access_block" {
    const p = parse("PUT", "localhost", "/buk", "publicAccessBlock");
    try testing.expectEqual(Operation.put_public_access_block, p.op);
}

test "publicAccessBlock: GET /b?publicAccessBlock → get_public_access_block" {
    const p = parse("GET", "localhost", "/buk", "publicAccessBlock");
    try testing.expectEqual(Operation.get_public_access_block, p.op);
}

test "publicAccessBlock: DELETE /b?publicAccessBlock → delete_public_access_block" {
    const p = parse("DELETE", "localhost", "/buk", "publicAccessBlock");
    try testing.expectEqual(Operation.delete_public_access_block, p.op);
}
