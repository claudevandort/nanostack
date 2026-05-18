//! SNS subscription-ops wire layer (v0.4.0).

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const params_mod = @import("params.zig");

pub const ParseError = error{ Malformed, OutOfMemory };

// ---------------------------------------------------------------------------
// Subscribe

pub const SubscribeRequest = struct {
    topic_name: []const u8,
    protocol: storage.SnsProtocol,
    endpoint: []const u8,
};

pub fn parseSubscribe(allocator: Allocator, params: []const params_mod.Param) ParseError!SubscribeRequest {
    const topic_arn = params_mod.get(params, "TopicArn") orelse return ParseError.Malformed;
    const last_colon = std.mem.lastIndexOfScalar(u8, topic_arn, ':') orelse return ParseError.Malformed;
    if (last_colon + 1 >= topic_arn.len) return ParseError.Malformed;
    const topic = try allocator.dupe(u8, topic_arn[last_colon + 1 ..]);

    const proto_str = params_mod.get(params, "Protocol") orelse return ParseError.Malformed;
    const proto = storage.SnsProtocol.fromString(proto_str);

    const endpoint = params_mod.get(params, "Endpoint") orelse return ParseError.Malformed;
    return .{
        .topic_name = topic,
        .protocol = proto,
        .endpoint = try allocator.dupe(u8, endpoint),
    };
}

pub fn renderSubscribeResult(allocator: Allocator, sub_arn: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print("    <SubscriptionArn>{s}</SubscriptionArn>", .{sub_arn});
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Unsubscribe / ConfirmSubscription / GetSubscriptionAttributes / SetSubscriptionAttributes

pub fn parseSubscriptionArn(allocator: Allocator, params: []const params_mod.Param) ParseError![]const u8 {
    const arn = params_mod.get(params, "SubscriptionArn") orelse return ParseError.Malformed;
    return try allocator.dupe(u8, arn);
}

pub const ConfirmSubscriptionRequest = struct {
    topic_name: []const u8,
    token: []const u8,
};

pub fn parseConfirmSubscription(allocator: Allocator, params: []const params_mod.Param) ParseError!ConfirmSubscriptionRequest {
    const topic_arn = params_mod.get(params, "TopicArn") orelse return ParseError.Malformed;
    const last_colon = std.mem.lastIndexOfScalar(u8, topic_arn, ':') orelse return ParseError.Malformed;
    if (last_colon + 1 >= topic_arn.len) return ParseError.Malformed;
    const token = params_mod.get(params, "Token") orelse return ParseError.Malformed;
    return .{
        .topic_name = try allocator.dupe(u8, topic_arn[last_colon + 1 ..]),
        .token = try allocator.dupe(u8, token),
    };
}

pub const SetSubAttrsRequest = struct {
    subscription_arn: []const u8,
    attribute_name: []const u8,
    attribute_value: []const u8,
};

pub fn parseSetSubscriptionAttributes(allocator: Allocator, params: []const params_mod.Param) ParseError!SetSubAttrsRequest {
    const arn = params_mod.get(params, "SubscriptionArn") orelse return ParseError.Malformed;
    const name = params_mod.get(params, "AttributeName") orelse return ParseError.Malformed;
    const value = params_mod.get(params, "AttributeValue") orelse "";
    return .{
        .subscription_arn = try allocator.dupe(u8, arn),
        .attribute_name = try allocator.dupe(u8, name),
        .attribute_value = try allocator.dupe(u8, value),
    };
}

// ---------------------------------------------------------------------------
// ListSubscriptions / ListSubscriptionsByTopic

pub fn renderListSubscriptionsResult(allocator: Allocator, out: storage.ListSubscriptionsOutput) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print("    <Subscriptions>\n", .{});
    for (out.subscriptions) |s| {
        try aw.writer.print(
            "      <member>\n        <SubscriptionArn>{s}</SubscriptionArn>\n        <TopicArn>{s}</TopicArn>\n        <Protocol>{s}</Protocol>\n        <Endpoint>{s}</Endpoint>\n        <Owner>{s}</Owner>\n      </member>\n",
            .{ s.subscription_arn, s.topic_arn, s.protocol, s.endpoint, s.owner },
        );
    }
    try aw.writer.print("    </Subscriptions>", .{});
    return aw.toOwnedSlice();
}

pub fn renderGetSubscriptionAttributesResult(allocator: Allocator, sub: *const storage.Subscription, owner: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print("    <Attributes>\n", .{});
    try writeAttr(&aw.writer, "SubscriptionArn", sub.arn);
    try writeAttr(&aw.writer, "TopicArn", sub.topic_arn);
    try writeAttr(&aw.writer, "Protocol", sub.protocol.toString());
    try writeAttr(&aw.writer, "Endpoint", sub.endpoint);
    try writeAttr(&aw.writer, "Owner", owner);
    try writeAttr(&aw.writer, "ConfirmationWasAuthenticated", if (sub.confirmed) "true" else "false");
    try writeAttr(&aw.writer, "RawMessageDelivery", if (sub.raw_message_delivery) "true" else "false");
    if (sub.filter_policy) |fp| try writeAttr(&aw.writer, "FilterPolicy", fp);
    if (sub.delivery_policy) |dp| try writeAttr(&aw.writer, "DeliveryPolicy", dp);
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

pub fn renderConfirmSubscriptionResult(allocator: Allocator, sub_arn: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print("    <SubscriptionArn>{s}</SubscriptionArn>", .{sub_arn});
    return aw.toOwnedSlice();
}
