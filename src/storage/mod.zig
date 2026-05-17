//! Storage backend interface.
//!
//! `fs.zig` is the only implementation; the vtable is retained because
//! it's a sound abstraction boundary for the future. Persistence is
//! controlled by `--data-dir`; pass a temporary directory for a
//! wipe-clean run.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    NoSuchBucket,
    NoSuchKey,
    NoSuchUpload,
    InvalidPart,
    NoSuchTagSet,
    NoSuchBucketPolicy,
    OwnershipControlsNotFound,
    NoSuchPublicAccessBlockConfiguration,
    AccessControlListNotSupported,
    NoSuchCorsConfiguration,
    ServerSideEncryptionConfigurationNotFound,
    NoSuchLifecycleConfiguration,
    NoSuchWebsiteConfiguration,
    ObjectLockConfigurationNotFound,
    InvalidBucketState,
    InvalidRetentionPeriod,
    AccessDenied,
    ReplicationConfigurationNotFound,
    BucketAlreadyExists,
    BucketAlreadyOwnedByYou,
    BucketNotEmpty,
    InvalidBucketName,
    InvalidObjectKey,
    InvalidTag,
    // DynamoDB (M15).
    TableAlreadyExists,
    TableNotFound,
    ConditionalCheckFailed,
    TransactionCanceled,
    Io,
    OutOfMemory,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// One tag (M9). Key + value owned by the caller's allocator (or
/// borrowed; the call site documents which).
pub const Tag = struct {
    key: []const u8,
    value: []const u8,
};

const max_tags = 10;
const max_tag_key_len = 128;
const max_tag_value_len = 256;

/// Validate a TagSet per the AWS S3 rules:
///   - at most 10 tags
///   - key length 1..=128, value length 0..=256
///   - keys + values use the AWS character set: letters, digits, space,
///     and `+`, `-`, `=`, `.`, `_`, `:`, `/`, `@`
///   - no duplicate keys
///   - no `aws:` prefix on keys (case-insensitive)
pub fn validateTagSet(tags: []const Tag) Error!void {
    if (tags.len > max_tags) return Error.InvalidTag;
    for (tags, 0..) |t, i| {
        if (t.key.len == 0 or t.key.len > max_tag_key_len) return Error.InvalidTag;
        if (t.value.len > max_tag_value_len) return Error.InvalidTag;
        if (!validTagChars(t.key)) return Error.InvalidTag;
        if (!validTagChars(t.value)) return Error.InvalidTag;
        if (hasAwsPrefix(t.key)) return Error.InvalidTag;
        // Duplicate key check — quadratic but n ≤ 10.
        var j: usize = 0;
        while (j < i) : (j += 1) {
            if (std.mem.eql(u8, tags[j].key, t.key)) return Error.InvalidTag;
        }
    }
}

fn validTagChars(s: []const u8) bool {
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', ' ', '+', '-', '=', '.', '_', ':', '/', '@' => {},
        else => return false,
    };
    return true;
}

fn hasAwsPrefix(s: []const u8) bool {
    if (s.len < 4) return false;
    return std.ascii.eqlIgnoreCase(s[0..4], "aws:");
}

// ---------------------------------------------------------------------------
// ACLs + bucket policies + ownership + public access block (M10).
//
// nanostack does NOT enforce ACLs or policies on requests. M10 is
// accept-store-roundtrip: parse, persist, and surface on Get. Documented
// divergence in docs/SUPPORT.md.

pub const CannedAcl = enum {
    private,
    public_read,
    public_read_write,
    authenticated_read,
    log_delivery_write,
    bucket_owner_read,
    bucket_owner_full_control,
    aws_exec_read,
};

pub const Permission = enum {
    FULL_CONTROL,
    WRITE,
    WRITE_ACP,
    READ,
    READ_ACP,
};

pub const GranteeKind = enum {
    canonical_user,
    group,
    amazon_customer_by_email,
};

/// AWS Grantee. Exactly one of (id+display_name) / uri / email_address is
/// meaningful per `kind`. Strings owned per call-site contract.
pub const Grantee = struct {
    kind: GranteeKind,
    id: []const u8 = "",
    display_name: []const u8 = "",
    uri: []const u8 = "",
    email_address: []const u8 = "",
};

pub const Grant = struct {
    grantee: Grantee,
    permission: Permission,
};

pub const Owner = struct {
    id: []const u8,
    display_name: []const u8 = "",
};

pub const Acl = struct {
    owner: Owner,
    grants: []const Grant = &.{},
};

pub const OwnershipControl = enum {
    BucketOwnerEnforced,
    BucketOwnerPreferred,
    ObjectWriter,
};

pub const PublicAccessBlockConfig = struct {
    block_public_acls: bool = false,
    ignore_public_acls: bool = false,
    block_public_policy: bool = false,
    restrict_public_buckets: bool = false,
};

/// The synthesized Owner we return for every bucket/object the client
/// never explicitly assigned a different owner to. AWS uses 64-hex-char
/// canonical IDs; ours is stable and distinct from anything AWS would
/// emit so it round-trips deterministically.
pub const default_owner_id = "0000000000000000000000000000000000000000000000000000000000000000";
pub const default_owner_display_name = "nanostack";

/// AWS predefined-group URIs used in canned ACL expansion + grant
/// header parsing.
pub const group_all_users = "http://acs.amazonaws.com/groups/global/AllUsers";
pub const group_authenticated_users = "http://acs.amazonaws.com/groups/global/AuthenticatedUsers";
pub const group_log_delivery = "http://acs.amazonaws.com/groups/s3/LogDelivery";

/// Parse a canned ACL header value. Returns the enum or an error so the
/// caller can map to 400 InvalidArgument.
pub fn parseCannedAcl(value: []const u8) error{UnknownCannedAcl}!CannedAcl {
    const map = .{
        .{ "private", CannedAcl.private },
        .{ "public-read", CannedAcl.public_read },
        .{ "public-read-write", CannedAcl.public_read_write },
        .{ "authenticated-read", CannedAcl.authenticated_read },
        .{ "log-delivery-write", CannedAcl.log_delivery_write },
        .{ "bucket-owner-read", CannedAcl.bucket_owner_read },
        .{ "bucket-owner-full-control", CannedAcl.bucket_owner_full_control },
        .{ "aws-exec-read", CannedAcl.aws_exec_read },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, value, entry[0])) return entry[1];
    }
    return error.UnknownCannedAcl;
}

/// Permission XML literal.
pub fn permissionToXml(p: Permission) []const u8 {
    return @tagName(p);
}

pub fn permissionFromXml(s: []const u8) error{InvalidPermission}!Permission {
    inline for (@typeInfo(Permission).@"enum".fields) |f| {
        if (std.mem.eql(u8, s, f.name)) return @field(Permission, f.name);
    }
    return error.InvalidPermission;
}

pub fn ownershipControlFromString(s: []const u8) error{InvalidOwnershipControl}!OwnershipControl {
    inline for (@typeInfo(OwnershipControl).@"enum".fields) |f| {
        if (std.mem.eql(u8, s, f.name)) return @field(OwnershipControl, f.name);
    }
    return error.InvalidOwnershipControl;
}

pub fn ownershipControlToString(oc: OwnershipControl) []const u8 {
    return @tagName(oc);
}

// ---------------------------------------------------------------------------
// Bucket configurations (M11). Accept-store-roundtrip. No enforcement.

// ----- CORS -----

pub const HttpMethod = enum { GET, PUT, POST, DELETE, HEAD };

pub fn httpMethodFromString(s: []const u8) error{InvalidHttpMethod}!HttpMethod {
    inline for (@typeInfo(HttpMethod).@"enum".fields) |f| {
        if (std.mem.eql(u8, s, f.name)) return @field(HttpMethod, f.name);
    }
    return error.InvalidHttpMethod;
}

pub fn httpMethodToString(m: HttpMethod) []const u8 {
    return @tagName(m);
}

pub const CorsRule = struct {
    id: []const u8 = "",
    allowed_methods: []const HttpMethod,
    allowed_origins: []const []const u8,
    allowed_headers: []const []const u8 = &.{},
    expose_headers: []const []const u8 = &.{},
    max_age_seconds: ?u32 = null,
};

pub const CorsConfig = struct {
    rules: []const CorsRule,
};

// ----- Encryption -----

pub const SseAlgorithm = enum {
    @"AES256",
    @"aws:kms",
    @"aws:kms:dsse",
};

pub fn sseAlgorithmFromString(s: []const u8) error{InvalidSseAlgorithm}!SseAlgorithm {
    if (std.mem.eql(u8, s, "AES256")) return .@"AES256";
    if (std.mem.eql(u8, s, "aws:kms")) return .@"aws:kms";
    if (std.mem.eql(u8, s, "aws:kms:dsse")) return .@"aws:kms:dsse";
    return error.InvalidSseAlgorithm;
}

