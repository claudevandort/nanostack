//! In-memory DynamoDB Streams (v0.2.2).
//!
//! Each stream-enabled `TableSlot` owns a `*Stream`. On every successful
//! item mutation the storage backend calls `capture()` which appends a
//! `StreamRecord` to a bounded ring buffer. `getRecords()` and
//! `nextIterator()` serve those records back via the Streams sub-service.
//!
//! Records live in process memory only — they do **not** persist across
//! restart. AWS spec is a 24h time-based retention; we approximate via
//! a 1000-record bound plus a best-effort age trim on every consult.
//!
//! Concurrency: both `capture` (writers) and `read` (the Streams
//! handler) run under the parent `Fs.mutex` already, so this module
//! does not need an additional lock. The trade-off — GetRecords
//! blocks writes — is acceptable for a local-dev emulator and keeps
//! the module Io-free (no Zig stdlib mutex types to thread through).

const std = @import("std");
const Allocator = std.mem.Allocator;
const dynamo_state = @import("dynamo_state.zig");
const Item = dynamo_state.Item;
const StreamViewType = dynamo_state.StreamViewType;
const attribute_value = @import("../wire/dynamodb/attribute_value.zig");

pub const ring_bound: usize = 1000;
/// Records older than this (in seconds) are eligible for trim when the
/// ring is consulted. 24 * 3600 = 86_400.
pub const retention_secs: i64 = 24 * 3600;

pub const RecordKind = enum {
    insert,
    modify,
    remove, // "remove" not "delete" so it doesn't clash with the AWS REMOVE op

    pub fn toAws(self: RecordKind) []const u8 {
        return switch (self) {
            .insert => "INSERT",
            .modify => "MODIFY",
            .remove => "REMOVE",
        };
    }
};

/// Source of a stream record. `.user` is the default — produced by
/// PutItem / UpdateItem / DeleteItem / BatchWriteItem / TransactWriteItems.
/// `.ttl_sweeper` marks evictions from the TTL background sweeper, which
/// AWS renders as `userIdentity: {type: "Service", principalId:
/// "dynamodb.amazonaws.com"}` in the stream record (and lets consumers
/// distinguish those from user-driven deletes).
pub const UserIdentity = enum {
    user,
    ttl_sweeper,
};

pub const StreamRecord = struct {
    seq: u64,
    kind: RecordKind,
    /// Keys (PK + optional SK) — always present, regardless of view-type.
    keys: Item,
    /// New image, present iff view_type ∈ {NEW_IMAGE, NEW_AND_OLD_IMAGES}
    /// and the op produced one (INSERT or MODIFY).
    new_image: ?Item,
    /// Old image, present iff view_type ∈ {OLD_IMAGE, NEW_AND_OLD_IMAGES}
    /// and the op had an existing item (MODIFY or REMOVE).
    old_image: ?Item,
    created_unix: i64,
    /// Default `.user`. The wire renderer only emits the `userIdentity`
    /// JSON field when this is non-user.
    identity: UserIdentity = .user,

    pub fn deinit(self: *StreamRecord, allocator: Allocator) void {
        self.keys.deinit(allocator);
        if (self.new_image) |*ni| ni.deinit(allocator);
        if (self.old_image) |*oi| oi.deinit(allocator);
    }
};

