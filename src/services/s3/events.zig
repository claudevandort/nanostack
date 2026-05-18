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
/// Errors during dispatch are logged + swallowed.
pub fn dispatchObjectCreated(ctx: mod.Context, bucket: []const u8, meta: ObjectCreatedMeta) void {
    dispatchInternal(ctx, bucket, .{
        .event_name = meta.event_name,
        .key = meta.key,
        .size = meta.size,
        .etag = meta.etag,
        .version_id = meta.version_id,
    });
}

/// Fire `s3:ObjectRemoved:*` events. Same fire-and-forget semantics.
pub fn dispatchObjectRemoved(ctx: mod.Context, bucket: []const u8, meta: ObjectRemovedMeta) void {
    const event_name: []const u8 = if (meta.delete_marker)
        "s3:ObjectRemoved:DeleteMarkerCreated"
    else
        "s3:ObjectRemoved:Delete";
    dispatchInternal(ctx, bucket, .{
        .event_name = event_name,
        .key = meta.key,
        .size = 0,
        .etag = "",
        .version_id = meta.version_id,
    });
}

const InternalDispatch = struct {
    event_name: []const u8,
    key: []const u8,
    size: u64,
    etag: []const u8,
    version_id: ?[]const u8,
};

fn dispatchInternal(ctx: mod.Context, bucket: []const u8, d: InternalDispatch) void {
    // Short-circuit when SQS isn't enabled — common case for S3-only deployments.
    const sqs = ctx.sqs_backend orelse return;

    // Fetch the notification config (per-request arena allocation —
    // freed when the request ends).
    const cfg = ctx.backend.getBucketNotification(ctx.allocator, bucket) catch return;
    if (cfg.entries.len == 0) return;

    for (cfg.entries) |entry| {
        // SNS / Lambda targets aren't supported yet — accept-store-roundtrip only.
        if (entry.target != .queue) continue;

        // Event match: walk entry.events, look for an exact or wildcard match.
        if (!eventListMatches(entry.events, d.event_name)) continue;

        // Filter match: prefix + suffix rules AND together.
        if (!filterMatches(entry.filter, d.key)) continue;

        const queue_name = extractQueueName(entry.arn) orelse {
            std.log.warn("s3 events: skipping malformed queue ARN {s}", .{entry.arn});
            continue;
        };

        // Confirm the queue actually exists; AWS would drop on a stale
        // ARN with no log, but we surface a warning for local-dev.
        _ = sqs.getQueueUrl(queue_name) catch {
            std.log.warn("s3 events: target queue {s} does not exist, dropping {s} event", .{ queue_name, d.event_name });
            continue;
        };

        const body = buildEnvelope(ctx.allocator, .{
            .region = ctx.region,
            .owner_id = ctx.owner_id,
            .bucket = bucket,
            .event_name = d.event_name,
            .configuration_id = entry.id,
            .key = d.key,
            .size = d.size,
            .etag = d.etag,
            .version_id = d.version_id,
        }) catch |err| {
            std.log.warn("s3 events: envelope build failed: {s}", .{@errorName(err)});
            continue;
        };

        const send_out = sqs.sendMessage(ctx.allocator, .{
            .queue_name = queue_name,
            .body = body,
        }) catch |err| {
            std.log.warn("s3 events: SendMessage to {s} failed: {s}", .{ queue_name, @errorName(err) });
            continue;
        };
        // Send succeeded; the message id is owned by the per-request arena.
        _ = send_out;
    }
}

/// Match an event name against the list of configured event filters.
/// Supports exact match + wildcard suffixes:
///   "s3:ObjectCreated:*" matches every s3:ObjectCreated:Foo
///   "s3:ObjectRemoved:*" matches every s3:ObjectRemoved:Foo
///   "s3:*"               matches every s3:* event
fn eventListMatches(filters: []const storage.S3EventName, actual: []const u8) bool {
    for (filters) |e| {
        const fstr = storage.s3EventToString(e);
        if (eventMatches(fstr, actual)) return true;
    }
    return false;
}

pub fn eventMatches(filter: []const u8, actual: []const u8) bool {
    if (std.mem.eql(u8, filter, actual)) return true;
    // Wildcard `s3:*` matches anything starting with "s3:".
    if (std.mem.eql(u8, filter, "s3:*")) {
        return std.mem.startsWith(u8, actual, "s3:");
    }
    // Wildcard `<prefix>:*` (one level): match `<prefix>:` then anything.
    if (std.mem.endsWith(u8, filter, ":*")) {
        const prefix = filter[0 .. filter.len - 1]; // includes the trailing ':'
        return std.mem.startsWith(u8, actual, prefix);
    }
    return false;
}

