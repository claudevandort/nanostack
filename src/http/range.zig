//! HTTP Range header parsing (RFC 9110 §14.2) for the byte unit only.
//!
//! Supports the three single-range forms a real client sends:
//!   `Range: bytes=N-M`   bytes N through M inclusive
//!   `Range: bytes=N-`    byte N to end of resource
//!   `Range: bytes=-M`    last M bytes (suffix range)
//!
//! Multi-range (`bytes=0-1,4-5`) returns `Unsupported`; clients get 416
//! until we land a `multipart/byteranges` body in a polish milestone.

const std = @import("std");

pub const Error = error{
    Malformed,
    Unsatisfiable,
    Unsupported,
};

pub const Range = struct {
    /// Inclusive start byte index.
    start: u64,
    /// Inclusive end byte index.
    end: u64,
};

/// Parse the value of a `Range` header against an object of `total_size`
/// bytes. Returns the resolved start/end pair or an error.
///
/// `header` is the value after `Range:` (no key, leading whitespace
/// already trimmed by the caller).
pub fn parse(header: []const u8, total_size: u64) Error!Range {
    const trimmed = std.mem.trim(u8, header, " \t");
    const prefix = "bytes=";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return Error.Malformed;
    const rest = trimmed[prefix.len..];

    if (std.mem.indexOfScalar(u8, rest, ',') != null) return Error.Unsupported;

    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return Error.Malformed;
    const lhs = rest[0..dash];
    const rhs = rest[dash + 1 ..];

    if (lhs.len == 0 and rhs.len == 0) return Error.Malformed;
    if (lhs.len == 0) {
        // Suffix range: last `n` bytes.
        const n = std.fmt.parseInt(u64, rhs, 10) catch return Error.Malformed;
        if (n == 0) return Error.Unsatisfiable;
        if (total_size == 0) return Error.Unsatisfiable;
        const clipped = if (n > total_size) total_size else n;
        return .{ .start = total_size - clipped, .end = total_size - 1 };
    }

    const start = std.fmt.parseInt(u64, lhs, 10) catch return Error.Malformed;
    if (start >= total_size) return Error.Unsatisfiable;

    if (rhs.len == 0) {
        return .{ .start = start, .end = total_size - 1 };
    }

    const end_raw = std.fmt.parseInt(u64, rhs, 10) catch return Error.Malformed;
    if (end_raw < start) return Error.Malformed;
    const end = if (end_raw >= total_size) total_size - 1 else end_raw;
    return .{ .start = start, .end = end };
}

/// Format a `Content-Range: bytes start-end/total` header value into `buf`.
/// Returns the populated slice.
pub fn formatContentRange(buf: []u8, r: Range, total: u64) ![]u8 {
    return std.fmt.bufPrint(buf, "bytes {d}-{d}/{d}", .{ r.start, r.end, total });
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "bytes=N-M" {
    const r = try parse("bytes=0-99", 1024);
    try testing.expectEqual(@as(u64, 0), r.start);
    try testing.expectEqual(@as(u64, 99), r.end);
}

test "bytes=N- to end" {
    const r = try parse("bytes=500-", 1024);
    try testing.expectEqual(@as(u64, 500), r.start);
    try testing.expectEqual(@as(u64, 1023), r.end);
}

test "bytes=-N suffix" {
    const r = try parse("bytes=-100", 1024);
    try testing.expectEqual(@as(u64, 924), r.start);
    try testing.expectEqual(@as(u64, 1023), r.end);
}

test "suffix larger than object" {
    const r = try parse("bytes=-9999", 100);
    try testing.expectEqual(@as(u64, 0), r.start);
    try testing.expectEqual(@as(u64, 99), r.end);
}

test "end clipped to object size" {
    const r = try parse("bytes=0-9999", 100);
    try testing.expectEqual(@as(u64, 0), r.start);
    try testing.expectEqual(@as(u64, 99), r.end);
}

test "start past end → Unsatisfiable" {
    try testing.expectError(Error.Unsatisfiable, parse("bytes=1000-", 100));
}

test "suffix on empty object → Unsatisfiable" {
    try testing.expectError(Error.Unsatisfiable, parse("bytes=-100", 0));
}

test "end < start → Malformed" {
    try testing.expectError(Error.Malformed, parse("bytes=50-10", 100));
}

test "multi-range → Unsupported" {
    try testing.expectError(Error.Unsupported, parse("bytes=0-9,20-29", 100));
}

test "no prefix → Malformed" {
    try testing.expectError(Error.Malformed, parse("0-99", 100));
}

test "Content-Range formatting" {
    var buf: [64]u8 = undefined;
    const s = try formatContentRange(&buf, .{ .start = 0, .end = 99 }, 1024);
    try testing.expectEqualStrings("bytes 0-99/1024", s);
}
