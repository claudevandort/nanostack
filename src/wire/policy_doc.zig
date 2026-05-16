//! Structured S3 bucket-policy document.
//!
//! Companion to `wire/policy_parser.zig` (which validates raw JSON
//! well-formedness for the round-trip path). This module parses the JSON
//! into a typed `PolicyDocument` that the M14 policy evaluator consumes.
//!
//! Out-of-scope for v1 (statements set `has_unsupported = true` and the
//! evaluator skips them):
//!   - `NotPrincipal`, `NotAction`, `NotResource` (rarely used in S3).
//!   - `Principal: { "Service": ... }` / `"CanonicalUser"` / `"Federated"`
//!     (single-tenant nanostack can't evaluate these meaningfully).
//!
//! Statements with any `Condition` block set `has_condition = true`. The
//! evaluator skips those too — condition-keys are a permanent v1 divergence
//! documented in `docs/SUPPORT.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ParseError = error{
    MalformedPolicy,
    OutOfMemory,
};

pub const Effect = enum { allow, deny };

/// `Principal` for a statement.
pub const Principal = union(enum) {
    /// `"Principal": "*"` or `{"AWS": "*"}` (anyone matches).
    wildcard,
    /// `{"AWS": "arn:..."}` or `{"AWS": ["arn:...", ...]}`. Slice is
    /// owned by the document allocator.
    aws_accounts: []const []const u8,
};

pub const Statement = struct {
    /// Optional decorative `Sid`. Owned slice or null.
    sid: ?[]const u8 = null,
    effect: Effect,
    principal: Principal,
    /// One or more action patterns, e.g. `["s3:GetObject", "s3:List*"]`.
    /// Wildcards within each pattern are handled at match time.
    actions: []const []const u8,
    /// One or more resource ARN patterns. Wildcards within each pattern
    /// are handled at match time (e.g. `arn:aws:s3:::bucket/*`).
    resources: []const []const u8,
    /// True if any `Condition` block was present. Evaluator treats the
    /// statement as no-match in this case (documented divergence).
    has_condition: bool = false,
    /// True if the statement uses any feature we don't support
    /// (NotPrincipal, NotAction, NotResource, non-AWS Principal type).
    /// Evaluator treats it as no-match.
    has_unsupported: bool = false,
};

pub const PolicyDocument = struct {
    /// Optional `Version` from the policy. AWS canonical is "2012-10-17".
    version: ?[]const u8 = null,
    /// Optional `Id`.
    id: ?[]const u8 = null,
    /// Parsed statements. Always at least one (empty `Statement` array
    /// → MalformedPolicy).
    statements: []Statement,

    pub fn deinit(self: *const PolicyDocument, allocator: Allocator) void {
        if (self.version) |v| allocator.free(v);
        if (self.id) |v| allocator.free(v);
        for (self.statements) |s| {
            if (s.sid) |v| allocator.free(v);
            switch (s.principal) {
                .wildcard => {},
                .aws_accounts => |arns| {
                    for (arns) |a| allocator.free(a);
                    allocator.free(arns);
                },
            }
            for (s.actions) |a| allocator.free(a);
            allocator.free(s.actions);
            for (s.resources) |r| allocator.free(r);
            allocator.free(s.resources);
        }
        allocator.free(self.statements);
    }
};

