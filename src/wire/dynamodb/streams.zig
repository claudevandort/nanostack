//! Wire parsers + renderers for the DynamoDBStreams sub-service.
//!
//! Inputs come in as JSON over POST /. Outputs render as JSON via
//! std.json.Stringify. AttributeValue rendering reuses the existing
//! `attribute_value.renderValue` since stream records carry the same
//! shape as GetItem responses.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const dynamo_state = @import("../../storage/dynamo_state.zig");
const dynamo_streams = @import("../../storage/dynamo_streams.zig");
const attribute_value = @import("attribute_value.zig");

pub const ParseError = error{
    Malformed,
    InvalidIteratorType,
    InvalidLimit,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// ListStreams

pub const ListStreamsRequest = struct {
    table_name: ?[]const u8 = null,
    limit: ?u32 = null,
    exclusive_start_stream_arn: ?[]const u8 = null,
};

pub fn parseListStreams(allocator: Allocator, body: []const u8) ParseError!ListStreamsRequest {
    if (body.len == 0) return .{};
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;

    var req: ListStreamsRequest = .{};
    if (root.get("TableName")) |v| {
        if (v != .string) return ParseError.Malformed;
        req.table_name = try allocator.dupe(u8, v.string);
    }
    if (root.get("Limit")) |v| switch (v) {
        .integer => |n| {
            if (n < 1 or n > 100) return ParseError.InvalidLimit;
            req.limit = @intCast(n);
        },
        else => return ParseError.Malformed,
    };
    if (root.get("ExclusiveStartStreamArn")) |v| {
        if (v != .string) return ParseError.Malformed;
        req.exclusive_start_stream_arn = try allocator.dupe(u8, v.string);
    }
    return req;
}

pub fn renderListStreams(allocator: Allocator, out: storage.ListStreamsOutput) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("Streams");
    try s.beginArray();
    for (out.streams) |summary| {
        try s.beginObject();
        try s.objectField("StreamArn");
        try s.write(summary.arn);
        try s.objectField("TableName");
        try s.write(summary.table_name);
        try s.objectField("StreamLabel");
        try s.write(summary.label);
        try s.endObject();
    }
    try s.endArray();
    if (out.last_evaluated_stream_arn) |arn| {
        try s.objectField("LastEvaluatedStreamArn");
        try s.write(arn);
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// DescribeStream

pub const DescribeStreamRequest = struct {
    arn: []const u8,
    limit: ?u32 = null,
    exclusive_start_shard_id: ?[]const u8 = null,
};

pub fn parseDescribeStream(allocator: Allocator, body: []const u8) ParseError!DescribeStreamRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    const arn_v = root.get("StreamArn") orelse return ParseError.Malformed;
    if (arn_v != .string) return ParseError.Malformed;
    var req: DescribeStreamRequest = .{ .arn = try allocator.dupe(u8, arn_v.string) };
    if (root.get("Limit")) |v| switch (v) {
        .integer => |n| {
            if (n < 1 or n > 100) return ParseError.InvalidLimit;
            req.limit = @intCast(n);
        },
        else => return ParseError.Malformed,
    };
    if (root.get("ExclusiveStartShardId")) |v| {
        if (v != .string) return ParseError.Malformed;
        req.exclusive_start_shard_id = try allocator.dupe(u8, v.string);
    }
    return req;
}

pub fn renderDescribeStream(allocator: Allocator, out: storage.DescribeStreamOutput) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("StreamDescription");
    try s.beginObject();

    try s.objectField("StreamArn");
    try s.write(out.arn);
    try s.objectField("StreamLabel");
    try s.write(out.label);
    try s.objectField("StreamStatus");
    try s.write(out.status.toAws());
    try s.objectField("StreamViewType");
    try s.write(out.view_type.toAws());
    try s.objectField("CreationRequestDateTime");
    try s.print("{d}", .{@as(f64, @floatFromInt(out.creation_request_unix))});
    try s.objectField("TableName");
    try s.write(out.table_name);

    try s.objectField("KeySchema");
    try s.beginArray();
    for (out.key_schema) |k| {
        try s.beginObject();
        try s.objectField("AttributeName");
        try s.write(k.name);
        try s.objectField("KeyType");
        try s.write(k.key_type.toAws());
        try s.endObject();
    }
    try s.endArray();

    try s.objectField("Shards");
    try s.beginArray();
    for (out.shards) |sh| {
        try s.beginObject();
        try s.objectField("ShardId");
        try s.write(sh.shard_id);
        try s.objectField("SequenceNumberRange");
        try s.beginObject();
        try s.objectField("StartingSequenceNumber");
        try s.write(sh.starting_sequence_number);
        if (sh.ending_sequence_number) |end_seq| {
            try s.objectField("EndingSequenceNumber");
            try s.write(end_seq);
        }
        try s.endObject();
        try s.endObject();
    }
    try s.endArray();

    if (out.last_evaluated_shard_id) |sid| {
        try s.objectField("LastEvaluatedShardId");
        try s.write(sid);
    }

    try s.endObject(); // StreamDescription
    try s.endObject(); // root
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// GetShardIterator

pub const GetShardIteratorRequest = struct {
    arn: []const u8,
    shard_id: []const u8,
    iterator_type: storage.GetShardIteratorInput.Type,
    sequence_number: ?[]const u8 = null,
};

pub fn parseGetShardIterator(allocator: Allocator, body: []const u8) ParseError!storage.GetShardIteratorInput {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;

    const arn_v = root.get("StreamArn") orelse return ParseError.Malformed;
    const shard_v = root.get("ShardId") orelse return ParseError.Malformed;
    const type_v = root.get("ShardIteratorType") orelse return ParseError.Malformed;
    if (arn_v != .string or shard_v != .string or type_v != .string) return ParseError.Malformed;

    const iter_type: storage.GetShardIteratorInput.Type =
        if (std.mem.eql(u8, type_v.string, "TRIM_HORIZON"))
            .trim_horizon
        else if (std.mem.eql(u8, type_v.string, "LATEST"))
            .latest
        else if (std.mem.eql(u8, type_v.string, "AT_SEQUENCE_NUMBER"))
            .at_sequence_number
        else if (std.mem.eql(u8, type_v.string, "AFTER_SEQUENCE_NUMBER"))
            .after_sequence_number
        else
            return ParseError.InvalidIteratorType;

    var seq: ?[]const u8 = null;
    if (root.get("SequenceNumber")) |v| {
        if (v != .string) return ParseError.Malformed;
        seq = try allocator.dupe(u8, v.string);
    }
    switch (iter_type) {
        .at_sequence_number, .after_sequence_number => if (seq == null) return ParseError.Malformed,
        else => {},
    }
    return .{
        .arn = try allocator.dupe(u8, arn_v.string),
        .shard_id = try allocator.dupe(u8, shard_v.string),
        .iterator_type = iter_type,
        .sequence_number = seq,
    };
}

pub fn renderGetShardIterator(allocator: Allocator, iterator: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("ShardIterator");
    try s.write(iterator);
    try s.endObject();
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// GetRecords

pub fn parseGetRecords(allocator: Allocator, body: []const u8) ParseError!storage.GetRecordsInput {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;

    const it_v = root.get("ShardIterator") orelse return ParseError.Malformed;
    if (it_v != .string) return ParseError.Malformed;

    var limit: u32 = 1000;
    if (root.get("Limit")) |v| switch (v) {
        .integer => |n| {
            if (n < 1 or n > 1000) return ParseError.InvalidLimit;
            limit = @intCast(n);
        },
        else => return ParseError.Malformed,
    };
    return .{
        .shard_iterator = try allocator.dupe(u8, it_v.string),
        .limit = limit,
    };
}

pub fn renderGetRecords(allocator: Allocator, out: storage.GetRecordsOutput) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("Records");
    try s.beginArray();
    for (out.records) |r| {
        try s.beginObject();
        try s.objectField("eventID");
        try s.write(r.seq);
        try s.objectField("eventName");
        try s.write(r.kind.toAws());
        try s.objectField("eventVersion");
        try s.write("1.1");
        try s.objectField("eventSource");
        try s.write("aws:dynamodb");
        try s.objectField("awsRegion");
        try s.write("us-east-1");
        try s.objectField("dynamodb");
        try s.beginObject();
        try s.objectField("ApproximateCreationDateTime");
        try s.print("{d}", .{@as(f64, @floatFromInt(r.created_unix))});
        try s.objectField("SequenceNumber");
        try s.write(r.seq);
        try s.objectField("Keys");
        try writeItem(&s, allocator, &r.keys);
        if (r.new_image) |ni| {
            try s.objectField("NewImage");
            try writeItem(&s, allocator, &ni);
        }
        if (r.old_image) |oi| {
            try s.objectField("OldImage");
            try writeItem(&s, allocator, &oi);
        }
        try s.objectField("StreamViewType");
        // The view type is per-stream; we'd need to plumb it through.
        // For now, derive from what's present:
        const vt = derive_view_type(r);
        try s.write(vt);
        try s.objectField("SizeBytes");
        try s.write(0);
        try s.endObject();
        try s.endObject();
    }
    try s.endArray();
    if (out.next_shard_iterator) |it| {
        try s.objectField("NextShardIterator");
        try s.write(it);
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

fn derive_view_type(r: storage.StreamRecordOut) []const u8 {
    if (r.new_image != null and r.old_image != null) return "NEW_AND_OLD_IMAGES";
    if (r.new_image != null) return "NEW_IMAGE";
    if (r.old_image != null) return "OLD_IMAGE";
    return "KEYS_ONLY";
}

fn writeItem(s: *std.json.Stringify, allocator: Allocator, item: *const dynamo_state.Item) !void {
    try s.beginObject();
    for (item.names, item.values) |name, value| {
        try s.objectField(name);
        try attribute_value.renderValue(s, allocator, value);
    }
    try s.endObject();
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parseListStreams: empty body → all defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = try parseListStreams(arena.allocator(), "");
    try testing.expect(req.table_name == null);
    try testing.expect(req.limit == null);
}

test "parseListStreams: TableName + Limit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = try parseListStreams(arena.allocator(),
        \\{"TableName":"t","Limit":10}
    );
    try testing.expectEqualStrings("t", req.table_name.?);
    try testing.expectEqual(@as(u32, 10), req.limit.?);
}

test "parseGetShardIterator: TRIM_HORIZON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const in = try parseGetShardIterator(arena.allocator(),
        \\{"StreamArn":"a","ShardId":"s","ShardIteratorType":"TRIM_HORIZON"}
    );
    try testing.expectEqual(storage.GetShardIteratorInput.Type.trim_horizon, in.iterator_type);
}

test "parseGetShardIterator: AT_SEQUENCE_NUMBER requires SequenceNumber" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ParseError.Malformed, parseGetShardIterator(arena.allocator(),
        \\{"StreamArn":"a","ShardId":"s","ShardIteratorType":"AT_SEQUENCE_NUMBER"}
    ));
}

test "parseGetShardIterator: bad type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ParseError.InvalidIteratorType, parseGetShardIterator(arena.allocator(),
        \\{"StreamArn":"a","ShardId":"s","ShardIteratorType":"BOGUS"}
    ));
}

test "parseGetRecords: defaults to limit=1000" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const in = try parseGetRecords(arena.allocator(),
        \\{"ShardIterator":"abc"}
    );
    try testing.expectEqual(@as(u32, 1000), in.limit);
    try testing.expectEqualStrings("abc", in.shard_iterator);
}
