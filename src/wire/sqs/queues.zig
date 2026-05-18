//! Wire parsers + renderers for SQS queue ops (v0.3.0).
//!
//! Modern SQS uses a JSON wire protocol (boto3 v1.34+, JS v3, CLI v2)
//! that mirrors DDB's shape. Request bodies are
//! `application/x-amz-json-1.0` and per-op type is selected via
//! `X-Amz-Target: AmazonSQS.<Op>`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const sqs_state = @import("../../storage/sqs_state.zig");

pub const ParseError = error{
    Malformed,
    InvalidQueueName,
    InvalidAttribute,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// CreateQueue

pub const CreateQueueRequest = struct {
    queue_name: []const u8,
    attrs: storage.QueueAttributes,
    /// Set when the client included a `FifoQueue` attribute (regardless
    /// of its value). The storage layer uses this to decide between
    /// "derive from name suffix" and "reject mismatch".
    fifo_attribute_specified: bool = false,
};

pub fn parseCreateQueue(allocator: Allocator, body: []const u8) ParseError!CreateQueueRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;

    const name_v = root.get("QueueName") orelse return ParseError.Malformed;
    if (name_v != .string) return ParseError.Malformed;
    sqs_state.validateQueueName(name_v.string) catch return ParseError.InvalidQueueName;
    const name = try allocator.dupe(u8, name_v.string);

    var attrs: storage.QueueAttributes = .{};
    var fifo_specified = false;
    if (root.get("Attributes")) |attrs_v| {
        if (attrs_v != .object) return ParseError.Malformed;
        try applyAttributes(allocator, attrs_v.object, &attrs, &fifo_specified);
    }
    return .{ .queue_name = name, .attrs = attrs, .fifo_attribute_specified = fifo_specified };
}

/// Apply a JSON object of `Attributes` onto a `QueueAttributes` value.
/// Used by both CreateQueue and SetQueueAttributes. Each known key is
/// parsed; unknown keys are silently dropped (matches AWS).
fn applyAttributes(allocator: Allocator, obj: std.json.ObjectMap, attrs: *storage.QueueAttributes, fifo_specified: *bool) ParseError!void {
    if (obj.get("VisibilityTimeout")) |v| attrs.visibility_timeout = try parseU32(v, 0, 43200);
    if (obj.get("DelaySeconds")) |v| attrs.delay_seconds = try parseU32(v, 0, 900);
    if (obj.get("ReceiveMessageWaitTimeSeconds")) |v| attrs.receive_message_wait_time_seconds = try parseU32(v, 0, 20);
    if (obj.get("MessageRetentionPeriod")) |v| attrs.message_retention_period = try parseU32(v, 60, 1_209_600);
    if (obj.get("MaximumMessageSize")) |v| attrs.maximum_message_size = try parseU32(v, 1024, 262_144);
    if (obj.get("RedrivePolicy")) |v| {
        if (v != .string) return ParseError.InvalidAttribute;
        if (attrs.redrive_policy) |old| allocator.free(old);
        attrs.redrive_policy = try allocator.dupe(u8, v.string);
    }
    if (obj.get("Policy")) |v| {
        if (v != .string) return ParseError.InvalidAttribute;
        if (attrs.policy) |old| allocator.free(old);
        attrs.policy = try allocator.dupe(u8, v.string);
    }
    if (obj.get("FifoQueue")) |v| {
        attrs.is_fifo = try parseBool(v);
        fifo_specified.* = true;
    }
    if (obj.get("ContentBasedDeduplication")) |v| {
        attrs.content_based_dedup = try parseBool(v);
    }
}

fn parseBool(v: std.json.Value) ParseError!bool {
    return switch (v) {
        .bool => |b| b,
        .string => |s| blk: {
            if (std.ascii.eqlIgnoreCase(s, "true")) break :blk true;
            if (std.ascii.eqlIgnoreCase(s, "false")) break :blk false;
            return ParseError.InvalidAttribute;
        },
        else => ParseError.InvalidAttribute,
    };
}

