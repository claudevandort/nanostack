//! Map nanostack's routed `Operation` enum to the IAM action string used
//! by AWS S3 bucket policies — e.g. `s3:GetObject`, `s3:PutBucketPolicy`.
//!
//! Source of truth: AWS S3 docs "Actions, resources, and condition keys
//! for Amazon S3" → "Actions defined by Amazon S3". The mapping is a
//! static lookup; no conditional logic.
//!
//! Notes:
//! - `head_bucket` maps to `s3:ListBucket` (AWS-exact — HEAD is permission-
//!   gated by the same action as listing).
//! - `head_object` maps to `s3:GetObject` (same — HEAD on an object needs
//!   the same permission as GET).
//! - `list_buckets` maps to `s3:ListAllMyBuckets` (account-scoped).
//! - `delete_objects` (batch) uses `s3:DeleteObject` — evaluated per-key
//!   inside the handler, not via this single lookup.
//! - `unknown` returns the empty string; callers should treat as
//!   "no action required" (the 501-NotImplemented path runs before authz).

const std = @import("std");
const router = @import("../router.zig");

/// Returns the IAM action string for `op`. Empty string for `.unknown`.
pub fn iamActionFor(op: router.Operation) []const u8 {
    return switch (op) {
        // --- bucket-scope ---
        .create_bucket => "s3:CreateBucket",
        .delete_bucket => "s3:DeleteBucket",
        .head_bucket => "s3:ListBucket",
        .list_buckets => "s3:ListAllMyBuckets",

        // --- object-scope ---
        .put_object => "s3:PutObject",
        .get_object => "s3:GetObject",
        .head_object => "s3:GetObject",
        .delete_object => "s3:DeleteObject",
        .delete_objects => "s3:DeleteObject",

        // --- listing ---
        .list_objects => "s3:ListBucket",
        .list_objects_v2 => "s3:ListBucket",
        .list_object_versions => "s3:ListBucketVersions",

        // --- multipart upload ---
        .create_multipart_upload => "s3:PutObject",
        .upload_part => "s3:PutObject",
        .complete_multipart_upload => "s3:PutObject",
        .abort_multipart_upload => "s3:AbortMultipartUpload",
        .list_parts => "s3:ListMultipartUploadParts",
        .list_multipart_uploads => "s3:ListBucketMultipartUploads",

        // --- versioning ---
        .put_bucket_versioning => "s3:PutBucketVersioning",
        .get_bucket_versioning => "s3:GetBucketVersioning",

        // --- tagging ---
        .put_bucket_tagging => "s3:PutBucketTagging",
        .get_bucket_tagging => "s3:GetBucketTagging",
        .delete_bucket_tagging => "s3:PutBucketTagging",
        .put_object_tagging => "s3:PutObjectTagging",
        .get_object_tagging => "s3:GetObjectTagging",
        .delete_object_tagging => "s3:DeleteObjectTagging",

        // --- ACL ---
        .put_bucket_acl => "s3:PutBucketAcl",
        .get_bucket_acl => "s3:GetBucketAcl",
        .put_object_acl => "s3:PutObjectAcl",
        .get_object_acl => "s3:GetObjectAcl",

        // --- policy ---
        .put_bucket_policy => "s3:PutBucketPolicy",
        .get_bucket_policy => "s3:GetBucketPolicy",
        .delete_bucket_policy => "s3:DeleteBucketPolicy",
        .get_bucket_policy_status => "s3:GetBucketPolicyStatus",

        // --- ownership controls ---
        .put_bucket_ownership_controls => "s3:PutBucketOwnershipControls",
        .get_bucket_ownership_controls => "s3:GetBucketOwnershipControls",
        .delete_bucket_ownership_controls => "s3:PutBucketOwnershipControls",

        // --- public access block ---
        .put_public_access_block => "s3:PutBucketPublicAccessBlock",
        .get_public_access_block => "s3:GetBucketPublicAccessBlock",
        .delete_public_access_block => "s3:PutBucketPublicAccessBlock",

        // --- CORS ---
        .put_bucket_cors => "s3:PutBucketCORS",
        .get_bucket_cors => "s3:GetBucketCORS",
        .delete_bucket_cors => "s3:PutBucketCORS",

        // --- encryption ---
        .put_bucket_encryption => "s3:PutEncryptionConfiguration",
        .get_bucket_encryption => "s3:GetEncryptionConfiguration",
        .delete_bucket_encryption => "s3:PutEncryptionConfiguration",
        .update_object_encryption => "s3:PutObject",

        // --- lifecycle ---
        .put_bucket_lifecycle => "s3:PutLifecycleConfiguration",
        .get_bucket_lifecycle => "s3:GetLifecycleConfiguration",
        .delete_bucket_lifecycle => "s3:PutLifecycleConfiguration",

        // --- notifications ---
        .put_bucket_notification => "s3:PutBucketNotification",
        .get_bucket_notification => "s3:GetBucketNotification",

        // --- website ---
        .put_bucket_website => "s3:PutBucketWebsite",
        .get_bucket_website => "s3:GetBucketWebsite",
        .delete_bucket_website => "s3:DeleteBucketWebsite",

        // --- object attributes ---
        .get_object_attributes => "s3:GetObjectAttributes",

        // --- object lock ---
        .put_object_lock_config => "s3:PutBucketObjectLockConfiguration",
        .get_object_lock_config => "s3:GetBucketObjectLockConfiguration",
        .put_object_retention => "s3:PutObjectRetention",
        .get_object_retention => "s3:GetObjectRetention",
        .put_object_legal_hold => "s3:PutObjectLegalHold",
        .get_object_legal_hold => "s3:GetObjectLegalHold",

        // --- restore ---
        .restore_object => "s3:RestoreObject",

        // --- replication ---
        .put_bucket_replication => "s3:PutReplicationConfiguration",
        .get_bucket_replication => "s3:GetReplicationConfiguration",
        .delete_bucket_replication => "s3:PutReplicationConfiguration",

        // --- unrouted (501 NotImplemented runs before authz) ---
        .unknown => "",
    };
}

