//! S3 service dispatch.
//!
//! M1 covered bucket operations; M3 lands the five object operations.
//! Every op resolves into either an `Output` (status + body + extra
//! headers) or an `errors.Code`. The HTTP layer renders both.

const std = @import("std");
const Allocator = std.mem.Allocator;
const router = @import("../../router.zig");
const errors = @import("../../wire/errors.zig");
const storage = @import("../../storage/mod.zig");
const s3_responses = @import("../../wire/s3_responses.zig");
const object_responses = @import("../../wire/object_responses.zig");
const delete_parser = @import("../../wire/delete_objects_parser.zig");
const http_range = @import("../../http/range.zig");
const fs_backend = @import("../../storage/fs.zig");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Output = struct {
    status: u16,
    body: []const u8,
    extra_headers: []const Header = &.{},
    /// If set, the server emits this instead of the default
    /// `application/xml`. Used by GetObject to surface user content type.
    content_type_override: ?[]const u8 = null,
};

pub const Result = union(enum) {
    ok: Output,
    err: errors.Code,
};

/// Per-request data the service handlers need access to. Populated by
/// server.zig from the incoming httpz request.
pub const RequestData = struct {
    headers: []const storage.Header = &.{},
    body: []const u8 = "",
    range: ?[]const u8 = null,
};

pub const Context = struct {
    backend: storage.Backend,
    /// Per-request arena, owned by the HTTP server. The result's body and
    /// header values are allocated here and live until the response is sent.
    allocator: Allocator,
    owner_id: []const u8,
    owner_display_name: []const u8,
    request: RequestData = .{},
};