pub fn sseAlgorithmToString(a: SseAlgorithm) []const u8 {
    return switch (a) {
        .@"AES256" => "AES256",
        .@"aws:kms" => "aws:kms",
        .@"aws:kms:dsse" => "aws:kms:dsse",
    };
}

pub const SseByDefault = struct {
    sse_algorithm: SseAlgorithm,
    kms_master_key_id: []const u8 = "",
};

pub const EncryptionRule = struct {
    apply: ?SseByDefault = null,
    bucket_key_enabled: ?bool = null,
};

pub const EncryptionConfig = struct {
    rules: []const EncryptionRule,
};

// ----- Lifecycle -----

pub const LifecycleStatus = enum { Enabled, Disabled };

pub fn lifecycleStatusFromString(s: []const u8) error{InvalidLifecycleStatus}!LifecycleStatus {
    inline for (@typeInfo(LifecycleStatus).@"enum".fields) |f| {
        if (std.mem.eql(u8, s, f.name)) return @field(LifecycleStatus, f.name);
    }
    return error.InvalidLifecycleStatus;
}

pub const StorageClass = enum {
    STANDARD,
    STANDARD_IA,
    ONEZONE_IA,
    INTELLIGENT_TIERING,
    GLACIER,
    DEEP_ARCHIVE,
    GLACIER_IR,
    REDUCED_REDUNDANCY,
};

pub fn storageClassFromString(s: []const u8) error{InvalidStorageClass}!StorageClass {
    inline for (@typeInfo(StorageClass).@"enum".fields) |f| {
        if (std.mem.eql(u8, s, f.name)) return @field(StorageClass, f.name);
    }
    return error.InvalidStorageClass;
}

pub const Transition = struct {
    days: ?u32 = null,
    date_iso8601: []const u8 = "",
    storage_class: StorageClass,
};

pub const Expiration = struct {
    days: ?u32 = null,
    date_iso8601: []const u8 = "",
    expired_object_delete_marker: ?bool = null,
};

pub const LifecycleFilter = struct {
    prefix: []const u8 = "",
    tag: ?Tag = null,
    object_size_greater_than: ?u64 = null,
    object_size_less_than: ?u64 = null,
};

pub const LifecycleRule = struct {
    id: []const u8 = "",
    status: LifecycleStatus,
    filter: ?LifecycleFilter = null,
    /// Legacy v1 form (pre-Filter).
    prefix: []const u8 = "",
    transitions: []const Transition = &.{},
    expiration: ?Expiration = null,
    noncurrent_version_transitions: []const Transition = &.{},
    noncurrent_version_expiration: ?Expiration = null,
    abort_incomplete_multipart_upload_days: ?u32 = null,
};

pub const LifecycleConfig = struct {
    rules: []const LifecycleRule,
};

// ----- Notifications -----

pub const S3EventName = enum {
    s3_ObjectCreated_All,
    s3_ObjectCreated_Put,
    s3_ObjectCreated_Post,
    s3_ObjectCreated_Copy,
    s3_ObjectCreated_CompleteMultipartUpload,
    s3_ObjectRemoved_All,
    s3_ObjectRemoved_Delete,
    s3_ObjectRemoved_DeleteMarkerCreated,
    s3_ObjectRestore_All,
    s3_ObjectRestore_Post,
    s3_ObjectRestore_Completed,
    s3_ReducedRedundancyLostObject,
    s3_Replication_All,
    s3_LifecycleExpiration_All,
    s3_LifecycleTransition,
    s3_IntelligentTiering,
    s3_ObjectTagging_All,
    s3_ObjectAcl_Put,
};

/// Translate the over-the-wire event name (`s3:ObjectCreated:Put`) to the
/// enum (which can't use `:` in identifiers, so we use `_`).
pub fn s3EventFromString(s: []const u8) error{InvalidS3Event}!S3EventName {
    const map = .{
        .{ "s3:ObjectCreated:*", S3EventName.s3_ObjectCreated_All },
        .{ "s3:ObjectCreated:Put", S3EventName.s3_ObjectCreated_Put },
        .{ "s3:ObjectCreated:Post", S3EventName.s3_ObjectCreated_Post },
        .{ "s3:ObjectCreated:Copy", S3EventName.s3_ObjectCreated_Copy },
        .{ "s3:ObjectCreated:CompleteMultipartUpload", S3EventName.s3_ObjectCreated_CompleteMultipartUpload },
        .{ "s3:ObjectRemoved:*", S3EventName.s3_ObjectRemoved_All },
        .{ "s3:ObjectRemoved:Delete", S3EventName.s3_ObjectRemoved_Delete },
        .{ "s3:ObjectRemoved:DeleteMarkerCreated", S3EventName.s3_ObjectRemoved_DeleteMarkerCreated },
        .{ "s3:ObjectRestore:*", S3EventName.s3_ObjectRestore_All },
        .{ "s3:ObjectRestore:Post", S3EventName.s3_ObjectRestore_Post },
        .{ "s3:ObjectRestore:Completed", S3EventName.s3_ObjectRestore_Completed },
        .{ "s3:ReducedRedundancyLostObject", S3EventName.s3_ReducedRedundancyLostObject },
        .{ "s3:Replication:*", S3EventName.s3_Replication_All },
        .{ "s3:LifecycleExpiration:*", S3EventName.s3_LifecycleExpiration_All },
        .{ "s3:LifecycleTransition", S3EventName.s3_LifecycleTransition },
        .{ "s3:IntelligentTiering", S3EventName.s3_IntelligentTiering },
        .{ "s3:ObjectTagging:*", S3EventName.s3_ObjectTagging_All },
        .{ "s3:ObjectAcl:Put", S3EventName.s3_ObjectAcl_Put },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, s, entry[0])) return entry[1];
    }
    return error.InvalidS3Event;
}

pub fn s3EventToString(e: S3EventName) []const u8 {
    return switch (e) {
        .s3_ObjectCreated_All => "s3:ObjectCreated:*",
        .s3_ObjectCreated_Put => "s3:ObjectCreated:Put",
        .s3_ObjectCreated_Post => "s3:ObjectCreated:Post",
        .s3_ObjectCreated_Copy => "s3:ObjectCreated:Copy",
        .s3_ObjectCreated_CompleteMultipartUpload => "s3:ObjectCreated:CompleteMultipartUpload",
        .s3_ObjectRemoved_All => "s3:ObjectRemoved:*",
        .s3_ObjectRemoved_Delete => "s3:ObjectRemoved:Delete",
        .s3_ObjectRemoved_DeleteMarkerCreated => "s3:ObjectRemoved:DeleteMarkerCreated",
        .s3_ObjectRestore_All => "s3:ObjectRestore:*",
        .s3_ObjectRestore_Post => "s3:ObjectRestore:Post",
        .s3_ObjectRestore_Completed => "s3:ObjectRestore:Completed",
        .s3_ReducedRedundancyLostObject => "s3:ReducedRedundancyLostObject",
        .s3_Replication_All => "s3:Replication:*",
        .s3_LifecycleExpiration_All => "s3:LifecycleExpiration:*",
        .s3_LifecycleTransition => "s3:LifecycleTransition",
        .s3_IntelligentTiering => "s3:IntelligentTiering",
        .s3_ObjectTagging_All => "s3:ObjectTagging:*",
        .s3_ObjectAcl_Put => "s3:ObjectAcl:Put",
    };
}

pub const NotificationFilterRule = struct {
    /// "prefix" or "suffix" (case-sensitive per AWS).
    name: []const u8,
    value: []const u8,
};

pub const NotificationFilter = struct {
    filter_rules: []const NotificationFilterRule,
};

pub const NotificationTarget = enum { topic, queue, lambda };

pub const NotificationConfigEntry = struct {
    target: NotificationTarget,
    id: []const u8 = "",
    arn: []const u8,
    events: []const S3EventName,
    filter: ?NotificationFilter = null,
};

pub const NotificationConfig = struct {
    entries: []const NotificationConfigEntry,
};

// ----- Website -----

pub const Protocol = enum { http, https };

pub fn protocolFromString(s: []const u8) error{InvalidProtocol}!Protocol {
    if (std.mem.eql(u8, s, "http")) return .http;
    if (std.mem.eql(u8, s, "https")) return .https;
    return error.InvalidProtocol;
}

pub fn protocolToString(p: Protocol) []const u8 {
    return @tagName(p);
}

pub const RedirectAllRequestsTo = struct {
    host_name: []const u8,
    protocol: ?Protocol = null,
};

pub const IndexDocument = struct { suffix: []const u8 };
pub const ErrorDocument = struct { key: []const u8 };

pub const RoutingCondition = struct {
    key_prefix_equals: []const u8 = "",
    http_error_code_returned_equals: []const u8 = "",
};

pub const RoutingRedirect = struct {
    host_name: []const u8 = "",
    http_redirect_code: []const u8 = "",
    protocol: ?Protocol = null,
    replace_key_prefix_with: []const u8 = "",
    replace_key_with: []const u8 = "",
};