pub const Stream = struct {
    allocator: Allocator,
    view_type: StreamViewType,
    /// Owned by `allocator`. Constant for the stream's lifetime; matches
    /// AWS's `shardId-<20-digit-zero-padded>-<8-hex>` shape close enough
    /// for clients that treat the ID as opaque. Stream ARN is *not*
    /// stored here — it's region-dependent and is constructed at render
    /// time from the table's region + name + stream_enabled_unix label.
    shard_id: []const u8,
    next_seq: u64 = 1,
    /// Ring buffer. Oldest record at index 0; newest at end. On eviction
    /// we pop from index 0. Capacity is `ring_bound`.
    records: std.ArrayListUnmanaged(StreamRecord),

    pub fn init(allocator: Allocator, view_type: StreamViewType, shard_id: []const u8) !Stream {
        const shard_owned = try allocator.dupe(u8, shard_id);
        errdefer allocator.free(shard_owned);

        var records: std.ArrayListUnmanaged(StreamRecord) = .empty;
        try records.ensureTotalCapacity(allocator, ring_bound);

        return .{
            .allocator = allocator,
            .view_type = view_type,
            .shard_id = shard_owned,
            .records = records,
        };
    }

    pub fn deinit(self: *Stream) void {
        for (self.records.items) |*r| r.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.allocator.free(self.shard_id);
    }

    /// Append a record for the given mutation. View-type filtering is
    /// applied here so the caller doesn't need to know what to pass.
    /// Callers MUST supply a key-only `keys_src` plus the optional
    /// pre-/post-images. The Stream's allocator deep-copies what it
    /// keeps.
    ///
    /// Returns the assigned sequence number.
    pub fn capture(
        self: *Stream,
        kind: RecordKind,
        keys_src: *const Item,
        new_src: ?*const Item,
        old_src: ?*const Item,
        now_unix: i64,
        identity: UserIdentity,
    ) !u64 {
        const keys_clone = try dynamo_state.cloneItem(self.allocator, keys_src);
        errdefer {
            var k = keys_clone;
            k.deinit(self.allocator);
        }

        const wants_new = switch (self.view_type) {
            .new_image, .new_and_old_images => true,
            .old_image, .keys_only => false,
        };
        const wants_old = switch (self.view_type) {
            .old_image, .new_and_old_images => true,
            .new_image, .keys_only => false,
        };

        const new_image: ?Item = if (wants_new and new_src != null)
            try dynamo_state.cloneItem(self.allocator, new_src.?)
        else
            null;
        errdefer if (new_image) |ni| {
            var x = ni;
            x.deinit(self.allocator);
        };
        const old_image: ?Item = if (wants_old and old_src != null)
            try dynamo_state.cloneItem(self.allocator, old_src.?)
        else
            null;
        errdefer if (old_image) |oi| {
            var x = oi;
            x.deinit(self.allocator);
        };

        // Best-effort age trim before insert. Keeps growth predictable
        // when a stream is consulted regularly.
        self.trimOlderThanLocked(now_unix - retention_secs);

        // Bound-trim: evict oldest if at capacity.
        if (self.records.items.len >= ring_bound) {
            var oldest = self.records.orderedRemove(0);
            oldest.deinit(self.allocator);
        }

        const seq = self.next_seq;
        self.next_seq += 1;
        try self.records.append(self.allocator, .{
            .seq = seq,
            .kind = kind,
            .keys = keys_clone,
            .new_image = new_image,
            .old_image = old_image,
            .created_unix = now_unix,
            .identity = identity,
        });
        return seq;
    }

    fn trimOlderThanLocked(self: *Stream, threshold_unix: i64) void {
        var i: usize = 0;
        while (i < self.records.items.len and self.records.items[i].created_unix < threshold_unix) : (i += 1) {}
        if (i == 0) return;
        for (self.records.items[0..i]) |*r| r.deinit(self.allocator);
        // Shift remainder left.
        const remaining = self.records.items.len - i;
        std.mem.copyForwards(StreamRecord, self.records.items[0..remaining], self.records.items[i..]);
        self.records.items.len = remaining;
    }

    /// Iterator positions used by GetShardIterator → GetRecords. Opaque
    /// to the client; we serialise + deserialise these in the streams
    /// handler.
    pub const Position = union(enum) {
        /// Oldest record currently in the buffer.
        trim_horizon,
        /// Records strictly newer than `next_seq` (used for `LATEST`
        /// and for `NextShardIterator` after a successful read).
        after_seq: u64,
        /// Records starting at exactly this seq.
        at_seq: u64,
    };

    /// Return up to `limit` records starting from `pos`, plus the
    /// position to use for the next call.
    pub fn read(self: *Stream, allocator: Allocator, pos: Position, limit: usize) !Result {
        const slice = self.records.items;
        // Compute the start index for the requested position.
        const start: usize = switch (pos) {
            .trim_horizon => 0,
            .at_seq => |s| firstIndexGE(slice, s),
            .after_seq => |s| firstIndexGT(slice, s),
        };
        const end = @min(start + limit, slice.len);

        // Clone records into the caller's allocator so the consumer can
        // outlive Stream.mutex.
        var out = try allocator.alloc(StreamRecord, end - start);
        var produced: usize = 0;
        errdefer {
            for (out[0..produced]) |*r| r.deinit(allocator);
            allocator.free(out);
        }
        for (slice[start..end], 0..) |src, i| {
            out[i] = .{
                .seq = src.seq,
                .kind = src.kind,
                .keys = try dynamo_state.cloneItem(allocator, &src.keys),
                .new_image = if (src.new_image) |ni| try dynamo_state.cloneItem(allocator, &ni) else null,
                .old_image = if (src.old_image) |oi| try dynamo_state.cloneItem(allocator, &oi) else null,
                .created_unix = src.created_unix,
                .identity = src.identity,
            };
            produced = i + 1;
        }

        // Next iterator: continue strictly after the last record returned.
        // If we returned nothing, the next iterator equals what was passed
        // in (clients poll on this when the shard is idle).
        const next_pos: Position = if (end == 0)
            pos
        else
            .{ .after_seq = slice[end - 1].seq };

        return .{ .records = out, .next_position = next_pos };
    }

    pub const Result = struct {
        records: []StreamRecord,
        next_position: Position,

        pub fn deinit(self: *Result, allocator: Allocator) void {
            for (self.records) |*r| r.deinit(allocator);
            allocator.free(self.records);
        }
    };

    /// Returns the latest sequence number in the buffer, or 0 if empty
    /// (sequence numbers are 1-indexed).
    pub fn latestSeq(self: *Stream) u64 {
        if (self.records.items.len == 0) return 0;
        return self.records.items[self.records.items.len - 1].seq;
    }

    fn firstIndexGE(slice: []const StreamRecord, target: u64) usize {
        // Records are seq-monotonic; linear scan is fine at ring_bound=1000.
        for (slice, 0..) |r, i| if (r.seq >= target) return i;
        return slice.len;
    }
    fn firstIndexGT(slice: []const StreamRecord, target: u64) usize {
        for (slice, 0..) |r, i| if (r.seq > target) return i;
        return slice.len;
    }
};