/// Parse a JSON bucket-policy body into a structured `PolicyDocument`.
///
/// Caller owns the returned struct; call `deinit` to free.
pub fn parse(allocator: Allocator, body: []const u8) ParseError!PolicyDocument {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.MalformedPolicy;
    defer parsed.deinit();

    if (parsed.value != .object) return ParseError.MalformedPolicy;
    const root = parsed.value.object;

    var doc: PolicyDocument = .{ .statements = &.{} };
    errdefer doc.deinit(allocator);

    if (root.get("Version")) |v| {
        if (v != .string) return ParseError.MalformedPolicy;
        doc.version = try allocator.dupe(u8, v.string);
    }
    if (root.get("Id")) |v| {
        if (v != .string) return ParseError.MalformedPolicy;
        doc.id = try allocator.dupe(u8, v.string);
    }

    const stmt_node = root.get("Statement") orelse return ParseError.MalformedPolicy;

    // `Statement` can be a single object or an array of objects.
    var stmts: std.ArrayList(Statement) = .empty;
    errdefer {
        for (stmts.items) |s| freeStatement(allocator, s);
        stmts.deinit(allocator);
    }

    switch (stmt_node) {
        .object => {
            const s = try parseStatement(allocator, stmt_node);
            try stmts.append(allocator, s);
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (item != .object) return ParseError.MalformedPolicy;
                const s = try parseStatement(allocator, item);
                try stmts.append(allocator, s);
            }
        },
        else => return ParseError.MalformedPolicy,
    }
    if (stmts.items.len == 0) return ParseError.MalformedPolicy;

    doc.statements = try stmts.toOwnedSlice(allocator);
    return doc;
}

fn parseStatement(allocator: Allocator, node: std.json.Value) ParseError!Statement {
    const obj = node.object;
    var s: Statement = .{
        .effect = undefined,
        .principal = .wildcard,
        .actions = &.{},
        .resources = &.{},
    };
    errdefer freeStatement(allocator, s);

    if (obj.get("Sid")) |v| {
        if (v != .string) return ParseError.MalformedPolicy;
        s.sid = try allocator.dupe(u8, v.string);
    }

    // Effect — required.
    const effect_node = obj.get("Effect") orelse return ParseError.MalformedPolicy;
    if (effect_node != .string) return ParseError.MalformedPolicy;
    if (std.mem.eql(u8, effect_node.string, "Allow")) {
        s.effect = .allow;
    } else if (std.mem.eql(u8, effect_node.string, "Deny")) {
        s.effect = .deny;
    } else {
        return ParseError.MalformedPolicy;
    }

    // NotPrincipal / NotAction / NotResource → unsupported (don't fail).
    if (obj.contains("NotPrincipal") or obj.contains("NotAction") or obj.contains("NotResource")) {
        s.has_unsupported = true;
    }

    // Condition → mark, don't fail.
    if (obj.get("Condition")) |c| {
        // Any non-empty Condition block flips the flag. Empty {} also flips
        // (defensive — AWS treats empty Condition as no-match too).
        _ = c;
        s.has_condition = true;
    }

    // Principal — required unless NotPrincipal supplied.
    if (obj.get("Principal")) |p| {
        s.principal = try parsePrincipal(allocator, p, &s.has_unsupported);
    } else if (!s.has_unsupported) {
        return ParseError.MalformedPolicy;
    }

    // Action — required.
    if (obj.get("Action")) |a| {
        s.actions = try parseStringOrArray(allocator, a);
    } else if (!s.has_unsupported) {
        return ParseError.MalformedPolicy;
    }

    // Resource — required.
    if (obj.get("Resource")) |r| {
        s.resources = try parseStringOrArray(allocator, r);
    } else if (!s.has_unsupported) {
        return ParseError.MalformedPolicy;
    }

    return s;
}

