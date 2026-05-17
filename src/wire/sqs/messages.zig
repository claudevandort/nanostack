//! SQS message ops wire layer (v0.3.0 Phase 2).
//!
//! SendMessage / ReceiveMessage / DeleteMessage / ChangeMessageVisibility.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const queues_wire = @import("queues.zig");

pub const ParseError = queues_wire.ParseError;

// ---------------------------------------------------------------------------
// SendMessage

pub const SendMessageRequest = struct {
    queue_name: []const u8,
    body: []const u8,
    delay_seconds: ?u32 = null,
    raw_attributes_json: ?[]const u8 = null,
    message_group_id: ?[]const u8 = null,
    message_deduplication_id: ?[]const u8 = null,
    /// True when the client provided a DelaySeconds field. Used by the
    /// handler to distinguish "missing" (allowed on FIFO) from "set to 0"
    /// (also allowed) from "set to >0" (rejected on FIFO).
    delay_seconds_specified: bool = false,
};

pub fn parseSendMessage(allocator: Allocator, body: []const u8) ParseError!SendMessageRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;

    const url_v = root.get("QueueUrl") orelse return ParseError.Malformed;
    const body_v = root.get("MessageBody") orelse return ParseError.Malformed;
    if (url_v != .string or body_v != .string) return ParseError.Malformed;

    var delay: ?u32 = null;
    var delay_specified = false;
    if (root.get("DelaySeconds")) |v| switch (v) {
        .integer => |n| {
            if (n < 0 or n > 900) return ParseError.InvalidAttribute;
            delay = @intCast(n);
            delay_specified = true;
        },
        .string => |s| {
            const n = std.fmt.parseInt(i64, s, 10) catch return ParseError.InvalidAttribute;
            if (n < 0 or n > 900) return ParseError.InvalidAttribute;
            delay = @intCast(n);
            delay_specified = true;
        },
        else => return ParseError.Malformed,
    };

    // We round-trip MessageAttributes verbatim — re-serialize the
    // value to a JSON string so it persists across ReceiveMessage.
    var attrs_json: ?[]const u8 = null;
    if (root.get("MessageAttributes")) |v| {
        if (v != .object) return ParseError.Malformed;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        std.json.Stringify.value(v, .{}, &aw.writer) catch return ParseError.OutOfMemory;
        attrs_json = aw.toOwnedSlice() catch return ParseError.OutOfMemory;
    }

    var group_id: ?[]const u8 = null;
    if (root.get("MessageGroupId")) |v| {
        if (v != .string) return ParseError.Malformed;
        group_id = try allocator.dupe(u8, v.string);
    }
    var dedup_id: ?[]const u8 = null;
    if (root.get("MessageDeduplicationId")) |v| {
        if (v != .string) return ParseError.Malformed;
        dedup_id = try allocator.dupe(u8, v.string);
    }

    return .{
        .queue_name = try allocator.dupe(u8, queues_wire.queueNameFromUrl(url_v.string)),
        .body = try allocator.dupe(u8, body_v.string),
        .delay_seconds = delay,
        .delay_seconds_specified = delay_specified,
        .raw_attributes_json = attrs_json,
        .message_group_id = group_id,
        .message_deduplication_id = dedup_id,
    };
}

pub fn renderSendMessage(allocator: Allocator, out: storage.SendMessageOutput) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("MessageId");
    try s.write(out.message_id);
    try s.objectField("MD5OfMessageBody");
    try s.write(out.md5_of_body);
    if (out.sequence_number) |seq| {
        try s.objectField("SequenceNumber");
        var buf: [40]u8 = undefined;
        const txt = try std.fmt.bufPrint(&buf, "{d:0>20}", .{seq});
        try s.write(txt);
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// ReceiveMessage

pub const ReceiveMessageRequest = struct {
    queue_name: []const u8,
    max_messages: u32 = 1,
    visibility_timeout: ?u32 = null,
    wait_time_seconds: u32 = 0,
};

pub fn parseReceiveMessage(allocator: Allocator, body: []const u8) ParseError!ReceiveMessageRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    const url_v = root.get("QueueUrl") orelse return ParseError.Malformed;
    if (url_v != .string) return ParseError.Malformed;

    var req: ReceiveMessageRequest = .{
        .queue_name = try allocator.dupe(u8, queues_wire.queueNameFromUrl(url_v.string)),
    };
    if (root.get("MaxNumberOfMessages")) |v| switch (v) {
        .integer => |n| {
            if (n < 1 or n > 10) return ParseError.InvalidAttribute;
            req.max_messages = @intCast(n);
        },
        else => return ParseError.Malformed,
    };
    if (root.get("VisibilityTimeout")) |v| switch (v) {
        .integer => |n| {
            if (n < 0 or n > 43200) return ParseError.InvalidAttribute;
            req.visibility_timeout = @intCast(n);
        },
        else => return ParseError.Malformed,
    };
    if (root.get("WaitTimeSeconds")) |v| switch (v) {
        .integer => |n| {
            if (n < 0 or n > 20) return ParseError.InvalidAttribute;
            req.wait_time_seconds = @intCast(n);
        },
        else => return ParseError.Malformed,
    };
    return req;
}

