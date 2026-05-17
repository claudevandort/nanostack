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
    if (root.get("DelaySeconds")) |v| switch (v) {
        .integer => |n| {
            if (n < 0 or n > 900) return ParseError.InvalidAttribute;
            delay = @intCast(n);
        },
        .string => |s| {
            const n = std.fmt.parseInt(i64, s, 10) catch return ParseError.InvalidAttribute;
            if (n < 0 or n > 900) return ParseError.InvalidAttribute;
            delay = @intCast(n);
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

    return .{
        .queue_name = try allocator.dupe(u8, queues_wire.queueNameFromUrl(url_v.string)),
        .body = try allocator.dupe(u8, body_v.string),
        .delay_seconds = delay,
        .raw_attributes_json = attrs_json,
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