pub const RoutingRule = struct {
    condition: ?RoutingCondition = null,
    redirect: RoutingRedirect,
};

pub const WebsiteConfig = struct {
    redirect_all: ?RedirectAllRequestsTo = null,
    index_document: ?IndexDocument = null,
    error_document: ?ErrorDocument = null,
    routing_rules: []const RoutingRule = &.{},
};

// ---------------------------------------------------------------------------
// Object Lock + retention + legal hold (M12). Unlike M10/M11, persisted
// state here actually enforces — deletes are blocked within retention,
// COMPLIANCE mode is immutable, legal hold supersedes everything.

pub const RetentionMode = enum { GOVERNANCE, COMPLIANCE };

pub fn retentionModeFromString(s: []const u8) error{InvalidRetentionMode}!RetentionMode {
    inline for (@typeInfo(RetentionMode).@"enum".fields) |f| {
        if (std.mem.eql(u8, s, f.name)) return @field(RetentionMode, f.name);
    }
    return error.InvalidRetentionMode;
}

pub fn retentionModeToString(m: RetentionMode) []const u8 {
    return @tagName(m);
}

pub const LegalHoldStatus = enum { ON, OFF };

pub fn legalHoldFromString(s: []const u8) error{InvalidLegalHoldStatus}!LegalHoldStatus {
    if (std.mem.eql(u8, s, "ON")) return .ON;
    if (std.mem.eql(u8, s, "OFF")) return .OFF;
    return error.InvalidLegalHoldStatus;
}

pub fn legalHoldToString(s: LegalHoldStatus) []const u8 {
    return @tagName(s);
}

pub const DefaultRetention = struct {
    mode: RetentionMode,
    days: ?u32 = null,
    years: ?u32 = null,
};

pub const ObjectLockRule = struct {
    default_retention: ?DefaultRetention = null,
};

pub const ObjectLockConfig = struct {
    /// AWS-exact: "Enabled" when persisted (we never store a disabled
    /// state). The field exists for XML round-trip clarity.
    object_lock_enabled: bool = true,
    rule: ?ObjectLockRule = null,
};

pub const ObjectRetention = struct {
    mode: RetentionMode,
    /// Unix epoch seconds; 0 = no retention.
    retain_until_unix: i64,
};

// ---------------------------------------------------------------------------
// Bucket replication (M13). Accept-store-roundtrip — no data actually
// crosses to a destination bucket.

pub const ReplicationStatus = enum { Enabled, Disabled };

pub fn replicationStatusFromString(s: []const u8) error{InvalidReplicationStatus}!ReplicationStatus {
    inline for (@typeInfo(ReplicationStatus).@"enum".fields) |f| {
        if (std.mem.eql(u8, s, f.name)) return @field(ReplicationStatus, f.name);
    }
    return error.InvalidReplicationStatus;
}

pub const ReplicationDestination = struct {
    /// ARN of the destination bucket (e.g. `arn:aws:s3:::dest-bucket`).
    bucket: []const u8,
    /// Optional storage class for replicated objects.
    storage_class: []const u8 = "",
};

pub const ReplicationRule = struct {
    id: []const u8 = "",
    status: ReplicationStatus,
    /// Legacy prefix filter (AWS V1 form).
    prefix: []const u8 = "",
    destination: ReplicationDestination,
};

pub const ReplicationConfig = struct {
    /// IAM role ARN used to perform replication.
    role: []const u8,
    rules: []const ReplicationRule,
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

/// Bucket versioning state (M8). `none` = never enabled; once flipped to
/// `enabled` AWS forbids returning to `none` (only `suspended`).
pub const VersioningStatus = enum { none, enabled, suspended };

/// RestoreObject result — surfaces the AWS 200-vs-202 distinction.
/// `initiated`: a fresh restore request was accepted → 202 Accepted.
/// `already_in_progress`: an earlier RestoreObject already initiated
///   a restore on this object → 200 OK (idempotent).
pub const RestoreOutcome = enum { initiated, already_in_progress };

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
    /// Empty when the bucket is in `none` versioning state; the literal
    /// string `"null"` for objects written under Suspended versioning or
    /// migrated from unversioned storage; otherwise a generated id.
    version_id: []const u8 = "",
    /// True when this entry is a delete marker (no data, no etag, no
    /// content_type). Backends carry this through so the service layer can
    /// surface `x-amz-delete-marker: true` headers.
    is_delete_marker: bool = false,
    /// M9. Per-object (per-version on versioned buckets) tag set.
    tags: []const Tag = &.{},
    /// M10. Per-object (per-version on versioned buckets) ACL. `null`
    /// means "synthesize the default private Owner FULL_CONTROL Acl on
    /// Get". An explicit Acl from canned/grant headers / PutObjectAcl
    /// gets persisted as-given.
    acl: ?Acl = null,
    /// M12. Per-version Object Lock state.
    retention_mode: ?RetentionMode = null,
    retain_until_unix: i64 = 0,
    legal_hold: bool = false,
    /// M13. Restore-from-Glacier state. `restore_in_progress` flips to
    /// true on POST `?restore`; `restore_expiry_unix` is computed from
    /// `now + Days*86400`. No actual data movement.
    restore_in_progress: bool = false,
    restore_expiry_unix: i64 = 0,
    /// M13. Per-object SSE algorithm + KMS key id (set via
    /// `UpdateObjectEncryption`). No actual cipher work.
    sse_algorithm: ?SseAlgorithm = null,
    sse_kms_key_id: []const u8 = "",
};

pub const PutObjectInput = struct {
    bucket: []const u8,
    key: []const u8,
    body: []const u8,
    content_type: []const u8,
    user_metadata: []const Header = &.{},
    /// M9. Inline tagging from the `x-amz-tagging` header.
    tags: []const Tag = &.{},
    /// M10. Inline ACL from `x-amz-acl` + `x-amz-grant-*` headers.
    acl: ?Acl = null,
    /// M12. Inline Object Lock headers
    /// (`x-amz-object-lock-{mode,retain-until-date,legal-hold}`).
    /// `null`/0/false means "no explicit lock"; the backend may apply
    /// bucket-default retention if a Rule is set.
    retention_mode: ?RetentionMode = null,
    retain_until_unix: i64 = 0,
    legal_hold: bool = false,
    /// M13. Per-object SSE (typically set via UpdateObjectEncryption,
    /// but also accepted via `x-amz-server-side-encryption[-aws-kms-key-id]`
    /// headers on the write).
    sse_algorithm: ?SseAlgorithm = null,
    sse_kms_key_id: []const u8 = "",
};

pub const PutObjectOutput = struct {
    etag: []const u8,
    /// New version's id on a versioned bucket; empty when versioning is `none`.
    version_id: []const u8 = "",
};

pub const GetObjectInput = struct {
    bucket: []const u8,
    key: []const u8,
    /// When set, read this exact version. When null, resolve to the
    /// current (latest) version.
    version_id: ?[]const u8 = null,
};

pub const HeadObjectInput = struct {
    bucket: []const u8,
    key: []const u8,
    version_id: ?[]const u8 = null,
};

pub const DeleteObjectInput = struct {
    bucket: []const u8,
    key: []const u8,
    /// On a versioned bucket: null creates a delete marker; set
    /// permanently removes that version.
    version_id: ?[]const u8 = null,
    /// M12. `x-amz-bypass-governance-retention: true`. Allows the
    /// backend to delete a GOVERNANCE-protected version. Has no effect
    /// on COMPLIANCE retention or legal hold.
    bypass_governance: bool = false,
};

pub const DeleteObjectOutput = struct {
    /// Version id of the entry that was deleted or of the delete marker
    /// that was created. Empty on unversioned buckets.
    version_id: []const u8 = "",
    /// True when the deleted entry was a delete marker, OR when a new
    /// delete marker was created.
    delete_marker: bool = false,
};

pub const GetObjectOutput = struct {
    meta: Object,
    body: []const u8,
};

