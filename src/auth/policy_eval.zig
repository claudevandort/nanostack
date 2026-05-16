//! IAM-style bucket-policy evaluator.
//!
//! Inputs a parsed `PolicyDocument` plus the request's `EvalContext`
//! (principal + action + resource ARN), returns a `Decision`:
//!   - `.allow`     — at least one `Allow` statement matched.
//!   - `.deny`      — at least one `Deny` statement matched. Beats Allow.
//!   - `.no_match`  — no statement matched. Caller falls through to ACL.
//!
//! Statements with `has_condition` or `has_unsupported` are skipped
//! (treated as no-match for that statement) — documented v1 divergences.

const std = @import("std");
const policy_doc = @import("../wire/policy_doc.zig");
const principal_mod = @import("principal.zig");

pub const Decision = enum { allow, deny, no_match };

pub const EvalContext = struct {
    principal: principal_mod.Principal,
    /// IAM action string, e.g. `"s3:GetObject"`.
    action: []const u8,
    /// Full resource ARN, e.g. `"arn:aws:s3:::bucket/key"`.
    resource_arn: []const u8,
};

pub fn evaluate(policy: policy_doc.PolicyDocument, ctx: EvalContext) Decision {
    var allow_seen = false;
    for (policy.statements) |stmt| {
        if (stmt.has_condition or stmt.has_unsupported) continue;
        if (!principalMatches(stmt.principal, ctx.principal)) continue;
        if (!anyPatternMatches(stmt.actions, ctx.action)) continue;
        if (!anyPatternMatches(stmt.resources, ctx.resource_arn)) continue;
        switch (stmt.effect) {
            .deny => return .deny, // Explicit Deny ends evaluation.
            .allow => allow_seen = true,
        }
    }
    return if (allow_seen) .allow else .no_match;
}

fn principalMatches(p: policy_doc.Principal, who: principal_mod.Principal) bool {
    switch (p) {
        .wildcard => return true, // `"*"` matches anyone.
        .aws_accounts => |arns| {
            if (who.kind == .anonymous) return false; // ARN-named principals don't match anonymous.
            for (arns) |arn| {
                // Exact string match: e.g. policy `"AWS": "test"` and our access_key is `"test"`.
                if (std.mem.eql(u8, arn, who.id)) return true;
                // ARN-suffix match: AWS IAM principal ARNs end with `/<name>`
                // — e.g. `arn:aws:iam::000:user/test`, `:role/test`,
                // `:federated-user/test`. We accept any ARN whose last
                // path segment after `/` is the configured access_key.
                if (arn.len > who.id.len + 1 and
                    arn[arn.len - who.id.len - 1] == '/' and
                    std.mem.eql(u8, arn[arn.len - who.id.len ..], who.id))
                {
                    return true;
                }
            }
            return false;
        },
    }
}

fn anyPatternMatches(patterns: []const []const u8, target: []const u8) bool {
    for (patterns) |pat| {
        if (globMatch(pat, target)) return true;
    }
    return false;
}

/// AWS-style glob match. `*` matches any sequence (including empty).
/// Pure iterative two-pointer — no recursion, no allocation.
fn globMatch(pattern: []const u8, target: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var match_t: usize = 0;
    while (t < target.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            match_t = t;
            p += 1;
        } else if (p < pattern.len and pattern[p] == target[t]) {
            p += 1;
            t += 1;
        } else if (star) |s| {
            p = s + 1;
            match_t += 1;
            t = match_t;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') : (p += 1) {}
    return p == pattern.len;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Principal = principal_mod.Principal;

fn parsePolicy(body: []const u8) !policy_doc.PolicyDocument {
    return try policy_doc.parse(testing.allocator, body);
}

test "evaluate: empty Allow against wildcard principal → allow" {
    var doc = try parsePolicy(
        \\{"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}]}
    );
    defer doc.deinit(testing.allocator);
    const d = evaluate(doc, .{
        .principal = Principal.anonymous(),
        .action = "s3:GetObject",
        .resource_arn = "arn:aws:s3:::b/key",
    });
    try testing.expectEqual(Decision.allow, d);
}

test "evaluate: Deny wins over Allow" {
    var doc = try parsePolicy(
        \\{"Statement":[
        \\  {"Effect":"Allow","Principal":"*","Action":"s3:*","Resource":"*"},
        \\  {"Effect":"Deny","Principal":"*","Action":"s3:DeleteObject","Resource":"*"}
        \\]}
    );
    defer doc.deinit(testing.allocator);
    const d = evaluate(doc, .{
        .principal = Principal.anonymous(),
        .action = "s3:DeleteObject",
        .resource_arn = "arn:aws:s3:::b/k",
    });
    try testing.expectEqual(Decision.deny, d);
}

test "evaluate: no matching statement → no_match" {
    var doc = try parsePolicy(
        \\{"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::other/*"}]}
    );
    defer doc.deinit(testing.allocator);
    const d = evaluate(doc, .{
        .principal = Principal.anonymous(),
        .action = "s3:GetObject",
        .resource_arn = "arn:aws:s3:::mine/k",
    });
    try testing.expectEqual(Decision.no_match, d);
}

test "evaluate: action wildcard s3:Get*" {
    var doc = try parsePolicy(
        \\{"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:Get*","Resource":"*"}]}
    );
    defer doc.deinit(testing.allocator);
    const got = evaluate(doc, .{
        .principal = Principal.anonymous(),
        .action = "s3:GetObject",
        .resource_arn = "arn:aws:s3:::b/k",
    });
    try testing.expectEqual(Decision.allow, got);
    const list = evaluate(doc, .{
        .principal = Principal.anonymous(),
        .action = "s3:GetBucketAcl",
        .resource_arn = "arn:aws:s3:::b",
    });
    try testing.expectEqual(Decision.allow, list);
    const put = evaluate(doc, .{
        .principal = Principal.anonymous(),
        .action = "s3:PutObject",
        .resource_arn = "arn:aws:s3:::b/k",
    });
    try testing.expectEqual(Decision.no_match, put);
}