pub fn filterMatches(filter: ?storage.NotificationFilter, key: []const u8) bool {
    const f = filter orelse return true;
    for (f.filter_rules) |rule| {
        if (std.ascii.eqlIgnoreCase(rule.name, "prefix")) {
            if (!std.mem.startsWith(u8, key, rule.value)) return false;
        } else if (std.ascii.eqlIgnoreCase(rule.name, "suffix")) {
            if (!std.mem.endsWith(u8, key, rule.value)) return false;
        }
        // Unknown rule names: ignore (AWS-strict would reject, but
        // putBucketNotification already validates at parse time).
    }
    return true;
}

/// Extract the queue name from an SQS ARN. Returns null if the ARN
/// doesn't have the `arn:aws:sqs:` prefix or has no trailing segment.
pub fn extractQueueName(arn: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arn, "arn:aws:sqs:")) return null;
    const last_colon = std.mem.lastIndexOfScalar(u8, arn, ':') orelse return null;
    if (last_colon + 1 >= arn.len) return null;
    return arn[last_colon + 1 ..];
}

const EnvelopeArgs = struct {
    region: []const u8,
    owner_id: []const u8,
    bucket: []const u8,
    event_name: []const u8,
    configuration_id: []const u8,
    key: []const u8,
    size: u64,
    etag: []const u8,
    version_id: ?[]const u8,
};

/// Build the AWS-format S3 event envelope JSON. Caller owns the
/// returned slice (allocator should be the per-request arena).
pub fn buildEnvelope(allocator: Allocator, args: EnvelopeArgs) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("Records");
    try s.beginArray();

    try s.beginObject();
    try s.objectField("eventVersion");
    try s.write("2.1");
    try s.objectField("eventSource");
    try s.write("aws:s3");
    try s.objectField("awsRegion");
    try s.write(args.region);
    try s.objectField("eventTime");
    var time_buf: [40]u8 = undefined;
    const time_str = isoNowUtc(&time_buf);
    try s.write(time_str);
    try s.objectField("eventName");
    try s.write(args.event_name);

    try s.objectField("userIdentity");
    try s.beginObject();
    try s.objectField("principalId");
    try s.write(args.owner_id);
    try s.endObject();

    try s.objectField("requestParameters");
    try s.beginObject();
    try s.objectField("sourceIPAddress");
    try s.write("127.0.0.1");
    try s.endObject();

    try s.objectField("responseElements");
    try s.beginObject();
    try s.objectField("x-amz-request-id");
    var rid_buf: [32]u8 = undefined;
    try s.write(mintHexId(&rid_buf, 16));
    try s.objectField("x-amz-id-2");
    var id2_buf: [64]u8 = undefined;
    try s.write(mintHexId(&id2_buf, 32));
    try s.endObject();

    try s.objectField("s3");
    try s.beginObject();
    try s.objectField("s3SchemaVersion");
    try s.write("1.0");
    try s.objectField("configurationId");
    try s.write(args.configuration_id);

    try s.objectField("bucket");
    try s.beginObject();
    try s.objectField("name");
    try s.write(args.bucket);
    try s.objectField("ownerIdentity");
    try s.beginObject();
    try s.objectField("principalId");
    try s.write(args.owner_id);
    try s.endObject();
    try s.objectField("arn");
    var arn_buf: [256]u8 = undefined;
    const arn = try std.fmt.bufPrint(&arn_buf, "arn:aws:s3:::{s}", .{args.bucket});
    try s.write(arn);
    try s.endObject();

    try s.objectField("object");
    try s.beginObject();
    try s.objectField("key");
    try s.write(args.key);
    try s.objectField("size");
    try s.write(args.size);
    try s.objectField("eTag");
    try s.write(args.etag);
    if (args.version_id) |v| {
        try s.objectField("versionId");
        try s.write(v);
    }
    try s.objectField("sequencer");
    var seq_buf: [32]u8 = undefined;
    try s.write(mintHexId(&seq_buf, 16));
    try s.endObject();

    try s.endObject(); // s3
    try s.endObject(); // record

    try s.endArray();
    try s.endObject(); // root

    return aw.toOwnedSlice();
}

