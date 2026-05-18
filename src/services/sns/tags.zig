//! SNS tag-ops handlers (v0.4.0 Phase E).

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const wire = @import("../../wire/sns/tags.zig");
const xml_response = @import("../../wire/sns/xml_response.zig");
const mod = @import("mod.zig");
const topics = @import("topics.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn tagResource(ctx: Context) Result {
    const req = wire.parseTagResource(ctx.allocator, ctx.request.params) catch |err|
        return .{ .err = mapParseErr(err) };
    ctx.backend.tagTopic(.{
        .topic_name = req.topic_name,
        .tags = req.tags,
    }) catch |err| return .{ .err = topics.mapStorageErr(err) };
    const body = xml_response.render(ctx.allocator, "TagResource", "", ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn untagResource(ctx: Context) Result {
    const req = wire.parseUntagResource(ctx.allocator, ctx.request.params) catch |err|
        return .{ .err = mapParseErr(err) };
    ctx.backend.untagTopic(.{
        .topic_name = req.topic_name,
        .keys = req.keys,
    }) catch |err| return .{ .err = topics.mapStorageErr(err) };
    const body = xml_response.render(ctx.allocator, "UntagResource", "", ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn listTagsForResource(ctx: Context) Result {
    const topic_name = wire.parseListTagsForResource(ctx.allocator, ctx.request.params) catch |err|
        return .{ .err = mapParseErr(err) };
    const out = ctx.backend.listTopicTags(ctx.allocator, topic_name) catch |err|
        return .{ .err = topics.mapStorageErr(err) };
    const inner = wire.renderListTagsForResource(ctx.allocator, out) catch
        return .{ .err = .{ .code = .internal_error } };
    const body = xml_response.render(ctx.allocator, "ListTagsForResource", inner, ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}

fn mapParseErr(e: wire.ParseError) mod.ErrorBody {
    return switch (e) {
        wire.ParseError.OutOfMemory => .{ .code = .internal_error },
        wire.ParseError.Malformed => .{ .code = .invalid_parameter, .message = "Request is malformed." },
    };
}
