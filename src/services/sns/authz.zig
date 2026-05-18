//! SNS topic-policy authz hook (v0.4.2).
//!
//! Mirrors `services/sqs/authz.zig` (v0.3.3). SNS has no PAB or ACLs;
//! the only authorization surface is the Topic Policy attribute, which
//! v0.4.1 storage helpers (`AddPermission` / `RemovePermission` /
//! `SetTopicAttributes`) populate on `SnsTopicSlot.attrs.policy`.
//!
//! Cascade:
//!   1. `--no-auth` → allow.
//!   2. Account-scoped op (CreateTopic / ListTopics / ListSubscriptions)
//!      → require non-anonymous principal; otherwise deny.
//!   3. Topic-scoped op, principal is the configured access_key → allow
//!      (owner-implicit, matches AWS).
//!   4. No topic name resolved → deny.
//!   5. Topic has no Policy → deny (only owner can reach, owner caught
//!      in step 3).
//!   6. Topic has a Policy → evaluate via the existing
//!      `auth/policy_eval.zig`. Allow / Deny short-circuit; `no_match`
//!      → default-deny.
//!
//! Called from `services/sns/mod.zig::handle()` between action match
//! and op dispatch. Result is wrapped into an `AuthorizationError`
//! response when `.deny`.

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const principal_mod = @import("../../auth/principal.zig");
const policy_doc = @import("../../wire/policy_doc.zig");
const policy_eval = @import("../../auth/policy_eval.zig");
const sns_action_map = @import("../../auth/sns_action_map.zig");
const params_mod = @import("../../wire/sns/params.zig");
const mod = @import("mod.zig");

pub const Decision = enum { allow, deny };

pub fn check(ctx: mod.Context, action: []const u8) Decision {
    // (1) `--no-auth` bypasses the entire gate.
    if (ctx.no_auth) return .allow;

    // (2) Account-scoped ops only require a non-anonymous principal.
    if (sns_action_map.isAccountScoped(action)) {
        return if (ctx.principal.kind == .anonymous) .deny else .allow;
    }

    // (3) Topic-scoped op + owner principal → allow.
    if (ctx.principal.kind == .aws_account and std.mem.eql(u8, ctx.principal.id, ctx.access_key))
        return .allow;

    // (4) Resolve the topic name for the resource being acted on.
    const topic_name = extractTopicName(ctx.request.params) orelse return .deny;

    // (5) Fetch the topic's policy. Missing topic → deny (the handler
    // would surface NotFound, but we deny first since unauth'd callers
    // shouldn't learn which topics exist).
    const slot = ctx.backend.getTopicAttributes(topic_name) catch return .deny;
    const policy_str = slot.attrs.policy orelse return .deny;

    // (6) Parse + evaluate the policy.
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const policy = policy_doc.parse(arena, policy_str) catch return .deny;

    var arn_buf: [512]u8 = undefined;
    const resource_arn = std.fmt.bufPrint(&arn_buf, "arn:aws:sns:{s}:{s}:{s}", .{
        ctx.region, ctx.account_id, topic_name,
    }) catch return .deny;

    const iam_action = sns_action_map.actionFor(action);
    const decision = policy_eval.evaluate(policy, .{
        .principal = ctx.principal,
        .action = iam_action,
        .resource_arn = resource_arn,
    });
    return switch (decision) {
        .allow => .allow,
        .deny, .no_match => .deny,
    };
}

/// Pull the topic name out of the request params. SNS ops carry the
/// resource via one of three fields, depending on the op:
///   * `TopicArn`          — most ops (Publish, Subscribe, DeleteTopic, ...)
///   * `SubscriptionArn`   — Unsubscribe / Get/SetSubscriptionAttributes
///                            (sub ARN is `<topic-arn>:<sub_id>`, so the
///                            second-to-last colon segment is the topic)
///   * `ResourceArn`       — TagResource / UntagResource / ListTagsForResource
///                            (always a topic ARN)
fn extractTopicName(params: []const params_mod.Param) ?[]const u8 {
    if (params_mod.get(params, "TopicArn")) |arn| return topicFromTopicArn(arn);
    if (params_mod.get(params, "ResourceArn")) |arn| return topicFromTopicArn(arn);
    if (params_mod.get(params, "SubscriptionArn")) |arn| return topicFromSubscriptionArn(arn);
    return null;
}

