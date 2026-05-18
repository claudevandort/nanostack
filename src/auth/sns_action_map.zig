//! Maps SNS `Action=<Op>` query-param values (e.g., "Publish") to their
//! IAM action equivalents (e.g., "sns:Publish"). Used by the v0.4.2
//! topic-policy authz hook in `services/sns/authz.zig`.
//!
//! Like SQS, the SNS dispatcher in `services/sns/mod.zig::handle()`
//! dispatches on the action string directly — no parsed enum. The
//! switch here is the source of truth for the SNS action namespace.

const std = @import("std");

/// AWS IAM action string for the given `Action=<Op>` value, or `""` if
/// the action is unknown (the dispatcher will reject it separately).
pub fn actionFor(action: []const u8) []const u8 {
    const Pair = struct { action: []const u8, iam: []const u8 };
    const table = [_]Pair{
        // Topic lifecycle.
        .{ .action = "CreateTopic", .iam = "sns:CreateTopic" },
        .{ .action = "DeleteTopic", .iam = "sns:DeleteTopic" },
        .{ .action = "ListTopics", .iam = "sns:ListTopics" },
        .{ .action = "GetTopicAttributes", .iam = "sns:GetTopicAttributes" },
        .{ .action = "SetTopicAttributes", .iam = "sns:SetTopicAttributes" },
        // Subscriptions.
        .{ .action = "Subscribe", .iam = "sns:Subscribe" },
        .{ .action = "Unsubscribe", .iam = "sns:Unsubscribe" },
        .{ .action = "ListSubscriptions", .iam = "sns:ListSubscriptions" },
        .{ .action = "ListSubscriptionsByTopic", .iam = "sns:ListSubscriptionsByTopic" },
        .{ .action = "GetSubscriptionAttributes", .iam = "sns:GetSubscriptionAttributes" },
        .{ .action = "SetSubscriptionAttributes", .iam = "sns:SetSubscriptionAttributes" },
        .{ .action = "ConfirmSubscription", .iam = "sns:ConfirmSubscription" },
        // Publish.
        .{ .action = "Publish", .iam = "sns:Publish" },
        // AWS evaluates batch publish against `sns:Publish` (per-message),
        // mirroring SQS's SendMessageBatch → sqs:SendMessage mapping.
        .{ .action = "PublishBatch", .iam = "sns:Publish" },
        // Tags.
        .{ .action = "TagResource", .iam = "sns:TagResource" },
        .{ .action = "UntagResource", .iam = "sns:UntagResource" },
        .{ .action = "ListTagsForResource", .iam = "sns:ListTagsForResource" },
        // Permissions (v0.4.1).
        .{ .action = "AddPermission", .iam = "sns:AddPermission" },
        .{ .action = "RemovePermission", .iam = "sns:RemovePermission" },
    };
    for (table) |row| {
        if (std.mem.eql(u8, row.action, action)) return row.iam;
    }
    return "";
}

/// True if the op operates at account scope (no specific topic involved
/// at request time). Used by the authz hook to skip topic-policy
/// evaluation for these — only the principal matters.
pub fn isAccountScoped(action: []const u8) bool {
    return std.mem.eql(u8, action, "CreateTopic") or
        std.mem.eql(u8, action, "ListTopics") or
        std.mem.eql(u8, action, "ListSubscriptions");
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "actionFor: maps known actions" {
    try testing.expectEqualStrings("sns:Publish", actionFor("Publish"));
    try testing.expectEqualStrings("sns:Subscribe", actionFor("Subscribe"));
    try testing.expectEqualStrings("sns:CreateTopic", actionFor("CreateTopic"));
    // PublishBatch maps to the per-message action.
    try testing.expectEqualStrings("sns:Publish", actionFor("PublishBatch"));
    // Permissions ops surfaced in v0.4.1.
    try testing.expectEqualStrings("sns:AddPermission", actionFor("AddPermission"));
    try testing.expectEqualStrings("sns:RemovePermission", actionFor("RemovePermission"));
    // Unknown → empty.
    try testing.expectEqualStrings("", actionFor("UnknownOp"));
}

test "isAccountScoped: CreateTopic + ListTopics + ListSubscriptions" {
    try testing.expect(isAccountScoped("CreateTopic"));
    try testing.expect(isAccountScoped("ListTopics"));
    try testing.expect(isAccountScoped("ListSubscriptions"));
    try testing.expect(!isAccountScoped("Publish"));
    try testing.expect(!isAccountScoped("Subscribe"));
    try testing.expect(!isAccountScoped("ListSubscriptionsByTopic"));
}
