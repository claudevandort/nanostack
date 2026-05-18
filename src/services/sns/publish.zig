//! SNS Publish + PublishBatch handlers (v0.4.0 Phase D).

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const wire = @import("../../wire/sns/publish.zig");
const xml_response = @import("../../wire/sns/xml_response.zig");
const mod = @import("mod.zig");
const topics = @import("topics.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn publish(ctx: Context) Result {
    const req = wire.parsePublish(ctx.allocator, ctx.request.params) catch |err|
        return .{ .err = mapParseErr(err) };
    const out = ctx.backend.publish(ctx.allocator, .{
        .topic_name = req.topic_name,
        .message = req.message,
        .subject = req.subject,
        .message_attributes_json = req.message_attributes_json,
    }) catch |err| return .{ .err = topics.mapStorageErr(err) };
    const inner = wire.renderPublishResult(ctx.allocator, out.message_id) catch
        return .{ .err = .{ .code = .internal_error } };
    const body = xml_response.render(ctx.allocator, "Publish", inner, ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn publishBatch(ctx: Context) Result {
    const req = wire.parsePublishBatch(ctx.allocator, ctx.request.params) catch |err|
        return .{ .err = mapParseErr(err) };
    const out = ctx.backend.publishBatch(ctx.allocator, .{
        .topic_name = req.topic_name,
        .entries = req.entries,
    }) catch |err| return .{ .err = topics.mapStorageErr(err) };
    const inner = wire.renderPublishBatchResult(ctx.allocator, out) catch
        return .{ .err = .{ .code = .internal_error } };
    const body = xml_response.render(ctx.allocator, "PublishBatch", inner, ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}

fn mapParseErr(e: wire.ParseError) mod.ErrorBody {
    return switch (e) {
        wire.ParseError.OutOfMemory => .{ .code = .internal_error },
        wire.ParseError.Malformed => .{ .code = .invalid_parameter, .message = "Request is malformed." },
    };
}
