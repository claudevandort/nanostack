//! The IAM-equivalent identity behind a request.
//!
//! Single-tenant nanostack: one configured `access_key` → one
//! `aws_account` principal. Unsigned requests get `anonymous`. The M14
//! policy evaluator matches `Principal: "*"` against both; `Principal:
//! {"AWS": "..."}` matches only `aws_account` with the same id.

const std = @import("std");

pub const Kind = enum { anonymous, aws_account };

pub const Principal = struct {
    kind: Kind,
    /// For `aws_account`: the access-key / account id string. Borrowed,
    /// not owned — typically points at `Config.access_key` which lives
    /// for the server's lifetime.
    id: []const u8,

    pub fn anonymous() Principal {
        return .{ .kind = .anonymous, .id = "" };
    }

    pub fn awsAccount(id: []const u8) Principal {
        return .{ .kind = .aws_account, .id = id };
    }

    pub fn isAnonymous(self: Principal) bool {
        return self.kind == .anonymous;
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "anonymous() yields .anonymous kind" {
    const p = Principal.anonymous();
    try testing.expect(p.isAnonymous());
    try testing.expectEqualStrings("", p.id);
}

test "awsAccount(id) yields .aws_account with id" {
    const p = Principal.awsAccount("test-access-key");
    try testing.expect(!p.isAnonymous());
    try testing.expectEqualStrings("test-access-key", p.id);
}
