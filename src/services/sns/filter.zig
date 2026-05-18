//! SNS filter policy evaluator (v0.4.1).
//!
//! AWS supports a rich filter-policy language. For v0.4.1 we implement
//! the most common shape — top-level keys whose values are arrays of
//! strings. Operator-object rules (`{"prefix": "..."}`, `{"numeric":
//! [">=", 100]}`, etc.) are treated as no-match (skip delivery) —
//! documented divergence.
//!
//! Example policy:
//!   {"customer_interests": ["rugby", "football"], "store": ["acme"]}
//! matches when ALL keys are present in the MessageAttributes JSON AND
//! the attribute's Value matches at least one entry in the rule array.
//!
//! Message attributes arrive as the JSON shape produced by
//! src/wire/sns/publish.zig::serializeMessageAttributes:
//!   {"name": {"Type": "String", "Value": "v"}}

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Evaluate `policy_json` against `message_attributes_json`. Returns
/// `true` if the message should be delivered, `false` if it should be
/// filtered out. Malformed inputs → false (skip delivery + log).
pub fn evaluatePolicy(policy_json: []const u8, message_attributes_json: ?[]const u8, allocator: Allocator) bool {
    var policy_parsed = std.json.parseFromSlice(std.json.Value, allocator, policy_json, .{}) catch return false;
    defer policy_parsed.deinit();
    if (policy_parsed.value != .object) return false;
    const policy_obj = policy_parsed.value.object;

    // No published attributes: empty-policy passes vacuously, but any
    // top-level rule key requires an attribute → fail.
    const attrs_json = message_attributes_json orelse {
        return policy_obj.count() == 0;
    };
    var attrs_parsed = std.json.parseFromSlice(std.json.Value, allocator, attrs_json, .{}) catch return false;
    defer attrs_parsed.deinit();
    if (attrs_parsed.value != .object) return false;
    const attrs_obj = attrs_parsed.value.object;

    var it = policy_obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const rule_v = entry.value_ptr.*;
        if (rule_v != .array) return false;

        // Find the attribute with this name.
        const attr_v = attrs_obj.get(key) orelse return false;
        if (attr_v != .object) return false;
        const value_v = attr_v.object.get("Value") orelse return false;
        const value = switch (value_v) {
            .string => |s| s,
            else => return false,
        };

        // Walk the rule array — first match wins for this key. Object
        // rules (operators) are not implemented → counted as no-match.
        var matched = false;
        for (rule_v.array.items) |rule_entry| {
            switch (rule_entry) {
                .string => |s| if (std.mem.eql(u8, s, value)) {
                    matched = true;
                    break;
                },
                else => {
                    // Operator rule (prefix, anything-but, numeric, etc.) — skip.
                    // The whole rule array still has to have a literal match
                    // for this key; operator entries just don't count.
                },
            }
        }
        if (!matched) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "no policy / empty attrs path returns vacuous true" {
    // This module isn't reached when filter_policy is null — but
    // make sure an empty policy object passes regardless of attrs.
    try testing.expect(evaluatePolicy("{}", null, testing.allocator));
    try testing.expect(evaluatePolicy("{}", "{}", testing.allocator));
}

test "single key matches" {
    const policy = "{\"category\":[\"news\"]}";
    const attrs = "{\"category\":{\"Type\":\"String\",\"Value\":\"news\"}}";
    try testing.expect(evaluatePolicy(policy, attrs, testing.allocator));
}

test "single key does not match" {
    const policy = "{\"category\":[\"news\"]}";
    const attrs = "{\"category\":{\"Type\":\"String\",\"Value\":\"sports\"}}";
    try testing.expect(!evaluatePolicy(policy, attrs, testing.allocator));
}

test "rule array OR semantics" {
    const policy = "{\"category\":[\"news\",\"sports\"]}";
    const attrs = "{\"category\":{\"Type\":\"String\",\"Value\":\"sports\"}}";
    try testing.expect(evaluatePolicy(policy, attrs, testing.allocator));
}

test "multiple top-level keys AND semantics" {
    const policy = "{\"a\":[\"1\"],\"b\":[\"2\"]}";
    const ok = "{\"a\":{\"Type\":\"String\",\"Value\":\"1\"},\"b\":{\"Type\":\"String\",\"Value\":\"2\"}}";
    const bad_missing = "{\"a\":{\"Type\":\"String\",\"Value\":\"1\"}}";
    const bad_mismatch = "{\"a\":{\"Type\":\"String\",\"Value\":\"1\"},\"b\":{\"Type\":\"String\",\"Value\":\"3\"}}";
    try testing.expect(evaluatePolicy(policy, ok, testing.allocator));
    try testing.expect(!evaluatePolicy(policy, bad_missing, testing.allocator));
    try testing.expect(!evaluatePolicy(policy, bad_mismatch, testing.allocator));
}

test "operator rule treated as no-match" {
    const policy = "{\"category\":[{\"prefix\":\"news-\"}]}";
    const attrs = "{\"category\":{\"Type\":\"String\",\"Value\":\"news-summary\"}}";
    // Despite Value starting with "news-", the operator rule isn't
    // implemented → no match → policy fails.
    try testing.expect(!evaluatePolicy(policy, attrs, testing.allocator));
}

test "missing attribute fails" {
    const policy = "{\"category\":[\"news\"]}";
    try testing.expect(!evaluatePolicy(policy, "{}", testing.allocator));
    try testing.expect(!evaluatePolicy(policy, null, testing.allocator));
}

test "malformed policy → false (skip delivery)" {
    try testing.expect(!evaluatePolicy("not json", "{}", testing.allocator));
}