pub const DeletedKey = struct {
    key: []const u8,
    /// Echoed back when the request supplied an explicit VersionId.
    version_id: ?[]const u8 = null,
    /// True when the delete created (or removed) a delete marker.
    delete_marker: bool = false,
    /// The version id of the delete marker (if `delete_marker == true`).
    delete_marker_version_id: ?[]const u8 = null,
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

// ---------------------------------------------------------------------------
// Multipart upload (M6)

pub const InitiateMultipartUploadInput = struct {
    bucket: []const u8,
    key: []const u8,
    content_type: []const u8,
    user_metadata: []const Header = &.{},
    /// M9. Tags applied to the final merged object on CompleteMultipartUpload.
    tags: []const Tag = &.{},
    /// M10. ACL applied to the final merged object on CompleteMultipartUpload.
    acl: ?Acl = null,
    /// M12. Object Lock state applied to the final merged object.
    retention_mode: ?RetentionMode = null,
    retain_until_unix: i64 = 0,
    legal_hold: bool = false,
    /// M13. SSE applied to the final merged object.
    sse_algorithm: ?SseAlgorithm = null,
    sse_kms_key_id: []const u8 = "",
    /// Wave 2 (drift #6). Identity captured at CreateMultipartUpload time —
    /// surfaced via `<Initiator>` on the eventual ListMultipartUploads response.
    /// Single-tenant in practice (equals the bucket-owner identity); schema
    /// supports distinction for future multi-tenant work.
    initiator_id: []const u8 = "",
    initiator_display_name: []const u8 = "",
};

/// M12. Input to `createBucket`. The `object_lock_enabled` flag is set
/// at creation time via the `x-amz-bucket-object-lock-enabled` header;
/// AWS does not allow enabling Object Lock after creation in the
/// standard flow.
pub const CreateBucketInput = struct {
    name: []const u8,
    object_lock_enabled: bool = false,
};

pub const InitiateMultipartUploadOutput = struct {
    /// Opaque token. We pick the format; clients must treat it as a blob.
    upload_id: []const u8,
};

pub const UploadPartInput = struct {
    bucket: []const u8,
    key: []const u8,
    upload_id: []const u8,
    /// 1..=10000 per AWS. Service validates the range; backends can assume
    /// they receive a valid number.
    part_number: u32,
    body: []const u8,
};

pub const UploadPartOutput = struct {
    /// Single-part MD5, quoted.
    etag: []const u8,
};

/// One client-provided part entry in a CompleteMultipartUpload body.
pub const CompletePart = struct {
    part_number: u32,
    etag: []const u8, // quoted, as received
};

pub const CompleteMultipartUploadInput = struct {
    bucket: []const u8,
    key: []const u8,
    upload_id: []const u8,
    /// Ordered ascending by part_number; service validates this.
    parts: []const CompletePart,
};

pub const CompleteMultipartUploadOutput = struct {
    /// AWS-style multipart etag: `"<hex>-N"`. Quoted, includes the suffix.
    etag: []const u8,
    /// New version's id on a versioned bucket; empty otherwise.
    version_id: []const u8 = "",
};

/// Metadata for one in-progress multipart upload (returned by
/// ListMultipartUploads).
pub const MultipartUploadInfo = struct {
    key: []const u8,
    upload_id: []const u8,
    initiated_unix: i64,
    /// Wave 2 (drift #6). Captured at CreateMultipartUpload time.
    initiator_id: []const u8 = "",
    initiator_display_name: []const u8 = "",
};

/// Metadata for one uploaded part (returned by ListParts).
pub const PartInfo = struct {
    part_number: u32,
    size: u64,
    etag: []const u8, // quoted
    last_modified_unix: i64,
};

pub const ListMultipartUploadsInput = struct {
    bucket: []const u8,
    prefix: []const u8 = "",
    delimiter: []const u8 = "",
    /// Pagination cursor — return uploads strictly after (key_marker,
    /// upload_id_marker) in the sort order (key asc, upload_id asc).
    key_marker: []const u8 = "",
    upload_id_marker: []const u8 = "",
    max_uploads: u32 = 1000,
};

pub const ListMultipartUploadsOutput = struct {
    uploads: []MultipartUploadInfo,
    common_prefixes: [][]const u8,
    is_truncated: bool,
    /// When truncated, these are the values to send as the next page's
    /// `key-marker` / `upload-id-marker`.
    next_key_marker: []const u8,
    next_upload_id_marker: []const u8,
};

pub const ListPartsInput = struct {
    bucket: []const u8,
    key: []const u8,
    upload_id: []const u8,
    /// Return parts with part_number strictly greater than this.
    part_number_marker: u32 = 0,
    max_parts: u32 = 1000,
};

pub const ListPartsOutput = struct {
    parts: []PartInfo,
    is_truncated: bool,
    next_part_number_marker: u32,
};

// ---------------------------------------------------------------------------
// Versioning (M8)

/// One version entry in `ListObjectVersions` output.
pub const ObjectVersion = struct {
    key: []const u8,
    version_id: []const u8,
    is_latest: bool,
    /// True for delete-marker entries (no data, no etag, no content_type).
    is_delete_marker: bool,
    last_modified_unix: i64,
    /// Empty for delete markers.
    etag: []const u8 = "",
    /// Zero for delete markers.
    size: u64 = 0,
};

pub const ListObjectVersionsInput = struct {
    bucket: []const u8,
    prefix: []const u8 = "",
    delimiter: []const u8 = "",
    /// Pagination cursor — return entries strictly after (key_marker,
    /// version_id_marker) in (key asc, version newest-first within key)
    /// sort order.
    key_marker: []const u8 = "",
    version_id_marker: []const u8 = "",
    max_keys: u32 = 1000,
};

pub const ListObjectVersionsOutput = struct {
    /// Versions + delete markers, intermixed in sort order. Caller
    /// distinguishes via `is_delete_marker`.
    versions: []ObjectVersion,
    common_prefixes: [][]const u8,
    is_truncated: bool,
    next_key_marker: []const u8,
    next_version_id_marker: []const u8,
};

pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Buckets (M1).
        createBucket: *const fn (ctx: *anyopaque, in: CreateBucketInput) Error!void,
        deleteBucket: *const fn (ctx: *anyopaque, name: []const u8) Error!void,
        headBucket: *const fn (ctx: *anyopaque, name: []const u8) Error!void,
        listBuckets: *const fn (ctx: *anyopaque, allocator: Allocator) Error![]Bucket,
        // Objects (M3, extended M8 with version_id).
        putObject: *const fn (ctx: *anyopaque, in: PutObjectInput) Error!PutObjectOutput,
        getObject: *const fn (ctx: *anyopaque, allocator: Allocator, in: GetObjectInput) Error!GetObjectOutput,
        headObject: *const fn (ctx: *anyopaque, allocator: Allocator, in: HeadObjectInput) Error!Object,
        deleteObject: *const fn (ctx: *anyopaque, in: DeleteObjectInput) Error!DeleteObjectOutput,
        // Listing (M4).
        listObjects: *const fn (ctx: *anyopaque, allocator: Allocator, in: ListObjectsInput) Error!ListObjectsOutput,
        // Multipart upload (M6).
        initiateMultipartUpload: *const fn (ctx: *anyopaque, allocator: Allocator, in: InitiateMultipartUploadInput) Error!InitiateMultipartUploadOutput,
        uploadPart: *const fn (ctx: *anyopaque, in: UploadPartInput) Error!UploadPartOutput,
        completeMultipartUpload: *const fn (ctx: *anyopaque, allocator: Allocator, in: CompleteMultipartUploadInput) Error!CompleteMultipartUploadOutput,
        abortMultipartUpload: *const fn (ctx: *anyopaque, bucket: []const u8, key: []const u8, upload_id: []const u8) Error!void,
        listMultipartUploads: *const fn (ctx: *anyopaque, allocator: Allocator, in: ListMultipartUploadsInput) Error!ListMultipartUploadsOutput,
        listParts: *const fn (ctx: *anyopaque, allocator: Allocator, in: ListPartsInput) Error!ListPartsOutput,
        // Versioning (M8).
        getBucketVersioning: *const fn (ctx: *anyopaque, bucket: []const u8) Error!VersioningStatus,
        putBucketVersioning: *const fn (ctx: *anyopaque, bucket: []const u8, status: VersioningStatus) Error!void,
        listObjectVersions: *const fn (ctx: *anyopaque, allocator: Allocator, in: ListObjectVersionsInput) Error!ListObjectVersionsOutput,
        // Tagging (M9). Object-tagging entries take optional version_id
        // (null = current version).
        putBucketTagging: *const fn (ctx: *anyopaque, bucket: []const u8, tags: []const Tag) Error!void,
        getBucketTagging: *const fn (ctx: *anyopaque, allocator: Allocator, bucket: []const u8) Error![]Tag,
        deleteBucketTagging: *const fn (ctx: *anyopaque, bucket: []const u8) Error!void,
        putObjectTagging: *const fn (ctx: *anyopaque, bucket: []const u8, key: []const u8, version_id: ?[]const u8, tags: []const Tag) Error!void,
        getObjectTagging: *const fn (ctx: *anyopaque, allocator: Allocator, bucket: []const u8, key: []const u8, version_id: ?[]const u8) Error![]Tag,
        deleteObjectTagging: *const fn (ctx: *anyopaque, bucket: []const u8, key: []const u8, version_id: ?[]const u8) Error!void,
        // ACLs (M10). Object-ACL entries take optional version_id.
        putBucketAcl: *const fn (ctx: *anyopaque, bucket: []const u8, acl: Acl) Error!void,
        getBucketAcl: *const fn (ctx: *anyopaque, allocator: Allocator, bucket: []const u8) Error!Acl,
        putObjectAcl: *const fn (ctx: *anyopaque, bucket: []const u8, key: []const u8, version_id: ?[]const u8, acl: Acl) Error!void,
        getObjectAcl: *const fn (ctx: *anyopaque, allocator: Allocator, bucket: []const u8, key: []const u8, version_id: ?[]const u8) Error!Acl,
        // Bucket policies (M10). Body is raw JSON bytes — well-formedness
        // checked at the wire layer; storage stores opaque.
        putBucketPolicy: *const fn (ctx: *anyopaque, bucket: []const u8, policy_json: []const u8) Error!void,
        getBucketPolicy: *const fn (ctx: *anyopaque, allocator: Allocator, bucket: []const u8) Error![]u8,
        deleteBucketPolicy: *const fn (ctx: *anyopaque, bucket: []const u8) Error!void,
        // Ownership controls (M10).
        putBucketOwnershipControls: *const fn (ctx: *anyopaque, bucket: []const u8, oc: OwnershipControl) Error!void,
        getBucketOwnershipControls: *const fn (ctx: *anyopaque, bucket: []const u8) Error!OwnershipControl,
        deleteBucketOwnershipControls: *const fn (ctx: *anyopaque, bucket: []const u8) Error!void,
        // Public access block (M10).
        putPublicAccessBlock: *const fn (ctx: *anyopaque, bucket: []const u8, pab: PublicAccessBlockConfig) Error!void,
        getPublicAccessBlock: *const fn (ctx: *anyopaque, bucket: []const u8) Error!PublicAccessBlockConfig,
        deletePublicAccessBlock: *const fn (ctx: *anyopaque, bucket: []const u8) Error!void,
        // CORS (M11).
        putBucketCors: *const fn (ctx: *anyopaque, bucket: []const u8, cfg: CorsConfig) Error!void,
        getBucketCors: *const fn (ctx: *anyopaque, allocator: Allocator, bucket: []const u8) Error!CorsConfig,
        deleteBucketCors: *const fn (ctx: *anyopaque, bucket: []const u8) Error!void,
        // Encryption (M11).
        putBucketEncryption: *const fn (ctx: *anyopaque, bucket: []const u8, cfg: EncryptionConfig) Error!void,
        getBucketEncryption: *const fn (ctx: *anyopaque, allocator: Allocator, bucket: []const u8) Error!EncryptionConfig,
        deleteBucketEncryption: *const fn (ctx: *anyopaque, bucket: []const u8) Error!void,
        // Lifecycle (M11).
        putBucketLifecycle: *const fn (ctx: *anyopaque, bucket: []const u8, cfg: LifecycleConfig) Error!void,
        getBucketLifecycle: *const fn (ctx: *anyopaque, allocator: Allocator, bucket: []const u8) Error!LifecycleConfig,
        deleteBucketLifecycle: *const fn (ctx: *anyopaque, bucket: []const u8) Error!void,
        // Notifications (M11). No Delete — empty Put removes.
        putBucketNotification: *const fn (ctx: *anyopaque, bucket: []const u8, cfg: NotificationConfig) Error!void,
        getBucketNotification: *const fn (ctx: *anyopaque, allocator: Allocator, bucket: []const u8) Error!NotificationConfig,
        // Website (M11).
        putBucketWebsite: *const fn (ctx: *anyopaque, bucket: []const u8, cfg: WebsiteConfig) Error!void,
        getBucketWebsite: *const fn (ctx: *anyopaque, allocator: Allocator, bucket: []const u8) Error!WebsiteConfig,
        deleteBucketWebsite: *const fn (ctx: *anyopaque, bucket: []const u8) Error!void,
        // Object Lock (M12). Object-level entries take optional version_id.
        putObjectLockConfig: *const fn (ctx: *anyopaque, bucket: []const u8, cfg: ObjectLockConfig) Error!void,
        getObjectLockConfig: *const fn (ctx: *anyopaque, allocator: Allocator, bucket: []const u8) Error!ObjectLockConfig,
        putObjectRetention: *const fn (ctx: *anyopaque, bucket: []const u8, key: []const u8, version_id: ?[]const u8, retention: ObjectRetention, bypass_governance: bool) Error!void,
        getObjectRetention: *const fn (ctx: *anyopaque, bucket: []const u8, key: []const u8, version_id: ?[]const u8) Error!ObjectRetention,
        putObjectLegalHold: *const fn (ctx: *anyopaque, bucket: []const u8, key: []const u8, version_id: ?[]const u8, status: LegalHoldStatus) Error!void,
        getObjectLegalHold: *const fn (ctx: *anyopaque, bucket: []const u8, key: []const u8, version_id: ?[]const u8) Error!LegalHoldStatus,
        // M13.
        restoreObject: *const fn (ctx: *anyopaque, bucket: []const u8, key: []const u8, version_id: ?[]const u8, days: u32) Error!RestoreOutcome,
        updateObjectEncryption: *const fn (ctx: *anyopaque, bucket: []const u8, key: []const u8, version_id: ?[]const u8, algorithm: SseAlgorithm, kms_key_id: []const u8) Error!void,
        putBucketReplication: *const fn (ctx: *anyopaque, bucket: []const u8, cfg: ReplicationConfig) Error!void,
        getBucketReplication: *const fn (ctx: *anyopaque, allocator: Allocator, bucket: []const u8) Error!ReplicationConfig,
        deleteBucketReplication: *const fn (ctx: *anyopaque, bucket: []const u8) Error!void,
    };

    // Pass-through helpers so call sites don't dereference the vtable.

    pub fn createBucket(self: Backend, in: CreateBucketInput) Error!void {
        return self.vtable.createBucket(self.ctx, in);
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
    pub fn getObject(self: Backend, allocator: Allocator, in: GetObjectInput) Error!GetObjectOutput {
        return self.vtable.getObject(self.ctx, allocator, in);
    }
    /// Caller owns the returned metadata strings.
    pub fn headObject(self: Backend, allocator: Allocator, in: HeadObjectInput) Error!Object {
        return self.vtable.headObject(self.ctx, allocator, in);
    }
    pub fn deleteObject(self: Backend, in: DeleteObjectInput) Error!DeleteObjectOutput {
        return self.vtable.deleteObject(self.ctx, in);
    }

    /// Caller owns the returned slice plus every nested string. Use the
    /// same allocator passed in to free.
    pub fn listObjects(self: Backend, allocator: Allocator, in: ListObjectsInput) Error!ListObjectsOutput {
        return self.vtable.listObjects(self.ctx, allocator, in);
    }

    pub fn initiateMultipartUpload(self: Backend, allocator: Allocator, in: InitiateMultipartUploadInput) Error!InitiateMultipartUploadOutput {
        return self.vtable.initiateMultipartUpload(self.ctx, allocator, in);
    }
    pub fn uploadPart(self: Backend, in: UploadPartInput) Error!UploadPartOutput {
        return self.vtable.uploadPart(self.ctx, in);
    }
    pub fn completeMultipartUpload(self: Backend, allocator: Allocator, in: CompleteMultipartUploadInput) Error!CompleteMultipartUploadOutput {
        return self.vtable.completeMultipartUpload(self.ctx, allocator, in);
    }
    pub fn abortMultipartUpload(self: Backend, bucket: []const u8, key: []const u8, upload_id: []const u8) Error!void {
        return self.vtable.abortMultipartUpload(self.ctx, bucket, key, upload_id);
    }
    pub fn listMultipartUploads(self: Backend, allocator: Allocator, in: ListMultipartUploadsInput) Error!ListMultipartUploadsOutput {
        return self.vtable.listMultipartUploads(self.ctx, allocator, in);
    }
    pub fn listParts(self: Backend, allocator: Allocator, in: ListPartsInput) Error!ListPartsOutput {
        return self.vtable.listParts(self.ctx, allocator, in);
    }

    pub fn getBucketVersioning(self: Backend, bucket: []const u8) Error!VersioningStatus {
        return self.vtable.getBucketVersioning(self.ctx, bucket);
    }
    pub fn putBucketVersioning(self: Backend, bucket: []const u8, status: VersioningStatus) Error!void {
        return self.vtable.putBucketVersioning(self.ctx, bucket, status);
    }
    pub fn listObjectVersions(self: Backend, allocator: Allocator, in: ListObjectVersionsInput) Error!ListObjectVersionsOutput {
        return self.vtable.listObjectVersions(self.ctx, allocator, in);
    }

    pub fn putBucketTagging(self: Backend, bucket: []const u8, tags: []const Tag) Error!void {
        return self.vtable.putBucketTagging(self.ctx, bucket, tags);
    }
    pub fn getBucketTagging(self: Backend, allocator: Allocator, bucket: []const u8) Error![]Tag {
        return self.vtable.getBucketTagging(self.ctx, allocator, bucket);
    }
    pub fn deleteBucketTagging(self: Backend, bucket: []const u8) Error!void {
        return self.vtable.deleteBucketTagging(self.ctx, bucket);
    }
    pub fn putObjectTagging(self: Backend, bucket: []const u8, key: []const u8, version_id: ?[]const u8, tags: []const Tag) Error!void {
        return self.vtable.putObjectTagging(self.ctx, bucket, key, version_id, tags);
    }
    pub fn getObjectTagging(self: Backend, allocator: Allocator, bucket: []const u8, key: []const u8, version_id: ?[]const u8) Error![]Tag {
        return self.vtable.getObjectTagging(self.ctx, allocator, bucket, key, version_id);
    }
    pub fn deleteObjectTagging(self: Backend, bucket: []const u8, key: []const u8, version_id: ?[]const u8) Error!void {
        return self.vtable.deleteObjectTagging(self.ctx, bucket, key, version_id);
    }

    pub fn putBucketAcl(self: Backend, bucket: []const u8, acl: Acl) Error!void {
        return self.vtable.putBucketAcl(self.ctx, bucket, acl);
    }
    pub fn getBucketAcl(self: Backend, allocator: Allocator, bucket: []const u8) Error!Acl {
        return self.vtable.getBucketAcl(self.ctx, allocator, bucket);
    }
    pub fn putObjectAcl(self: Backend, bucket: []const u8, key: []const u8, version_id: ?[]const u8, acl: Acl) Error!void {
        return self.vtable.putObjectAcl(self.ctx, bucket, key, version_id, acl);
    }
    pub fn getObjectAcl(self: Backend, allocator: Allocator, bucket: []const u8, key: []const u8, version_id: ?[]const u8) Error!Acl {
        return self.vtable.getObjectAcl(self.ctx, allocator, bucket, key, version_id);
    }

    pub fn putBucketPolicy(self: Backend, bucket: []const u8, policy_json: []const u8) Error!void {
        return self.vtable.putBucketPolicy(self.ctx, bucket, policy_json);
    }
    pub fn getBucketPolicy(self: Backend, allocator: Allocator, bucket: []const u8) Error![]u8 {
        return self.vtable.getBucketPolicy(self.ctx, allocator, bucket);
    }
    pub fn deleteBucketPolicy(self: Backend, bucket: []const u8) Error!void {
        return self.vtable.deleteBucketPolicy(self.ctx, bucket);
    }

    pub fn putBucketOwnershipControls(self: Backend, bucket: []const u8, oc: OwnershipControl) Error!void {
        return self.vtable.putBucketOwnershipControls(self.ctx, bucket, oc);
    }
    pub fn getBucketOwnershipControls(self: Backend, bucket: []const u8) Error!OwnershipControl {
        return self.vtable.getBucketOwnershipControls(self.ctx, bucket);
    }
    pub fn deleteBucketOwnershipControls(self: Backend, bucket: []const u8) Error!void {
        return self.vtable.deleteBucketOwnershipControls(self.ctx, bucket);
    }

    pub fn putPublicAccessBlock(self: Backend, bucket: []const u8, pab: PublicAccessBlockConfig) Error!void {
        return self.vtable.putPublicAccessBlock(self.ctx, bucket, pab);
    }
    pub fn getPublicAccessBlock(self: Backend, bucket: []const u8) Error!PublicAccessBlockConfig {
        return self.vtable.getPublicAccessBlock(self.ctx, bucket);
    }
    pub fn deletePublicAccessBlock(self: Backend, bucket: []const u8) Error!void {
        return self.vtable.deletePublicAccessBlock(self.ctx, bucket);
    }

    pub fn putBucketCors(self: Backend, bucket: []const u8, cfg: CorsConfig) Error!void {
        return self.vtable.putBucketCors(self.ctx, bucket, cfg);
    }
    pub fn getBucketCors(self: Backend, allocator: Allocator, bucket: []const u8) Error!CorsConfig {
        return self.vtable.getBucketCors(self.ctx, allocator, bucket);
    }
    pub fn deleteBucketCors(self: Backend, bucket: []const u8) Error!void {
        return self.vtable.deleteBucketCors(self.ctx, bucket);
    }

    pub fn putBucketEncryption(self: Backend, bucket: []const u8, cfg: EncryptionConfig) Error!void {
        return self.vtable.putBucketEncryption(self.ctx, bucket, cfg);
    }
    pub fn getBucketEncryption(self: Backend, allocator: Allocator, bucket: []const u8) Error!EncryptionConfig {
        return self.vtable.getBucketEncryption(self.ctx, allocator, bucket);
    }
    pub fn deleteBucketEncryption(self: Backend, bucket: []const u8) Error!void {
        return self.vtable.deleteBucketEncryption(self.ctx, bucket);
    }

    pub fn putBucketLifecycle(self: Backend, bucket: []const u8, cfg: LifecycleConfig) Error!void {
        return self.vtable.putBucketLifecycle(self.ctx, bucket, cfg);
    }
    pub fn getBucketLifecycle(self: Backend, allocator: Allocator, bucket: []const u8) Error!LifecycleConfig {
        return self.vtable.getBucketLifecycle(self.ctx, allocator, bucket);
    }
    pub fn deleteBucketLifecycle(self: Backend, bucket: []const u8) Error!void {
        return self.vtable.deleteBucketLifecycle(self.ctx, bucket);
    }

    pub fn putBucketNotification(self: Backend, bucket: []const u8, cfg: NotificationConfig) Error!void {
        return self.vtable.putBucketNotification(self.ctx, bucket, cfg);
    }
    pub fn getBucketNotification(self: Backend, allocator: Allocator, bucket: []const u8) Error!NotificationConfig {
        return self.vtable.getBucketNotification(self.ctx, allocator, bucket);
    }

    pub fn putBucketWebsite(self: Backend, bucket: []const u8, cfg: WebsiteConfig) Error!void {
        return self.vtable.putBucketWebsite(self.ctx, bucket, cfg);
    }
    pub fn getBucketWebsite(self: Backend, allocator: Allocator, bucket: []const u8) Error!WebsiteConfig {
        return self.vtable.getBucketWebsite(self.ctx, allocator, bucket);
    }
    pub fn deleteBucketWebsite(self: Backend, bucket: []const u8) Error!void {
        return self.vtable.deleteBucketWebsite(self.ctx, bucket);
    }

    pub fn putObjectLockConfig(self: Backend, bucket: []const u8, cfg: ObjectLockConfig) Error!void {
        return self.vtable.putObjectLockConfig(self.ctx, bucket, cfg);
    }
    pub fn getObjectLockConfig(self: Backend, allocator: Allocator, bucket: []const u8) Error!ObjectLockConfig {
        return self.vtable.getObjectLockConfig(self.ctx, allocator, bucket);
    }
    pub fn putObjectRetention(self: Backend, bucket: []const u8, key: []const u8, version_id: ?[]const u8, retention: ObjectRetention, bypass_governance: bool) Error!void {
        return self.vtable.putObjectRetention(self.ctx, bucket, key, version_id, retention, bypass_governance);
    }
    pub fn getObjectRetention(self: Backend, bucket: []const u8, key: []const u8, version_id: ?[]const u8) Error!ObjectRetention {
        return self.vtable.getObjectRetention(self.ctx, bucket, key, version_id);
    }
    pub fn putObjectLegalHold(self: Backend, bucket: []const u8, key: []const u8, version_id: ?[]const u8, status: LegalHoldStatus) Error!void {
        return self.vtable.putObjectLegalHold(self.ctx, bucket, key, version_id, status);
    }
    pub fn getObjectLegalHold(self: Backend, bucket: []const u8, key: []const u8, version_id: ?[]const u8) Error!LegalHoldStatus {
        return self.vtable.getObjectLegalHold(self.ctx, bucket, key, version_id);
    }

    pub fn restoreObject(self: Backend, bucket: []const u8, key: []const u8, version_id: ?[]const u8, days: u32) Error!RestoreOutcome {
        return self.vtable.restoreObject(self.ctx, bucket, key, version_id, days);
    }
    pub fn updateObjectEncryption(self: Backend, bucket: []const u8, key: []const u8, version_id: ?[]const u8, algorithm: SseAlgorithm, kms_key_id: []const u8) Error!void {
        return self.vtable.updateObjectEncryption(self.ctx, bucket, key, version_id, algorithm, kms_key_id);
    }
    pub fn putBucketReplication(self: Backend, bucket: []const u8, cfg: ReplicationConfig) Error!void {
        return self.vtable.putBucketReplication(self.ctx, bucket, cfg);
    }
    pub fn getBucketReplication(self: Backend, allocator: Allocator, bucket: []const u8) Error!ReplicationConfig {
        return self.vtable.getBucketReplication(self.ctx, allocator, bucket);
    }
    pub fn deleteBucketReplication(self: Backend, bucket: []const u8) Error!void {
        return self.vtable.deleteBucketReplication(self.ctx, bucket);
    }
};

