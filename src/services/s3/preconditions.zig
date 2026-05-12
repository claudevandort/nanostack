//! Conditional-header evaluator for GetObject, HeadObject, PutObject, and
//! CopyObject. Centralises the precondition logic so all four call sites
//! share the same RFC 9110 / AWS semantics.
//!
//! AWS-exact behaviour summary:
//!   - GET / HEAD honour all four (`If-Match`, `If-None-Match`,
//!     `If-Modified-Since`, `If-Unmodified-Since`). 304/412 per the spec.
//!   - PUT honours `If-Match` and `If-None-Match` only. AWS does not
//!     enforce `If-*-Since` on PUT.
//!   - CopyObject honours the four `x-amz-copy-source-if-*` variants
//!     against the source object; semantics match the Read set.
//!
//! ETag values must be either:
//!   - The literal `*` (unquoted) — matches any existing object's etag.
//!   - A quoted strong etag (`"abc..."`) — byte-compared against the
//!     stored value (which we always store quoted).
//! Anything else (weak `W/"..."`, comma-lists, unquoted hex) is rejected
//! with `.invalid` — the caller maps that to `InvalidArgument`.

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const http_date = @import("../../http/date.zig");

pub const Outcome = enum {
    ok,
    not_modified, // 304 — GetObject/HeadObject only
    precondition_failed, // 412
    invalid, // caller maps to InvalidArgument
};

pub const Subject = struct {
    /// Existing object's quoted ETag (e.g. `"abc123..."`). Empty when no
    /// existing object.
    etag: []const u8 = "",
    /// Unix seconds. Unused when `exists == false`.
    last_modified_unix: i64 = 0,
    exists: bool = false,
};

const HeaderNames = struct {
    if_match: []const u8,
    if_none_match: []const u8,
    if_modified_since: []const u8,
    if_unmodified_since: []const u8,
};

const read_names: HeaderNames = .{
    .if_match = "if-match",
    .if_none_match = "if-none-match",
    .if_modified_since = "if-modified-since",
    .if_unmodified_since = "if-unmodified-since",
};

const copy_source_names: HeaderNames = .{
    .if_match = "x-amz-copy-source-if-match",
    .if_none_match = "x-amz-copy-source-if-none-match",
    .if_modified_since = "x-amz-copy-source-if-modified-since",
    .if_unmodified_since = "x-amz-copy-source-if-unmodified-since",
};

/// Evaluate read preconditions (GET / HEAD). May return `.not_modified`.
pub fn forRead(headers: []const storage.Header, subject: Subject) Outcome {
    return evalReadLike(headers, subject, read_names);
}

/// Evaluate copy-source preconditions (CopyObject). Same shape as `forRead`
/// but uses the `x-amz-copy-source-if-*` header set.
pub fn forCopySource(headers: []const storage.Header, subject: Subject) Outcome {
    return evalReadLike(headers, subject, copy_source_names);
}

/// Evaluate write preconditions (PUT). Honours `If-Match` and
/// `If-None-Match` only — AWS ignores `If-*-Since` on PUT, so we do too.
/// Never returns `.not_modified`.
pub fn forWrite(headers: []const storage.Header, subject: Subject) Outcome {
    if (findHeader(headers, read_names.if_match)) |raw| {
        const v = std.mem.trim(u8, raw, " \t");
        const parsed = parseEtagValue(v) orelse return .invalid;
        if (!subject.exists) return .precondition_failed;
        if (!parsed.matches(subject.etag)) return .precondition_failed;
    }

    if (findHeader(headers, read_names.if_none_match)) |raw| {
        const v = std.mem.trim(u8, raw, " \t");
        const parsed = parseEtagValue(v) orelse return .invalid;
        if (subject.exists and parsed.matches(subject.etag)) return .precondition_failed;
    }

    return .ok;
}

