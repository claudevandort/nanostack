//! SNS subscription-ops handlers (v0.4.0 Phase C).

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const wire = @import("../../wire/sns/subscriptions.zig");
const xml_response = @import("../../wire/sns/xml_response.zig");
const mod = @import("mod.zig");
const topics = @import("topics.zig");

const Context = mod.Context;
const Result = mod.Result;
const ErrorBody = mod.ErrorBody;

pub fn subscribe(ctx: Context) Result {
    const req = wire.parseSubscribe(ctx.allocator, ctx.request.params) catch |err|
        return .{ .err = topics.mapParseErr(err) };
    const out = ctx.backend.subscribe(ctx.allocator, .{
        .topic_name = req.topic_name,
        .protocol = req.protocol,
        .endpoint = req.endpoint,
    }) catch |err| return .{ .err = topics.mapStorageErr(err) };
    const inner = wire.renderSubscribeResult(ctx.allocator, out.subscription_arn) catch
        return .{ .err = .{ .code = .internal_error } };
    const body = xml_response.render(ctx.allocator, "Subscribe", inner, ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn unsubscribe(ctx: Context) Result {
    const arn = wire.parseSubscriptionArn(ctx.allocator, ctx.request.params) catch |err|
        return .{ .err = topics.mapParseErr(err) };
    ctx.backend.unsubscribe(.{ .subscription_arn = arn }) catch |err|
        return .{ .err = topics.mapStorageErr(err) };
    const body = xml_response.render(ctx.allocator, "Unsubscribe", "", ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn listSubscriptions(ctx: Context) Result {
    const out = ctx.backend.listSubscriptions(ctx.allocator, .{}) catch |err|
        return .{ .err = topics.mapStorageErr(err) };
    const inner = wire.renderListSubscriptionsResult(ctx.allocator, out) catch
        return .{ .err = .{ .code = .internal_error } };
    const body = xml_response.render(ctx.allocator, "ListSubscriptions", inner, ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn listSubscriptionsByTopic(ctx: Context) Result {
    const topic_name = wire.parseSubscriptionArn(ctx.allocator, ctx.request.params) catch null;
    _ = topic_name;
    // The wire field for this op is `TopicArn`, not `SubscriptionArn`.
    const params_mod = @import("../../wire/sns/params.zig");
    const topic_arn = params_mod.get(ctx.request.params, "TopicArn") orelse
        return .{ .err = .{ .code = .invalid_parameter, .message = "Missing TopicArn." } };
    const last = std.mem.lastIndexOfScalar(u8, topic_arn, ':') orelse
        return .{ .err = .{ .code = .invalid_parameter, .message = "Malformed TopicArn." } };
    const topic = topic_arn[last + 1 ..];
    const out = ctx.backend.listSubscriptionsByTopic(ctx.allocator, .{ .topic_name = topic }) catch |err|
        return .{ .err = topics.mapStorageErr(err) };
    const inner = wire.renderListSubscriptionsResult(ctx.allocator, out) catch
        return .{ .err = .{ .code = .internal_error } };
    const body = xml_response.render(ctx.allocator, "ListSubscriptionsByTopic", inner, ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn getSubscriptionAttributes(ctx: Context) Result {
    const arn = wire.parseSubscriptionArn(ctx.allocator, ctx.request.params) catch |err|
        return .{ .err = topics.mapParseErr(err) };
    const sub = ctx.backend.getSubscriptionAttributes(arn) catch |err|
        return .{ .err = topics.mapStorageErr(err) };
    const inner = wire.renderGetSubscriptionAttributesResult(ctx.allocator, sub, ctx.account_id) catch
        return .{ .err = .{ .code = .internal_error } };
    const body = xml_response.render(ctx.allocator, "GetSubscriptionAttributes", inner, ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn setSubscriptionAttributes(ctx: Context) Result {
    const req = wire.parseSetSubscriptionAttributes(ctx.allocator, ctx.request.params) catch |err|
        return .{ .err = topics.mapParseErr(err) };
    ctx.backend.setSubscriptionAttributes(.{
        .subscription_arn = req.subscription_arn,
        .attribute_name = req.attribute_name,
        .attribute_value = req.attribute_value,
    }) catch |err| return .{ .err = topics.mapStorageErr(err) };
    const body = xml_response.render(ctx.allocator, "SetSubscriptionAttributes", "", ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn confirmSubscription(ctx: Context) Result {
    const req = wire.parseConfirmSubscription(ctx.allocator, ctx.request.params) catch |err|
        return .{ .err = topics.mapParseErr(err) };
    const out = ctx.backend.confirmSubscription(ctx.allocator, .{
        .topic_name = req.topic_name,
        .token = req.token,
    }) catch |err| return .{ .err = topics.mapStorageErr(err) };
    const inner = wire.renderConfirmSubscriptionResult(ctx.allocator, out.subscription_arn) catch
        return .{ .err = .{ .code = .internal_error } };
    const body = xml_response.render(ctx.allocator, "ConfirmSubscription", inner, ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}