/// True for operations that target an account-level scope (not a specific
/// bucket). These bypass the bucket-policy fetch — they evaluate against
/// the account principal directly.
pub fn isAccountScoped(op: router.Operation) bool {
    return switch (op) {
        .list_buckets, .create_bucket => true,
        else => false,
    };
}

/// True for operations whose resource ARN includes a key (object-scoped).
/// Returns false for bucket-scoped operations like `s3:GetBucketAcl` even
/// when they reference a bucket (the resource ARN is `arn:aws:s3:::bucket`,
/// no `/<key>` suffix).
pub fn isObjectScoped(op: router.Operation) bool {
    return switch (op) {
        .put_object,
        .get_object,
        .head_object,
        .delete_object,
        .delete_objects,
        .create_multipart_upload,
        .upload_part,
        .complete_multipart_upload,
        .abort_multipart_upload,
        .list_parts,
        .put_object_tagging,
        .get_object_tagging,
        .delete_object_tagging,
        .put_object_acl,
        .get_object_acl,
        .get_object_attributes,
        .put_object_retention,
        .get_object_retention,
        .put_object_legal_hold,
        .get_object_legal_hold,
        .restore_object,
        .update_object_encryption,
        => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "iamActionFor: every routed op returns a non-empty string except .unknown" {
    inline for (@typeInfo(router.Operation).@"enum".fields) |f| {
        const op: router.Operation = @enumFromInt(f.value);
        const action = iamActionFor(op);
        if (op == .unknown) {
            try testing.expectEqualStrings("", action);
        } else {
            try testing.expect(action.len > 0);
            try testing.expect(std.mem.startsWith(u8, action, "s3:"));
        }
    }
}

test "iamActionFor: head_bucket = ListBucket (AWS-exact)" {
    try testing.expectEqualStrings("s3:ListBucket", iamActionFor(.head_bucket));
}

test "iamActionFor: head_object = GetObject (AWS-exact)" {
    try testing.expectEqualStrings("s3:GetObject", iamActionFor(.head_object));
}

test "iamActionFor: list_buckets = ListAllMyBuckets (account-scoped)" {
    try testing.expectEqualStrings("s3:ListAllMyBuckets", iamActionFor(.list_buckets));
}

test "iamActionFor: delete_bucket_tagging = PutBucketTagging (AWS-exact — delete maps to put permission)" {
    try testing.expectEqualStrings("s3:PutBucketTagging", iamActionFor(.delete_bucket_tagging));
}

test "iamActionFor: create_multipart_upload = PutObject" {
    try testing.expectEqualStrings("s3:PutObject", iamActionFor(.create_multipart_upload));
}

test "isAccountScoped: list_buckets + create_bucket" {
    try testing.expect(isAccountScoped(.list_buckets));
    try testing.expect(isAccountScoped(.create_bucket));
    try testing.expect(!isAccountScoped(.get_object));
    try testing.expect(!isAccountScoped(.delete_bucket));
}

test "isObjectScoped: object ops yes, bucket ops no" {
    try testing.expect(isObjectScoped(.get_object));
    try testing.expect(isObjectScoped(.put_object));
    try testing.expect(isObjectScoped(.upload_part));
    try testing.expect(isObjectScoped(.put_object_acl));
    try testing.expect(!isObjectScoped(.put_bucket_acl));
    try testing.expect(!isObjectScoped(.list_objects));
    try testing.expect(!isObjectScoped(.head_bucket));
}
