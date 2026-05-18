//! In-memory SNS state (v0.4.0).
//!
//! Each topic has an `SnsTopicSlot` carrying attributes + tags + a list
//! of subscriptions. Persisted at:
//!   <data_dir>/profiles/<profile>/sns/topics/<name>/
//!     attributes.json   — TopicAttributes
//!     tags.json         — TagResource / UntagResource / ListTagsForResource
//!     subscriptions/<sub_id>.json — one file per subscription

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Topic attributes. Standard topics only (no FIFO in v0.4.0).
pub const TopicAttributes = struct {
    /// DisplayName attribute (free-form). Used by AWS for email subjects.
    display_name: ?[]const u8 = null,
    /// Policy attribute (IAM JSON). Accepted, not evaluated.
    policy: ?[]const u8 = null,
    /// DeliveryPolicy (retry config). Accepted, not enforced.
    delivery_policy: ?[]const u8 = null,
    /// KmsMasterKeyId — accepted, not used (no encryption-at-rest).
    kms_key_id: ?[]const u8 = null,
};

/// One topic's persisted + in-memory state.
pub const SnsTopicSlot = struct {
    name: []const u8,
    /// `arn:aws:sns:<region>:<account>:<name>`. Cached at create time.
    arn: []const u8,
    created_unix: i64,
    attrs: TopicAttributes,
    tags: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Subscriptions belonging to this topic.
    subscriptions: std.ArrayListUnmanaged(*Subscription) = .empty,

    pub fn deinit(self: *SnsTopicSlot, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.arn);
        if (self.attrs.display_name) |s| allocator.free(s);
        if (self.attrs.policy) |s| allocator.free(s);
        if (self.attrs.delivery_policy) |s| allocator.free(s);
        if (self.attrs.kms_key_id) |s| allocator.free(s);
        var tag_it = self.tags.iterator();
        while (tag_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.tags.deinit(allocator);
        for (self.subscriptions.items) |s| {
            s.deinit(allocator);
            allocator.destroy(s);
        }
        self.subscriptions.deinit(allocator);
    }
};

/// SNS subscription protocols. Only `.sqs` actually fires in v0.4.0;
/// others are accept-store-roundtrip.
pub const Protocol = enum {
    sqs,
    lambda,
    http,
    https,
    email,
    email_json,
    sms,
    unknown,

    pub fn fromString(s: []const u8) Protocol {
        if (std.mem.eql(u8, s, "sqs")) return .sqs;
        if (std.mem.eql(u8, s, "lambda")) return .lambda;
        if (std.mem.eql(u8, s, "http")) return .http;
        if (std.mem.eql(u8, s, "https")) return .https;
        if (std.mem.eql(u8, s, "email")) return .email;
        if (std.mem.eql(u8, s, "email-json")) return .email_json;
        if (std.mem.eql(u8, s, "sms")) return .sms;
        return .unknown;
    }

    pub fn toString(self: Protocol) []const u8 {
        return switch (self) {
            .sqs => "sqs",
            .lambda => "lambda",
            .http => "http",
            .https => "https",
            .email => "email",
            .email_json => "email-json",
            .sms => "sms",
            .unknown => "unknown",
        };
    }
};

/// A single subscription on a topic.
pub const Subscription = struct {
    /// 8-byte hex unique id. Owned.
    sub_id: []const u8,
    /// `arn:aws:sns:...:<topic-name>:<sub_id>`. Owned.
    arn: []const u8,
    /// Topic ARN. Owned.
    topic_arn: []const u8,
    /// Protocol kind.
    protocol: Protocol,
    /// Endpoint string (e.g., SQS queue ARN for protocol=sqs). Owned.
    endpoint: []const u8,
    /// True when ConfirmSubscription was called (or auto-confirmed for SQS).
    confirmed: bool = true,
    /// RawMessageDelivery subscription attribute. When true, SNS sends
    /// just the Message field to SQS (no envelope wrapper).
    raw_message_delivery: bool = false,
    /// FilterPolicy subscription attribute. Accepted, not evaluated.
    /// Owned.
    filter_policy: ?[]const u8 = null,
    /// DeliveryPolicy subscription attribute. Accepted, not enforced.
    delivery_policy: ?[]const u8 = null,

    pub fn deinit(self: *Subscription, allocator: Allocator) void {
        allocator.free(self.sub_id);
        allocator.free(self.arn);
        allocator.free(self.topic_arn);
        allocator.free(self.endpoint);
        if (self.filter_policy) |s| allocator.free(s);
        if (self.delivery_policy) |s| allocator.free(s);
    }
};

/// AWS topic-name rules: 1..=256 chars, alphanumeric + `-`, `_`.
/// FIFO topics end in `.fifo` (rejected in v0.4.0).
pub const ValidateNameError = error{ InvalidTopicName, FifoNotSupported };

pub fn validateTopicName(name: []const u8) ValidateNameError!void {
    if (name.len == 0 or name.len > 256) return error.InvalidTopicName;
    if (std.mem.endsWith(u8, name, ".fifo")) return error.FifoNotSupported;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
        if (!ok) return error.InvalidTopicName;
    }
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "validateTopicName: shapes" {
    try validateTopicName("topic1");
    try validateTopicName("Foo_Bar-123");
    try testing.expectError(error.InvalidTopicName, validateTopicName(""));
    try testing.expectError(error.InvalidTopicName, validateTopicName("has space"));
    try testing.expectError(error.InvalidTopicName, validateTopicName("emoji-🚀"));
    try testing.expectError(error.FifoNotSupported, validateTopicName("orders.fifo"));
}

test "Protocol.fromString round-trip" {
    try testing.expectEqual(Protocol.sqs, Protocol.fromString("sqs"));
    try testing.expectEqual(Protocol.lambda, Protocol.fromString("lambda"));
    try testing.expectEqual(Protocol.unknown, Protocol.fromString("bogus"));
}