fn parsePrincipal(allocator: Allocator, node: std.json.Value, has_unsupported: *bool) ParseError!Principal {
    switch (node) {
        .string => |s| {
            if (std.mem.eql(u8, s, "*")) return .wildcard;
            // AWS only accepts "*" as the string form. Anything else is
            // malformed for the wildcard case. But to be lenient with
            // policies generated by other tools, treat as unsupported.
            has_unsupported.* = true;
            return .wildcard;
        },
        .object => |o| {
            // Recognised key: "AWS". Anything else → unsupported.
            if (o.count() != 1 or o.get("AWS") == null) {
                has_unsupported.* = true;
                return .wildcard;
            }
            const aws = o.get("AWS").?;
            return switch (aws) {
                .string => |s| blk: {
                    if (std.mem.eql(u8, s, "*")) break :blk .wildcard;
                    const list = try allocator.alloc([]const u8, 1);
                    errdefer allocator.free(list);
                    list[0] = try allocator.dupe(u8, s);
                    break :blk .{ .aws_accounts = list };
                },
                .array => |arr| blk: {
                    // If any element is "*", treat the whole as wildcard.
                    for (arr.items) |item| {
                        if (item == .string and std.mem.eql(u8, item.string, "*")) break :blk .wildcard;
                    }
                    var owned: std.ArrayList([]const u8) = .empty;
                    errdefer {
                        for (owned.items) |s| allocator.free(s);
                        owned.deinit(allocator);
                    }
                    for (arr.items) |item| {
                        if (item != .string) return ParseError.MalformedPolicy;
                        try owned.append(allocator, try allocator.dupe(u8, item.string));
                    }
                    break :blk .{ .aws_accounts = try owned.toOwnedSlice(allocator) };
                },
                else => return ParseError.MalformedPolicy,
            };
        },
        else => return ParseError.MalformedPolicy,
    }
}

fn parseStringOrArray(allocator: Allocator, node: std.json.Value) ParseError![]const []const u8 {
    switch (node) {
        .string => |s| {
            const list = try allocator.alloc([]const u8, 1);
            errdefer allocator.free(list);
            list[0] = try allocator.dupe(u8, s);
            return list;
        },
        .array => |arr| {
            var owned: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (owned.items) |s| allocator.free(s);
                owned.deinit(allocator);
            }
            for (arr.items) |item| {
                if (item != .string) return ParseError.MalformedPolicy;
                try owned.append(allocator, try allocator.dupe(u8, item.string));
            }
            return try owned.toOwnedSlice(allocator);
        },
        else => return ParseError.MalformedPolicy,
    }
}

fn freeStatement(allocator: Allocator, s: Statement) void {
    if (s.sid) |v| allocator.free(v);
    switch (s.principal) {
        .wildcard => {},
        .aws_accounts => |arns| {
            for (arns) |a| allocator.free(a);
            allocator.free(arns);
        },
    }
    for (s.actions) |a| allocator.free(a);
    allocator.free(s.actions);
    for (s.resources) |r| allocator.free(r);
    allocator.free(s.resources);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parse: minimal Allow with wildcard Principal" {
    const body =
        \\{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}]}
    ;
    var doc = try parse(testing.allocator, body);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualStrings("2012-10-17", doc.version.?);
    try testing.expectEqual(@as(usize, 1), doc.statements.len);
    const s = doc.statements[0];
    try testing.expectEqual(Effect.allow, s.effect);
    try testing.expect(s.principal == .wildcard);
    try testing.expectEqualStrings("s3:GetObject", s.actions[0]);
    try testing.expectEqualStrings("arn:aws:s3:::b/*", s.resources[0]);
    try testing.expect(!s.has_condition);
    try testing.expect(!s.has_unsupported);
}

test "parse: Principal {\"AWS\": \"*\"} → wildcard" {
    const body =
        \\{"Statement":[{"Effect":"Deny","Principal":{"AWS":"*"},"Action":"s3:*","Resource":"*"}]}
    ;
    var doc = try parse(testing.allocator, body);
    defer doc.deinit(testing.allocator);
    try testing.expect(doc.statements[0].principal == .wildcard);
}

test "parse: Principal {\"AWS\": \"arn\"} → single specific" {
    const body =
        \\{"Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::000:user/x"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}]}
    ;
    var doc = try parse(testing.allocator, body);
    defer doc.deinit(testing.allocator);
    const p = doc.statements[0].principal;
    try testing.expect(p == .aws_accounts);
    try testing.expectEqual(@as(usize, 1), p.aws_accounts.len);
    try testing.expectEqualStrings("arn:aws:iam::000:user/x", p.aws_accounts[0]);
}