pub fn renderReceiveMessage(allocator: Allocator, out: storage.ReceiveMessageOutput) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    if (out.messages.len > 0) {
        try s.objectField("Messages");
        try s.beginArray();
        for (out.messages) |m| {
            try s.beginObject();
            try s.objectField("MessageId");
            try s.write(m.message_id);
            try s.objectField("ReceiptHandle");
            try s.write(m.receipt_handle);
            try s.objectField("Body");
            try s.write(m.body);
            try s.objectField("MD5OfBody");
            try s.write(m.md5_of_body);
            if (m.raw_attributes_json) |attrs| {
                try s.objectField("MessageAttributes");
                // Parse + re-render to embed without breaking the
                // stringifier's internal state.
                var attrs_parsed = std.json.parseFromSlice(std.json.Value, allocator, attrs, .{}) catch {
                    try s.beginObject();
                    try s.endObject();
                    continue;
                };
                defer attrs_parsed.deinit();
                try s.write(attrs_parsed.value);
            }
            try s.endObject();
        }
        try s.endArray();
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// DeleteMessage

pub const DeleteMessageRequest = struct {
    queue_name: []const u8,
    receipt_handle: []const u8,
};

pub fn parseDeleteMessage(allocator: Allocator, body: []const u8) ParseError!DeleteMessageRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    const url_v = root.get("QueueUrl") orelse return ParseError.Malformed;
    const handle_v = root.get("ReceiptHandle") orelse return ParseError.Malformed;
    if (url_v != .string or handle_v != .string) return ParseError.Malformed;
    return .{
        .queue_name = try allocator.dupe(u8, queues_wire.queueNameFromUrl(url_v.string)),
        .receipt_handle = try allocator.dupe(u8, handle_v.string),
    };
}

// ---------------------------------------------------------------------------
// ChangeMessageVisibility

pub const ChangeMessageVisibilityRequest = struct {
    queue_name: []const u8,
    receipt_handle: []const u8,
    visibility_timeout: u32,
};

pub fn parseChangeMessageVisibility(allocator: Allocator, body: []const u8) ParseError!ChangeMessageVisibilityRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    const url_v = root.get("QueueUrl") orelse return ParseError.Malformed;
    const handle_v = root.get("ReceiptHandle") orelse return ParseError.Malformed;
    const vt_v = root.get("VisibilityTimeout") orelse return ParseError.Malformed;
    if (url_v != .string or handle_v != .string) return ParseError.Malformed;
    const vt: i64 = switch (vt_v) {
        .integer => |n| n,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch return ParseError.InvalidAttribute,
        else => return ParseError.Malformed,
    };
    if (vt < 0 or vt > 43200) return ParseError.InvalidAttribute;
    return .{
        .queue_name = try allocator.dupe(u8, queues_wire.queueNameFromUrl(url_v.string)),
        .receipt_handle = try allocator.dupe(u8, handle_v.string),
        .visibility_timeout = @intCast(vt),
    };
}

// ---------------------------------------------------------------------------
// Batch ops: SendMessageBatch / DeleteMessageBatch / ChangeMessageVisibilityBatch

pub const SendBatchEntry = struct {
    id: []const u8,
    body: []const u8,
    delay_seconds: ?u32 = null,
    delay_seconds_specified: bool = false,
    raw_attributes_json: ?[]const u8 = null,
    message_group_id: ?[]const u8 = null,
    message_deduplication_id: ?[]const u8 = null,
};

pub const SendBatchRequest = struct {
    queue_name: []const u8,
    entries: []SendBatchEntry,
};