// ---------------------------------------------------------------------------
// DynamoDB backend (M15, v0.2.0).
//
// Separate vtable from S3's `Backend` to keep each surface focused and
// readable. `Fs` implements both — one struct, two backend views.

pub const dynamo_state = @import("dynamo_state.zig");
pub const TableSlot = dynamo_state.TableSlot;
pub const Item = dynamo_state.Item;

/// Inputs for CreateTable. All slices are borrowed from the request
/// arena; the backend is responsible for copying anything it persists.
pub const CreateTableInput = struct {
    name: []const u8,
    key_schema: []const dynamo_state.KeyAttribute,
    attribute_definitions: []const dynamo_state.AttributeDef,
    billing_mode: dynamo_state.BillingMode = .pay_per_request,
    global_secondary_indexes: []const dynamo_state.GsiDef = &.{},
    local_secondary_indexes: []const dynamo_state.LsiDef = &.{},
    tags: []const dynamo_state.Tag = &.{},
    stream_spec: ?dynamo_state.StreamSpecification = null,
};

/// Inputs for UpdateTable. Supports BillingMode and StreamSpecification
/// mutations; other fields are accepted-and-ignored (documented
/// divergence).
pub const UpdateTableInput = struct {
    name: []const u8,
    billing_mode: ?dynamo_state.BillingMode = null,
    stream_spec: ?dynamo_state.StreamSpecification = null,
};

