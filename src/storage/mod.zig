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
    NoSuchTagSet,
    NoSuchBucketPolicy,
    OwnershipControlsNotFound,
    NoSuchPublicAccessBlockConfiguration,
    AccessControlListNotSupported,
    BucketAlreadyExists,
    BucketAlreadyOwnedByYou,
    BucketNotEmpty,
    InvalidBucketName,
    InvalidObjectKey,
    InvalidTag,
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
// divergence in SUPPORT.md.

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
        createBucket: *const fn (ctx: *anyopaque, name: []const u8) Error!void,
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
