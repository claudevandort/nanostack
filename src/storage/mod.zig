//! Storage backend interface.
//!
//! M1 lands two implementations: `fs.zig` (default, filesystem-backed) and
//! `mem.zig` (`--ephemeral`). Both satisfy this vtable so the S3 service
//! layer is backend-agnostic.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    NoSuchBucket,
    NoSuchKey,
    BucketAlreadyExists,
    BucketAlreadyOwnedByYou,
    BucketNotEmpty,
    InvalidBucketName,
    Io,
    OutOfMemory,
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

pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        createBucket: *const fn (ctx: *anyopaque, name: []const u8) Error!void,
        deleteBucket: *const fn (ctx: *anyopaque, name: []const u8) Error!void,
        headBucket: *const fn (ctx: *anyopaque, name: []const u8) Error!void,
        listBuckets: *const fn (ctx: *anyopaque, allocator: Allocator) Error![]Bucket,
    };

    pub fn createBucket(self: Backend, name: []const u8) Error!void {
        return self.vtable.createBucket(self.ctx, name);
    }

    pub fn deleteBucket(self: Backend, name: []const u8) Error!void {
        return self.vtable.deleteBucket(self.ctx, name);
    }

    pub fn headBucket(self: Backend, name: []const u8) Error!void {
        return self.vtable.headBucket(self.ctx, name);
    }

    /// Caller owns the returned slice; free with the same allocator passed in.
    pub fn listBuckets(self: Backend, allocator: Allocator) Error![]Bucket {
        return self.vtable.listBuckets(self.ctx, allocator);
    }
};