/// A pre-evaluated condition predicate. Storage holds the mutex and
/// calls `evaluate` against the existing item. Returns true if the
/// condition passes; false → the storage op fails with
/// `ConditionalCheckFailed`.
pub const ConditionPredicate = struct {
    ctx: *anyopaque,
    evaluate_fn: *const fn (ctx: *anyopaque, existing: ?*const Item) bool,

    pub fn evaluate(self: ConditionPredicate, existing: ?*const Item) bool {
        return self.evaluate_fn(self.ctx, existing);
    }
};

/// PutItem input. `item` is borrowed from the request arena. The backend
/// deep-copies into long-lived state.
pub const PutItemInput = struct {
    table: []const u8,
    item: *const Item,
    condition: ?ConditionPredicate = null,
};

/// PutItem result includes the previous item (when ReturnValues=ALL_OLD).
/// The caller's allocator owns the returned item.
pub const PutItemResult = struct {
    /// The previously-stored item at the same key, if any. The caller
    /// owns the slices via the allocator passed to the call.
    old_item: ?Item = null,
};

pub const GetItemInput = struct {
    table: []const u8,
    /// Item carrying only the key attributes.
    key: *const Item,
};

pub const GetItemResult = struct {
    item: ?Item = null,
};

pub const DeleteItemInput = struct {
    table: []const u8,
    key: *const Item,
    condition: ?ConditionPredicate = null,
};