pub fn parseSendMessageBatch(allocator: Allocator, body: []const u8) ParseError!SendBatchRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    const url_v = root.get("QueueUrl") orelse return ParseError.Malformed;
    if (url_v != .string) return ParseError.Malformed;
    const entries_v = root.get("Entries") orelse return ParseError.Malformed;
    if (entries_v != .array) return ParseError.Malformed;
    const items = entries_v.array.items;
    if (items.len == 0 or items.len > 10) return ParseError.InvalidAttribute;

    const out = try allocator.alloc(SendBatchEntry, items.len);
    for (items, 0..) |entry, i| {
        if (entry != .object) return ParseError.Malformed;
        const id_v = entry.object.get("Id") orelse return ParseError.Malformed;
        const body_v = entry.object.get("MessageBody") orelse return ParseError.Malformed;
        if (id_v != .string or body_v != .string) return ParseError.Malformed;
        var delay: ?u32 = null;
        var delay_specified = false;
        if (entry.object.get("DelaySeconds")) |v| switch (v) {
            .integer => |n| {
                if (n < 0 or n > 900) return ParseError.InvalidAttribute;
                delay = @intCast(n);
                delay_specified = true;
            },
            .string => |s| {
                const n = std.fmt.parseInt(i64, s, 10) catch return ParseError.InvalidAttribute;
                if (n < 0 or n > 900) return ParseError.InvalidAttribute;
                delay = @intCast(n);
                delay_specified = true;
            },
            else => return ParseError.Malformed,
        };
        var attrs_json: ?[]const u8 = null;
        if (entry.object.get("MessageAttributes")) |v| {
            if (v != .object) return ParseError.Malformed;
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            std.json.Stringify.value(v, .{}, &aw.writer) catch return ParseError.OutOfMemory;
            attrs_json = aw.toOwnedSlice() catch return ParseError.OutOfMemory;
        }
        var group_id: ?[]const u8 = null;
        if (entry.object.get("MessageGroupId")) |v| {
            if (v != .string) return ParseError.Malformed;
            group_id = try allocator.dupe(u8, v.string);
        }
        var dedup_id: ?[]const u8 = null;
        if (entry.object.get("MessageDeduplicationId")) |v| {
            if (v != .string) return ParseError.Malformed;
            dedup_id = try allocator.dupe(u8, v.string);
        }
        out[i] = .{
            .id = try allocator.dupe(u8, id_v.string),
            .body = try allocator.dupe(u8, body_v.string),
            .delay_seconds = delay,
            .delay_seconds_specified = delay_specified,
            .raw_attributes_json = attrs_json,
            .message_group_id = group_id,
            .message_deduplication_id = dedup_id,
        };
    }
    return .{
        .queue_name = try allocator.dupe(u8, queues_wire.queueNameFromUrl(url_v.string)),
        .entries = out,
    };
}

pub const DeleteBatchEntry = struct {
    id: []const u8,
    receipt_handle: []const u8,
};

pub const DeleteBatchRequest = struct {
    queue_name: []const u8,
    entries: []DeleteBatchEntry,
};

pub fn parseDeleteMessageBatch(allocator: Allocator, body: []const u8) ParseError!DeleteBatchRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    const url_v = root.get("QueueUrl") orelse return ParseError.Malformed;
    if (url_v != .string) return ParseError.Malformed;
    const entries_v = root.get("Entries") orelse return ParseError.Malformed;
    if (entries_v != .array) return ParseError.Malformed;
    const items = entries_v.array.items;
    if (items.len == 0 or items.len > 10) return ParseError.InvalidAttribute;

    const out = try allocator.alloc(DeleteBatchEntry, items.len);
    for (items, 0..) |entry, i| {
        if (entry != .object) return ParseError.Malformed;
        const id_v = entry.object.get("Id") orelse return ParseError.Malformed;
        const handle_v = entry.object.get("ReceiptHandle") orelse return ParseError.Malformed;
        if (id_v != .string or handle_v != .string) return ParseError.Malformed;
        out[i] = .{
            .id = try allocator.dupe(u8, id_v.string),
            .receipt_handle = try allocator.dupe(u8, handle_v.string),
        };
    }
    return .{
        .queue_name = try allocator.dupe(u8, queues_wire.queueNameFromUrl(url_v.string)),
        .entries = out,
    };
}

pub const VisBatchEntry = struct {
    id: []const u8,
    receipt_handle: []const u8,
    visibility_timeout: u32,
};

pub const VisBatchRequest = struct {
    queue_name: []const u8,
    entries: []VisBatchEntry,
};

