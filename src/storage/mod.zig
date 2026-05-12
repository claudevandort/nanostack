//! Storage backend interface.
//!
//! M1 landed bucket ops; M3 adds object ops. Two implementations satisfy
//! this vtable: `fs.zig` (default, filesystem-backed per PRD §9) and
//! `mem.zig` (`--ephemeral`). The S3 service layer never knows which.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    NoSuchBucket,
    NoSuchKey,
    BucketAlreadyExists,
    BucketAlreadyOwnedByYou,
    BucketNotEmpty,
    InvalidBucketName,
    InvalidObjectKey,
    Io,
    OutOfMemory,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// One bucket's persisted metadata. Strings borrow from the backend's
/// allocator; consumers must not retain past the backend lifetime unless
/// they dupe. `listBuckets` returns a slice freshly allocated by the
/// caller-supplied allocator.
pub const Bucket = struct {
    name: []const u8,
    region: []const u8,
    /// Unix epoch seconds at creation.
    created_unix: i64,
};

/// One stored object's metadata. Strings are owned by either the backend
/// (when surfaced through `headObject`) or the caller's allocator (when
/// surfaced through `getObject`). The variant that owns is documented at
/// the call site.
pub const Object = struct {
    key: []const u8,
    size: u64,
    /// Includes the surrounding double quotes (AWS convention).
    etag: []const u8,
    content_type: []const u8,
    /// Unix epoch seconds when last written.
    last_modified_unix: i64,
    /// `x-amz-meta-*` user metadata, preserved verbatim (already lowercased).
    user_metadata: []const Header,
};

pub const PutObjectInput = struct {
    bucket: []const u8,
    key: []const u8,
    body: []const u8,
    content_type: []const u8,
    user_metadata: []const Header = &.{},
};

pub const PutObjectOutput = struct {
    etag: []const u8,
};

pub const GetObjectOutput = struct {
    meta: Object,
    body: []const u8,
};

pub const DeletedKey = struct {
    key: []const u8,
};

pub const DeleteError = struct {
    key: []const u8,
    code: []const u8,
    message: []const u8,
};

pub const DeleteResult = struct {
    deleted: []DeletedKey,
    errors: []DeleteError,
    /// If true, only `errors` is surfaced in the response body (AWS
    /// `<Quiet>true</Quiet>` semantics).
    quiet: bool = false,
};

pub const ListObjectsInput = struct {
    bucket: []const u8,
    prefix: []const u8 = "",
    /// Filter keys to strictly greater than this string. V1 callers pass
    /// `marker`; V2 callers pass either `start-after` or the key decoded
    /// from `continuation-token`.
    start_after: []const u8 = "",
    delimiter: []const u8 = "",
    /// Caller is responsible for clamping to AWS's 1000 ceiling.
    max_keys: u32 = 1000,
};

pub const ListObjectsOutput = struct {
    /// Owned by the caller-supplied allocator; full Object metadata for
    /// every key that contributes to this page.
    contents: []Object,
    /// Owned the same way. Each entry is the key prefix up to and
    /// including the first occurrence of `delimiter` after `prefix`.
    common_prefixes: [][]const u8,
    is_truncated: bool,
    /// Set when truncated. V1 surfaces this as `NextMarker`; V2 base64s
    /// it into the `NextContinuationToken`. Empty otherwise.
    next_key: []const u8,
};

pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Buckets (M1).
        createBucket: *const fn (ctx: *anyopaque, name: []const u8) Error!void,
        deleteBucket: *const fn (ctx: *anyopaque, name: []const u8) Error!void,
        headBucket: *const fn (ctx: *anyopaque, name: []const u8) Error!void,
        listBuckets: *const fn (ctx: *anyopaque, allocator: Allocator) Error![]Bucket,
        // Objects (M3).
        putObject: *const fn (ctx: *anyopaque, in: PutObjectInput) Error!PutObjectOutput,
        getObject: *const fn (ctx: *anyopaque, allocator: Allocator, bucket: []const u8, key: []const u8) Error!GetObjectOutput,
        headObject: *const fn (ctx: *anyopaque, allocator: Allocator, bucket: []const u8, key: []const u8) Error!Object,
        deleteObject: *const fn (ctx: *anyopaque, bucket: []const u8, key: []const u8) Error!void,
        // Listing (M4).
        listObjects: *const fn (ctx: *anyopaque, allocator: Allocator, in: ListObjectsInput) Error!ListObjectsOutput,
    };

    // Pass-through helpers so call sites don't dereference the vtable.

    pub fn createBucket(self: Backend, name: []const u8) Error!void {
        return self.vtable.createBucket(self.ctx, name);
    }
    pub fn deleteBucket(self: Backend, name: []const u8) Error!void {
        return self.vtable.deleteBucket(self.ctx, name);
    }
    pub fn headBucket(self: Backend, name: []const u8) Error!void {
        return self.vtable.headBucket(self.ctx, name);
    }
    pub fn listBuckets(self: Backend, allocator: Allocator) Error![]Bucket {
        return self.vtable.listBuckets(self.ctx, allocator);
    }

    pub fn putObject(self: Backend, in: PutObjectInput) Error!PutObjectOutput {
        return self.vtable.putObject(self.ctx, in);
    }
    /// Caller owns the returned body and any allocated metadata strings.
    pub fn getObject(self: Backend, allocator: Allocator, bucket: []const u8, key: []const u8) Error!GetObjectOutput {
        return self.vtable.getObject(self.ctx, allocator, bucket, key);
    }
    /// Caller owns the returned metadata strings.
    pub fn headObject(self: Backend, allocator: Allocator, bucket: []const u8, key: []const u8) Error!Object {
        return self.vtable.headObject(self.ctx, allocator, bucket, key);
    }
    pub fn deleteObject(self: Backend, bucket: []const u8, key: []const u8) Error!void {
        return self.vtable.deleteObject(self.ctx, bucket, key);
    }

    /// Caller owns the returned slice plus every nested string. Use the
    /// same allocator passed in to free.
    pub fn listObjects(self: Backend, allocator: Allocator, in: ListObjectsInput) Error!ListObjectsOutput {
        return self.vtable.listObjects(self.ctx, allocator, in);
    }
};

/// Validate an S3 object key. AWS permits virtually any UTF-8; the only
/// hard rules we enforce are non-empty and ≤ 1024 bytes.
pub fn validateObjectKey(key: []const u8) Error!void {
    if (key.len == 0 or key.len > 1024) return Error.InvalidObjectKey;
}

test "validateObjectKey: empty" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidObjectKey, validateObjectKey(""));
}

test "validateObjectKey: too long" {
    const testing = std.testing;
    const s = "x" ** 1025;
    try testing.expectError(Error.InvalidObjectKey, validateObjectKey(s));
}

test "validateObjectKey: typical" {
    try validateObjectKey("foo/bar.txt");
    try validateObjectKey("emoji-🚀.bin");
}