fn evalReadLike(headers: []const storage.Header, subject: Subject, names: HeaderNames) Outcome {
    // RFC 9110 §13.2.2 step ordering:
    //   1. If-Match
    //   2. If-Unmodified-Since (skipped if If-Match present and resource exists)
    //   3. If-None-Match
    //   4. If-Modified-Since (skipped if If-None-Match present)

    var if_match_present = false;
    if (findHeader(headers, names.if_match)) |raw| {
        if_match_present = true;
        const v = std.mem.trim(u8, raw, " \t");
        const parsed = parseEtagValue(v) orelse return .invalid;
        if (!subject.exists) return .precondition_failed;
        if (!parsed.matches(subject.etag)) return .precondition_failed;
    }

    if (!if_match_present) {
        if (findHeader(headers, names.if_unmodified_since)) |raw| {
            const v = std.mem.trim(u8, raw, " \t");
            const since = http_date.parseHttpDate(v) catch return .invalid;
            if (subject.exists and subject.last_modified_unix > since) return .precondition_failed;
        }
    }

    var if_none_match_present = false;
    if (findHeader(headers, names.if_none_match)) |raw| {
        if_none_match_present = true;
        const v = std.mem.trim(u8, raw, " \t");
        const parsed = parseEtagValue(v) orelse return .invalid;
        if (subject.exists and parsed.matches(subject.etag)) return .not_modified;
    }

    if (!if_none_match_present) {
        if (findHeader(headers, names.if_modified_since)) |raw| {
            const v = std.mem.trim(u8, raw, " \t");
            const since = http_date.parseHttpDate(v) catch return .invalid;
            if (subject.exists and subject.last_modified_unix <= since) return .not_modified;
        }
    }

    return .ok;
}

const EtagValue = union(enum) {
    any, // `*`
    exact: []const u8, // includes the surrounding quotes

    fn matches(self: EtagValue, stored: []const u8) bool {
        return switch (self) {
            .any => true,
            .exact => |e| std.mem.eql(u8, e, stored),
        };
    }
};

fn parseEtagValue(s: []const u8) ?EtagValue {
    if (s.len == 0) return null;
    if (std.mem.eql(u8, s, "*")) return .{ .any = {} };
    // Reject weak etags (W/"...") — AWS S3 does not accept them.
    if (s.len >= 2 and s[0] == 'W' and s[1] == '/') return null;
    // Reject comma-lists — we only support single values.
    if (std.mem.indexOfScalar(u8, s, ',') != null) return null;
    if (s.len < 2 or s[0] != '"' or s[s.len - 1] != '"') return null;
    return .{ .exact = s };
}

fn findHeader(headers: []const storage.Header, lower_name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, lower_name)) return h.value;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn mkH(name: []const u8, value: []const u8) storage.Header {
    return .{ .name = name, .value = value };
}

test "forRead: no headers → ok" {
    try testing.expectEqual(Outcome.ok, forRead(&.{}, .{ .exists = true, .etag = "\"abc\"" }));
}

test "forRead: If-Match matches → ok" {
    const hdrs = [_]storage.Header{mkH("If-Match", "\"abc\"")};
    try testing.expectEqual(Outcome.ok, forRead(&hdrs, .{ .exists = true, .etag = "\"abc\"" }));
}

test "forRead: If-Match mismatch → 412" {
    const hdrs = [_]storage.Header{mkH("If-Match", "\"xyz\"")};
    try testing.expectEqual(Outcome.precondition_failed, forRead(&hdrs, .{ .exists = true, .etag = "\"abc\"" }));
}

test "forRead: If-Match: * with existing → ok" {
    const hdrs = [_]storage.Header{mkH("If-Match", "*")};
    try testing.expectEqual(Outcome.ok, forRead(&hdrs, .{ .exists = true, .etag = "\"abc\"" }));
}

test "forRead: If-None-Match matches → 304" {
    const hdrs = [_]storage.Header{mkH("If-None-Match", "\"abc\"")};
    try testing.expectEqual(Outcome.not_modified, forRead(&hdrs, .{ .exists = true, .etag = "\"abc\"" }));
}

test "forRead: If-None-Match: * with existing → 304" {
    const hdrs = [_]storage.Header{mkH("If-None-Match", "*")};
    try testing.expectEqual(Outcome.not_modified, forRead(&hdrs, .{ .exists = true, .etag = "\"abc\"" }));
}

test "forRead: If-Modified-Since older than object → ok" {
    const hdrs = [_]storage.Header{mkH("If-Modified-Since", "Thu, 01 Jan 1970 00:00:00 GMT")};
    try testing.expectEqual(Outcome.ok, forRead(&hdrs, .{ .exists = true, .last_modified_unix = 100, .etag = "\"e\"" }));
}

test "forRead: If-Modified-Since newer than object → 304" {
    const hdrs = [_]storage.Header{mkH("If-Modified-Since", "Fri, 15 May 2026 13:00:00 GMT")};
    try testing.expectEqual(Outcome.not_modified, forRead(&hdrs, .{ .exists = true, .last_modified_unix = 100, .etag = "\"e\"" }));
}

test "forRead: If-Unmodified-Since older than object → 412" {
    const hdrs = [_]storage.Header{mkH("If-Unmodified-Since", "Thu, 01 Jan 1970 00:00:00 GMT")};
    try testing.expectEqual(Outcome.precondition_failed, forRead(&hdrs, .{ .exists = true, .last_modified_unix = 100, .etag = "\"e\"" }));
}

