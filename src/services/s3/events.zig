//! S3 → SQS event-notification dispatcher (v0.3.4).
//!
//! Walks the bucket's NotificationConfiguration, matches events +
//! filter rules (prefix/suffix), and dispatches AWS-format event
//! envelopes to matching SQS queues. Fire-and-forget: errors are
//! logged but never bubble back to the S3 op response.
//!
//! Internal dispatch goes via the storage SqsBackend directly,
//! bypassing the SQS service's queue-policy authz hook. This matches
//! AWS's service-principal model where S3 gets implicit permission to
//! deliver events. Documented in SUPPORT.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const mod = @import("mod.zig");

/// Metadata about an object that just landed. Threaded into
/// `dispatchObjectCreated` from PutObject / CopyObject /
/// CompleteMultipartUpload.
pub const ObjectCreatedMeta = struct {
    /// Object key.
    key: []const u8,
    /// Object size in bytes.
    size: u64,
    /// MD5 etag (for single-part) or `<md5-of-concat-md5s>-N` (for
    /// multipart). Owned by the caller.
    etag: []const u8,
    /// Version id when the bucket is versioned. Null otherwise.
    version_id: ?[]const u8 = null,
    /// The S3 event name to emit. One of:
    ///   "s3:ObjectCreated:Put"
    ///   "s3:ObjectCreated:Post"
    ///   "s3:ObjectCreated:Copy"
    ///   "s3:ObjectCreated:CompleteMultipartUpload"
    event_name: []const u8,
};

/// Metadata about an object that was just removed.
pub const ObjectRemovedMeta = struct {
    key: []const u8,
    version_id: ?[]const u8 = null,
    /// True when this delete created a delete marker (versioned bucket,
    /// no explicit versionId on the delete). Picks the event name:
    ///   true  → "s3:ObjectRemoved:DeleteMarkerCreated"
    ///   false → "s3:ObjectRemoved:Delete"
    delete_marker: bool = false,
};

/// Fire `s3:ObjectCreated:*` events for the given object. No-op when:
///   - the SQS backend isn't configured (ctx.sqs_backend == null),
///   - the bucket has no NotificationConfiguration,
///   - no QueueConfiguration entry matches the event + filter.
///
/// Errors during dispatch are logged + swallowed. Phase A: skeleton —
/// always returns without dispatching. Phase B fills this in.
pub fn dispatchObjectCreated(ctx: mod.Context, bucket: []const u8, meta: ObjectCreatedMeta) void {
    _ = ctx;
    _ = bucket;
    _ = meta;
    // Phase A: no-op. Phase B implements the real dispatch.
}

/// Fire `s3:ObjectRemoved:*` events. Same fire-and-forget semantics.
pub fn dispatchObjectRemoved(ctx: mod.Context, bucket: []const u8, meta: ObjectRemovedMeta) void {
    _ = ctx;
    _ = bucket;
    _ = meta;
    // Phase A: no-op. Phase B implements the real dispatch.
}
