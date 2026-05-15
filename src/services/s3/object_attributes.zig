//! S3 GetObjectAttributes service handler (M11). Derives the response
//! from existing object metadata + multipart-ETag suffix.

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const oa_wire = @import("../../wire/object_attributes.zig");
const s3_responses = @import("../../wire/s3_responses.zig");
const preconditions = @import("preconditions.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn getObjectAttributes(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const sel_raw = mod.findHeader(ctx.request.headers, "x-amz-object-attributes") orelse return .{ .err = .invalid_request };
    const sel = oa_wire.Selected.parseHeader(sel_raw);
    if (!sel.anySelected()) return .{ .err = .invalid_request };

    const version_id = mod.queryValue(ctx.allocator, ctx.request.query, "versionId") catch return .{ .err = .internal_error };
    const meta = ctx.backend.headObject(ctx.allocator, .{ .bucket = bucket, .key = key, .version_id = version_id }) catch |err|
        return .{ .err = mod.mapStorageErr(err) };

    switch (preconditions.forRead(ctx.request.headers, .{
        .etag = meta.etag,
        .last_modified_unix = meta.last_modified_unix,
        .exists = true,
    })) {
        .ok => {},
        .precondition_failed => return .{ .err = .precondition_failed },
        .not_modified => return .{ .err = .not_modified },
        .invalid => return .{ .err = .invalid_argument },
    }

    const attrs: oa_wire.Attrs = .{
        .etag = meta.etag,
        .object_size = meta.size,
        .parts_count = oa_wire.partsCountFromEtag(meta.etag),
    };
    const body = oa_wire.render(ctx.allocator, sel, attrs) catch return .{ .err = .internal_error };

    var hs: std.ArrayList(mod.Header) = .empty;
    // AWS-exact: GetObjectAttributes surfaces Last-Modified (HTTP-date) on every
    // response, plus x-amz-delete-marker when the targeted version is a delete
    // marker. Drift table row 10.
    const last_modified = s3_responses.formatHttpDate(ctx.allocator, meta.last_modified_unix) catch
        return .{ .err = .internal_error };
    hs.append(ctx.allocator, .{ .name = "Last-Modified", .value = last_modified }) catch return .{ .err = .internal_error };
    if (meta.version_id.len > 0) {
        hs.append(ctx.allocator, .{ .name = "x-amz-version-id", .value = meta.version_id }) catch return .{ .err = .internal_error };
    }
    if (meta.is_delete_marker) {
        hs.append(ctx.allocator, .{ .name = "x-amz-delete-marker", .value = "true" }) catch return .{ .err = .internal_error };
    }
    const extras = hs.toOwnedSlice(ctx.allocator) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body, .extra_headers = extras } };
}
