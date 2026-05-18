//! SNS AddPermission / RemovePermission wire layer (v0.4.1).
//!
//! Mirrors the SQS pattern but parses query-string params instead of
//! JSON. AddPermission request shape:
//!   Action=AddPermission&TopicArn=...&Label=...
//!   &AWSAccountId.member.1=123456789012
//!   &ActionName.member.1=Publish

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const params_mod = @import("params.zig");

pub const ParseError = error{ Malformed, OutOfMemory };

pub const AddPermissionRequest = struct {
    topic_name: []const u8,
    label: []const u8,
    aws_account_ids: []const []const u8,
    /// Raw action names from the wire (without `sns:` prefix). Handler
    /// adds the prefix.
    actions: []const []const u8,
};

pub fn parseAddPermission(allocator: Allocator, params: []const params_mod.Param) ParseError!AddPermissionRequest {
    const topic_arn = params_mod.get(params, "TopicArn") orelse return ParseError.Malformed;
    const last = std.mem.lastIndexOfScalar(u8, topic_arn, ':') orelse return ParseError.Malformed;
    if (last + 1 >= topic_arn.len) return ParseError.Malformed;
    const topic = try allocator.dupe(u8, topic_arn[last + 1 ..]);

    const label_v = params_mod.get(params, "Label") orelse return ParseError.Malformed;
    if (label_v.len == 0) return ParseError.Malformed;
    const label = try allocator.dupe(u8, label_v);

    // AWSAccountId.member.N
    const acct_indices = params_mod.listIndices(allocator, params, "AWSAccountId.member.") catch return ParseError.OutOfMemory;
    defer allocator.free(acct_indices);
    if (acct_indices.len == 0) return ParseError.Malformed;
    const accts = try allocator.alloc([]const u8, acct_indices.len);
    for (acct_indices, 0..) |n, i| {
        var buf: [64]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "AWSAccountId.member.{d}", .{n}) catch continue;
        const v = params_mod.get(params, key) orelse "";
        accts[i] = try allocator.dupe(u8, v);
    }

    // ActionName.member.N
    const act_indices = params_mod.listIndices(allocator, params, "ActionName.member.") catch return ParseError.OutOfMemory;
    defer allocator.free(act_indices);
    if (act_indices.len == 0) return ParseError.Malformed;
    const actions = try allocator.alloc([]const u8, act_indices.len);
    for (act_indices, 0..) |n, i| {
        var buf: [64]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "ActionName.member.{d}", .{n}) catch continue;
        const v = params_mod.get(params, key) orelse "";
        actions[i] = try allocator.dupe(u8, v);
    }

    return .{
        .topic_name = topic,
        .label = label,
        .aws_account_ids = accts,
        .actions = actions,
    };
}

pub const RemovePermissionRequest = struct {
    topic_name: []const u8,
    label: []const u8,
};

pub fn parseRemovePermission(allocator: Allocator, params: []const params_mod.Param) ParseError!RemovePermissionRequest {
    const topic_arn = params_mod.get(params, "TopicArn") orelse return ParseError.Malformed;
    const last = std.mem.lastIndexOfScalar(u8, topic_arn, ':') orelse return ParseError.Malformed;
    if (last + 1 >= topic_arn.len) return ParseError.Malformed;
    const label_v = params_mod.get(params, "Label") orelse return ParseError.Malformed;
    if (label_v.len == 0) return ParseError.Malformed;
    return .{
        .topic_name = try allocator.dupe(u8, topic_arn[last + 1 ..]),
        .label = try allocator.dupe(u8, label_v),
    };
}