/// Attribute values arrive as JSON strings (AWS-real wire) OR integers
/// (some SDKs send them un-quoted). Accept both.
fn parseU32(v: std.json.Value, min: u32, max: u32) ParseError!u32 {
    const n: i64 = switch (v) {
        .integer => |x| x,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch return ParseError.InvalidAttribute,
        else => return ParseError.InvalidAttribute,
    };
    if (n < @as(i64, min) or n > @as(i64, max)) return ParseError.InvalidAttribute;
    return @intCast(n);
}

/// Render `{QueueUrl: "..."}`. Used by CreateQueue + GetQueueUrl.
pub fn renderQueueUrl(allocator: Allocator, base_url: []const u8, account_id: []const u8, queue_name: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("QueueUrl");
    try s.print("\"{s}/{s}/{s}\"", .{ base_url, account_id, queue_name });
    try s.endObject();
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// DeleteQueue / GetQueueUrl / PurgeQueue all take just QueueUrl (or
// QueueName for GetQueueUrl).

pub fn parseQueueUrlOrName(allocator: Allocator, body: []const u8) ParseError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    if (parsed.value.object.get("QueueUrl")) |v| {
        if (v != .string) return ParseError.Malformed;
        return try allocator.dupe(u8, queueNameFromUrl(v.string));
    }
    if (parsed.value.object.get("QueueName")) |v| {
        if (v != .string) return ParseError.Malformed;
        return try allocator.dupe(u8, v.string);
    }
    return ParseError.Malformed;
}

/// Extract the trailing queue-name segment from a QueueUrl of the form
/// `http://host:port/<account>/<name>`. If the input doesn't match,
/// return it verbatim — that's the "use the URL as a name" fallback.
pub fn queueNameFromUrl(url: []const u8) []const u8 {
    const last_slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return url;
    return url[last_slash + 1 ..];
}

// ---------------------------------------------------------------------------
// ListQueues

pub const ListQueuesRequest = struct {
    name_prefix: ?[]const u8 = null,
    max_results: ?u32 = null,
    next_token: ?[]const u8 = null,
};

pub fn parseListQueues(allocator: Allocator, body: []const u8) ParseError!ListQueuesRequest {
    if (body.len == 0) return .{};
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;

    var req: ListQueuesRequest = .{};
    if (root.get("QueueNamePrefix")) |v| {
        if (v != .string) return ParseError.Malformed;
        req.name_prefix = try allocator.dupe(u8, v.string);
    }
    if (root.get("MaxResults")) |v| switch (v) {
        .integer => |n| {
            if (n < 1 or n > 1000) return ParseError.Malformed;
            req.max_results = @intCast(n);
        },
        else => return ParseError.Malformed,
    };
    if (root.get("NextToken")) |v| {
        if (v != .string) return ParseError.Malformed;
        req.next_token = try allocator.dupe(u8, v.string);
    }
    return req;
}

pub fn renderListQueues(
    allocator: Allocator,
    base_url: []const u8,
    account_id: []const u8,
    out: storage.ListQueuesOutput,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("QueueUrls");
    try s.beginArray();
    for (out.queue_names) |n| {
        var buf: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{ base_url, account_id, n });
        try s.write(url);
    }
    try s.endArray();
    if (out.next_token) |tok| {
        try s.objectField("NextToken");
        try s.write(tok);
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// GetQueueAttributes

pub const GetQueueAttributesRequest = struct {
    queue_name: []const u8,
    /// Slice of attribute names the caller wants. Empty = all.
    attribute_names: []const []const u8,
};

pub fn parseGetQueueAttributes(allocator: Allocator, body: []const u8) ParseError!GetQueueAttributesRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    const url_v = root.get("QueueUrl") orelse return ParseError.Malformed;
    if (url_v != .string) return ParseError.Malformed;
    const name = try allocator.dupe(u8, queueNameFromUrl(url_v.string));

    var attr_names: std.ArrayList([]const u8) = .empty;
    if (root.get("AttributeNames")) |v| {
        if (v != .array) return ParseError.Malformed;
        for (v.array.items) |entry| {
            if (entry != .string) return ParseError.Malformed;
            try attr_names.append(allocator, try allocator.dupe(u8, entry.string));
        }
    }
    return .{
        .queue_name = name,
        .attribute_names = try attr_names.toOwnedSlice(allocator),
    };
}

