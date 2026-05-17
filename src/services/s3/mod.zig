//! S3 service dispatch.
//!
//! M1 covered bucket operations; M3 lands the five object operations.
//! Every op resolves into either an `Output` (status + body + extra
//! headers) or an `errors.Code`. The HTTP layer renders both.

const std = @import("std");
const Allocator = std.mem.Allocator;
const router = @import("../../router.zig");
pub const errors = @import("../../wire/errors.zig");
const storage = @import("../../storage/mod.zig");
const s3_responses = @import("../../wire/s3_responses.zig");
const object_responses = @import("../../wire/object_responses.zig");
const delete_parser = @import("../../wire/delete_objects_parser.zig");
const list_objects_wire = @import("../../wire/list_objects.zig");
const tagging_parser = @import("../../wire/tagging_parser.zig");
const acl_parser = @import("../../wire/acl_parser.zig");
const http_range = @import("../../http/range.zig");
const fs_backend = @import("../../storage/fs.zig");
const preconditions = @import("preconditions.zig");
const multipart = @import("multipart.zig");
const versioning = @import("versioning.zig");
const tagging = @import("tagging.zig");
const acl_service = @import("acl.zig");
const policy = @import("policy.zig");
const ownership = @import("ownership.zig");
const public_access_block_service = @import("public_access_block.zig");
const cors_service = @import("cors.zig");
const encryption_service = @import("encryption.zig");
const lifecycle_service = @import("lifecycle.zig");
const notification_service = @import("notification.zig");
const website_service = @import("website.zig");
const object_attributes_service = @import("object_attributes.zig");
const object_lock_service = @import("object_lock.zig");
const object_retention_service = @import("object_retention.zig");
const object_legal_hold_service = @import("object_legal_hold.zig");
const object_retention_wire = @import("../../wire/object_retention.zig");
const policy_status_service = @import("policy_status.zig");
const restore_service = @import("restore.zig");
const object_encryption_service = @import("object_encryption.zig");
const replication_service = @import("replication.zig");

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

/// Some error paths (notably the M8 delete-marker 404 on GET/HEAD) need
/// to carry response headers alongside the error body. This wraps an
/// error code with an extra-headers slice owned by the request arena.
pub const ErrorWithHeaders = struct {
    code: errors.Code,
    extra_headers: []const Header,
};

