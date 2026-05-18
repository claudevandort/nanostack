//! SNS tag-ops wire layer (v0.4.0 Phase E).
//!
//! AWS uses different op names than the SQS pattern: TagResource /
//! UntagResource / ListTagsForResource. The "Resource" identifier is
//! always a topic ARN.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const params_mod = @import("params.zig");

pub const ParseError = error{ Malformed, OutOfMemory };

pub const TagResourceRequest = struct {
    topic_name: []const u8,
    tags: []storage.Tag,
};

fn topicNameFromResourceArn(allocator: Allocator, params: []const params_mod.Param) ParseError![]const u8 {
    const arn = params_mod.get(params, "ResourceArn") orelse return ParseError.Malformed;
    const last = std.mem.lastIndexOfScalar(u8, arn, ':') orelse return ParseError.Malformed;
    if (last + 1 >= arn.len) return ParseError.Malformed;
    return try allocator.dupe(u8, arn[last + 1 ..]);
}

pub fn parseTagResource(allocator: Allocator, params: []const params_mod.Param) ParseError!TagResourceRequest {
    const topic = try topicNameFromResourceArn(allocator, params);

    // Tags arrive as `Tags.member.N.Key=...&Tags.member.N.Value=...`.
    const indices = params_mod.listIndices(allocator, params, "Tags.member.") catch return ParseError.OutOfMemory;
    defer allocator.free(indices);
    const tags = try allocator.alloc(storage.Tag, indices.len);
    for (indices, 0..) |n, i| {
        var k_buf: [64]u8 = undefined;
        var v_buf: [64]u8 = undefined;
        const k_key = std.fmt.bufPrint(&k_buf, "Tags.member.{d}.Key", .{n}) catch continue;
        const v_key = std.fmt.bufPrint(&v_buf, "Tags.member.{d}.Value", .{n}) catch continue;
        const k = params_mod.get(params, k_key) orelse "";
        const v = params_mod.get(params, v_key) orelse "";
        tags[i] = .{
            .key = try allocator.dupe(u8, k),
            .value = try allocator.dupe(u8, v),
        };
    }
    return .{ .topic_name = topic, .tags = tags };
}

pub const UntagResourceRequest = struct {
    topic_name: []const u8,
    keys: [][]const u8,
};

pub fn parseUntagResource(allocator: Allocator, params: []const params_mod.Param) ParseError!UntagResourceRequest {
    const topic = try topicNameFromResourceArn(allocator, params);

    // Keys arrive as `TagKeys.member.N=foo`.
    const indices = params_mod.listIndices(allocator, params, "TagKeys.member.") catch return ParseError.OutOfMemory;
    defer allocator.free(indices);
    const keys = try allocator.alloc([]const u8, indices.len);
    for (indices, 0..) |n, i| {
        var buf: [64]u8 = undefined;
        const key_path = std.fmt.bufPrint(&buf, "TagKeys.member.{d}", .{n}) catch continue;
        const k = params_mod.get(params, key_path) orelse "";
        keys[i] = try allocator.dupe(u8, k);
    }
    return .{ .topic_name = topic, .keys = keys };
}

pub fn parseListTagsForResource(allocator: Allocator, params: []const params_mod.Param) ParseError![]const u8 {
    return try topicNameFromResourceArn(allocator, params);
}

pub fn renderListTagsForResource(allocator: Allocator, out: storage.ListTopicTagsOutput) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print("    <Tags>\n", .{});
    for (out.tags) |t| {
        try aw.writer.print(
            "      <member>\n        <Key>{s}</Key>\n        <Value>{s}</Value>\n      </member>\n",
            .{ t.key, t.value },
        );
    }
    try aw.writer.print("    </Tags>", .{});
    return aw.toOwnedSlice();
}