/// Render the current UTC time as `YYYY-MM-DDTHH:MM:SS.mmmZ`. Uses the
/// nanostack clock so tests run deterministically when the clock is
/// mocked (currently it isn't).
fn isoNowUtc(buf: *[40]u8) []const u8 {
    const now_ns = std.time.nanoTimestamp();
    const total_secs: i64 = @intCast(@divFloor(now_ns, std.time.ns_per_s));
    const millis: u32 = @intCast(@divFloor(@mod(now_ns, std.time.ns_per_s), std.time.ns_per_ms));
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(total_secs) };
    const day_secs = epoch.getDaySeconds();
    const epoch_day = epoch.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        @as(u32, year_day.year),
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
        millis,
    }) catch buf[0..];
}

/// Mint a fresh hex id of length `width` bytes (2*width hex chars).
/// Uses nanosecond timestamp + a small counter so consecutive calls
/// within the same nanosecond don't collide.
var id_counter: std.atomic.Value(u64) = .init(0);

fn mintHexId(buf: []u8, width: usize) []const u8 {
    std.debug.assert(buf.len >= width * 2);
    const ns: u128 = @intCast(std.time.nanoTimestamp());
    const n: u64 = id_counter.fetchAdd(1, .monotonic);
    var raw: [32]u8 = undefined;
    // First 16 bytes from the nanosecond timestamp.
    std.mem.writeInt(u128, raw[0..16], ns, .big);
    // Next 8 bytes from the per-process counter (helps disambiguate
    // within the same nanosecond).
    std.mem.writeInt(u64, raw[16..24], n, .big);
    // Remaining 8 bytes: zero (kept for any future extension).
    @memset(raw[24..32], 0);
    const w = @min(width, raw.len);
    return std.fmt.bytesToHex(raw[0..w], .lower)[0 .. w * 2] catch unreachable;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "eventMatches: exact" {
    try testing.expect(eventMatches("s3:ObjectCreated:Put", "s3:ObjectCreated:Put"));
    try testing.expect(!eventMatches("s3:ObjectCreated:Put", "s3:ObjectCreated:Copy"));
}

test "eventMatches: one-level wildcard" {
    try testing.expect(eventMatches("s3:ObjectCreated:*", "s3:ObjectCreated:Put"));
    try testing.expect(eventMatches("s3:ObjectCreated:*", "s3:ObjectCreated:Copy"));
    try testing.expect(eventMatches("s3:ObjectCreated:*", "s3:ObjectCreated:CompleteMultipartUpload"));
    try testing.expect(!eventMatches("s3:ObjectCreated:*", "s3:ObjectRemoved:Delete"));
    try testing.expect(eventMatches("s3:ObjectRemoved:*", "s3:ObjectRemoved:Delete"));
}

test "eventMatches: top-level wildcard" {
    try testing.expect(eventMatches("s3:*", "s3:ObjectCreated:Put"));
    try testing.expect(eventMatches("s3:*", "s3:ObjectRemoved:Delete"));
    try testing.expect(!eventMatches("s3:*", "sqs:SendMessage"));
}

test "filterMatches: no filter" {
    try testing.expect(filterMatches(null, "any/key"));
}

test "filterMatches: prefix only" {
    const f: storage.NotificationFilter = .{
        .filter_rules = &.{.{ .name = "prefix", .value = "images/" }},
    };
    try testing.expect(filterMatches(f, "images/cat.jpg"));
    try testing.expect(!filterMatches(f, "docs/readme.md"));
}

test "filterMatches: suffix only" {
    const f: storage.NotificationFilter = .{
        .filter_rules = &.{.{ .name = "suffix", .value = ".jpg" }},
    };
    try testing.expect(filterMatches(f, "any/file.jpg"));
    try testing.expect(!filterMatches(f, "any/file.png"));
}

test "filterMatches: prefix AND suffix" {
    const f: storage.NotificationFilter = .{
        .filter_rules = &.{
            .{ .name = "prefix", .value = "images/" },
            .{ .name = "suffix", .value = ".jpg" },
        },
    };
    try testing.expect(filterMatches(f, "images/cat.jpg"));
    try testing.expect(!filterMatches(f, "images/cat.png"));
    try testing.expect(!filterMatches(f, "docs/cat.jpg"));
}

test "extractQueueName: valid ARN" {
    try testing.expectEqualStrings("uploads", extractQueueName("arn:aws:sqs:us-east-1:000000000000:uploads").?);
}

test "extractQueueName: rejects non-sqs ARN" {
    try testing.expect(extractQueueName("arn:aws:sns:us-east-1:000000000000:topic") == null);
}

test "extractQueueName: rejects trailing colon" {
    try testing.expect(extractQueueName("arn:aws:sqs:us-east-1:000000000000:") == null);
}