pub const Result = union(enum) {
    ok: Output,
    err: errors.Code,
    err_with_headers: ErrorWithHeaders,
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
    /// Server's configured region. Used by CreateBucket to validate the
    /// optional `<LocationConstraint>` in the request body.
    region: []const u8 = "us-east-1",
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
        .put_bucket_versioning => versioning.putBucketVersioning(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .get_bucket_versioning => versioning.getBucketVersioning(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .list_object_versions => versioning.listObjectVersions(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .put_bucket_tagging => tagging.putBucketTagging(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .get_bucket_tagging => tagging.getBucketTagging(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .delete_bucket_tagging => tagging.deleteBucketTagging(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .put_object_tagging => tagging.putObjectTagging(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .get_object_tagging => tagging.getObjectTagging(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .delete_object_tagging => tagging.deleteObjectTagging(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .put_bucket_acl => acl_service.putBucketAcl(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .get_bucket_acl => acl_service.getBucketAcl(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .put_object_acl => acl_service.putObjectAcl(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .get_object_acl => acl_service.getObjectAcl(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .put_bucket_policy => policy.putBucketPolicy(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .get_bucket_policy => policy.getBucketPolicy(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .delete_bucket_policy => policy.deleteBucketPolicy(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .put_bucket_ownership_controls => ownership.putBucketOwnershipControls(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .get_bucket_ownership_controls => ownership.getBucketOwnershipControls(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .delete_bucket_ownership_controls => ownership.deleteBucketOwnershipControls(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .put_public_access_block => public_access_block_service.putPublicAccessBlock(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .get_public_access_block => public_access_block_service.getPublicAccessBlock(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .delete_public_access_block => public_access_block_service.deletePublicAccessBlock(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
        ),
        .put_bucket_cors => cors_service.putBucketCors(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .get_bucket_cors => cors_service.getBucketCors(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .delete_bucket_cors => cors_service.deleteBucketCors(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .put_bucket_encryption => encryption_service.putBucketEncryption(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .get_bucket_encryption => encryption_service.getBucketEncryption(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .delete_bucket_encryption => encryption_service.deleteBucketEncryption(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .put_bucket_lifecycle => lifecycle_service.putBucketLifecycle(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .get_bucket_lifecycle => lifecycle_service.getBucketLifecycle(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .delete_bucket_lifecycle => lifecycle_service.deleteBucketLifecycle(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .put_bucket_notification => notification_service.putBucketNotification(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .get_bucket_notification => notification_service.getBucketNotification(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .put_bucket_website => website_service.putBucketWebsite(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .get_bucket_website => website_service.getBucketWebsite(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .delete_bucket_website => website_service.deleteBucketWebsite(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .get_object_attributes => object_attributes_service.getObjectAttributes(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .put_object_lock_config => object_lock_service.putObjectLockConfig(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .get_object_lock_config => object_lock_service.getObjectLockConfig(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .put_object_retention => object_retention_service.putObjectRetention(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .get_object_retention => object_retention_service.getObjectRetention(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .put_object_legal_hold => object_legal_hold_service.putObjectLegalHold(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .get_object_legal_hold => object_legal_hold_service.getObjectLegalHold(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .get_bucket_policy_status => policy_status_service.getBucketPolicyStatus(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .restore_object => restore_service.restoreObject(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .update_object_encryption => object_encryption_service.updateObjectEncryption(
            ctx,
            parsed.bucket orelse return .{ .err = .invalid_request },
            parsed.key orelse return .{ .err = .invalid_request },
        ),
        .put_bucket_replication => replication_service.putBucketReplication(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .get_bucket_replication => replication_service.getBucketReplication(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
        .delete_bucket_replication => replication_service.deleteBucketReplication(ctx, parsed.bucket orelse return .{ .err = .invalid_request }),
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

/// Result of extracting an inline ACL from `x-amz-acl` + `x-amz-grant-*`
/// headers on a write request. `.none` means no ACL-related headers
/// were present (caller should pass `null` to the backend).
pub const InlineAclOutcome = union(enum) {
    none: void,
    ok: storage.Acl,
    err: errors.Code,
};

/// Extract an inline ACL from a request's headers. Returns `.none` when
/// no ACL-related headers are present. Otherwise, expands the canned
/// value (default "private") and folds in any `x-amz-grant-*` headers.
pub fn extractInlineAcl(ctx: Context) InlineAclOutcome {
    const has_canned = findHeader(ctx.request.headers, "x-amz-acl") != null;
    const grant_pairs = [_]GrantPair{
        .{ .name = "x-amz-grant-read", .perm = .READ },
        .{ .name = "x-amz-grant-write", .perm = .WRITE },
        .{ .name = "x-amz-grant-read-acp", .perm = .READ_ACP },
        .{ .name = "x-amz-grant-write-acp", .perm = .WRITE_ACP },
        .{ .name = "x-amz-grant-full-control", .perm = .FULL_CONTROL },
    };
    var has_grant = false;
    for (grant_pairs) |g| {
        if (findHeader(ctx.request.headers, g.name) != null) {
            has_grant = true;
            break;
        }
    }
    if (!has_canned and !has_grant) return .{ .none = {} };

    const canned_str = findHeader(ctx.request.headers, "x-amz-acl") orelse "private";
    const canned = acl_parser.parseCanned(canned_str) catch return .{ .err = .invalid_argument };
    var acl = acl_parser.cannedToAcl(ctx.allocator, canned) catch return .{ .err = .internal_error };

    for (grant_pairs) |g| {
        const v = findHeader(ctx.request.headers, g.name) orelse continue;
        const extras = acl_parser.parseGrantHeader(ctx.allocator, v, g.perm) catch return .{ .err = .malformed_acl_error };
        acl = acl_parser.mergeGrants(ctx.allocator, acl, extras) catch return .{ .err = .internal_error };
    }
    return .{ .ok = acl };
}

const GrantPair = struct { name: []const u8, perm: storage.Permission };

/// M12: parse inline `x-amz-object-lock-*` headers into a triple of
/// (mode, retain_until_unix, legal_hold). All three fields default to
/// "no explicit lock" — the backend may apply bucket-default retention.
pub const InlineLockInfo = struct {
    mode: ?storage.RetentionMode = null,
    retain_until_unix: i64 = 0,
    legal_hold: bool = false,
};

pub const InlineLockOutcome = union(enum) {
    ok: InlineLockInfo,
    err: errors.Code,
};

pub fn extractInlineLockInfo(ctx: Context) InlineLockOutcome {
    var info: InlineLockInfo = .{};
    if (findHeader(ctx.request.headers, "x-amz-object-lock-mode")) |hv| {
        info.mode = storage.retentionModeFromString(hv) catch return .{ .err = .invalid_argument };
    }
    if (findHeader(ctx.request.headers, "x-amz-object-lock-retain-until-date")) |hv| {
        info.retain_until_unix = object_retention_wire.parseIsoOrUnix(hv) catch return .{ .err = .invalid_retention_period };
    }
    if (findHeader(ctx.request.headers, "x-amz-object-lock-legal-hold")) |hv| {
        info.legal_hold = std.ascii.eqlIgnoreCase(hv, "ON");
    }
    return .{ .ok = info };
}

pub fn mapStorageErr(e: storage.Error) errors.Code {
    return switch (e) {
        storage.Error.NoSuchBucket => .no_such_bucket,
        storage.Error.NoSuchKey => .no_such_key,
        storage.Error.NoSuchUpload => .no_such_upload,
        storage.Error.InvalidPart => .invalid_part,
        storage.Error.NoSuchTagSet => .no_such_tag_set,
        storage.Error.NoSuchBucketPolicy => .no_such_bucket_policy,
        storage.Error.OwnershipControlsNotFound => .ownership_controls_not_found,
        storage.Error.NoSuchPublicAccessBlockConfiguration => .no_such_public_access_block_configuration,
        storage.Error.AccessControlListNotSupported => .access_control_list_not_supported,
        storage.Error.NoSuchCorsConfiguration => .no_such_cors_configuration,
        storage.Error.ServerSideEncryptionConfigurationNotFound => .server_side_encryption_configuration_not_found_error,
        storage.Error.NoSuchLifecycleConfiguration => .no_such_lifecycle_configuration,
        storage.Error.NoSuchWebsiteConfiguration => .no_such_website_configuration,
        storage.Error.ObjectLockConfigurationNotFound => .object_lock_configuration_not_found_error,
        storage.Error.InvalidBucketState => .invalid_bucket_state,
        storage.Error.InvalidRetentionPeriod => .invalid_retention_period,
        storage.Error.AccessDenied => .access_denied,
        storage.Error.ReplicationConfigurationNotFound => .replication_configuration_not_found_error,
        storage.Error.BucketAlreadyExists => .bucket_already_exists,
        storage.Error.BucketAlreadyOwnedByYou => .bucket_already_owned_by_you,
        storage.Error.BucketNotEmpty => .bucket_not_empty,
        storage.Error.InvalidBucketName => .invalid_bucket_name,
        storage.Error.InvalidObjectKey => .invalid_argument,
        storage.Error.InvalidTag => .invalid_tag,
        // DynamoDB error variants — S3 should never see them; if it does,
        // treat as internal_error (defensive).
        storage.Error.TableAlreadyExists,
        storage.Error.TableNotFound,
        storage.Error.ConditionalCheckFailed,
        storage.Error.TransactionCanceled,
        storage.Error.StreamNotFound,
        storage.Error.ShardNotFound,
        storage.Error.InvalidStreamArn,
        storage.Error.InvalidShardIterator,
        storage.Error.BackupNotFound,
        storage.Error.InvalidBackupArn,
        => .internal_error,
        storage.Error.Io, storage.Error.OutOfMemory => .internal_error,
    };
}

// ---------------------------------------------------------------------------
// Bucket ops

fn createBucket(ctx: Context, name: []const u8) Result {
    // M12: x-amz-bucket-object-lock-enabled: true on CreateBucket enables
    // Object Lock + auto-enables versioning. AWS-exact: enabling Object
    // Lock after bucket creation requires a separate flow we don't support.
    const lock_enabled = blk: {
        const hv = findHeader(ctx.request.headers, "x-amz-bucket-object-lock-enabled") orelse break :blk false;
        break :blk std.ascii.eqlIgnoreCase(hv, "true");
    };

    // Wave 3 #20: validate <LocationConstraint> in the request body if present.
    // AWS rejects a constraint that doesn't match the endpoint's region with
    // IllegalLocationConstraintException (400). An empty/missing body is
    // historically "us-east-1, no constraint" and always accepted.
    if (extractLocationConstraint(ctx.request.body)) |constraint| {
        if (!std.mem.eql(u8, constraint, ctx.region)) {
            return .{ .err = .illegal_location_constraint };
        }
    }

    ctx.backend.createBucket(.{ .name = name, .object_lock_enabled = lock_enabled }) catch |err| return .{ .err = mapStorageErr(err) };
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

    // Wave 3 #22: 2023 pagination params.
    const prefix = queryValueOpt(ctx.allocator, ctx.request.query, "prefix") catch
        return .{ .err = .invalid_request };
    const region_filter = queryValueOpt(ctx.allocator, ctx.request.query, "bucket-region") catch
        return .{ .err = .invalid_request };
    const cont_token = queryValueOpt(ctx.allocator, ctx.request.query, "continuation-token") catch
        return .{ .err = .invalid_request };
    const max_buckets_raw = queryValueOpt(ctx.allocator, ctx.request.query, "max-buckets") catch
        return .{ .err = .invalid_request };

    // Default 1000, hard cap 10000 per AWS docs.
    var max_buckets: usize = 1000;
    if (max_buckets_raw) |v| {
        max_buckets = std.fmt.parseInt(usize, v, 10) catch return .{ .err = .invalid_request };
        if (max_buckets == 0 or max_buckets > 10000) return .{ .err = .invalid_request };
    }

    // Sort lex-ascending so pagination is deterministic.
    std.mem.sort(storage.Bucket, buckets, {}, struct {
        fn lt(_: void, a: storage.Bucket, b: storage.Bucket) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    // Build a filtered+paginated view.
    var emitted: std.ArrayList(storage.Bucket) = .empty;
    defer emitted.deinit(ctx.allocator);
    var next_token: ?[]const u8 = null;

    for (buckets) |b| {
        if (prefix) |p| if (!std.mem.startsWith(u8, b.name, p)) continue;
        if (region_filter) |r| if (!std.mem.eql(u8, b.region, r)) continue;
        // Skip past the continuation token (token = last-emitted-name; we
        // start with the bucket strictly greater).
        if (cont_token) |t| if (!std.mem.lessThan(u8, t, b.name)) continue;
        if (emitted.items.len >= max_buckets) {
            // We hit the cap; the previous loop iteration's last name is
            // the continuation token for the next page.
            next_token = emitted.items[emitted.items.len - 1].name;
            break;
        }
        emitted.append(ctx.allocator, b) catch return .{ .err = .internal_error };
    }

    const body = s3_responses.renderListAllMyBucketsResult(ctx.allocator, .{
        .owner_id = ctx.owner_id,
        .display_name = ctx.owner_display_name,
        .buckets = emitted.items,
        .prefix = prefix,
        .continuation_token = next_token,
    }) catch return .{ .err = .internal_error };
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
        if (ctx.backend.headObject(ctx.allocator, .{ .bucket = bucket, .key = key })) |meta| {
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

    // M9 inline tagging via `x-amz-tagging` header.
    const inline_tags: []storage.Tag = if (findHeader(ctx.request.headers, "x-amz-tagging")) |hv|
        tagging_parser.parseHeader(ctx.allocator, hv) catch |err| switch (err) {
            tagging_parser.ParseError.InvalidTag => return .{ .err = .invalid_tag },
            tagging_parser.ParseError.OutOfMemory => return .{ .err = .internal_error },
            tagging_parser.ParseError.InvalidBody => return .{ .err = .invalid_request },
        }
    else
        &.{};

    // M10 inline ACL via `x-amz-acl` + `x-amz-grant-*` headers.
    const inline_acl: ?storage.Acl = switch (extractInlineAcl(ctx)) {
        .none => null,
        .ok => |a| a,
        .err => |c| return .{ .err = c },
    };

    // M12 inline Object Lock headers.
    const lock_info: InlineLockInfo = switch (extractInlineLockInfo(ctx)) {
        .ok => |i| i,
        .err => |c| return .{ .err = c },
    };

    const out = ctx.backend.putObject(.{
        .bucket = bucket,
        .key = key,
        .body = ctx.request.body,
        .content_type = content_type,
        .user_metadata = meta_list.items,
        .tags = inline_tags,
        .acl = inline_acl,
        .retention_mode = lock_info.mode,
        .retain_until_unix = lock_info.retain_until_unix,
        .legal_hold = lock_info.legal_hold,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    var hs: std.ArrayList(Header) = .empty;
    defer hs.deinit(ctx.allocator);
    hs.append(ctx.allocator, .{ .name = "ETag", .value = out.etag }) catch return .{ .err = .internal_error };
    if (out.version_id.len > 0) {
        hs.append(ctx.allocator, .{ .name = "x-amz-version-id", .value = out.version_id }) catch return .{ .err = .internal_error };
    }
    const headers = hs.toOwnedSlice(ctx.allocator) catch return .{ .err = .internal_error };
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
    const source_obj = ctx.backend.getObject(ctx.allocator, .{ .bucket = source_bucket, .key = source_key }) catch |err|
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

    // ---------- Tagging directive ----------
    // x-amz-tagging-directive: COPY (default) | REPLACE. COPY: carry source
    // tags. REPLACE: take tags from request `x-amz-tagging` header (or empty).
    const tagging_directive_raw = findHeader(ctx.request.headers, "x-amz-tagging-directive") orelse "COPY";
    const tagging_replace: bool = if (std.mem.eql(u8, tagging_directive_raw, "COPY"))
        false
    else if (std.mem.eql(u8, tagging_directive_raw, "REPLACE"))
        true
    else
        return .{ .err = .invalid_argument };

    const dest_tags: []const storage.Tag = if (tagging_replace) blk: {
        if (findHeader(ctx.request.headers, "x-amz-tagging")) |hv| {
            break :blk tagging_parser.parseHeader(ctx.allocator, hv) catch |err| switch (err) {
                tagging_parser.ParseError.InvalidTag => return .{ .err = .invalid_tag },
                tagging_parser.ParseError.OutOfMemory => return .{ .err = .internal_error },
                tagging_parser.ParseError.InvalidBody => return .{ .err = .invalid_request },
            };
        }
        break :blk &.{};
    } else source_obj.meta.tags;

    // ---------- ACL ----------
    // M10. CopyObject: if `x-amz-acl` or `x-amz-grant-*` headers are
    // present, they take effect on the destination. Otherwise the dest
    // gets the source's ACL (which itself may be null → default).
    const dest_acl: ?storage.Acl = switch (extractInlineAcl(ctx)) {
        .none => source_obj.meta.acl,
        .ok => |a| a,
        .err => |c| return .{ .err = c },
    };

    // ---------- Object Lock ----------
    // M12: AWS-exact — CopyObject does NOT inherit source retention.
    // Lock state comes from the request headers (or bucket default).
    const lock_info: InlineLockInfo = switch (extractInlineLockInfo(ctx)) {
        .ok => |i| i,
        .err => |c| return .{ .err = c },
    };

    // ---------- Write destination ----------
    const put_out = ctx.backend.putObject(.{
        .bucket = dest_bucket,
        .key = dest_key,
        .body = source_obj.body,
        .content_type = dest_content_type,
        .user_metadata = dest_metadata,
        .tags = dest_tags,
        .acl = dest_acl,
        .retention_mode = lock_info.mode,
        .retain_until_unix = lock_info.retain_until_unix,
        .legal_hold = lock_info.legal_hold,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    // ---------- Render response ----------
    // Fetch the destination's stored last_modified_unix for the response.
    const dest_meta = ctx.backend.headObject(ctx.allocator, .{ .bucket = dest_bucket, .key = dest_key }) catch |err|
        return .{ .err = mapStorageErr(err) };
    const body = object_responses.renderCopyObjectResult(ctx.allocator, put_out.etag, dest_meta.last_modified_unix) catch
        return .{ .err = .internal_error };

    // Versioning-aware response headers: x-amz-version-id for destination,
    // x-amz-copy-source-version-id for the source's version (M8).
    var hs: std.ArrayList(Header) = .empty;
    defer hs.deinit(ctx.allocator);
    if (put_out.version_id.len > 0) {
        hs.append(ctx.allocator, .{ .name = "x-amz-version-id", .value = put_out.version_id }) catch return .{ .err = .internal_error };
    }
    if (source_obj.meta.version_id.len > 0) {
        hs.append(ctx.allocator, .{ .name = "x-amz-copy-source-version-id", .value = source_obj.meta.version_id }) catch return .{ .err = .internal_error };
    }
    const extras = hs.toOwnedSlice(ctx.allocator) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body, .extra_headers = extras } };
}

const MetadataDirective = enum { copy, replace };


fn getObject(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const version_id = queryValue(ctx.allocator, ctx.request.query, "versionId") catch return .{ .err = .internal_error };
    const got = ctx.backend.getObject(ctx.allocator, .{ .bucket = bucket, .key = key, .version_id = version_id }) catch |err|
        return .{ .err = mapStorageErr(err) };

    // Delete-marker on the current version → 404 with marker headers.
    if (got.meta.is_delete_marker) {
        const extra = ctx.allocator.dupe(Header, &.{
            .{ .name = "x-amz-delete-marker", .value = "true" },
            .{ .name = "x-amz-version-id", .value = got.meta.version_id },
        }) catch return .{ .err = .internal_error };
        return .{ .err_with_headers = .{ .code = .no_such_key, .extra_headers = extra } };
    }

    switch (preconditions.forRead(ctx.request.headers, .{
        .etag = got.meta.etag,
        .last_modified_unix = got.meta.last_modified_unix,
        .exists = true,
    })) {
        .ok => {},
        .precondition_failed => return .{ .err = .precondition_failed },
        .not_modified => {
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

    const headers = buildObjectHeadersWithVersion(ctx, got.meta, range_header) catch return .{ .err = .internal_error };
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
    const version_id = queryValue(ctx.allocator, ctx.request.query, "versionId") catch return .{ .err = .internal_error };
    const meta = ctx.backend.headObject(ctx.allocator, .{ .bucket = bucket, .key = key, .version_id = version_id }) catch |err|
        return .{ .err = mapStorageErr(err) };

    if (meta.is_delete_marker) {
        // AWS-exact: HEAD on a delete marker → 405 Method Not Allowed +
        // `Allow: DELETE` + delete-marker / version-id headers. GET takes
        // the analogous-but-distinct path further up (404 NoSuchKey + same
        // marker headers). Drift table row 3.
        const extra = ctx.allocator.dupe(Header, &.{
            .{ .name = "Allow", .value = "DELETE" },
            .{ .name = "x-amz-delete-marker", .value = "true" },
            .{ .name = "x-amz-version-id", .value = meta.version_id },
        }) catch return .{ .err = .internal_error };
        return .{ .err_with_headers = .{ .code = .method_not_allowed, .extra_headers = extra } };
    }

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

    const headers = buildHeadHeadersWithVersion(ctx, meta) catch return .{ .err = .internal_error };
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
    const version_id = queryValue(ctx.allocator, ctx.request.query, "versionId") catch return .{ .err = .internal_error };
    const bypass_governance = blk: {
        const hv = findHeader(ctx.request.headers, "x-amz-bypass-governance-retention") orelse break :blk false;
        break :blk std.ascii.eqlIgnoreCase(hv, "true");
    };
    const out = ctx.backend.deleteObject(.{ .bucket = bucket, .key = key, .version_id = version_id, .bypass_governance = bypass_governance }) catch |err|
        return .{ .err = mapStorageErr(err) };

    // On a versioned bucket the response carries `x-amz-version-id` and
    // (when applicable) `x-amz-delete-marker: true`.
    var hs: std.ArrayList(Header) = .empty;
    defer hs.deinit(ctx.allocator);
    if (out.version_id.len > 0) {
        hs.append(ctx.allocator, .{ .name = "x-amz-version-id", .value = out.version_id }) catch return .{ .err = .internal_error };
    }
    if (out.delete_marker) {
        hs.append(ctx.allocator, .{ .name = "x-amz-delete-marker", .value = "true" }) catch return .{ .err = .internal_error };
    }
    const extras = hs.toOwnedSlice(ctx.allocator) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 204, .body = "", .extra_headers = extras } };
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

    const bypass_governance = blk: {
        const hv = findHeader(ctx.request.headers, "x-amz-bypass-governance-retention") orelse break :blk false;
        break :blk std.ascii.eqlIgnoreCase(hv, "true");
    };
    for (parsed_body.objects) |entry| {
        const out = ctx.backend.deleteObject(.{
            .bucket = bucket,
            .key = entry.key,
            .version_id = entry.version_id,
            .bypass_governance = bypass_governance,
        }) catch |err| {
            const code: errors.Code = mapStorageErr(err);
            errs.append(ctx.allocator, .{
                .key = entry.key,
                .code = code.awsCode(),
                .message = code.defaultMessage(),
            }) catch return .{ .err = .internal_error };
            continue;
        };
        // AWS-exact response shape:
        //  - request set VersionId → echo it back via <VersionId>.
        //  - delete created a delete marker (no VersionId in request, versioned bucket)
        //    → <DeleteMarker>true</DeleteMarker> + <DeleteMarkerVersionId>...</DeleteMarkerVersionId>.
        var entry_result: storage.DeletedKey = .{ .key = entry.key };
        if (entry.version_id) |v| entry_result.version_id = v;
        if (out.delete_marker) {
            entry_result.delete_marker = true;
            if (out.version_id.len > 0) entry_result.delete_marker_version_id = out.version_id;
        }
        deleted.append(ctx.allocator, entry_result) catch return .{ .err = .internal_error };
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

/// Extract the inner text of `<LocationConstraint>...</LocationConstraint>`
/// from a CreateBucket request body. Returns null if absent or empty.
/// Substring-scan rather than XML parse — the body is tiny (≤200 bytes
/// in practice) and the shape is rigidly fixed by the AWS SDK.
fn extractLocationConstraint(body: []const u8) ?[]const u8 {
    const open = "<LocationConstraint>";
    const close = "</LocationConstraint>";
    const start = std.mem.indexOf(u8, body, open) orelse return null;
    const after_open = start + open.len;
    const end = std.mem.indexOfPos(u8, body, after_open, close) orelse return null;
    const value = body[after_open..end];
    return if (value.len == 0) null else value;
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

/// M13: emit x-amz-restore (when restore state set) + SSE response headers.
fn appendRestoreAndSseHeaders(ctx: Context, hs: *std.ArrayList(Header), meta: storage.Object) !void {
    if (meta.restore_in_progress) {
        const expiry = try object_retention_wire.formatIsoUnix(ctx.allocator, meta.restore_expiry_unix);
        const val = try std.fmt.allocPrint(ctx.allocator, "ongoing-request=\"false\", expiry-date=\"{s}\"", .{expiry});
        try hs.append(ctx.allocator, .{ .name = "x-amz-restore", .value = val });
    }
    if (meta.sse_algorithm) |a| {
        try hs.append(ctx.allocator, .{ .name = "x-amz-server-side-encryption", .value = storage.sseAlgorithmToString(a) });
        if (meta.sse_kms_key_id.len > 0) {
            try hs.append(ctx.allocator, .{ .name = "x-amz-server-side-encryption-aws-kms-key-id", .value = meta.sse_kms_key_id });
        }
    }
}

fn appendLockHeaders(ctx: Context, hs: *std.ArrayList(Header), meta: storage.Object) !void {
    if (meta.retention_mode) |m| {
        try hs.append(ctx.allocator, .{ .name = "x-amz-object-lock-mode", .value = storage.retentionModeToString(m) });
        const date_str = try object_retention_wire.formatIsoUnix(ctx.allocator, meta.retain_until_unix);
        try hs.append(ctx.allocator, .{ .name = "x-amz-object-lock-retain-until-date", .value = date_str });
    }
    // AWS-exact: always emit legal-hold header (ON or OFF) when Object Lock
    // headers appear. We emit it any time the object has any lock state.
    if (meta.retention_mode != null or meta.legal_hold) {
        try hs.append(ctx.allocator, .{
            .name = "x-amz-object-lock-legal-hold",
            .value = if (meta.legal_hold) "ON" else "OFF",
        });
    }
}

fn buildObjectHeadersWithVersion(ctx: Context, meta: storage.Object, range_header: ?[]const u8) ![]Header {
    const base = try buildObjectHeaders(ctx, meta, range_header);
    var hs: std.ArrayList(Header) = .empty;
    errdefer hs.deinit(ctx.allocator);
    try hs.appendSlice(ctx.allocator, base);
    ctx.allocator.free(base);
    if (meta.version_id.len > 0) {
        try hs.append(ctx.allocator, .{ .name = "x-amz-version-id", .value = meta.version_id });
    }
    if (meta.tags.len > 0) {
        const count_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{meta.tags.len});
        try hs.append(ctx.allocator, .{ .name = "x-amz-tagging-count", .value = count_str });
    }
    try appendLockHeaders(ctx, &hs, meta);
    try appendRestoreAndSseHeaders(ctx, &hs, meta);
    return hs.toOwnedSlice(ctx.allocator);
}

fn buildHeadHeadersWithVersion(ctx: Context, meta: storage.Object) ![]Header {
    const base = try buildHeadHeaders(ctx, meta);
    var hs: std.ArrayList(Header) = .empty;
    errdefer hs.deinit(ctx.allocator);
    try hs.appendSlice(ctx.allocator, base);
    ctx.allocator.free(base);
    if (meta.version_id.len > 0) {
        try hs.append(ctx.allocator, .{ .name = "x-amz-version-id", .value = meta.version_id });
    }
    if (meta.tags.len > 0) {
        const count_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{meta.tags.len});
        try hs.append(ctx.allocator, .{ .name = "x-amz-tagging-count", .value = count_str });
    }
    try appendLockHeaders(ctx, &hs, meta);
    try appendRestoreAndSseHeaders(ctx, &hs, meta);
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