pub fn parseChangeMessageVisibilityBatch(allocator: Allocator, body: []const u8) ParseError!VisBatchRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    const url_v = root.get("QueueUrl") orelse return ParseError.Malformed;
    if (url_v != .string) return ParseError.Malformed;
    const entries_v = root.get("Entries") orelse return ParseError.Malformed;
    if (entries_v != .array) return ParseError.Malformed;
    const items = entries_v.array.items;
    if (items.len == 0 or items.len > 10) return ParseError.InvalidAttribute;

    const out = try allocator.alloc(VisBatchEntry, items.len);
    for (items, 0..) |entry, i| {
        if (entry != .object) return ParseError.Malformed;
        const id_v = entry.object.get("Id") orelse return ParseError.Malformed;
        const handle_v = entry.object.get("ReceiptHandle") orelse return ParseError.Malformed;
        const vt_v = entry.object.get("VisibilityTimeout") orelse return ParseError.Malformed;
        if (id_v != .string or handle_v != .string) return ParseError.Malformed;
        const vt: i64 = switch (vt_v) {
            .integer => |n| n,
            .string => |s| std.fmt.parseInt(i64, s, 10) catch return ParseError.InvalidAttribute,
            else => return ParseError.Malformed,
        };
        if (vt < 0 or vt > 43200) return ParseError.InvalidAttribute;
        out[i] = .{
            .id = try allocator.dupe(u8, id_v.string),
            .receipt_handle = try allocator.dupe(u8, handle_v.string),
            .visibility_timeout = @intCast(vt),
        };
    }
    return .{
        .queue_name = try allocator.dupe(u8, queues_wire.queueNameFromUrl(url_v.string)),
        .entries = out,
    };
}

pub const SendBatchResultEntry = struct {
    id: []const u8,
    message_id: []const u8,
    md5_of_body: []const u8,
    sequence_number: ?u128 = null,
};

pub const BatchFailedEntry = struct {
    id: []const u8,
    code: []const u8,
    message: []const u8,
    sender_fault: bool,
};

pub fn renderSendMessageBatch(
    allocator: Allocator,
    successful: []const SendBatchResultEntry,
    failed: []const BatchFailedEntry,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("Successful");
    try s.beginArray();
    for (successful) |e| {
        try s.beginObject();
        try s.objectField("Id");
        try s.write(e.id);
        try s.objectField("MessageId");
        try s.write(e.message_id);
        try s.objectField("MD5OfMessageBody");
        try s.write(e.md5_of_body);
        if (e.sequence_number) |seq| {
            try s.objectField("SequenceNumber");
            var buf: [40]u8 = undefined;
            const txt = try std.fmt.bufPrint(&buf, "{d:0>20}", .{seq});
            try s.write(txt);
        }
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("Failed");
    try writeFailed(&s, failed);
    try s.endObject();
    return aw.toOwnedSlice();
}

pub fn renderIdOnlyBatch(
    allocator: Allocator,
    successful_ids: []const []const u8,
    failed: []const BatchFailedEntry,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("Successful");
    try s.beginArray();
    for (successful_ids) |id| {
        try s.beginObject();
        try s.objectField("Id");
        try s.write(id);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("Failed");
    try writeFailed(&s, failed);
    try s.endObject();
    return aw.toOwnedSlice();
}

fn writeFailed(s: *std.json.Stringify, failed: []const BatchFailedEntry) !void {
    try s.beginArray();
    for (failed) |f| {
        try s.beginObject();
        try s.objectField("Id");
        try s.write(f.id);
        try s.objectField("Code");
        try s.write(f.code);
        try s.objectField("Message");
        try s.write(f.message);
        try s.objectField("SenderFault");
        try s.write(f.sender_fault);
        try s.endObject();
    }
    try s.endArray();
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parseSendMessage: minimal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try parseSendMessage(arena.allocator(),
        \\{"QueueUrl":"http://h/0/orders","MessageBody":"hello"}
    );
    try testing.expectEqualStrings("orders", r.queue_name);
    try testing.expectEqualStrings("hello", r.body);
    try testing.expect(r.delay_seconds == null);
}

test "parseSendMessage: with DelaySeconds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try parseSendMessage(arena.allocator(),
        \\{"QueueUrl":"http://h/0/orders","MessageBody":"hello","DelaySeconds":30}
    );
    try testing.expectEqual(@as(u32, 30), r.delay_seconds.?);
}

test "parseReceiveMessage: defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try parseReceiveMessage(arena.allocator(),
        \\{"QueueUrl":"http://h/0/orders"}
    );
    try testing.expectEqual(@as(u32, 1), r.max_messages);
    try testing.expectEqual(@as(u32, 0), r.wait_time_seconds);
}

test "parseReceiveMessage: MaxNumberOfMessages clamps to 10" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ParseError.InvalidAttribute, parseReceiveMessage(arena.allocator(),
        \\{"QueueUrl":"http://h/0/orders","MaxNumberOfMessages":11}
    ));
}
