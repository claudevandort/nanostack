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
const list_objects_wire = @import("../../wire/list_objects.zig");
const http_range = @import("../../http/range.zig");
const fs_backend = @import("../../storage/fs.zig");
const preconditions = @import("preconditions.zig");
const multipart = @import("multipart.zig");

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
    /// Raw query string (no leading `?`). Used by listing ops to pull
    /// prefix/delimiter/max-keys/continuation-token/etc.
    query: []const u8 = "",
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
        .list_objects => listObjects(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .list_objects_v2 => listObjectsV2(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .create_multipart_upload => multipart.createMultipartUpload(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .upload_part => multipart.uploadPart(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .complete_multipart_upload => multipart.completeMultipartUpload(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .abort_multipart_upload => multipart.abortMultipartUpload(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .list_parts => multipart.listParts(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .list_multipart_uploads => multipart.listMultipartUploads(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .unknown => .{ .err = .not_implemented },
    };
}

// ---------------------------------------------------------------------------
// Query helpers

/// Find a query parameter by name. Returns the *percent-decoded* value or
/// null if absent. Caller's arena owns the returned slice when a decode
/// happened; otherwise it's a slice into the raw query string.
pub fn queryValue(arena: Allocator, query: []const u8, name: []const u8) !?[]const u8 {
    if (query.len == 0) return null;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        const raw = pair[eq + 1 ..];
        return try percentDecode(arena, raw);
    }
    return null;
}

pub fn percentDecode(arena: Allocator, in: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, in.len);
    var i: usize = 0;
    while (i < in.len) : (i += 1) {
        if (in[i] == '%' and i + 2 < in.len) {
            const hi = hexDigit(in[i + 1]) orelse {
                try out.append(arena, in[i]);
                continue;
            };
            const lo = hexDigit(in[i + 2]) orelse {
                try out.append(arena, in[i]);
                continue;
            };
            try out.append(arena, (hi << 4) | lo);
            i += 2;
        } else if (in[i] == '+') {
            try out.append(arena, ' ');
        } else {
            try out.append(arena, in[i]);
        }
    }
    return out.toOwnedSlice(arena);
}

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

pub fn mapStorageErr(e: storage.Error) errors.Code {
    return switch (e) {
        storage.Error.NoSuchBucket => .no_such_bucket,
        storage.Error.NoSuchKey => .no_such_key,
        storage.Error.NoSuchUpload => .no_such_upload,
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
    // CopyObject is a PUT with `x-amz-copy-source`. The router can't tell
    // the two apart (both are `PUT /bucket/key`); we discriminate here.
    if (findHeader(ctx.request.headers, "x-amz-copy-source")) |_| {
        return copyObject(ctx, bucket, key);
    }

    // Conditional-write preconditions (If-Match, If-None-Match).
    if (findHeader(ctx.request.headers, "if-match") != null or
        findHeader(ctx.request.headers, "if-none-match") != null)
    {
        var subj: preconditions.Subject = .{};
        if (ctx.backend.headObject(ctx.allocator, bucket, key)) |meta| {
            subj = .{ .etag = meta.etag, .last_modified_unix = meta.last_modified_unix, .exists = true };
        } else |err| switch (err) {
            storage.Error.NoSuchKey => {},
            storage.Error.NoSuchBucket => return .{ .err = .no_such_bucket },
            else => return .{ .err = mapStorageErr(err) },
        }
        switch (preconditions.forWrite(ctx.request.headers, subj)) {
            .ok => {},
            .precondition_failed => return .{ .err = .precondition_failed },
            .not_modified => unreachable, // forWrite never returns this
            .invalid => return .{ .err = .invalid_argument },
        }
    }

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

fn copyObject(ctx: Context, dest_bucket: []const u8, dest_key: []const u8) Result {
    // ---------- Parse copy-source ----------
    const raw_source = findHeader(ctx.request.headers, "x-amz-copy-source") orelse
        return .{ .err = .invalid_request };
    const decoded_source = percentDecode(ctx.allocator, raw_source) catch
        return .{ .err = .internal_error };
    // AWS allows the source to begin with `/` (path style) — strip it.
    const stripped = if (decoded_source.len > 0 and decoded_source[0] == '/') decoded_source[1..] else decoded_source;
    const slash = std.mem.indexOfScalar(u8, stripped, '/') orelse
        return .{ .err = .invalid_request };
    const source_bucket = stripped[0..slash];
    const source_key = stripped[slash + 1 ..];
    if (source_bucket.len == 0 or source_key.len == 0) return .{ .err = .invalid_request };

    // ---------- Metadata directive ----------
    const directive_raw = findHeader(ctx.request.headers, "x-amz-metadata-directive") orelse "COPY";
    const directive: MetadataDirective = if (std.mem.eql(u8, directive_raw, "COPY"))
        .copy
    else if (std.mem.eql(u8, directive_raw, "REPLACE"))
        .replace
    else
        return .{ .err = .invalid_argument };

    // ---------- Read source ----------
    const source_obj = ctx.backend.getObject(ctx.allocator, source_bucket, source_key) catch |err|
        return .{ .err = mapStorageErr(err) };

    // ---------- Conditional copy-source preconditions ----------
    switch (preconditions.forCopySource(ctx.request.headers, .{
        .etag = source_obj.meta.etag,
        .last_modified_unix = source_obj.meta.last_modified_unix,
        .exists = true,
    })) {
        .ok => {},
        .precondition_failed => return .{ .err = .precondition_failed },
        .not_modified => return .{ .err = .precondition_failed }, // CopyObject can't 304; AWS surfaces 412
        .invalid => return .{ .err = .invalid_argument },
    }

    // ---------- Compose destination input ----------
    var dest_content_type: []const u8 = source_obj.meta.content_type;
    var dest_metadata: []const storage.Header = source_obj.meta.user_metadata;

    if (directive == .replace) {
        dest_content_type = findHeader(ctx.request.headers, "content-type") orelse "application/octet-stream";
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
        dest_metadata = meta_list.toOwnedSlice(ctx.allocator) catch return .{ .err = .internal_error };
    }

    // ---------- Write destination ----------
    const put_out = ctx.backend.putObject(.{
        .bucket = dest_bucket,
        .key = dest_key,
        .body = source_obj.body,
        .content_type = dest_content_type,
        .user_metadata = dest_metadata,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    // ---------- Render response ----------
    // Fetch the destination's stored last_modified_unix for the response.
    const dest_meta = ctx.backend.headObject(ctx.allocator, dest_bucket, dest_key) catch |err|
        return .{ .err = mapStorageErr(err) };
    const body = object_responses.renderCopyObjectResult(ctx.allocator, put_out.etag, dest_meta.last_modified_unix) catch
        return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}

const MetadataDirective = enum { copy, replace };


fn getObject(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const got = ctx.backend.getObject(ctx.allocator, bucket, key) catch |err|
        return .{ .err = mapStorageErr(err) };

    switch (preconditions.forRead(ctx.request.headers, .{
        .etag = got.meta.etag,
        .last_modified_unix = got.meta.last_modified_unix,
        .exists = true,
    })) {
        .ok => {},
        .precondition_failed => return .{ .err = .precondition_failed },
        .not_modified => {
            // RFC 9110 §15.4.5: 304 carries no body but SHOULD include
            // ETag + Last-Modified so cache validators stay coherent.
            const hs = buildObjectHeaders(ctx, got.meta, null) catch return .{ .err = .internal_error };
            return .{ .ok = .{ .status = 304, .body = "", .extra_headers = hs } };
        },
        .invalid => return .{ .err = .invalid_argument },
    }

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

    switch (preconditions.forRead(ctx.request.headers, .{
        .etag = meta.etag,
        .last_modified_unix = meta.last_modified_unix,
        .exists = true,
    })) {
        .ok => {},
        .precondition_failed => return .{ .err = .precondition_failed },
        .not_modified => {
            const hs = buildObjectHeaders(ctx, meta, null) catch return .{ .err = .internal_error };
            return .{ .ok = .{ .status = 304, .body = "", .extra_headers = hs } };
        },
        .invalid => return .{ .err = .invalid_argument },
    }

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

pub fn findHeader(headers: []const storage.Header, lower_name: []const u8) ?[]const u8 {
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

// ---------------------------------------------------------------------------
// Listing

fn listObjects(ctx: Context, bucket: []const u8) Result {
    const echo = parseListEcho(ctx, .v1) catch |err| return mapListParseErr(err);
    return runListing(ctx, bucket, echo, false);
}

fn listObjectsV2(ctx: Context, bucket: []const u8) Result {
    const echo = parseListEcho(ctx, .v2) catch |err| return mapListParseErr(err);
    return runListing(ctx, bucket, echo, true);
}

const ListVariant = enum { v1, v2 };

const ListParseError = error{ InvalidArgument, OutOfMemory };

fn mapListParseErr(e: ListParseError) Result {
    return switch (e) {
        ListParseError.InvalidArgument => .{ .err = .invalid_argument },
        ListParseError.OutOfMemory => .{ .err = .internal_error },
    };
}

fn parseListEcho(ctx: Context, variant: ListVariant) ListParseError!list_objects_wire.RequestEcho {
    var echo: list_objects_wire.RequestEcho = .{};
    const q = ctx.request.query;

    if (try queryValueOpt(ctx.allocator, q, "prefix")) |v| echo.prefix = v;
    if (try queryValueOpt(ctx.allocator, q, "delimiter")) |v| echo.delimiter = v;
    if (try queryValueOpt(ctx.allocator, q, "encoding-type")) |v| {
        if (!std.mem.eql(u8, v, "url")) return ListParseError.InvalidArgument;
        echo.encoding_type = v;
    }

    if (try queryValueOpt(ctx.allocator, q, "max-keys")) |v| {
        const parsed = std.fmt.parseInt(u32, v, 10) catch return ListParseError.InvalidArgument;
        echo.max_keys = if (parsed > 1000) 1000 else parsed;
    }

    switch (variant) {
        .v1 => {
            if (try queryValueOpt(ctx.allocator, q, "marker")) |v| echo.marker = v;
        },
        .v2 => {
            if (try queryValueOpt(ctx.allocator, q, "continuation-token")) |v| echo.continuation_token = v;
            if (try queryValueOpt(ctx.allocator, q, "start-after")) |v| echo.start_after = v;
            if (try queryValueOpt(ctx.allocator, q, "fetch-owner")) |v| {
                echo.fetch_owner = std.mem.eql(u8, v, "true");
            }
        },
    }
    return echo;
}

fn queryValueOpt(arena: Allocator, query: []const u8, name: []const u8) ListParseError!?[]const u8 {
    return queryValue(arena, query, name) catch return ListParseError.OutOfMemory;
}

fn runListing(ctx: Context, bucket: []const u8, echo: list_objects_wire.RequestEcho, v2: bool) Result {
    var start_after: []const u8 = "";
    if (v2) {
        if (echo.continuation_token) |t| {
            start_after = list_objects_wire.decodeContinuationToken(ctx.allocator, t) catch
                return .{ .err = .invalid_argument };
        } else if (echo.start_after) |sa| {
            start_after = sa;
        }
    } else {
        start_after = echo.marker;
    }

    const result = ctx.backend.listObjects(ctx.allocator, .{
        .bucket = bucket,
        .prefix = echo.prefix,
        .start_after = start_after,
        .delimiter = echo.delimiter,
        .max_keys = echo.max_keys,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const body = if (v2)
        list_objects_wire.renderListObjectsV2(
            ctx.allocator,
            bucket,
            echo,
            result,
            .{ .id = ctx.owner_id, .display_name = ctx.owner_display_name },
        ) catch return .{ .err = .internal_error }
    else
        list_objects_wire.renderListObjectsV1(
            ctx.allocator,
            bucket,
            echo,
            result,
        ) catch return .{ .err = .internal_error };

    return .{ .ok = .{ .status = 200, .body = body } };
}
