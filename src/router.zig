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
    put_bucket_cors,
    get_bucket_cors,
    delete_bucket_cors,
    put_bucket_encryption,
    get_bucket_encryption,
    delete_bucket_encryption,
    put_bucket_lifecycle,
    get_bucket_lifecycle,
    delete_bucket_lifecycle,
    put_bucket_notification,
    get_bucket_notification,
    put_bucket_website,
    get_bucket_website,
    delete_bucket_website,
    get_object_attributes,
    put_object_lock_config,
    get_object_lock_config,
    put_object_retention,
    get_object_retention,
    put_object_legal_hold,
    get_object_legal_hold,
    get_bucket_policy_status,
    restore_object,
    update_object_encryption,
    put_bucket_replication,
    get_bucket_replication,
    delete_bucket_replication,
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
        if (hasQueryParam(query, "attributes") and eql(method, "GET")) return .get_object_attributes;
        if (hasQueryParam(query, "retention")) {
            if (eql(method, "PUT")) return .put_object_retention;
            if (eql(method, "GET")) return .get_object_retention;
        }
        if (hasQueryParam(query, "legal-hold")) {
            if (eql(method, "PUT")) return .put_object_legal_hold;
            if (eql(method, "GET")) return .get_object_legal_hold;
        }
        // M13: object-level restore (POST) + per-object encryption (PUT).
        if (eql(method, "POST") and hasQueryParam(query, "restore")) return .restore_object;
        if (eql(method, "PUT") and hasQueryParam(query, "encryption")) return .update_object_encryption;
        // Explicitly never-implemented sub-resources route to `.unknown`
        // (501 NotImplemented) rather than falling through to get_object.
        if (hasQueryParam(query, "torrent")) return .unknown;
        if (hasQueryParam(query, "select")) return .unknown;
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
        if (hasQueryParam(query, "cors")) return .get_bucket_cors;
        if (hasQueryParam(query, "encryption")) return .get_bucket_encryption;
        if (hasQueryParam(query, "lifecycle")) return .get_bucket_lifecycle;
        if (hasQueryParam(query, "notification")) return .get_bucket_notification;
        if (hasQueryParam(query, "website")) return .get_bucket_website;
        if (hasQueryParam(query, "object-lock")) return .get_object_lock_config;
        if (hasQueryParam(query, "policyStatus")) return .get_bucket_policy_status;
        if (hasQueryParam(query, "replication")) return .get_bucket_replication;
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
        if (hasQueryParam(query, "cors")) return .put_bucket_cors;
        if (hasQueryParam(query, "encryption")) return .put_bucket_encryption;
        if (hasQueryParam(query, "lifecycle")) return .put_bucket_lifecycle;
        if (hasQueryParam(query, "notification")) return .put_bucket_notification;
        if (hasQueryParam(query, "website")) return .put_bucket_website;
        if (hasQueryParam(query, "object-lock")) return .put_object_lock_config;
        if (hasQueryParam(query, "replication")) return .put_bucket_replication;
        return .create_bucket;
    }
    if (eql(method, "DELETE") and has_bucket) {
        if (hasQueryParam(query, "tagging")) return .delete_bucket_tagging;
        if (hasQueryParam(query, "policy")) return .delete_bucket_policy;
        if (hasQueryParam(query, "ownershipControls")) return .delete_bucket_ownership_controls;
        if (hasQueryParam(query, "publicAccessBlock")) return .delete_public_access_block;
        if (hasQueryParam(query, "cors")) return .delete_bucket_cors;
        if (hasQueryParam(query, "encryption")) return .delete_bucket_encryption;
        if (hasQueryParam(query, "lifecycle")) return .delete_bucket_lifecycle;
        if (hasQueryParam(query, "website")) return .delete_bucket_website;
        if (hasQueryParam(query, "replication")) return .delete_bucket_replication;
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

/// Extract a virtual-hosted bucket name from `host` (port already stripped).
///
/// Returns the bucket name if `host` looks like a virtual-host suffix we
/// recognise, otherwise null (caller falls back to path-style routing).
///
/// Recognised suffixes:
///   - `.s3.amazonaws.com`                  (legacy global)
///   - `.s3.<region>.amazonaws.com`         (modern)
///   - `.s3-<region>.amazonaws.com`         (older regional)
///   - `.s3-website-<region>.amazonaws.com` (S3 Website)
///   - `.s3-accelerate.amazonaws.com`       (Transfer Acceleration)
///   - `.localhost`, `.127.0.0.1`           (dev-local)
///
/// Anything else returns null — important to avoid the historical bug
/// where `s3.amazonaws.com` was parsed as bucket=`s3`.
fn virtualHostBucket(host: []const u8) ?[]const u8 {
    // Reserved bare hosts: never virtual-hosted.
    const reserved = [_][]const u8{ "localhost", "127.0.0.1", "0.0.0.0" };
    for (reserved) |r| {
        if (std.mem.eql(u8, host, r)) return null;
    }

    // Dev-local: `.localhost`, `.127.0.0.1`.
    const dev_suffixes = [_][]const u8{ ".localhost", ".127.0.0.1" };
    for (dev_suffixes) |suf| {
        if (std.mem.endsWith(u8, host, suf)) {
            const bucket = host[0 .. host.len - suf.len];
            return if (bucket.len == 0) null else bucket;
        }
    }

    // AWS canonical forms — explicit suffixes.
    const aws_fixed = [_][]const u8{
        ".s3.amazonaws.com",
        ".s3-accelerate.amazonaws.com",
    };
    for (aws_fixed) |suf| {
        if (std.mem.endsWith(u8, host, suf)) {
            const bucket = host[0 .. host.len - suf.len];
            return if (bucket.len == 0) null else bucket;
        }
    }

    // Regional forms: `.s3.<region>.amazonaws.com`, `.s3-<region>.amazonaws.com`,
    // `.s3-website-<region>.amazonaws.com`. Check the `.amazonaws.com` suffix and
    // then verify the bucket-side ends with one of the s3* labels.
    const amazonaws = ".amazonaws.com";
    if (std.mem.endsWith(u8, host, amazonaws)) {
        const without_tld = host[0 .. host.len - amazonaws.len];
        // `without_tld` is now `<bucket>.s3<-?region|-website-<region>>` —
        // or `<bucket>.s3` for the no-region AWS-canonical case (handled above).
        // We need to find the s3-label boundary.
        const last_dot = std.mem.lastIndexOfScalar(u8, without_tld, '.') orelse return null;
        const tail = without_tld[last_dot + 1 ..];
        if (std.mem.startsWith(u8, tail, "s3-") or std.mem.startsWith(u8, tail, "s3.")) {
            // `<bucket>.s3-region` form.
            const bucket = without_tld[0..last_dot];
            return if (bucket.len == 0) null else bucket;
        }
        // `<bucket>.s3.<region>` modern form: tail is the region; need to walk
        // back one more dot to find the `s3` label and the bucket boundary.
        const prev_dot = std.mem.lastIndexOfScalar(u8, without_tld[0..last_dot], '.') orelse return null;
        const s3_label = without_tld[prev_dot + 1 .. last_dot];
        if (std.mem.eql(u8, s3_label, "s3")) {
            const bucket = without_tld[0..prev_dot];
            return if (bucket.len == 0) null else bucket;
        }
        return null;
    }

    return null;
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

test "virtual-hosted: s3.amazonaws.com is NOT a virtual-host → falls back to path-style" {
    // Drift #19 regression: the old "everything before the first dot" parser
    // would misroute this as bucket=s3 with no key.
    const p = parse("GET", "s3.amazonaws.com", "/foo", "");
    try testing.expectEqualStrings("foo", p.bucket.?);
    try testing.expectEqual(Operation.list_objects, p.op);
}

test "virtual-hosted: s3-us-west-2.amazonaws.com (older regional form) → null" {
    const p = parse("GET", "s3-us-west-2.amazonaws.com", "/foo", "");
    try testing.expectEqualStrings("foo", p.bucket.?);
}

test "virtual-hosted: mybucket.s3-us-west-2.amazonaws.com → virtual-host" {
    const p = parse("GET", "mybucket.s3-us-west-2.amazonaws.com", "/foo", "");
    try testing.expectEqualStrings("mybucket", p.bucket.?);
    try testing.expectEqualStrings("foo", p.key.?);
}

test "virtual-hosted: mybucket.localhost → virtual-host" {
    const p = parse("GET", "mybucket.localhost", "/", "");
    try testing.expectEqualStrings("mybucket", p.bucket.?);
}

test "virtual-hosted: example.com is not an S3 host → null" {
    const p = parse("GET", "example.com", "/foo", "");
    try testing.expectEqualStrings("foo", p.bucket.?);
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

test "cors: PUT/GET/DELETE /b?cors" {
    try testing.expectEqual(Operation.put_bucket_cors, parse("PUT", "localhost", "/buk", "cors").op);
    try testing.expectEqual(Operation.get_bucket_cors, parse("GET", "localhost", "/buk", "cors").op);
    try testing.expectEqual(Operation.delete_bucket_cors, parse("DELETE", "localhost", "/buk", "cors").op);
}

test "encryption: PUT/GET/DELETE /b?encryption" {
    try testing.expectEqual(Operation.put_bucket_encryption, parse("PUT", "localhost", "/buk", "encryption").op);
    try testing.expectEqual(Operation.get_bucket_encryption, parse("GET", "localhost", "/buk", "encryption").op);
    try testing.expectEqual(Operation.delete_bucket_encryption, parse("DELETE", "localhost", "/buk", "encryption").op);
}

test "lifecycle: PUT/GET/DELETE /b?lifecycle" {
    try testing.expectEqual(Operation.put_bucket_lifecycle, parse("PUT", "localhost", "/buk", "lifecycle").op);
    try testing.expectEqual(Operation.get_bucket_lifecycle, parse("GET", "localhost", "/buk", "lifecycle").op);
    try testing.expectEqual(Operation.delete_bucket_lifecycle, parse("DELETE", "localhost", "/buk", "lifecycle").op);
}

test "notification: PUT/GET /b?notification" {
    try testing.expectEqual(Operation.put_bucket_notification, parse("PUT", "localhost", "/buk", "notification").op);
    try testing.expectEqual(Operation.get_bucket_notification, parse("GET", "localhost", "/buk", "notification").op);
}

test "website: PUT/GET/DELETE /b?website" {
    try testing.expectEqual(Operation.put_bucket_website, parse("PUT", "localhost", "/buk", "website").op);
    try testing.expectEqual(Operation.get_bucket_website, parse("GET", "localhost", "/buk", "website").op);
    try testing.expectEqual(Operation.delete_bucket_website, parse("DELETE", "localhost", "/buk", "website").op);
}

test "objectAttributes: GET /b/k?attributes → get_object_attributes" {
    const p = parse("GET", "localhost", "/buk/k", "attributes");
    try testing.expectEqual(Operation.get_object_attributes, p.op);
}

test "object-lock: PUT/GET /b?object-lock" {
    try testing.expectEqual(Operation.put_object_lock_config, parse("PUT", "localhost", "/buk", "object-lock").op);
    try testing.expectEqual(Operation.get_object_lock_config, parse("GET", "localhost", "/buk", "object-lock").op);
}

test "retention: PUT/GET /b/k?retention" {
    try testing.expectEqual(Operation.put_object_retention, parse("PUT", "localhost", "/buk/k", "retention").op);
    try testing.expectEqual(Operation.get_object_retention, parse("GET", "localhost", "/buk/k", "retention").op);
}

test "legal-hold: PUT/GET /b/k?legal-hold" {
    try testing.expectEqual(Operation.put_object_legal_hold, parse("PUT", "localhost", "/buk/k", "legal-hold").op);
    try testing.expectEqual(Operation.get_object_legal_hold, parse("GET", "localhost", "/buk/k", "legal-hold").op);
}

test "policyStatus: GET /b?policyStatus" {
    try testing.expectEqual(Operation.get_bucket_policy_status, parse("GET", "localhost", "/buk", "policyStatus").op);
}

test "restore: POST /b/k?restore" {
    try testing.expectEqual(Operation.restore_object, parse("POST", "localhost", "/buk/k", "restore").op);
}

test "objectEncryption: PUT /b/k?encryption" {
    try testing.expectEqual(Operation.update_object_encryption, parse("PUT", "localhost", "/buk/k", "encryption").op);
}

test "replication: PUT/GET/DELETE /b?replication" {
    try testing.expectEqual(Operation.put_bucket_replication, parse("PUT", "localhost", "/buk", "replication").op);
    try testing.expectEqual(Operation.get_bucket_replication, parse("GET", "localhost", "/buk", "replication").op);
    try testing.expectEqual(Operation.delete_bucket_replication, parse("DELETE", "localhost", "/buk", "replication").op);
}