pub fn renderGetQueueAttributes(
    allocator: Allocator,
    attrs: storage.QueueAttributes,
    queue_name: []const u8,
    account_id: []const u8,
    requested: []const []const u8,
    created_unix: i64,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("Attributes");
    try s.beginObject();
    if (requestedHas(requested, "All") or requested.len == 0 or requestedHas(requested, "VisibilityTimeout")) {
        try s.objectField("VisibilityTimeout");
        try writeUint(&s, attrs.visibility_timeout);
    }
    if (requestedHas(requested, "All") or requested.len == 0 or requestedHas(requested, "DelaySeconds")) {
        try s.objectField("DelaySeconds");
        try writeUint(&s, attrs.delay_seconds);
    }
    if (requestedHas(requested, "All") or requested.len == 0 or requestedHas(requested, "ReceiveMessageWaitTimeSeconds")) {
        try s.objectField("ReceiveMessageWaitTimeSeconds");
        try writeUint(&s, attrs.receive_message_wait_time_seconds);
    }
    if (requestedHas(requested, "All") or requested.len == 0 or requestedHas(requested, "MessageRetentionPeriod")) {
        try s.objectField("MessageRetentionPeriod");
        try writeUint(&s, attrs.message_retention_period);
    }
    if (requestedHas(requested, "All") or requested.len == 0 or requestedHas(requested, "MaximumMessageSize")) {
        try s.objectField("MaximumMessageSize");
        try writeUint(&s, attrs.maximum_message_size);
    }
    if (attrs.redrive_policy) |p| if (requestedHas(requested, "All") or requested.len == 0 or requestedHas(requested, "RedrivePolicy")) {
        try s.objectField("RedrivePolicy");
        try s.write(p);
    };
    if (attrs.policy) |p| if (requestedHas(requested, "All") or requested.len == 0 or requestedHas(requested, "Policy")) {
        try s.objectField("Policy");
        try s.write(p);
    };
    if (requestedHas(requested, "All") or requested.len == 0 or requestedHas(requested, "QueueArn")) {
        try s.objectField("QueueArn");
        var buf: [256]u8 = undefined;
        const arn = try std.fmt.bufPrint(&buf, "arn:aws:sqs:us-east-1:{s}:{s}", .{ account_id, queue_name });
        try s.write(arn);
    }
    if (requestedHas(requested, "All") or requested.len == 0 or requestedHas(requested, "CreatedTimestamp")) {
        try s.objectField("CreatedTimestamp");
        try writeI64Stringy(&s, created_unix);
    }
    if (attrs.is_fifo) {
        // AWS only emits these on FIFO queues — Standard queues omit
        // them entirely.
        if (requestedHas(requested, "All") or requested.len == 0 or requestedHas(requested, "FifoQueue")) {
            try s.objectField("FifoQueue");
            try s.write("true");
        }
        if (requestedHas(requested, "All") or requested.len == 0 or requestedHas(requested, "ContentBasedDeduplication")) {
            try s.objectField("ContentBasedDeduplication");
            try s.write(if (attrs.content_based_dedup) "true" else "false");
        }
    }
    try s.endObject();
    try s.endObject();
    return aw.toOwnedSlice();
}

fn writeUint(s: *std.json.Stringify, v: u32) !void {
    // AWS-real serialises attribute values as strings.
    var buf: [16]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "{d}", .{v});
    try s.write(out);
}

