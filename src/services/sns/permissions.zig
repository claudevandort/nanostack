//! SNS AddPermission / RemovePermission handlers (v0.4.1).

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const wire = @import("../../wire/sns/permissions.zig");
const xml_response = @import("../../wire/sns/xml_response.zig");
const mod = @import("mod.zig");
const topics = @import("topics.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn addPermission(ctx: Context) Result {
    const req = wire.parseAddPermission(ctx.allocator, ctx.request.params) catch |err|
        return .{ .err = mapParseErr(err) };

    // Prefix each action with `sns:` (AWS-real accepts both shorthand
    // and prefixed; we always store the prefixed form).
    var prefixed: std.ArrayList([]const u8) = .empty;
    for (req.actions) |a| {
        const owned = std.fmt.allocPrint(ctx.allocator, "sns:{s}", .{a}) catch
            return .{ .err = .{ .code = .internal_error } };
        prefixed.append(ctx.allocator, owned) catch
            return .{ .err = .{ .code = .internal_error } };
    }

    const arn = std.fmt.allocPrint(ctx.allocator, "arn:aws:sns:{s}:{s}:{s}", .{
        ctx.region, ctx.account_id, req.topic_name,
    }) catch return .{ .err = .{ .code = .internal_error } };

    ctx.backend.addPermission(.{
        .topic_name = req.topic_name,
        .label = req.label,
        .aws_account_ids = req.aws_account_ids,
        .actions = prefixed.items,
        .topic_arn = arn,
    }) catch |err| return .{ .err = topics.mapStorageErr(err) };

    const body = xml_response.render(ctx.allocator, "AddPermission", "", ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn removePermission(ctx: Context) Result {
    const req = wire.parseRemovePermission(ctx.allocator, ctx.request.params) catch |err|
        return .{ .err = mapParseErr(err) };
    ctx.backend.removePermission(.{
        .topic_name = req.topic_name,
        .label = req.label,
    }) catch |err| return .{ .err = topics.mapStorageErr(err) };
    const body = xml_response.render(ctx.allocator, "RemovePermission", "", ctx.request.request_id) catch
        return .{ .err = .{ .code = .internal_error } };
    return .{ .ok = .{ .body = body } };
}

fn mapParseErr(e: wire.ParseError) mod.ErrorBody {
    return switch (e) {
        wire.ParseError.OutOfMemory => .{ .code = .internal_error },
        wire.ParseError.Malformed => .{ .code = .invalid_parameter, .message = "Request is malformed." },
    };
}
