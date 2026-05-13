//! Multipart-upload service handlers (M6).
//!
//! Seven AWS operations route here: CreateMultipartUpload, UploadPart,
//! UploadPartCopy, CompleteMultipartUpload, AbortMultipartUpload,
//! ListParts, ListMultipartUploads. UploadPart special-cases the
//! `x-amz-copy-source` header to dispatch to UploadPartCopy, mirroring
//! how PutObject special-cases CopyObject in M5.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const errors = @import("../../wire/errors.zig");
const multipart_wire = @import("../../wire/multipart_responses.zig");
const complete_parser = @import("../../wire/complete_multipart_parser.zig");
const preconditions = @import("preconditions.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;
const Output = mod.Output;
const Header = mod.Header;

// AWS S3 part-size rule: every non-final part must be at least 5 MiB.
const min_part_size: u64 = 5 * 1024 * 1024;
const max_part_number: u32 = 10000;

pub fn createMultipartUpload(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const content_type = mod.findHeader(ctx.request.headers, "content-type") orelse "application/octet-stream";
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

    const out = ctx.backend.initiateMultipartUpload(ctx.allocator, .{
        .bucket = bucket,
        .key = key,
        .content_type = content_type,
        .user_metadata = meta_list.items,
    }) catch |err| return .{ .err = mod.mapStorageErr(err) };

    const body = multipart_wire.renderInitiateMultipartUploadResult(ctx.allocator, bucket, key, out.upload_id) catch
        return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}

pub fn uploadPart(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const upload_id = (mod.queryValue(ctx.allocator, ctx.request.query, "uploadId") catch return .{ .err = .internal_error }) orelse
        return .{ .err = .invalid_request };
    const part_number_raw = (mod.queryValue(ctx.allocator, ctx.request.query, "partNumber") catch return .{ .err = .internal_error }) orelse
        return .{ .err = .invalid_argument };
    const part_number = std.fmt.parseInt(u32, part_number_raw, 10) catch return .{ .err = .invalid_argument };
    if (part_number == 0 or part_number > max_part_number) return .{ .err = .invalid_argument };

    if (mod.findHeader(ctx.request.headers, "x-amz-copy-source") != null) {
        return uploadPartCopy(ctx, bucket, key, upload_id, part_number);
    }

    const out = ctx.backend.uploadPart(.{
        .bucket = bucket,
        .key = key,
        .upload_id = upload_id,
        .part_number = part_number,
        .body = ctx.request.body,
    }) catch |err| return .{ .err = mod.mapStorageErr(err) };

    const headers = ctx.allocator.dupe(Header, &.{
        .{ .name = "ETag", .value = out.etag },
    }) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = "", .extra_headers = headers } };
}

fn uploadPartCopy(ctx: Context, dest_bucket: []const u8, dest_key: []const u8, upload_id: []const u8, part_number: u32) Result {
    const raw_source = mod.findHeader(ctx.request.headers, "x-amz-copy-source") orelse
        return .{ .err = .invalid_request };
    const decoded = mod.percentDecode(ctx.allocator, raw_source) catch return .{ .err = .internal_error };
    const stripped = if (decoded.len > 0 and decoded[0] == '/') decoded[1..] else decoded;
    const slash = std.mem.indexOfScalar(u8, stripped, '/') orelse return .{ .err = .invalid_request };
    const source_bucket = stripped[0..slash];
    const source_key = stripped[slash + 1 ..];
    if (source_bucket.len == 0 or source_key.len == 0) return .{ .err = .invalid_request };

    const source_obj = ctx.backend.getObject(ctx.allocator, source_bucket, source_key) catch |err|
        return .{ .err = mod.mapStorageErr(err) };

    switch (preconditions.forCopySource(ctx.request.headers, .{
        .etag = source_obj.meta.etag,
        .last_modified_unix = source_obj.meta.last_modified_unix,
        .exists = true,
    })) {
        .ok => {},
        .precondition_failed, .not_modified => return .{ .err = .precondition_failed },
        .invalid => return .{ .err = .invalid_argument },
    }

    const out = ctx.backend.uploadPart(.{
        .bucket = dest_bucket,
        .key = dest_key,
        .upload_id = upload_id,
        .part_number = part_number,
        .body = source_obj.body,
    }) catch |err| return .{ .err = mod.mapStorageErr(err) };

    const body = multipart_wire.renderCopyPartResult(ctx.allocator, out.etag, source_obj.meta.last_modified_unix) catch
        return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}

