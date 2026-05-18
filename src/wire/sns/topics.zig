//! SNS topic-ops wire layer (v0.4.0). Parsers for query-string bodies +
//! XML inner-result renderers (envelope is added by xml_response.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const params_mod = @import("params.zig");

pub const ParseError = error{
    Malformed,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// CreateTopic

pub const CreateTopicRequest = struct {
    name: []const u8,
    attrs: storage.TopicAttributes,
};

pub fn parseCreateTopic(allocator: Allocator, params: []const params_mod.Param) ParseError!CreateTopicRequest {
    const name = params_mod.get(params, "Name") orelse return ParseError.Malformed;
    var attrs: storage.TopicAttributes = .{};

    // Attributes come in as `Attributes.entry.N.key=DisplayName&Attributes.entry.N.value=foo`.
    const indices = params_mod.listIndices(allocator, params, "Attributes.entry.") catch return ParseError.OutOfMemory;
    defer allocator.free(indices);
    for (indices) |n| {
        var k_buf: [64]u8 = undefined;
        var v_buf: [64]u8 = undefined;
        const k_path = std.fmt.bufPrint(&k_buf, "Attributes.entry.{d}.key", .{n}) catch continue;
        const v_path = std.fmt.bufPrint(&v_buf, "Attributes.entry.{d}.value", .{n}) catch continue;
        const k = params_mod.get(params, k_path) orelse continue;
        const v = params_mod.get(params, v_path) orelse continue;
        if (std.mem.eql(u8, k, "DisplayName")) {
            attrs.display_name = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "Policy")) {
            attrs.policy = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "DeliveryPolicy")) {
            attrs.delivery_policy = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "KmsMasterKeyId")) {
            attrs.kms_key_id = try allocator.dupe(u8, v);
        }
    }
    return .{
        .name = try allocator.dupe(u8, name),
        .attrs = attrs,
    };
}

pub fn renderCreateTopicResult(allocator: Allocator, topic_arn: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print("    <TopicArn>{s}</TopicArn>", .{topic_arn});
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// DeleteTopic / GetTopicAttributes / SetTopicAttributes

/// Extract `TopicArn` from params, return the topic name (last segment).
pub fn parseTopicArn(allocator: Allocator, params: []const params_mod.Param) ParseError![]const u8 {
    const arn = params_mod.get(params, "TopicArn") orelse return ParseError.Malformed;
    const last_colon = std.mem.lastIndexOfScalar(u8, arn, ':') orelse return ParseError.Malformed;
    if (last_colon + 1 >= arn.len) return ParseError.Malformed;
    return try allocator.dupe(u8, arn[last_colon + 1 ..]);
}

pub const SetTopicAttributesRequest = struct {
    topic_name: []const u8,
    attribute_name: []const u8,
    attribute_value: []const u8,
};

pub fn parseSetTopicAttributes(allocator: Allocator, params: []const params_mod.Param) ParseError!SetTopicAttributesRequest {
    const topic_name = try parseTopicArn(allocator, params);
    const attr_name = params_mod.get(params, "AttributeName") orelse return ParseError.Malformed;
    const attr_value = params_mod.get(params, "AttributeValue") orelse "";
    return .{
        .topic_name = topic_name,
        .attribute_name = try allocator.dupe(u8, attr_name),
        .attribute_value = try allocator.dupe(u8, attr_value),
    };
}

pub fn renderGetTopicAttributesResult(allocator: Allocator, slot: *const storage.SnsTopicSlot, account_id: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print("    <Attributes>\n", .{});
    try writeAttr(&aw.writer, "TopicArn", slot.arn);
    try writeAttr(&aw.writer, "Owner", account_id);
    if (slot.attrs.display_name) |s| try writeAttr(&aw.writer, "DisplayName", s);
    if (slot.attrs.policy) |s| try writeAttr(&aw.writer, "Policy", s);
    if (slot.attrs.delivery_policy) |s| try writeAttr(&aw.writer, "DeliveryPolicy", s);
    if (slot.attrs.kms_key_id) |s| try writeAttr(&aw.writer, "KmsMasterKeyId", s);
    try writeAttrFmt(&aw.writer, "SubscriptionsConfirmed", "{d}", .{slot.subscriptions.items.len});
    try writeAttrFmt(&aw.writer, "SubscriptionsPending", "{d}", .{0});
    try writeAttrFmt(&aw.writer, "SubscriptionsDeleted", "{d}", .{0});
    try aw.writer.print("    </Attributes>", .{});
    return aw.toOwnedSlice();
}

fn writeAttr(w: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try w.print(
        \\      <entry>
        \\        <key>{s}</key>
        \\        <value>{s}</value>
        \\      </entry>
        \\
    , .{ name, value });
}

fn writeAttrFmt(w: *std.Io.Writer, name: []const u8, comptime fmt: []const u8, args: anytype) !void {
    try w.print(
        \\      <entry>
        \\        <key>{s}</key>
        \\        <value>
    , .{name});
    try w.print(fmt, args);
    try w.print(
        \\</value>
        \\      </entry>
        \\
    , .{});
}

// ---------------------------------------------------------------------------
// ListTopics

pub fn renderListTopicsResult(allocator: Allocator, out: storage.ListTopicsOutput) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print("    <Topics>\n", .{});
    for (out.topic_arns) |arn| {
        try aw.writer.print("      <member>\n        <TopicArn>{s}</TopicArn>\n      </member>\n", .{arn});
    }
    try aw.writer.print("    </Topics>", .{});
    if (out.next_token) |tok| {
        try aw.writer.print("\n    <NextToken>{s}</NextToken>", .{tok});
    }
    return aw.toOwnedSlice();
}