pub const DeleteItemResult = struct {
    old_item: ?Item = null,
};

/// UpdateItem input — runs the supplied applier under the Fs mutex.
pub const UpdateItemInput = struct {
    table: []const u8,
    key: *const Item,
    /// Called with a writable clone of the existing item (or a fresh
    /// key-only item if absent). Should mutate it in-place.
    apply_fn: *const fn (ctx: *anyopaque, item: *Item) bool,
    apply_ctx: *anyopaque,
    /// Optional ConditionExpression predicate.
    condition: ?ConditionPredicate = null,
};

pub const UpdateItemResult = struct {
    old_item: ?Item = null,
    new_item: ?Item = null,
};

/// Generic predicate that the service layer passes to query/scan to
/// match items against a partition key + sort-key predicate. Returns
/// true if the item should be included. Caller-side state lives in `ctx`.
pub const ItemPredicate = struct {
    ctx: *anyopaque,
    match_fn: *const fn (ctx: *anyopaque, item: *const Item) bool,

    pub fn match(self: ItemPredicate, item: *const Item) bool {
        return self.match_fn(self.ctx, item);
    }
};

/// Query input: storage walks all items in the table that satisfy
/// `key_predicate` (PK + optional SK), then applies the optional
/// `filter_predicate` (the FilterExpression). Result is sorted by sort
/// key according to `forward`.
pub const QueryInput = struct {
    table: []const u8,
    /// Predicate that fires only on the partition+sort key match.
    key_predicate: ItemPredicate,
    /// Optional FilterExpression predicate, applied after the key match.
    filter_predicate: ?ItemPredicate = null,
    /// false = descending sort by sort key.
    forward: bool = true,
    /// Cap on emitted items. 0 = no cap.
    limit: u32 = 0,
    /// ExclusiveStartKey serialised as the composite key string. Items
    /// strictly after this in sort order are emitted.
    exclusive_start_key: ?[]const u8 = null,
};

pub const QueryResult = struct {
    items: []Item,
    count: u32,
    scanned_count: u32,
    /// Last item's composite-key string when truncated. null otherwise.
    last_evaluated_key: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Transactions (M15-tx)

pub const TxGetItem = struct {
    table: []const u8,
    key: *const Item,
};

/// Result of TransactGetItems. Items are in the same order as the input
/// list. A missing item is represented as a null entry.
pub const TxGetResult = struct {
    items: []?Item,
};

pub const TxWriteKind = enum { put, delete, update, condition_check };

pub const TxWriteOp = struct {
    kind: TxWriteKind,
    table: []const u8,
    /// Put: full item. Delete/Update/ConditionCheck: just the key attrs.
    item_or_key: *const Item,
    /// Optional ConditionExpression predicate (called with the existing
    /// item if any).
    condition: ?ConditionPredicate = null,
    /// Update-only: mutates a writable item in place. Returns false on
    /// applier-internal failure (treated as cancellation).
    apply_fn: ?*const fn (ctx: *anyopaque, item: *Item) bool = null,
    apply_ctx: ?*anyopaque = null,
};

/// Returns when the transaction succeeds. On cancellation, the backend
/// returns Error.TransactionCanceled and sets `cancellation_reasons`
/// on the input slice via the caller-supplied buffer.
pub const TxWriteResult = struct {
    /// Per-op cancellation reason strings. Parallel to the input ops.
    /// On success this is empty; on cancellation, all ops have a reason
    /// ("None" for ops that didn't fail).
    cancellation_reasons: []?[]const u8 = &.{},
};

pub const TxCancellationReason = struct {
    code: []const u8,
    message: ?[]const u8 = null,
};


pub const DynamoBackend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        listTables: *const fn (ctx: *anyopaque, allocator: Allocator) Error![]const []const u8,
        createTable: *const fn (ctx: *anyopaque, in: CreateTableInput) Error!void,
        describeTable: *const fn (ctx: *anyopaque, name: []const u8) Error!*const TableSlot,
        deleteTable: *const fn (ctx: *anyopaque, name: []const u8) Error!void,
        updateTable: *const fn (ctx: *anyopaque, in: UpdateTableInput) Error!*const TableSlot,
        // M15-items.
        putItem: *const fn (ctx: *anyopaque, allocator: Allocator, in: PutItemInput) Error!PutItemResult,
        getItem: *const fn (ctx: *anyopaque, allocator: Allocator, in: GetItemInput) Error!GetItemResult,
        deleteItem: *const fn (ctx: *anyopaque, allocator: Allocator, in: DeleteItemInput) Error!DeleteItemResult,
        updateItem: *const fn (ctx: *anyopaque, allocator: Allocator, in: UpdateItemInput) Error!UpdateItemResult,
        query: *const fn (ctx: *anyopaque, allocator: Allocator, in: QueryInput) Error!QueryResult,
        transactGetItems: *const fn (ctx: *anyopaque, allocator: Allocator, ops: []const TxGetItem) Error!TxGetResult,
        transactWriteItems: *const fn (ctx: *anyopaque, allocator: Allocator, ops: []const TxWriteOp, reasons_out: *[]?[]const u8) Error!void,
    };

    pub fn listTables(self: DynamoBackend, allocator: Allocator) Error![]const []const u8 {
        return self.vtable.listTables(self.ctx, allocator);
    }
    pub fn createTable(self: DynamoBackend, in: CreateTableInput) Error!void {
        return self.vtable.createTable(self.ctx, in);
    }
    pub fn describeTable(self: DynamoBackend, name: []const u8) Error!*const TableSlot {
        return self.vtable.describeTable(self.ctx, name);
    }
    pub fn deleteTable(self: DynamoBackend, name: []const u8) Error!void {
        return self.vtable.deleteTable(self.ctx, name);
    }
    pub fn updateTable(self: DynamoBackend, in: UpdateTableInput) Error!*const TableSlot {
        return self.vtable.updateTable(self.ctx, in);
    }
    pub fn putItem(self: DynamoBackend, allocator: Allocator, in: PutItemInput) Error!PutItemResult {
        return self.vtable.putItem(self.ctx, allocator, in);
    }
    pub fn getItem(self: DynamoBackend, allocator: Allocator, in: GetItemInput) Error!GetItemResult {
        return self.vtable.getItem(self.ctx, allocator, in);
    }
    pub fn deleteItem(self: DynamoBackend, allocator: Allocator, in: DeleteItemInput) Error!DeleteItemResult {
        return self.vtable.deleteItem(self.ctx, allocator, in);
    }
    pub fn updateItem(self: DynamoBackend, allocator: Allocator, in: UpdateItemInput) Error!UpdateItemResult {
        return self.vtable.updateItem(self.ctx, allocator, in);
    }
    pub fn query(self: DynamoBackend, allocator: Allocator, in: QueryInput) Error!QueryResult {
        return self.vtable.query(self.ctx, allocator, in);
    }
    pub fn transactGetItems(self: DynamoBackend, allocator: Allocator, ops: []const TxGetItem) Error!TxGetResult {
        return self.vtable.transactGetItems(self.ctx, allocator, ops);
    }
    pub fn transactWriteItems(
        self: DynamoBackend,
        allocator: Allocator,
        ops: []const TxWriteOp,
        reasons_out: *[]?[]const u8,
    ) Error!void {
        return self.vtable.transactWriteItems(self.ctx, allocator, ops, reasons_out);
    }
};