/// Format the constant shard ID for a stream. We embed the table's
/// enable-time so different streams on the same table over time get
/// distinct shard IDs (matching AWS's "shard rotates on
/// disable→re-enable" behaviour, even though we only keep one open
/// shard at a time).
pub fn formatShardId(allocator: Allocator, enable_unix: i64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "shardId-{d:0>20}-{x:0>8}", .{
        @as(u64, @intCast(enable_unix)),
        @as(u32, @truncate(@as(u64, @bitCast(enable_unix)))),
    });
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn makeItem(allocator: Allocator, k: []const u8, v: []const u8) !Item {
    const names = try allocator.alloc([]const u8, 1);
    names[0] = try allocator.dupe(u8, k);
    const values = try allocator.alloc(attribute_value.AttributeValue, 1);
    values[0] = .{ .s = try allocator.dupe(u8, v) };
    return .{ .names = names, .values = values };
}

test "Stream: capture appends in order, assigns monotonic seq" {
    var stream = try Stream.init(testing.allocator, .new_and_old_images, "shard-1");
    defer stream.deinit();

    var k1 = try makeItem(testing.allocator, "id", "a");
    defer k1.deinit(testing.allocator);
    var k2 = try makeItem(testing.allocator, "id", "b");
    defer k2.deinit(testing.allocator);

    const s1 = try stream.capture(.insert, &k1, &k1, null, 1000, .user);
    const s2 = try stream.capture(.insert, &k2, &k2, null, 1001, .user);
    try testing.expectEqual(@as(u64, 1), s1);
    try testing.expectEqual(@as(u64, 2), s2);
    try testing.expectEqual(@as(usize, 2), stream.records.items.len);
}

test "Stream: view_type=KEYS_ONLY drops both images" {
    var stream = try Stream.init(testing.allocator, .keys_only, "shard");
    defer stream.deinit();
    var k = try makeItem(testing.allocator, "id", "a");
    defer k.deinit(testing.allocator);
    var img = try makeItem(testing.allocator, "id", "a");
    defer img.deinit(testing.allocator);

    _ = try stream.capture(.modify, &k, &img, &img, 100, .user);
    try testing.expect(stream.records.items[0].new_image == null);
    try testing.expect(stream.records.items[0].old_image == null);
}

test "Stream: view_type=NEW_IMAGE drops old, keeps new" {
    var stream = try Stream.init(testing.allocator, .new_image, "shard");
    defer stream.deinit();
    var k = try makeItem(testing.allocator, "id", "a");
    defer k.deinit(testing.allocator);
    var img = try makeItem(testing.allocator, "id", "a");
    defer img.deinit(testing.allocator);

    _ = try stream.capture(.modify, &k, &img, &img, 100, .user);
    try testing.expect(stream.records.items[0].new_image != null);
    try testing.expect(stream.records.items[0].old_image == null);
}

test "Stream: view_type=OLD_IMAGE drops new, keeps old" {
    var stream = try Stream.init(testing.allocator, .old_image, "shard");
    defer stream.deinit();
    var k = try makeItem(testing.allocator, "id", "a");
    defer k.deinit(testing.allocator);
    var img = try makeItem(testing.allocator, "id", "a");
    defer img.deinit(testing.allocator);

    _ = try stream.capture(.modify, &k, &img, &img, 100, .user);
    try testing.expect(stream.records.items[0].new_image == null);
    try testing.expect(stream.records.items[0].old_image != null);
}

test "Stream: ring bound evicts oldest" {
    // Drop the bound so the test is fast. We hijack the bound via a
    // smaller test stream by manually populating + verifying eviction.
    var stream = try Stream.init(testing.allocator, .new_and_old_images, "shard");
    defer stream.deinit();

    var k = try makeItem(testing.allocator, "id", "x");
    defer k.deinit(testing.allocator);
    // Fill to ring_bound, then add one more.
    var i: usize = 0;
    while (i < ring_bound) : (i += 1) {
        _ = try stream.capture(.insert, &k, &k, null, @intCast(i), .user);
    }
    try testing.expectEqual(@as(usize, ring_bound), stream.records.items.len);
    const first_seq_before = stream.records.items[0].seq;
    _ = try stream.capture(.insert, &k, &k, null, @intCast(ring_bound), .user);
    try testing.expectEqual(@as(usize, ring_bound), stream.records.items.len);
    // After eviction the oldest seq advances by one.
    try testing.expectEqual(first_seq_before + 1, stream.records.items[0].seq);
}

