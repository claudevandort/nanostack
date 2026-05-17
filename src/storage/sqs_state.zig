//! In-memory SQS state managed by `Fs` (v0.3.0).
//!
//! Each queue has a `SqsQueueSlot` carrying attributes + an in-memory
//! `messages` list. Persisted at:
//!   <data_dir>/profiles/<profile>/sqs/queues/<name>/
//!     attributes.json   — QueueAttributes (immutable + mutable)
//!     tags.json         — TagQueue / UntagQueue / ListQueueTags
//!     messages/<id>.json — one file per message

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Attributes that affect queue behaviour. Defaults match AWS-real.
pub const QueueAttributes = struct {
    /// Default message visibility timeout (seconds). Range 0..=43200.
    /// AWS default = 30.
    visibility_timeout: u32 = 30,
    /// Default DelaySeconds for SendMessage. Range 0..=900.
    delay_seconds: u32 = 0,
    /// Default WaitTimeSeconds for ReceiveMessage long-poll. Range 0..=20.
    receive_message_wait_time_seconds: u32 = 0,
    /// MessageRetentionPeriod (seconds). Range 60..=1_209_600.
    /// AWS default = 4 days (345_600). Not currently enforced; messages
    /// persist until deleted or DLQ-routed.
    message_retention_period: u32 = 345_600,
    /// MaximumMessageSize (bytes). Range 1024..=262_144.
    /// AWS default = 262_144.
    maximum_message_size: u32 = 262_144,
    /// RedrivePolicy: optional dead-letter routing config. Persisted as
    /// the raw JSON string the user supplied so we round-trip it
    /// verbatim; ReceiveMessage parses it lazily when checking maxReceiveCount.
    redrive_policy: ?[]const u8 = null,
    /// Raw `Policy` attribute. Accepted, not evaluated. Round-trips
    /// verbatim.
    policy: ?[]const u8 = null,
    /// FIFO queue flag. Immutable after creation; derived from the
    /// `.fifo` name suffix and validated against the `FifoQueue`
    /// attribute at CreateQueue time.
    is_fifo: bool = false,
    /// Whether the queue uses SHA-256 of the body as the implicit
    /// MessageDeduplicationId when the client omits it. FIFO-only.
    content_based_dedup: bool = false,
    /// Monotonic counter that mints `SequenceNumber` for FIFO messages.
    /// Persisted on disk so re-sends after restart don't collide.
    sequence_counter: u128 = 0,
};

/// FIFO-only: an entry in the per-queue 5-minute dedup window.
pub const DedupEntry = struct {
    /// The MessageId of the original send that this dedup id maps to.
    /// Owned by `Fs.allocator`.
    message_id: []const u8,
    /// The SequenceNumber returned on the original send.
    sequence_number: u128,
    /// Wall-clock seconds when this entry should be pruned (= original
    /// send + 300).
    expire_unix: i64,
};

/// One queue's persisted + in-memory state.
pub const SqsQueueSlot = struct {
    name: []const u8,
    /// Owned by `Fs.allocator`. RFC3339 wall-clock at creation.
    created_unix: i64,
    attrs: QueueAttributes,
    /// Stable ULID-like ID — used as part of the QueueUrl. AWS uses the
    /// queue name itself; we follow suit, so this struct's `name` is
    /// the canonical identifier.
    tags: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// In-memory message store. Insertion-ordered; ReceiveMessage walks
    /// it in oldest-first order.
    messages: std.ArrayListUnmanaged(*Message) = .empty,
    /// FIFO-only 5-minute dedup window. Keys are MessageDeduplicationId
    /// (or sha256(body) under ContentBasedDeduplication). In-memory
    /// only; not persisted across restart.
    dedup_history: std.StringHashMapUnmanaged(DedupEntry) = .empty,

    pub fn deinit(self: *SqsQueueSlot, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.attrs.redrive_policy) |s| allocator.free(s);
        if (self.attrs.policy) |s| allocator.free(s);
        var tag_it = self.tags.iterator();
        while (tag_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.tags.deinit(allocator);
        for (self.messages.items) |m| {
            m.deinit(allocator);
            allocator.destroy(m);
        }
        self.messages.deinit(allocator);
        var dedup_it = self.dedup_history.iterator();
        while (dedup_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.message_id);
        }
        self.dedup_history.deinit(allocator);
    }
};