/// Validate an S3 object key. AWS permits virtually any UTF-8; the rules
/// we enforce are non-empty, ≤ 1024 bytes, and well-formed UTF-8.
pub fn validateObjectKey(key: []const u8) Error!void {
    if (key.len == 0 or key.len > 1024) return Error.InvalidObjectKey;
    if (!std.unicode.utf8ValidateSlice(key)) return Error.InvalidObjectKey;
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

test "validateObjectKey: rejects invalid UTF-8" {
    const testing = std.testing;
    // Lone continuation byte — invalid UTF-8.
    try testing.expectError(Error.InvalidObjectKey, validateObjectKey("bad-\xff-key"));
    // Truncated multibyte sequence.
    try testing.expectError(Error.InvalidObjectKey, validateObjectKey("trunc-\xc2"));
}

test "validateTagSet: empty + typical" {
    try validateTagSet(&.{});
    try validateTagSet(&.{
        .{ .key = "env", .value = "prod" },
        .{ .key = "team", .value = "alpha" },
    });
}

test "validateTagSet: too many tags" {
    const testing = std.testing;
    var many: [11]Tag = undefined;
    var buf: [11][8]u8 = undefined;
    for (0..11) |i| {
        buf[i] = [_]u8{ 'k', '0' + @as(u8, @intCast(i)), 0, 0, 0, 0, 0, 0 };
        many[i] = .{ .key = buf[i][0..2], .value = "v" };
    }
    try testing.expectError(Error.InvalidTag, validateTagSet(&many));
}

test "validateTagSet: duplicate key" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidTag, validateTagSet(&.{
        .{ .key = "env", .value = "prod" },
        .{ .key = "env", .value = "stage" },
    }));
}

test "validateTagSet: aws: prefix is reserved" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidTag, validateTagSet(&.{
        .{ .key = "aws:internal", .value = "x" },
    }));
    try testing.expectError(Error.InvalidTag, validateTagSet(&.{
        .{ .key = "AWS:Internal", .value = "x" },
    }));
}

test "validateTagSet: key length bounds" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidTag, validateTagSet(&.{
        .{ .key = "", .value = "v" },
    }));
    const long_key = "x" ** 129;
    try testing.expectError(Error.InvalidTag, validateTagSet(&.{
        .{ .key = long_key, .value = "v" },
    }));
}

test "validateTagSet: value length bound" {
    const testing = std.testing;
    const long_value = "x" ** 257;
    try testing.expectError(Error.InvalidTag, validateTagSet(&.{
        .{ .key = "k", .value = long_value },
    }));
    // Empty value is OK.
    try validateTagSet(&.{.{ .key = "k", .value = "" }});
}

test "validateTagSet: rejects invalid chars" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidTag, validateTagSet(&.{
        .{ .key = "k!", .value = "v" },
    }));
}

test "parseCannedAcl: known values + unknown" {
    const testing = std.testing;
    try testing.expectEqual(CannedAcl.private, try parseCannedAcl("private"));
    try testing.expectEqual(CannedAcl.public_read, try parseCannedAcl("public-read"));
    try testing.expectEqual(CannedAcl.bucket_owner_full_control, try parseCannedAcl("bucket-owner-full-control"));
    try testing.expectError(error.UnknownCannedAcl, parseCannedAcl("frobnicate"));
    try testing.expectError(error.UnknownCannedAcl, parseCannedAcl(""));
}

test "permissionFromXml + permissionToXml round-trip" {
    const testing = std.testing;
    try testing.expectEqual(Permission.FULL_CONTROL, try permissionFromXml("FULL_CONTROL"));
    try testing.expectEqual(Permission.READ, try permissionFromXml("READ"));
    try testing.expectError(error.InvalidPermission, permissionFromXml("OWNER"));
    try testing.expectEqualStrings("WRITE_ACP", permissionToXml(.WRITE_ACP));
}

test "ownershipControlFromString round-trip" {
    const testing = std.testing;
    try testing.expectEqual(OwnershipControl.BucketOwnerEnforced, try ownershipControlFromString("BucketOwnerEnforced"));
    try testing.expectEqual(OwnershipControl.ObjectWriter, try ownershipControlFromString("ObjectWriter"));
    try testing.expectError(error.InvalidOwnershipControl, ownershipControlFromString("Whatever"));
    try testing.expectEqualStrings("BucketOwnerPreferred", ownershipControlToString(.BucketOwnerPreferred));
}

test "httpMethodFromString round-trip" {
    const testing = std.testing;
    try testing.expectEqual(HttpMethod.GET, try httpMethodFromString("GET"));
    try testing.expectEqual(HttpMethod.HEAD, try httpMethodFromString("HEAD"));
    try testing.expectError(error.InvalidHttpMethod, httpMethodFromString("PATCH"));
    try testing.expectEqualStrings("DELETE", httpMethodToString(.DELETE));
}

test "sseAlgorithmFromString round-trip" {
    const testing = std.testing;
    try testing.expectEqual(SseAlgorithm.@"AES256", try sseAlgorithmFromString("AES256"));
    try testing.expectEqual(SseAlgorithm.@"aws:kms", try sseAlgorithmFromString("aws:kms"));
    try testing.expectError(error.InvalidSseAlgorithm, sseAlgorithmFromString("ROT13"));
    try testing.expectEqualStrings("AES256", sseAlgorithmToString(.@"AES256"));
}

test "lifecycleStatusFromString round-trip" {
    const testing = std.testing;
    try testing.expectEqual(LifecycleStatus.Enabled, try lifecycleStatusFromString("Enabled"));
    try testing.expectError(error.InvalidLifecycleStatus, lifecycleStatusFromString("enabled"));
}

test "storageClassFromString known + unknown" {
    const testing = std.testing;
    try testing.expectEqual(StorageClass.GLACIER, try storageClassFromString("GLACIER"));
    try testing.expectError(error.InvalidStorageClass, storageClassFromString("FROZEN_TUNDRA"));
}

test "s3Event round-trip" {
    const testing = std.testing;
    try testing.expectEqual(S3EventName.s3_ObjectCreated_All, try s3EventFromString("s3:ObjectCreated:*"));
    try testing.expectEqual(S3EventName.s3_ObjectRemoved_DeleteMarkerCreated, try s3EventFromString("s3:ObjectRemoved:DeleteMarkerCreated"));
    try testing.expectError(error.InvalidS3Event, s3EventFromString("s3:Frobnicate"));
    try testing.expectEqualStrings("s3:LifecycleExpiration:*", s3EventToString(.s3_LifecycleExpiration_All));
}

test "protocolFromString" {
    const testing = std.testing;
    try testing.expectEqual(Protocol.http, try protocolFromString("http"));
    try testing.expectEqual(Protocol.https, try protocolFromString("https"));
    try testing.expectError(error.InvalidProtocol, protocolFromString("ftp"));
}

test "retentionModeFromString round-trip" {
    const testing = std.testing;
    try testing.expectEqual(RetentionMode.GOVERNANCE, try retentionModeFromString("GOVERNANCE"));
    try testing.expectEqual(RetentionMode.COMPLIANCE, try retentionModeFromString("COMPLIANCE"));
    try testing.expectError(error.InvalidRetentionMode, retentionModeFromString("strict"));
    try testing.expectEqualStrings("COMPLIANCE", retentionModeToString(.COMPLIANCE));
}

test "legalHoldFromString round-trip" {
    const testing = std.testing;
    try testing.expectEqual(LegalHoldStatus.ON, try legalHoldFromString("ON"));
    try testing.expectEqual(LegalHoldStatus.OFF, try legalHoldFromString("OFF"));
    try testing.expectError(error.InvalidLegalHoldStatus, legalHoldFromString("on"));
    try testing.expectEqualStrings("ON", legalHoldToString(.ON));
}

test "replicationStatusFromString" {
    const testing = std.testing;
    try testing.expectEqual(ReplicationStatus.Enabled, try replicationStatusFromString("Enabled"));
    try testing.expectEqual(ReplicationStatus.Disabled, try replicationStatusFromString("Disabled"));
    try testing.expectError(error.InvalidReplicationStatus, replicationStatusFromString("enabled"));
}
