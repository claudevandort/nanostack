//! SNS topic-management handlers (v0.4.0). Thin glue between wire
//! (src/wire/sns/topics.zig) and storage backend.

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const wire = @import("../../wire/sns/topics.zig");
const errors = @import("../../wire/sns/errors.zig");
const xml_response = @import("../../wire/sns/xml_response.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;
const ErrorBody = mod.ErrorBody;

pub fn createTopic(ctx: Context) Result {
    const req = wire.parseCreateTopic(ctx.allocator, ctx.request.params) catch |err|
        return .{ .err = mapParseErr(err) };

    const slot = ctx.backend.createTopic(.{
        .name = req.name,
        .attrs = req.attrs,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const inner = wire.renderCreateTopicResult(ctx.allocator, slot.arn) catch
        return .{ .err = .{ .code = .internal_error } };
    const body = xml_response.render(ctx.allocator, "CreateTopic", inner, ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn deleteTopic(ctx: Context) Result {
    const name = wire.parseTopicArn(ctx.allocator, ctx.request.params) catch |err|
        return .{ .err = mapParseErr(err) };
    ctx.backend.deleteTopic(name) catch |err| return .{ .err = mapStorageErr(err) };
    const body = xml_response.render(ctx.allocator, "DeleteTopic", "", ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn listTopics(ctx: Context) Result {
    const out = ctx.backend.listTopics(ctx.allocator, .{}) catch |err| return .{ .err = mapStorageErr(err) };
    const inner = wire.renderListTopicsResult(ctx.allocator, out) catch
        return .{ .err = .{ .code = .internal_error } };
    const body = xml_response.render(ctx.allocator, "ListTopics", inner, ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn getTopicAttributes(ctx: Context) Result {
    const name = wire.parseTopicArn(ctx.allocator, ctx.request.params) catch |err|
        return .{ .err = mapParseErr(err) };
    const slot = ctx.backend.getTopicAttributes(name) catch |err|
        return .{ .err = mapStorageErr(err) };
    const inner = wire.renderGetTopicAttributesResult(ctx.allocator, slot, ctx.account_id) catch
        return .{ .err = .{ .code = .internal_error } };
    const body = xml_response.render(ctx.allocator, "GetTopicAttributes", inner, ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn setTopicAttributes(ctx: Context) Result {
    const req = wire.parseSetTopicAttributes(ctx.allocator, ctx.request.params) catch |err|
        return .{ .err = mapParseErr(err) };
    ctx.backend.setTopicAttributes(.{
        .topic_name = req.topic_name,
        .attribute_name = req.attribute_name,
        .attribute_value = req.attribute_value,
    }) catch |err| return .{ .err = mapStorageErr(err) };
    const body = xml_response.render(ctx.allocator, "SetTopicAttributes", "", ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}

// ---------------------------------------------------------------------------
// Error mapping

pub fn mapParseErr(e: wire.ParseError) ErrorBody {
    return switch (e) {
        wire.ParseError.OutOfMemory => .{ .code = .internal_error },
        wire.ParseError.Malformed => .{ .code = .invalid_parameter, .message = "Request is malformed." },
    };
}

pub fn mapStorageErr(e: storage.Error) ErrorBody {
    return switch (e) {
        storage.Error.TopicNotFound => .{ .code = .not_found, .message = "Topic does not exist." },
        storage.Error.TopicAlreadyExists => .{ .code = .topic_already_exists },
        storage.Error.InvalidTopicName => .{ .code = .invalid_parameter, .message = "Invalid topic name." },
        storage.Error.InvalidProtocol => .{ .code = .invalid_parameter, .message = "Invalid subscription protocol." },
        storage.Error.SubscriptionNotFound => .{ .code = .subscription_not_found },
        storage.Error.InvalidParameterValue => .{ .code = .invalid_parameter },
        storage.Error.OutOfMemory, storage.Error.Io => .{ .code = .internal_error },
        else => .{ .code = .internal_error },
    };
}