/// A single SQS message. The body is opaque bytes (UTF-8 in practice);
/// AWS allows binary via attribute_value.b but the body itself is
/// always a string.
pub const Message = struct {
    /// AWS-style UUID. Owned by `Fs.allocator`.
    id: []const u8,
    body: []const u8,
    /// Wall-clock seconds when the message was sent.
    sent_unix: i64,
    /// Wall-clock seconds when the message next becomes visible. Equal
    /// to `sent_unix + DelaySeconds` initially; ReceiveMessage stamps
    /// it to `now + VisibilityTimeout` to lock the message in-flight.
    visible_unix: i64,
    /// Number of times this message has been delivered. Used by the
    /// DLQ routing logic (Phase 4).
    receive_count: u32 = 0,
    /// MD5 of the body, hex-encoded lowercase. Computed once at send.
    md5_of_body: [32]u8,
    /// User-supplied message attributes. We persist them verbatim as
    /// JSON for the moment — full typed parsing in a later phase.
    /// `null` when no attributes were sent.
    raw_attributes_json: ?[]const u8 = null,
    /// FIFO-only: per-message group identifier. Required on FIFO sends,
    /// rejected on Standard sends. Owned by `Fs.allocator`.
    message_group_id: ?[]const u8 = null,
    /// FIFO-only: explicit dedup id or content-hash. Stored for
    /// debugging / restart-survival (the live dedup-window lives in
    /// `SqsQueueSlot.dedup_history`).
    message_deduplication_id: ?[]const u8 = null,
    /// FIFO-only: monotonic per-queue sequence number minted on send.
    /// Zero on Standard messages.
    sequence_number: u128 = 0,

    pub fn deinit(self: *Message, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.body);
        if (self.raw_attributes_json) |s| allocator.free(s);
        if (self.message_group_id) |s| allocator.free(s);
        if (self.message_deduplication_id) |s| allocator.free(s);
    }
};

/// Validate an SQS queue name per AWS rules:
///   - 1..=80 chars total (FIFO suffix `.fifo` counts)
///   - alphanumeric + `_` + `-`
///   - FIFO queues end with `.fifo`; the body before the suffix
///     follows the standard alphabet
pub const ValidateNameError = error{InvalidQueueName};

pub fn hasFifoSuffix(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".fifo");
}

pub fn validateQueueName(name: []const u8) ValidateNameError!void {
    if (name.len == 0 or name.len > 80) return error.InvalidQueueName;
    // The body before any `.fifo` suffix is the standard-name alphabet
    // (no dots). The suffix itself is the only place where `.` appears.
    const body = if (hasFifoSuffix(name)) name[0 .. name.len - ".fifo".len] else name;
    if (body.len == 0) return error.InvalidQueueName;
    for (body) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
        if (!ok) return error.InvalidQueueName;
    }
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "validateQueueName: shapes" {
    try validateQueueName("orders");
    try validateQueueName("orders-1");
    try validateQueueName("orders_1");
    try validateQueueName("orders.fifo");
    try testing.expectError(error.InvalidQueueName, validateQueueName(""));
    try testing.expectError(error.InvalidQueueName, validateQueueName("has space"));
    try testing.expectError(error.InvalidQueueName, validateQueueName("emoji-🚀"));
    // Dots are only legal as part of the `.fifo` suffix.
    try testing.expectError(error.InvalidQueueName, validateQueueName("orders.dev"));
    try testing.expectError(error.InvalidQueueName, validateQueueName("a.b.fifo"));
    try testing.expectError(error.InvalidQueueName, validateQueueName(".fifo"));
    // 80-char limit
    try validateQueueName("a" ** 80);
    try testing.expectError(error.InvalidQueueName, validateQueueName("a" ** 81));
}

test "hasFifoSuffix" {
    try testing.expect(hasFifoSuffix("orders.fifo"));
    try testing.expect(!hasFifoSuffix("orders"));
    try testing.expect(!hasFifoSuffix("orders.dev"));
}
