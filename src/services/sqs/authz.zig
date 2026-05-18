//! SQS queue-policy authz hook (v0.3.3).
//!
//! Smaller surface than S3's `auth/authz.zig`: SQS has no ACLs, no
//! Public Access Block, no bucket-owner-implicit-deny. The cascade is:
//!
//!   1. `--no-auth` → allow (matches the S3 hook bypass).
//!   2. Account-scoped op (CreateQueue / ListQueues) → require non-
//!      anonymous principal; otherwise deny.
//!   3. Queue-scoped op, principal is the configured access_key →
//!      allow (owner-implicit). Owner bypasses any Policy, matching
//!      AWS-real behaviour.
//!   4. Queue-scoped op without a queue name resolved → deny.
//!   5. Queue-scoped op + queue has no Policy → deny (only owner can
//!      reach the queue; owner was caught in step 3).
//!   6. Queue has a Policy → evaluate via the existing
//!      `auth/policy_eval.zig`. Allow / Deny short-circuit; `no_match`
//!      → default-deny (matches AWS).
//!
//! Called from `services/sqs/mod.zig::handle()` between the target
//! match and the op-handler dispatch. The result is wrapped by the
//! caller into an `AccessDenied` error response when `.deny`.

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const principal_mod = @import("../../auth/principal.zig");
const policy_doc = @import("../../wire/policy_doc.zig");
const policy_eval = @import("../../auth/policy_eval.zig");
const sqs_action_map = @import("../../auth/sqs_action_map.zig");
const mod = @import("mod.zig");

pub const Decision = enum { allow, deny };

pub fn check(ctx: mod.Context, target: []const u8, queue_name: ?[]const u8) Decision {
    // (1) `--no-auth` bypasses the entire gate.
    if (ctx.no_auth) return .allow;

    // (2) Account-scoped ops only require a non-anonymous principal.
    if (sqs_action_map.isAccountScoped(target)) {
        return if (ctx.principal.kind == .anonymous) .deny else .allow;
    }

    // (3) Queue-scoped op + owner principal → allow.
    if (ctx.principal.kind == .aws_account and std.mem.eql(u8, ctx.principal.id, ctx.access_key))
        return .allow;

    // (4) No queue name resolved for a queue-scoped op → deny.
    const qname = queue_name orelse return .deny;

    // (5) Fetch the queue's policy. Missing queue → deny (handler
    // would have surfaced NonExistentQueue, but we deny now since
    // unauth'd callers don't get info about which queues exist).
    const slot = ctx.backend.getQueueUrl(qname) catch return .deny;
    const policy_str = slot.attrs.policy orelse return .deny;

    // (6) Parse + evaluate the policy.
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const policy = policy_doc.parse(arena, policy_str) catch return .deny;

    var arn_buf: [512]u8 = undefined;
    const resource_arn = std.fmt.bufPrint(&arn_buf, "arn:aws:sqs:{s}:{s}:{s}", .{
        ctx.region, ctx.account_id, qname,
    }) catch return .deny;

    const action = sqs_action_map.actionFor(target);
    const decision = policy_eval.evaluate(policy, .{
        .principal = ctx.principal,
        .action = action,
        .resource_arn = resource_arn,
    });
    return switch (decision) {
        .allow => .allow,
        .deny, .no_match => .deny,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "no_auth bypasses gate" {
    // The Context type carries backend etc. that we can't easily mock
    // here; the integration coverage lives in
    // tests/conformance/python/sqs/test_policy_enforcement.py.
    // This test just exercises the no-side-effect path.
    var ctx: mod.Context = undefined;
    ctx.no_auth = true;
    ctx.principal = .{ .kind = .anonymous, .id = "" };
    try testing.expectEqual(Decision.allow, check(ctx, "SendMessage", null));
}