test "forRead: If-Match wins over If-Unmodified-Since" {
    // If-Match passes; If-Unmodified-Since would fail; expect ok per precedence.
    const hdrs = [_]storage.Header{
        mkH("If-Match", "\"abc\""),
        mkH("If-Unmodified-Since", "Thu, 01 Jan 1970 00:00:00 GMT"),
    };
    try testing.expectEqual(Outcome.ok, forRead(&hdrs, .{ .exists = true, .etag = "\"abc\"", .last_modified_unix = 100 }));
}

test "forRead: If-None-Match wins over If-Modified-Since" {
    // If-None-Match doesn't match → would pass; If-Modified-Since would yield 304;
    // precedence says skip If-Modified-Since → ok.
    const hdrs = [_]storage.Header{
        mkH("If-None-Match", "\"different\""),
        mkH("If-Modified-Since", "Fri, 15 May 2026 13:00:00 GMT"),
    };
    try testing.expectEqual(Outcome.ok, forRead(&hdrs, .{ .exists = true, .etag = "\"abc\"", .last_modified_unix = 100 }));
}

test "forRead: malformed etag → invalid" {
    const hdrs = [_]storage.Header{mkH("If-Match", "notquoted")};
    try testing.expectEqual(Outcome.invalid, forRead(&hdrs, .{ .exists = true, .etag = "\"abc\"" }));
}

test "forRead: malformed date → invalid" {
    const hdrs = [_]storage.Header{mkH("If-Modified-Since", "not a date")};
    try testing.expectEqual(Outcome.invalid, forRead(&hdrs, .{ .exists = true, .etag = "\"abc\"", .last_modified_unix = 100 }));
}

test "forRead: weak etag rejected → invalid" {
    const hdrs = [_]storage.Header{mkH("If-Match", "W/\"abc\"")};
    try testing.expectEqual(Outcome.invalid, forRead(&hdrs, .{ .exists = true, .etag = "\"abc\"" }));
}

test "forWrite: If-None-Match: * against absent → ok" {
    const hdrs = [_]storage.Header{mkH("If-None-Match", "*")};
    try testing.expectEqual(Outcome.ok, forWrite(&hdrs, .{ .exists = false }));
}

test "forWrite: If-None-Match: * against existing → 412" {
    const hdrs = [_]storage.Header{mkH("If-None-Match", "*")};
    try testing.expectEqual(Outcome.precondition_failed, forWrite(&hdrs, .{ .exists = true, .etag = "\"e\"" }));
}

test "forWrite: If-Match matches existing → ok" {
    const hdrs = [_]storage.Header{mkH("If-Match", "\"e\"")};
    try testing.expectEqual(Outcome.ok, forWrite(&hdrs, .{ .exists = true, .etag = "\"e\"" }));
}

test "forWrite: If-Match against absent → 412" {
    const hdrs = [_]storage.Header{mkH("If-Match", "\"e\"")};
    try testing.expectEqual(Outcome.precondition_failed, forWrite(&hdrs, .{ .exists = false }));
}

test "forWrite: ignores If-Modified-Since" {
    // PUT should not 304 or 412 on If-Modified-Since per AWS — we ignore it.
    const hdrs = [_]storage.Header{mkH("If-Modified-Since", "Fri, 15 May 2026 13:00:00 GMT")};
    try testing.expectEqual(Outcome.ok, forWrite(&hdrs, .{ .exists = true, .last_modified_unix = 100, .etag = "\"e\"" }));
}

test "forCopySource: x-amz-copy-source-if-match matches → ok" {
    const hdrs = [_]storage.Header{mkH("x-amz-copy-source-if-match", "\"abc\"")};
    try testing.expectEqual(Outcome.ok, forCopySource(&hdrs, .{ .exists = true, .etag = "\"abc\"" }));
}

test "forCopySource: x-amz-copy-source-if-match mismatch → 412" {
    const hdrs = [_]storage.Header{mkH("x-amz-copy-source-if-match", "\"nope\"")};
    try testing.expectEqual(Outcome.precondition_failed, forCopySource(&hdrs, .{ .exists = true, .etag = "\"abc\"" }));
}

test "forCopySource: x-amz-copy-source-if-modified-since older → ok" {
    const hdrs = [_]storage.Header{mkH("x-amz-copy-source-if-modified-since", "Thu, 01 Jan 1970 00:00:00 GMT")};
    try testing.expectEqual(Outcome.ok, forCopySource(&hdrs, .{ .exists = true, .last_modified_unix = 100, .etag = "\"e\"" }));
}
