//! SQS tag-ops wire layer (v0.3.0 Phase 5).
//!
//! TagQueue / UntagQueue / ListQueueTags.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const queues_wire = @import("queues.zig");

pub const ParseError = queues_wire.ParseError;

pub const TagRequest = struct {
    queue_name: []const u8,
    tags: []storage.Tag,
};

pub fn parseTagQueue(allocator: Allocator, body: []const u8) ParseError!TagRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    const url_v = root.get("QueueUrl") orelse return ParseError.Malformed;
    if (url_v != .string) return ParseError.Malformed;
    const tags_v = root.get("Tags") orelse return ParseError.Malformed;
    if (tags_v != .object) return ParseError.Malformed;
    const obj = tags_v.object;
    const out = try allocator.alloc(storage.Tag, obj.count());
    var i: usize = 0;
    var it = obj.iterator();
    while (it.next()) |entry| : (i += 1) {
        if (entry.value_ptr.* != .string) return ParseError.Malformed;
        out[i] = .{
            .key = try allocator.dupe(u8, entry.key_ptr.*),
            .value = try allocator.dupe(u8, entry.value_ptr.*.string),
        };
    }
    return .{
        .queue_name = try allocator.dupe(u8, queues_wire.queueNameFromUrl(url_v.string)),
        .tags = out,
    };
}

pub const UntagRequest = struct {
    queue_name: []const u8,
    keys: [][]const u8,
};

pub fn parseUntagQueue(allocator: Allocator, body: []const u8) ParseError!UntagRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    const url_v = root.get("QueueUrl") orelse return ParseError.Malformed;
    if (url_v != .string) return ParseError.Malformed;
    const keys_v = root.get("TagKeys") orelse return ParseError.Malformed;
    if (keys_v != .array) return ParseError.Malformed;
    const items = keys_v.array.items;
    const out = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |entry, i| {
        if (entry != .string) return ParseError.Malformed;
        out[i] = try allocator.dupe(u8, entry.string);
    }
    return .{
        .queue_name = try allocator.dupe(u8, queues_wire.queueNameFromUrl(url_v.string)),
        .keys = out,
    };
}

pub fn renderListQueueTags(allocator: Allocator, out: storage.ListQueueTagsOutput) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("Tags");
    try s.beginObject();
    for (out.tags) |t| {
        try s.objectField(t.key);
        try s.write(t.value);
    }
    try s.endObject();
    try s.endObject();
    return aw.toOwnedSlice();
}