test "evaluate: resource wildcard arn:aws:s3:::bucket/*" {
    var doc = try parsePolicy(
        \\{"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}]}
    );
    defer doc.deinit(testing.allocator);
    const obj = evaluate(doc, .{
        .principal = Principal.anonymous(),
        .action = "s3:GetObject",
        .resource_arn = "arn:aws:s3:::b/some/key",
    });
    try testing.expectEqual(Decision.allow, obj);
    const bucket = evaluate(doc, .{
        .principal = Principal.anonymous(),
        .action = "s3:GetObject",
        .resource_arn = "arn:aws:s3:::b",
    });
    try testing.expectEqual(Decision.no_match, bucket);
}

test "evaluate: Principal aws_account exact-string match" {
    var doc = try parsePolicy(
        \\{"Statement":[{"Effect":"Deny","Principal":{"AWS":"test"},"Action":"s3:DeleteObject","Resource":"*"}]}
    );
    defer doc.deinit(testing.allocator);
    const d = evaluate(doc, .{
        .principal = Principal.awsAccount("test"),
        .action = "s3:DeleteObject",
        .resource_arn = "arn:aws:s3:::b/k",
    });
    try testing.expectEqual(Decision.deny, d);
}

test "evaluate: Principal aws_account ARN-suffix match" {
    var doc = try parsePolicy(
        \\{"Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::000:user/test"},"Action":"s3:*","Resource":"*"}]}
    );
    defer doc.deinit(testing.allocator);
    const d = evaluate(doc, .{
        .principal = Principal.awsAccount("test"),
        .action = "s3:GetObject",
        .resource_arn = "arn:aws:s3:::b/k",
    });
    try testing.expectEqual(Decision.allow, d);
}

test "evaluate: anonymous never matches aws_accounts principal" {
    var doc = try parsePolicy(
        \\{"Statement":[{"Effect":"Allow","Principal":{"AWS":"test"},"Action":"s3:*","Resource":"*"}]}
    );
    defer doc.deinit(testing.allocator);
    const d = evaluate(doc, .{
        .principal = Principal.anonymous(),
        .action = "s3:GetObject",
        .resource_arn = "arn:aws:s3:::b/k",
    });
    try testing.expectEqual(Decision.no_match, d);
}

test "evaluate: Condition-bearing statement is skipped" {
    var doc = try parsePolicy(
        \\{"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"*","Condition":{"StringEquals":{"aws:Referer":"x"}}}]}
    );
    defer doc.deinit(testing.allocator);
    const d = evaluate(doc, .{
        .principal = Principal.anonymous(),
        .action = "s3:GetObject",
        .resource_arn = "arn:aws:s3:::b/k",
    });
    try testing.expectEqual(Decision.no_match, d);
}

test "evaluate: NotPrincipal-bearing statement is skipped" {
    var doc = try parsePolicy(
        \\{"Statement":[{"Effect":"Deny","NotPrincipal":{"AWS":"arn:x"},"Action":"s3:*","Resource":"*"}]}
    );
    defer doc.deinit(testing.allocator);
    const d = evaluate(doc, .{
        .principal = Principal.anonymous(),
        .action = "s3:GetObject",
        .resource_arn = "arn:aws:s3:::b/k",
    });
    try testing.expectEqual(Decision.no_match, d);
}

test "globMatch: AWS-shape patterns" {
    try testing.expect(globMatch("*", "anything"));
    try testing.expect(globMatch("s3:*", "s3:GetObject"));
    try testing.expect(globMatch("s3:Get*", "s3:GetObject"));
    try testing.expect(globMatch("s3:Get*", "s3:GetBucketAcl"));
    try testing.expect(!globMatch("s3:Get*", "s3:PutObject"));
    try testing.expect(globMatch("arn:aws:s3:::b/*", "arn:aws:s3:::b/k"));
    try testing.expect(globMatch("arn:aws:s3:::b/*", "arn:aws:s3:::b/sub/k"));
    try testing.expect(!globMatch("arn:aws:s3:::b/*", "arn:aws:s3:::b"));
    try testing.expect(!globMatch("arn:aws:s3:::b/*", "arn:aws:s3:::other/k"));
    try testing.expect(globMatch("a*b*c", "a-XX-b-YY-c"));
    try testing.expect(globMatch("", ""));
    try testing.expect(!globMatch("", "a"));
    try testing.expect(globMatch("*", ""));
}
