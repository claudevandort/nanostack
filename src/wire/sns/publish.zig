//! SNS Publish + PublishBatch wire layer (v0.4.0 Phase D).

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const params_mod = @import("params.zig");

pub const ParseError = error{ Malformed, OutOfMemory };

pub const PublishRequest = struct {
    topic_name: []const u8,
    message: []const u8,
    subject: ?[]const u8,
    message_attributes_json: ?[]const u8,
};

pub fn parsePublish(allocator: Allocator, params: []const params_mod.Param) ParseError!PublishRequest {
    const topic_arn = params_mod.get(params, "TopicArn") orelse return ParseError.Malformed;
    const last_colon = std.mem.lastIndexOfScalar(u8, topic_arn, ':') orelse return ParseError.Malformed;
    if (last_colon + 1 >= topic_arn.len) return ParseError.Malformed;
    const topic = try allocator.dupe(u8, topic_arn[last_colon + 1 ..]);

    const message = params_mod.get(params, "Message") orelse return ParseError.Malformed;
    var subject: ?[]const u8 = null;
    if (params_mod.get(params, "Subject")) |s| subject = try allocator.dupe(u8, s);

    // MessageAttributes are awkward in the query protocol. We serialize them
    // to JSON for storage layer reuse.
    const attrs_json = serializeMessageAttributes(allocator, params, "MessageAttributes.entry.") catch null;

    return .{
        .topic_name = topic,
        .message = try allocator.dupe(u8, message),
        .subject = subject,
        .message_attributes_json = attrs_json,
    };
}

pub fn renderPublishResult(allocator: Allocator, message_id: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print("    <MessageId>{s}</MessageId>", .{message_id});
    return aw.toOwnedSlice();
}

fn serializeMessageAttributes(allocator: Allocator, params: []const params_mod.Param, prefix: []const u8) !?[]const u8 {
    const indices = try params_mod.listIndices(allocator, params, prefix);
    defer allocator.free(indices);
    if (indices.len == 0) return null;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    for (indices) |n| {
        var name_buf: [128]u8 = undefined;
        var type_buf: [128]u8 = undefined;
        var value_buf: [128]u8 = undefined;
        const name_key = std.fmt.bufPrint(&name_buf, "{s}{d}.Name", .{ prefix, n }) catch continue;
        const type_key = std.fmt.bufPrint(&type_buf, "{s}{d}.Value.DataType", .{ prefix, n }) catch continue;
        const value_key = std.fmt.bufPrint(&value_buf, "{s}{d}.Value.StringValue", .{ prefix, n }) catch continue;
        const name = params_mod.get(params, name_key) orelse continue;
        const dtype = params_mod.get(params, type_key) orelse continue;
        const value = params_mod.get(params, value_key) orelse continue;
        try s.objectField(name);
        try s.beginObject();
        try s.objectField("Type");
        try s.write(dtype);
        try s.objectField("Value");
        try s.write(value);
        try s.endObject();
    }
    try s.endObject();
    return try aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// PublishBatch

pub const PublishBatchRequest = struct {
    topic_name: []const u8,
    entries: []const storage.PublishBatchEntry,
};

pub fn parsePublishBatch(allocator: Allocator, params: []const params_mod.Param) ParseError!PublishBatchRequest {
    const topic_arn = params_mod.get(params, "TopicArn") orelse return ParseError.Malformed;
    const last_colon = std.mem.lastIndexOfScalar(u8, topic_arn, ':') orelse return ParseError.Malformed;
    const topic = try allocator.dupe(u8, topic_arn[last_colon + 1 ..]);

    const indices = params_mod.listIndices(allocator, params, "PublishBatchRequestEntries.member.") catch return ParseError.OutOfMemory;
    defer allocator.free(indices);
    const entries = try allocator.alloc(storage.PublishBatchEntry, indices.len);
    for (indices, 0..) |n, i| {
        var id_buf: [128]u8 = undefined;
        var msg_buf: [128]u8 = undefined;
        var subj_buf: [128]u8 = undefined;
        const id_key = std.fmt.bufPrint(&id_buf, "PublishBatchRequestEntries.member.{d}.Id", .{n}) catch continue;
        const msg_key = std.fmt.bufPrint(&msg_buf, "PublishBatchRequestEntries.member.{d}.Message", .{n}) catch continue;
        const subj_key = std.fmt.bufPrint(&subj_buf, "PublishBatchRequestEntries.member.{d}.Subject", .{n}) catch continue;
        const id = params_mod.get(params, id_key) orelse continue;
        const msg = params_mod.get(params, msg_key) orelse continue;
        var subj: ?[]const u8 = null;
        if (params_mod.get(params, subj_key)) |sj| subj = try allocator.dupe(u8, sj);
        entries[i] = .{
            .id = try allocator.dupe(u8, id),
            .message = try allocator.dupe(u8, msg),
            .subject = subj,
            .message_attributes_json = null, // not yet wired for batch
        };
    }
    return .{ .topic_name = topic, .entries = entries };
}

pub fn renderPublishBatchResult(allocator: Allocator, out: storage.PublishBatchOutput) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print("    <Successful>\n", .{});
    for (out.successful) |s| {
        try aw.writer.print(
            "      <member>\n        <Id>{s}</Id>\n        <MessageId>{s}</MessageId>\n      </member>\n",
            .{ s.id, s.message_id },
        );
    }
    try aw.writer.print("    </Successful>\n", .{});
    try aw.writer.print("    <Failed>\n", .{});
    for (out.failed) |f| {
        try aw.writer.print(
            "      <member>\n        <Id>{s}</Id>\n        <Code>{s}</Code>\n        <Message>{s}</Message>\n        <SenderFault>{}</SenderFault>\n      </member>\n",
            .{ f.id, f.code, f.message, f.sender_fault },
        );
    }
    try aw.writer.print("    </Failed>", .{});
    return aw.toOwnedSlice();
}