fn writeI64Stringy(s: *std.json.Stringify, v: i64) !void {
    var buf: [32]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "{d}", .{v});
    try s.write(out);
}

fn requestedHas(requested: []const []const u8, name: []const u8) bool {
    for (requested) |r| if (std.mem.eql(u8, r, name)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// MessageMoveTask trio (v0.3.2)

pub const StartMessageMoveTaskRequest = struct {
    source_arn: []const u8,
    destination_arn: ?[]const u8,
    max_per_second: ?u32,
};

pub fn parseStartMessageMoveTask(allocator: Allocator, body: []const u8) ParseError!StartMessageMoveTaskRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    const src_v = root.get("SourceArn") orelse return ParseError.Malformed;
    if (src_v != .string) return ParseError.Malformed;
    var dst: ?[]const u8 = null;
    if (root.get("DestinationArn")) |v| {
        if (v != .string) return ParseError.Malformed;
        dst = try allocator.dupe(u8, v.string);
    }
    var mps: ?u32 = null;
    if (root.get("MaxNumberOfMessagesPerSecond")) |v| switch (v) {
        .integer => |n| if (n > 0 and n <= 500) {
            mps = @intCast(n);
        } else return ParseError.InvalidAttribute,
        .string => |s| {
            const n = std.fmt.parseInt(u32, s, 10) catch return ParseError.InvalidAttribute;
            if (n == 0 or n > 500) return ParseError.InvalidAttribute;
            mps = n;
        },
        else => return ParseError.Malformed,
    };
    return .{
        .source_arn = try allocator.dupe(u8, src_v.string),
        .destination_arn = dst,
        .max_per_second = mps,
    };
}

pub fn renderStartMessageMoveTask(allocator: Allocator, task_handle: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("TaskHandle");
    try s.write(task_handle);
    try s.endObject();
    return aw.toOwnedSlice();
}

pub fn parseCancelMessageMoveTask(allocator: Allocator, body: []const u8) ParseError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const v = parsed.value.object.get("TaskHandle") orelse return ParseError.Malformed;
    if (v != .string) return ParseError.Malformed;
    return try allocator.dupe(u8, v.string);
}

pub fn renderCancelMessageMoveTask(allocator: Allocator, count: u64) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("ApproximateNumberOfMessagesMoved");
    try s.write(count);
    try s.endObject();
    return aw.toOwnedSlice();
}

pub const ListMessageMoveTasksWireRequest = struct {
    source_arn: []const u8,
    max_results: ?u32,
};

pub fn parseListMessageMoveTasks(allocator: Allocator, body: []const u8) ParseError!ListMessageMoveTasksWireRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    const src_v = root.get("SourceArn") orelse return ParseError.Malformed;
    if (src_v != .string) return ParseError.Malformed;
    var maxr: ?u32 = null;
    if (root.get("MaxResults")) |v| switch (v) {
        .integer => |n| if (n >= 1 and n <= 10) {
            maxr = @intCast(n);
        } else return ParseError.InvalidAttribute,
        else => return ParseError.Malformed,
    };
    return .{
        .source_arn = try allocator.dupe(u8, src_v.string),
        .max_results = maxr,
    };
}

