//! S3 service dispatch.
//!
//! M1 covers the four bucket operations. The result is either an `Output`
//! (status + body + extra headers) or an AWS error code. The HTTP layer
//! renders both.

const std = @import("std");
const Allocator = std.mem.Allocator;
const router = @import("../../router.zig");
const errors = @import("../../wire/errors.zig");
const storage = @import("../../storage/mod.zig");
const s3_responses = @import("../../wire/s3_responses.zig");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Output = struct {
    status: u16,
    body: []const u8,
    extra_headers: []const Header = &.{},
};

pub const Result = union(enum) {
    ok: Output,
    err: errors.Code,
};

pub const Context = struct {
    backend: storage.Backend,
    /// Per-request arena, owned by the HTTP server. The result's body and
    /// header values are allocated here and live until the response is sent.
    allocator: Allocator,
    owner_id: []const u8,
    owner_display_name: []const u8,
};

pub fn handle(ctx: Context, parsed: router.Parsed) Result {
    return switch (parsed.op) {
        .create_bucket => createBucket(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .delete_bucket => deleteBucket(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .head_bucket => headBucket(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .list_buckets => listBuckets(ctx),
        .unknown => .{ .err = .not_implemented },
    };
}

fn mapStorageErr(e: storage.Error) errors.Code {
    return switch (e) {
        storage.Error.NoSuchBucket => .no_such_bucket,
        storage.Error.NoSuchKey => .no_such_key,
        storage.Error.BucketAlreadyExists => .bucket_already_exists,
        storage.Error.BucketAlreadyOwnedByYou => .bucket_already_owned_by_you,
        storage.Error.BucketNotEmpty => .bucket_not_empty,
        storage.Error.InvalidBucketName => .invalid_bucket_name,
        storage.Error.Io, storage.Error.OutOfMemory => .internal_error,
    };
}

fn createBucket(ctx: Context, name: []const u8) Result {
    ctx.backend.createBucket(name) catch |err| return .{ .err = mapStorageErr(err) };
    const location = std.fmt.allocPrint(ctx.allocator, "/{s}", .{name}) catch
        return .{ .err = .internal_error };
    const headers = ctx.allocator.dupe(Header, &.{
        .{ .name = "Location", .value = location },
    }) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = "", .extra_headers = headers } };
}

fn deleteBucket(ctx: Context, name: []const u8) Result {
    ctx.backend.deleteBucket(name) catch |err| return .{ .err = mapStorageErr(err) };
    return .{ .ok = .{ .status = 204, .body = "" } };
}

fn headBucket(ctx: Context, name: []const u8) Result {
    ctx.backend.headBucket(name) catch |err| return .{ .err = mapStorageErr(err) };
    return .{ .ok = .{ .status = 200, .body = "" } };
}

fn listBuckets(ctx: Context) Result {
    const buckets = ctx.backend.listBuckets(ctx.allocator) catch |err|
        return .{ .err = mapStorageErr(err) };
    // The body borrows strings from `buckets`. We free `buckets` here only
    // after rendering completes. The body itself lives on `ctx.allocator`.
    defer {
        for (buckets) |b| {
            ctx.allocator.free(b.name);
            ctx.allocator.free(b.region);
        }
        ctx.allocator.free(buckets);
    }
    const body = s3_responses.renderListAllMyBucketsResult(
        ctx.allocator,
        ctx.owner_id,
        ctx.owner_display_name,
        buckets,
    ) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}