test "Stream: read TRIM_HORIZON returns oldest first" {
    var stream = try Stream.init(testing.allocator, .new_and_old_images, "shard");
    defer stream.deinit();
    var k = try makeItem(testing.allocator, "id", "a");
    defer k.deinit(testing.allocator);
    _ = try stream.capture(.insert, &k, &k, null, 1, .user);
    _ = try stream.capture(.modify, &k, &k, &k, 2, .user);
    _ = try stream.capture(.remove, &k, null, &k, 3, .user);

    var res = try stream.read(testing.allocator, .trim_horizon, 10);
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), res.records.len);
    try testing.expectEqual(RecordKind.insert, res.records[0].kind);
    try testing.expectEqual(RecordKind.modify, res.records[1].kind);
    try testing.expectEqual(RecordKind.remove, res.records[2].kind);
    try testing.expectEqual(Stream.Position{ .after_seq = 3 }, res.next_position);
}

test "Stream: read AT_SEQ starts at that seq" {
    var stream = try Stream.init(testing.allocator, .new_and_old_images, "shard");
    defer stream.deinit();
    var k = try makeItem(testing.allocator, "id", "a");
    defer k.deinit(testing.allocator);
    _ = try stream.capture(.insert, &k, &k, null, 1, .user);
    _ = try stream.capture(.insert, &k, &k, null, 2, .user);
    _ = try stream.capture(.insert, &k, &k, null, 3, .user);

    var res = try stream.read(testing.allocator, .{ .at_seq = 2 }, 10);
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), res.records.len);
    try testing.expectEqual(@as(u64, 2), res.records[0].seq);
    try testing.expectEqual(@as(u64, 3), res.records[1].seq);
}

test "Stream: read AFTER_SEQ skips that seq" {
    var stream = try Stream.init(testing.allocator, .new_and_old_images, "shard");
    defer stream.deinit();
    var k = try makeItem(testing.allocator, "id", "a");
    defer k.deinit(testing.allocator);
    _ = try stream.capture(.insert, &k, &k, null, 1, .user);
    _ = try stream.capture(.insert, &k, &k, null, 2, .user);
    _ = try stream.capture(.insert, &k, &k, null, 3, .user);

    var res = try stream.read(testing.allocator, .{ .after_seq = 2 }, 10);
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), res.records.len);
    try testing.expectEqual(@as(u64, 3), res.records[0].seq);
}

test "Stream: read respects limit" {
    var stream = try Stream.init(testing.allocator, .new_and_old_images, "shard");
    defer stream.deinit();
    var k = try makeItem(testing.allocator, "id", "a");
    defer k.deinit(testing.allocator);
    _ = try stream.capture(.insert, &k, &k, null, 1, .user);
    _ = try stream.capture(.insert, &k, &k, null, 2, .user);
    _ = try stream.capture(.insert, &k, &k, null, 3, .user);

    var res = try stream.read(testing.allocator, .trim_horizon, 2);
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), res.records.len);
    try testing.expectEqual(Stream.Position{ .after_seq = 2 }, res.next_position);
}

test "Stream: trim drops records older than threshold" {
    var stream = try Stream.init(testing.allocator, .new_and_old_images, "shard");
    defer stream.deinit();
    var k = try makeItem(testing.allocator, "id", "a");
    defer k.deinit(testing.allocator);
    _ = try stream.capture(.insert, &k, &k, null, 100, .user);
    _ = try stream.capture(.insert, &k, &k, null, 200, .user);
    _ = try stream.capture(.insert, &k, &k, null, 300, .user);

    // Now insert at a time that pushes threshold past 200.
    _ = try stream.capture(.insert, &k, &k, null, 200 + retention_secs + 1, .user);
    // Only seq 3 + seq 4 remain (seq 1 & 2 were older than retention).
    try testing.expectEqual(@as(usize, 2), stream.records.items.len);
    try testing.expectEqual(@as(u64, 3), stream.records.items[0].seq);
}

test "formatShardId: shape" {
    const id = try formatShardId(testing.allocator, 1700000000);
    defer testing.allocator.free(id);
    try testing.expect(std.mem.startsWith(u8, id, "shardId-"));
    // "shardId-" (8) + 20 digits + "-" (1) + 8 hex = 37 total
    try testing.expectEqual(@as(usize, 37), id.len);
}