pub fn renderListMessageMoveTasks(allocator: Allocator, out: storage.ListMessageMoveTasksOutput) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("Results");
    try s.beginArray();
    for (out.tasks) |t| {
        try s.beginObject();
        try s.objectField("TaskHandle");
        try s.write(t.task_handle);
        try s.objectField("SourceArn");
        try s.write(t.source_arn);
        try s.objectField("DestinationArn");
        try s.write(t.destination_arn);
        try s.objectField("Status");
        try s.write(t.status);
        try s.objectField("ApproximateNumberOfMessagesToMove");
        try s.write(t.approximate_messages_to_move);
        try s.objectField("ApproximateNumberOfMessagesMoved");
        try s.write(t.approximate_messages_moved);
        try s.objectField("StartedTimestamp");
        try s.write(t.started_unix);
        if (t.failure_reason) |fr| {
            try s.objectField("FailureReason");
            try s.write(fr);
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// AddPermission / RemovePermission (v0.3.2)

pub const AddPermissionRequest = struct {
    queue_name: []const u8,
    label: []const u8,
    aws_account_ids: []const []const u8,
    /// Action names from the wire — without the `sqs:` prefix. Caller
    /// adds the prefix before passing to storage.
    actions: []const []const u8,
};

pub fn parseAddPermission(allocator: Allocator, body: []const u8) ParseError!AddPermissionRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;

    const url_v = root.get("QueueUrl") orelse return ParseError.Malformed;
    if (url_v != .string) return ParseError.Malformed;
    const name = try allocator.dupe(u8, queueNameFromUrl(url_v.string));

    const label_v = root.get("Label") orelse return ParseError.Malformed;
    if (label_v != .string or label_v.string.len == 0) return ParseError.Malformed;
    const label = try allocator.dupe(u8, label_v.string);

    const accts_v = root.get("AWSAccountIds") orelse return ParseError.Malformed;
    if (accts_v != .array or accts_v.array.items.len == 0) return ParseError.Malformed;
    const accts = try allocator.alloc([]const u8, accts_v.array.items.len);
    for (accts_v.array.items, 0..) |entry, i| {
        if (entry != .string) return ParseError.Malformed;
        accts[i] = try allocator.dupe(u8, entry.string);
    }

    const actions_v = root.get("Actions") orelse return ParseError.Malformed;
    if (actions_v != .array or actions_v.array.items.len == 0) return ParseError.Malformed;
    const actions = try allocator.alloc([]const u8, actions_v.array.items.len);
    for (actions_v.array.items, 0..) |entry, i| {
        if (entry != .string) return ParseError.Malformed;
        actions[i] = try allocator.dupe(u8, entry.string);
    }

    return .{
        .queue_name = name,
        .label = label,
        .aws_account_ids = accts,
        .actions = actions,
    };
}

pub const RemovePermissionRequest = struct {
    queue_name: []const u8,
    label: []const u8,
};

pub fn parseRemovePermission(allocator: Allocator, body: []const u8) ParseError!RemovePermissionRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    const url_v = root.get("QueueUrl") orelse return ParseError.Malformed;
    if (url_v != .string) return ParseError.Malformed;
    const label_v = root.get("Label") orelse return ParseError.Malformed;
    if (label_v != .string or label_v.string.len == 0) return ParseError.Malformed;
    return .{
        .queue_name = try allocator.dupe(u8, queueNameFromUrl(url_v.string)),
        .label = try allocator.dupe(u8, label_v.string),
    };
}

// ---------------------------------------------------------------------------
// ListDeadLetterSourceQueues (v0.3.2)

/// Returns the DLQ's queue name. Both input shapes (`QueueUrl` —
/// what the modern SDKs send — and `QueueName`) are accepted.
pub fn parseListDeadLetterSourceQueues(allocator: Allocator, body: []const u8) ParseError![]const u8 {
    return parseQueueUrlOrName(allocator, body);
}

pub fn renderListDeadLetterSourceQueues(
    allocator: Allocator,
    base_url: []const u8,
    account_id: []const u8,
    out: storage.ListDeadLetterSourceQueuesOutput,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    // AWS uses uppercase `QueueUrls` here, matching ListQueues. (Some
    // older docs render it lowercase; modern SDKs accept both.)
    try s.objectField("queueUrls");
    try s.beginArray();
    for (out.queue_names) |n| {
        var buf: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{ base_url, account_id, n });
        try s.write(url);
    }
    try s.endArray();
    try s.endObject();
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// SetQueueAttributes

pub const SetQueueAttributesRequest = struct {
    queue_name: []const u8,
    attrs: storage.PartialAttributes,
};