/// `arn:aws:sns:<region>:<account>:<topic>` → `<topic>`.
fn topicFromTopicArn(arn: []const u8) ?[]const u8 {
    const last_colon = std.mem.lastIndexOfScalar(u8, arn, ':') orelse return null;
    if (last_colon + 1 >= arn.len) return null;
    return arn[last_colon + 1 ..];
}

/// `arn:aws:sns:<region>:<account>:<topic>:<sub_id>` → `<topic>`.
fn topicFromSubscriptionArn(arn: []const u8) ?[]const u8 {
    const last = std.mem.lastIndexOfScalar(u8, arn, ':') orelse return null;
    if (last == 0) return null;
    const head = arn[0..last];
    const second_to_last = std.mem.lastIndexOfScalar(u8, head, ':') orelse return null;
    if (second_to_last + 1 >= head.len) return null;
    return head[second_to_last + 1 ..];
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "topicFromTopicArn: standard shape" {
    try testing.expectEqualStrings("orders", topicFromTopicArn("arn:aws:sns:us-east-1:000000000000:orders").?);
}

test "topicFromTopicArn: malformed → null" {
    try testing.expectEqual(@as(?[]const u8, null), topicFromTopicArn("not-an-arn"));
    try testing.expectEqual(@as(?[]const u8, null), topicFromTopicArn("arn:aws:sns:us-east-1:000000000000:"));
}

test "topicFromSubscriptionArn: extracts topic" {
    try testing.expectEqualStrings(
        "orders",
        topicFromSubscriptionArn("arn:aws:sns:us-east-1:000000000000:orders:abc123").?,
    );
}

test "topicFromSubscriptionArn: malformed → null" {
    try testing.expectEqual(@as(?[]const u8, null), topicFromSubscriptionArn("nope"));
    try testing.expectEqual(@as(?[]const u8, null), topicFromSubscriptionArn("only-one:colon"));
}

test "extractTopicName: prefers TopicArn over others" {
    const ps = [_]params_mod.Param{
        .{ .key = "TopicArn", .value = "arn:aws:sns:us-east-1:000000000000:t1" },
        .{ .key = "ResourceArn", .value = "arn:aws:sns:us-east-1:000000000000:other" },
    };
    try testing.expectEqualStrings("t1", extractTopicName(&ps).?);
}

test "extractTopicName: falls back to ResourceArn" {
    const ps = [_]params_mod.Param{
        .{ .key = "ResourceArn", .value = "arn:aws:sns:us-east-1:000000000000:tagged-topic" },
    };
    try testing.expectEqualStrings("tagged-topic", extractTopicName(&ps).?);
}

test "extractTopicName: SubscriptionArn → parent topic" {
    const ps = [_]params_mod.Param{
        .{ .key = "SubscriptionArn", .value = "arn:aws:sns:us-east-1:000000000000:parent-topic:sub-id-x" },
    };
    try testing.expectEqualStrings("parent-topic", extractTopicName(&ps).?);
}

test "extractTopicName: none present → null" {
    const ps = [_]params_mod.Param{
        .{ .key = "Action", .value = "ListTopics" },
    };
    try testing.expectEqual(@as(?[]const u8, null), extractTopicName(&ps));
}

test "no_auth bypasses gate" {
    var ctx: mod.Context = undefined;
    ctx.no_auth = true;
    ctx.principal = .{ .kind = .anonymous, .id = "" };
    try testing.expectEqual(Decision.allow, check(ctx, "Publish"));
}