pub fn handle(ctx: Context, parsed: router.Parsed) Result {
    return switch (parsed.op) {
        .create_bucket => createBucket(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .delete_bucket => deleteBucket(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .head_bucket => headBucket(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .list_buckets => listBuckets(ctx),
        .put_object => putObject(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .get_object => getObject(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .head_object => headObject(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .delete_object => deleteObject(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .delete_objects => deleteObjects(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
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
        storage.Error.InvalidObjectKey => .invalid_argument,
        storage.Error.Io, storage.Error.OutOfMemory => .internal_error,
    };
}

// ---------------------------------------------------------------------------
// Bucket ops

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

// ---------------------------------------------------------------------------
// Object ops

fn putObject(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const content_type = findHeader(ctx.request.headers, "content-type") orelse "application/octet-stream";
    var meta_list: std.ArrayList(storage.Header) = .empty;
    defer meta_list.deinit(ctx.allocator);
    for (ctx.request.headers) |h| {
        var lower_buf: [256]u8 = undefined;
        const lower = std.ascii.lowerString(lower_buf[0..@min(lower_buf.len, h.name.len)], h.name);
        if (std.mem.startsWith(u8, lower, "x-amz-meta-")) {
            const owned_name = ctx.allocator.dupe(u8, lower) catch return .{ .err = .internal_error };
            const owned_value = ctx.allocator.dupe(u8, h.value) catch return .{ .err = .internal_error };
            meta_list.append(ctx.allocator, .{ .name = owned_name, .value = owned_value }) catch return .{ .err = .internal_error };
        }
    }

    const out = ctx.backend.putObject(.{
        .bucket = bucket,
        .key = key,
        .body = ctx.request.body,
        .content_type = content_type,
        .user_metadata = meta_list.items,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const headers = ctx.allocator.dupe(Header, &.{
        .{ .name = "ETag", .value = out.etag },
    }) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = "", .extra_headers = headers } };
}

fn getObject(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const got = ctx.backend.getObject(ctx.allocator, bucket, key) catch |err|
        return .{ .err = mapStorageErr(err) };

    var status: u16 = 200;
    var body: []const u8 = got.body;
    var range_header: ?[]const u8 = null;

    if (ctx.request.range) |r| {
        const parsed = http_range.parse(r, got.body.len) catch |err| switch (err) {
            http_range.Error.Unsatisfiable, http_range.Error.Malformed => return .{ .err = .invalid_range },
            http_range.Error.Unsupported => return .{ .err = .invalid_range },
        };
        body = got.body[parsed.start .. parsed.end + 1];
        var cr_buf: [128]u8 = undefined;
        const cr = http_range.formatContentRange(&cr_buf, parsed, got.body.len) catch return .{ .err = .internal_error };
        range_header = ctx.allocator.dupe(u8, cr) catch return .{ .err = .internal_error };
        status = 206;
    }

    const headers = buildObjectHeaders(ctx, got.meta, range_header) catch return .{ .err = .internal_error };
    return .{
        .ok = .{
            .status = status,
            .body = body,
            .extra_headers = headers,
            .content_type_override = got.meta.content_type,
        },
    };
}

fn headObject(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const meta = ctx.backend.headObject(ctx.allocator, bucket, key) catch |err|
        return .{ .err = mapStorageErr(err) };
    const headers = buildHeadHeaders(ctx, meta) catch return .{ .err = .internal_error };
    return .{
        .ok = .{
            .status = 200,
            .body = "",
            .extra_headers = headers,
            .content_type_override = meta.content_type,
        },
    };
}

fn deleteObject(ctx: Context, bucket: []const u8, key: []const u8) Result {
    ctx.backend.deleteObject(bucket, key) catch |err| return .{ .err = mapStorageErr(err) };
    return .{ .ok = .{ .status = 204, .body = "" } };
}

fn deleteObjects(ctx: Context, bucket: []const u8) Result {
    const parsed_body = delete_parser.parse(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        delete_parser.ParseError.InvalidBody => return .{ .err = .invalid_request },
        delete_parser.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };
    defer delete_parser.freeResult(ctx.allocator, parsed_body);

    var deleted: std.ArrayList(storage.DeletedKey) = .empty;
    defer deleted.deinit(ctx.allocator);
    var errs: std.ArrayList(storage.DeleteError) = .empty;
    defer errs.deinit(ctx.allocator);

    for (parsed_body.keys) |k| {
        ctx.backend.deleteObject(bucket, k) catch |err| {
            const code: errors.Code = mapStorageErr(err);
            errs.append(ctx.allocator, .{
                .key = k,
                .code = code.awsCode(),
                .message = code.defaultMessage(),
            }) catch return .{ .err = .internal_error };
            continue;
        };
        deleted.append(ctx.allocator, .{ .key = k }) catch return .{ .err = .internal_error };
    }

    const result: storage.DeleteResult = .{
        .deleted = deleted.items,
        .errors = errs.items,
        .quiet = parsed_body.quiet,
    };
    const body = object_responses.renderDeleteResult(ctx.allocator, result) catch
        return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}

// ---------------------------------------------------------------------------
// Helpers

fn findHeader(headers: []const storage.Header, lower_name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, lower_name)) return h.value;
    }
    return null;
}

fn buildObjectHeaders(ctx: Context, meta: storage.Object, range_header: ?[]const u8) ![]Header {
    var hs: std.ArrayList(Header) = .empty;
    errdefer hs.deinit(ctx.allocator);

    try hs.append(ctx.allocator, .{ .name = "ETag", .value = meta.etag });
    try hs.append(ctx.allocator, .{ .name = "Accept-Ranges", .value = "bytes" });

    // `Last-Modified` is an HTTP header, not an XML body field — RFC 7231
    // HTTP-date, not ISO 8601. The SDKs reject the latter.
    const last_modified = try s3_responses.formatHttpDate(ctx.allocator, meta.last_modified_unix);
    try hs.append(ctx.allocator, .{ .name = "Last-Modified", .value = last_modified });

    for (meta.user_metadata) |m| {
        try hs.append(ctx.allocator, .{ .name = m.name, .value = m.value });
    }

    if (range_header) |r| {
        try hs.append(ctx.allocator, .{ .name = "Content-Range", .value = r });
    }

    return hs.toOwnedSlice(ctx.allocator);
}

/// HeadObject must surface `Content-Length` equal to the object size — even
/// though the response carries no body. This separate header builder is
/// used by the head path so we can include the explicit length without
/// disturbing GetObject (where httpz computes Content-Length from the
/// actual body slice).
fn buildHeadHeaders(ctx: Context, meta: storage.Object) ![]Header {
    const base = try buildObjectHeaders(ctx, meta, null);
    var hs: std.ArrayList(Header) = .empty;
    errdefer hs.deinit(ctx.allocator);
    try hs.appendSlice(ctx.allocator, base);
    ctx.allocator.free(base);
    const len_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{meta.size});
    try hs.append(ctx.allocator, .{ .name = "Content-Length", .value = len_str });
    return hs.toOwnedSlice(ctx.allocator);
}

// Avoid the "unused" warning on fs_backend; we may want it later for
// timing helpers.
const _unused_fs_backend = fs_backend;