pub fn parseSetQueueAttributes(allocator: Allocator, body: []const u8) ParseError!SetQueueAttributesRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    const url_v = root.get("QueueUrl") orelse return ParseError.Malformed;
    if (url_v != .string) return ParseError.Malformed;
    const name = try allocator.dupe(u8, queueNameFromUrl(url_v.string));

    var partial: storage.PartialAttributes = .{};
    const attrs_v = root.get("Attributes") orelse return ParseError.Malformed;
    if (attrs_v != .object) return ParseError.Malformed;
    if (attrs_v.object.get("VisibilityTimeout")) |v| partial.visibility_timeout = try parseU32(v, 0, 43200);
    if (attrs_v.object.get("DelaySeconds")) |v| partial.delay_seconds = try parseU32(v, 0, 900);
    if (attrs_v.object.get("ReceiveMessageWaitTimeSeconds")) |v| partial.receive_message_wait_time_seconds = try parseU32(v, 0, 20);
    if (attrs_v.object.get("MessageRetentionPeriod")) |v| partial.message_retention_period = try parseU32(v, 60, 1_209_600);
    if (attrs_v.object.get("MaximumMessageSize")) |v| partial.maximum_message_size = try parseU32(v, 1024, 262_144);
    if (attrs_v.object.get("RedrivePolicy")) |v| {
        if (v != .string) return ParseError.InvalidAttribute;
        partial.redrive_policy = try allocator.dupe(u8, v.string);
    }
    if (attrs_v.object.get("Policy")) |v| {
        if (v != .string) return ParseError.InvalidAttribute;
        partial.policy = try allocator.dupe(u8, v.string);
    }
    if (attrs_v.object.get("FifoQueue")) |_| {
        // FifoQueue is immutable post-creation. Surface the attempt so
        // the storage layer can return InvalidAttributeValue.
        partial.fifo_attribute_specified = true;
    }
    if (attrs_v.object.get("ContentBasedDeduplication")) |v| {
        partial.content_based_dedup = try parseBool(v);
    }
    return .{ .queue_name = name, .attrs = partial };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parseCreateQueue: name only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try parseCreateQueue(arena.allocator(),
        \\{"QueueName":"orders"}
    );
    try testing.expectEqualStrings("orders", r.queue_name);
    try testing.expectEqual(@as(u32, 30), r.attrs.visibility_timeout);
}

test "parseCreateQueue: with attributes (string-encoded ints)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try parseCreateQueue(arena.allocator(),
        \\{"QueueName":"orders","Attributes":{"VisibilityTimeout":"60","DelaySeconds":"5"}}
    );
    try testing.expectEqual(@as(u32, 60), r.attrs.visibility_timeout);
    try testing.expectEqual(@as(u32, 5), r.attrs.delay_seconds);
}

test "parseCreateQueue: rejects bad queue name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ParseError.InvalidQueueName, parseCreateQueue(arena.allocator(),
        \\{"QueueName":"has space"}
    ));
}

test "queueNameFromUrl: extracts trailing segment" {
    try testing.expectEqualStrings("orders", queueNameFromUrl("http://127.0.0.1:4566/000000000000/orders"));
    try testing.expectEqualStrings("orders", queueNameFromUrl("orders"));
}

test "parseQueueUrlOrName: accepts QueueUrl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const name = try parseQueueUrlOrName(arena.allocator(),
        \\{"QueueUrl":"http://h/000000000000/orders"}
    );
    try testing.expectEqualStrings("orders", name);
}

test "parseListQueues: empty body → defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try parseListQueues(arena.allocator(), "");
    try testing.expect(r.name_prefix == null);
    try testing.expect(r.max_results == null);
}

test "parseListQueues: with prefix + max_results" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try parseListQueues(arena.allocator(),
        \\{"QueueNamePrefix":"o","MaxResults":5}
    );
    try testing.expectEqualStrings("o", r.name_prefix.?);
    try testing.expectEqual(@as(u32, 5), r.max_results.?);
}