test "parse: Principal {\"AWS\": [arn1, arn2]} → list" {
    const body =
        \\{"Statement":[{"Effect":"Allow","Principal":{"AWS":["a","b"]},"Action":"s3:GetObject","Resource":"*"}]}
    ;
    var doc = try parse(testing.allocator, body);
    defer doc.deinit(testing.allocator);
    const p = doc.statements[0].principal;
    try testing.expectEqual(@as(usize, 2), p.aws_accounts.len);
}

test "parse: Principal {\"AWS\": [\"*\", arn]} → wildcard wins" {
    const body =
        \\{"Statement":[{"Effect":"Allow","Principal":{"AWS":["*","arn:x"]},"Action":"s3:GetObject","Resource":"*"}]}
    ;
    var doc = try parse(testing.allocator, body);
    defer doc.deinit(testing.allocator);
    try testing.expect(doc.statements[0].principal == .wildcard);
}

test "parse: Action/Resource as array" {
    const body =
        \\{"Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject","s3:ListBucket"],"Resource":["arn:1","arn:2"]}]}
    ;
    var doc = try parse(testing.allocator, body);
    defer doc.deinit(testing.allocator);
    const s = doc.statements[0];
    try testing.expectEqual(@as(usize, 2), s.actions.len);
    try testing.expectEqual(@as(usize, 2), s.resources.len);
    try testing.expectEqualStrings("s3:ListBucket", s.actions[1]);
}

test "parse: Condition block flips has_condition" {
    const body =
        \\{"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"*","Condition":{"StringEquals":{"aws:Referer":"x"}}}]}
    ;
    var doc = try parse(testing.allocator, body);
    defer doc.deinit(testing.allocator);
    try testing.expect(doc.statements[0].has_condition);
}

test "parse: NotPrincipal flips has_unsupported" {
    const body =
        \\{"Statement":[{"Effect":"Deny","NotPrincipal":{"AWS":"arn:x"},"Action":"s3:*","Resource":"*"}]}
    ;
    var doc = try parse(testing.allocator, body);
    defer doc.deinit(testing.allocator);
    try testing.expect(doc.statements[0].has_unsupported);
}

test "parse: Principal {\"Service\":\"...\"} → has_unsupported, wildcard fallback" {
    const body =
        \\{"Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"s3:*","Resource":"*"}]}
    ;
    var doc = try parse(testing.allocator, body);
    defer doc.deinit(testing.allocator);
    try testing.expect(doc.statements[0].has_unsupported);
}

test "parse: Statement as a single object (not array)" {
    const body =
        \\{"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}}
    ;
    var doc = try parse(testing.allocator, body);
    defer doc.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), doc.statements.len);
}

test "parse: garbage → MalformedPolicy" {
    try testing.expectError(ParseError.MalformedPolicy, parse(testing.allocator, "{not json"));
    try testing.expectError(ParseError.MalformedPolicy, parse(testing.allocator, "[]"));
    try testing.expectError(ParseError.MalformedPolicy, parse(testing.allocator, "{}"));
    try testing.expectError(ParseError.MalformedPolicy, parse(testing.allocator, "{\"Statement\":[]}"));
}

test "parse: bad Effect → MalformedPolicy" {
    const body =
        \\{"Statement":[{"Effect":"Maybe","Principal":"*","Action":"s3:*","Resource":"*"}]}
    ;
    try testing.expectError(ParseError.MalformedPolicy, parse(testing.allocator, body));
}

test "parse: missing Action → MalformedPolicy" {
    const body =
        \\{"Statement":[{"Effect":"Allow","Principal":"*","Resource":"*"}]}
    ;
    try testing.expectError(ParseError.MalformedPolicy, parse(testing.allocator, body));
}
