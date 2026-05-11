//! Storage backend interface — shape only in M0.
//!
//! M1 lands the filesystem implementation per PRD §9. M7 adds the
//! in-memory `--ephemeral` variant. Both implement this vtable so the
//! S3 service layer is backend-agnostic.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    NoSuchBucket,
    NoSuchKey,
    BucketAlreadyExists,
    BucketNotEmpty,
    Io,
    OutOfMemory,
};

pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Bucket ops — M1.
        createBucket: *const fn (ctx: *anyopaque, name: []const u8) Error!void,
        deleteBucket: *const fn (ctx: *anyopaque, name: []const u8) Error!void,
        headBucket: *const fn (ctx: *anyopaque, name: []const u8) Error!void,
        // Object ops — M3, signatures TBD.
        // putObject, getObject, headObject, deleteObject ...
    };
};
