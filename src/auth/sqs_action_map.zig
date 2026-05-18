//! Maps SQS X-Amz-Target op strings (e.g., "SendMessage") to their
//! IAM action equivalents (e.g., "sqs:SendMessage"). Used by the
//! v0.3.3 queue-policy authz hook in `services/sqs/authz.zig`.
//!
//! Why a string-keyed switch (not enum)?
//! The SQS dispatcher in `services/sqs/mod.zig::handle()` dispatches on
//! the target string directly rather than a parsed enum; introducing
//! one solely for authz isn't worth the duplication. The switch here
//! is the source of truth for the SQS action namespace.

const std = @import("std");

/// AWS IAM action string for the given X-Amz-Target value, or `""` if
/// the target is unknown (the dispatcher will reject it separately).
/// Batch ops map to their per-message action (AWS-exact).
pub fn actionFor(target: []const u8) []const u8 {
    const Pair = struct { target: []const u8, action: []const u8 };
    const table = [_]Pair{
        // Queue lifecycle.
        .{ .target = "CreateQueue", .action = "sqs:CreateQueue" },
        .{ .target = "DeleteQueue", .action = "sqs:DeleteQueue" },
        .{ .target = "ListQueues", .action = "sqs:ListQueues" },
        .{ .target = "GetQueueUrl", .action = "sqs:GetQueueUrl" },
        // Queue attributes / tags.
        .{ .target = "GetQueueAttributes", .action = "sqs:GetQueueAttributes" },
        .{ .target = "SetQueueAttributes", .action = "sqs:SetQueueAttributes" },
        .{ .target = "PurgeQueue", .action = "sqs:PurgeQueue" },
        .{ .target = "TagQueue", .action = "sqs:TagQueue" },
        .{ .target = "UntagQueue", .action = "sqs:UntagQueue" },
        .{ .target = "ListQueueTags", .action = "sqs:ListQueueTags" },
        // Messages.
        .{ .target = "SendMessage", .action = "sqs:SendMessage" },
        .{ .target = "ReceiveMessage", .action = "sqs:ReceiveMessage" },
        .{ .target = "DeleteMessage", .action = "sqs:DeleteMessage" },
        .{ .target = "ChangeMessageVisibility", .action = "sqs:ChangeMessageVisibility" },
        // Batches map to the per-message action (AWS-exact).
        .{ .target = "SendMessageBatch", .action = "sqs:SendMessage" },
        .{ .target = "DeleteMessageBatch", .action = "sqs:DeleteMessage" },
        .{ .target = "ChangeMessageVisibilityBatch", .action = "sqs:ChangeMessageVisibility" },
        // Robustness ops (v0.3.2).
        .{ .target = "ListDeadLetterSourceQueues", .action = "sqs:ListDeadLetterSourceQueues" },
        .{ .target = "AddPermission", .action = "sqs:AddPermission" },
        .{ .target = "RemovePermission", .action = "sqs:RemovePermission" },
        .{ .target = "StartMessageMoveTask", .action = "sqs:StartMessageMoveTask" },
        .{ .target = "CancelMessageMoveTask", .action = "sqs:CancelMessageMoveTask" },
        .{ .target = "ListMessageMoveTasks", .action = "sqs:ListMessageMoveTasks" },
    };
    for (table) |row| {
        if (std.mem.eql(u8, row.target, target)) return row.action;
    }
    return "";
}

/// True if the op operates at account scope (no specific queue
/// involved at request time). Used by the authz hook to skip queue-
/// policy evaluation for these — only the principal matters.
pub fn isAccountScoped(target: []const u8) bool {
    return std.mem.eql(u8, target, "CreateQueue") or
        std.mem.eql(u8, target, "ListQueues");
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "actionFor: maps known targets" {
    try testing.expectEqualStrings("sqs:SendMessage", actionFor("SendMessage"));
    try testing.expectEqualStrings("sqs:ReceiveMessage", actionFor("ReceiveMessage"));
    try testing.expectEqualStrings("sqs:CreateQueue", actionFor("CreateQueue"));
    // Batches map to the per-message action.
    try testing.expectEqualStrings("sqs:SendMessage", actionFor("SendMessageBatch"));
    try testing.expectEqualStrings("sqs:DeleteMessage", actionFor("DeleteMessageBatch"));
    // Unknown → empty.
    try testing.expectEqualStrings("", actionFor("UnknownOp"));
}

test "isAccountScoped: only CreateQueue + ListQueues" {
    try testing.expect(isAccountScoped("CreateQueue"));
    try testing.expect(isAccountScoped("ListQueues"));
    try testing.expect(!isAccountScoped("SendMessage"));
    try testing.expect(!isAccountScoped("GetQueueUrl"));
}