pub fn completeMultipartUpload(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const upload_id = (mod.queryValue(ctx.allocator, ctx.request.query, "uploadId") catch return .{ .err = .internal_error }) orelse
        return .{ .err = .invalid_request };

    // Conditional CompleteMultipartUpload: evaluate `If-Match` and
    // `If-None-Match` against the destination key (the soon-to-be-merged
    // object). Mirrors PutObject's conditional check from M5.
    if (mod.findHeader(ctx.request.headers, "if-match") != null or
        mod.findHeader(ctx.request.headers, "if-none-match") != null)
    {
        var subj: preconditions.Subject = .{};
        if (ctx.backend.headObject(ctx.allocator, bucket, key)) |meta| {
            subj = .{ .etag = meta.etag, .last_modified_unix = meta.last_modified_unix, .exists = true };
        } else |err| switch (err) {
            storage.Error.NoSuchKey => {},
            storage.Error.NoSuchBucket => return .{ .err = .no_such_bucket },
            else => return .{ .err = mod.mapStorageErr(err) },
        }
        switch (preconditions.forWrite(ctx.request.headers, subj)) {
            .ok => {},
            .precondition_failed => return .{ .err = .precondition_failed },
            .not_modified => unreachable,
            .invalid => return .{ .err = .invalid_argument },
        }
    }

    // Parse XML body.
    const parsed = complete_parser.parse(ctx.allocator, ctx.request.body) catch |err| switch (err) {
        complete_parser.ParseError.InvalidBody => return .{ .err = .invalid_request },
        complete_parser.ParseError.InvalidPartOrder => return .{ .err = .invalid_part_order },
        complete_parser.ParseError.OutOfMemory => return .{ .err = .internal_error },
    };

    // Look up part sizes to enforce the 5 MiB rule on every non-final part.
    const list_out = ctx.backend.listParts(ctx.allocator, .{
        .bucket = bucket,
        .key = key,
        .upload_id = upload_id,
        .max_parts = 1000,
    }) catch |err| return .{ .err = mod.mapStorageErr(err) };

    var size_lookup = std.AutoHashMap(u32, u64).init(ctx.allocator);
    defer size_lookup.deinit();
    for (list_out.parts) |p| {
        size_lookup.put(p.part_number, p.size) catch return .{ .err = .internal_error };
    }
    for (parsed.parts, 0..) |p, i| {
        const size = size_lookup.get(p.part_number) orelse return .{ .err = .invalid_part };
        if (i != parsed.parts.len - 1 and size < min_part_size) {
            return .{ .err = .entity_too_small };
        }
    }

    const out = ctx.backend.completeMultipartUpload(ctx.allocator, .{
        .bucket = bucket,
        .key = key,
        .upload_id = upload_id,
        .parts = parsed.parts,
    }) catch |err| switch (err) {
        storage.Error.NoSuchUpload => return .{ .err = .invalid_part },
        else => return .{ .err = mod.mapStorageErr(err) },
    };

    const host_header = mod.findHeader(ctx.request.headers, "host") orelse "localhost";
    const location = std.fmt.allocPrint(ctx.allocator, "http://{s}/{s}/{s}", .{ host_header, bucket, key }) catch
        return .{ .err = .internal_error };

    const body = multipart_wire.renderCompleteMultipartUploadResult(ctx.allocator, location, bucket, key, out.etag) catch
        return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}

pub fn abortMultipartUpload(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const upload_id = (mod.queryValue(ctx.allocator, ctx.request.query, "uploadId") catch return .{ .err = .internal_error }) orelse
        return .{ .err = .invalid_request };
    ctx.backend.abortMultipartUpload(bucket, key, upload_id) catch |err| return .{ .err = mod.mapStorageErr(err) };
    return .{ .ok = .{ .status = 204, .body = "" } };
}

pub fn listParts(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const upload_id = (mod.queryValue(ctx.allocator, ctx.request.query, "uploadId") catch return .{ .err = .internal_error }) orelse
        return .{ .err = .invalid_request };

    var pm: u32 = 0;
    if (mod.queryValue(ctx.allocator, ctx.request.query, "part-number-marker") catch return .{ .err = .internal_error }) |v| {
        pm = std.fmt.parseInt(u32, v, 10) catch return .{ .err = .invalid_argument };
    }
    var mp: u32 = 1000;
    if (mod.queryValue(ctx.allocator, ctx.request.query, "max-parts") catch return .{ .err = .internal_error }) |v| {
        const parsed = std.fmt.parseInt(u32, v, 10) catch return .{ .err = .invalid_argument };
        mp = if (parsed > 1000) 1000 else parsed;
    }

    const result = ctx.backend.listParts(ctx.allocator, .{
        .bucket = bucket,
        .key = key,
        .upload_id = upload_id,
        .part_number_marker = pm,
        .max_parts = mp,
    }) catch |err| return .{ .err = mod.mapStorageErr(err) };

    const body = multipart_wire.renderListPartsResult(ctx.allocator, .{
        .bucket = bucket,
        .key = key,
        .upload_id = upload_id,
        .part_number_marker = pm,
        .max_parts = mp,
    }, result) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}

pub fn listMultipartUploads(ctx: Context, bucket: []const u8) Result {
    var echo: multipart_wire.ListMultipartUploadsEcho = .{};
    const q = ctx.request.query;

    if (mod.queryValue(ctx.allocator, q, "prefix") catch return .{ .err = .internal_error }) |v| echo.prefix = v;
    if (mod.queryValue(ctx.allocator, q, "delimiter") catch return .{ .err = .internal_error }) |v| echo.delimiter = v;
    if (mod.queryValue(ctx.allocator, q, "key-marker") catch return .{ .err = .internal_error }) |v| echo.key_marker = v;
    if (mod.queryValue(ctx.allocator, q, "upload-id-marker") catch return .{ .err = .internal_error }) |v| echo.upload_id_marker = v;
    if (mod.queryValue(ctx.allocator, q, "encoding-type") catch return .{ .err = .internal_error }) |v| {
        if (!std.mem.eql(u8, v, "url")) return .{ .err = .invalid_argument };
        echo.encoding_type = v;
    }
    if (mod.queryValue(ctx.allocator, q, "max-uploads") catch return .{ .err = .internal_error }) |v| {
        const parsed = std.fmt.parseInt(u32, v, 10) catch return .{ .err = .invalid_argument };
        echo.max_uploads = if (parsed > 1000) 1000 else parsed;
    }

    const result = ctx.backend.listMultipartUploads(ctx.allocator, .{
        .bucket = bucket,
        .prefix = echo.prefix,
        .delimiter = echo.delimiter,
        .key_marker = echo.key_marker,
        .upload_id_marker = echo.upload_id_marker,
        .max_uploads = echo.max_uploads,
    }) catch |err| return .{ .err = mod.mapStorageErr(err) };

    const body = multipart_wire.renderListMultipartUploadsResult(ctx.allocator, bucket, echo, result) catch
        return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}
