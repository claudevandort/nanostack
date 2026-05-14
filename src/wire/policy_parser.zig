//! Bucket policy parser (M10). AWS bucket policies are IAM-style JSON
//! documents. nanostack does not enforce them; we only need a
//! well-formedness check (valid JSON object) and pass-through bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ParseError = error{
    MalformedPolicy,
    OutOfMemory,
};

/// Verify well-formedness and return a freshly-owned copy of `body`.
/// AWS-exact: the first non-whitespace byte must be `{` (per the
/// MalformedPolicy error message).
pub fn parsePolicyJson(allocator: Allocator, body: []const u8) ParseError![]u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return ParseError.MalformedPolicy;
    // Validate JSON well-formedness without retaining the parse tree.
    var scanner = std.json.Scanner.initCompleteInput(allocator, body);
    defer scanner.deinit();
    while (true) {
        const tok = scanner.next() catch return ParseError.MalformedPolicy;
        if (tok == .end_of_document) break;
    }
    return allocator.dupe(u8, body) catch ParseError.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parsePolicyJson: well-formed → returns copy" {
    const policy = "{\"Version\":\"2012-10-17\",\"Statement\":[]}";
    const out = try parsePolicyJson(testing.allocator, policy);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(policy, out);
}

test "parsePolicyJson: empty → MalformedPolicy" {
    try testing.expectError(ParseError.MalformedPolicy, parsePolicyJson(testing.allocator, ""));
}

test "parsePolicyJson: non-object root → MalformedPolicy" {
    try testing.expectError(ParseError.MalformedPolicy, parsePolicyJson(testing.allocator, "[]"));
    try testing.expectError(ParseError.MalformedPolicy, parsePolicyJson(testing.allocator, "\"x\""));
}

test "parsePolicyJson: garbage → MalformedPolicy" {
    try testing.expectError(ParseError.MalformedPolicy, parsePolicyJson(testing.allocator, "{not json"));
}

test "parsePolicyJson: leading whitespace OK" {
    const out = try parsePolicyJson(testing.allocator, "   \n  {}");
    defer testing.allocator.free(out);
}
