//! Shared storage helpers — currently just AWS-strict bucket-name validation.
//!
//! Rules sourced from the AWS S3 User Guide "Bucket naming rules". We match
//! the strict (post-2018) rules even though older buckets in real AWS may
//! violate them; nanostack is for new local dev work, never legacy state.

const std = @import("std");
const Error = @import("mod.zig").Error;

/// Validate a bucket name. Returns `error.InvalidBucketName` on any rule
/// violation. The rules:
///
///   1. 3 to 63 characters long.
///   2. Only lowercase letters, digits, hyphens, and dots.
///   3. Must begin and end with a letter or digit.
///   4. Must not contain two adjacent periods.
///   5. Must not contain `.-` or `-.` sequences.
///   6. Must not be formatted as an IPv4 address.
///   7. Must not start with the prefix `xn--` (reserved for Punycode).
///   8. Must not start with the prefix `sthree-`.
///   9. Must not end with `-s3alias` (Access Point alias suffix).
///  10. Must not end with `--ol-s3` (Object Lambda alias suffix).
pub fn validateBucketName(name: []const u8) Error!void {
    if (name.len < 3 or name.len > 63) return Error.InvalidBucketName;

    // Rule 3: bookend chars.
    if (!isAlphaNumLower(name[0]) or !isAlphaNumLower(name[name.len - 1])) {
        return Error.InvalidBucketName;
    }

    // Rule 2: charset; rules 4 and 5 enforced in the same pass.
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        const c = name[i];
        const allowed = isAlphaNumLower(c) or c == '-' or c == '.';
        if (!allowed) return Error.InvalidBucketName;
        if (i + 1 < name.len) {
            const next = name[i + 1];
            if (c == '.' and next == '.') return Error.InvalidBucketName;
            if (c == '.' and next == '-') return Error.InvalidBucketName;
            if (c == '-' and next == '.') return Error.InvalidBucketName;
        }
    }

    // Rule 6: not an IPv4 literal.
    if (looksLikeIpv4(name)) return Error.InvalidBucketName;

    // Rules 7 + 8: forbidden prefixes.
    if (std.mem.startsWith(u8, name, "xn--")) return Error.InvalidBucketName;
    if (std.mem.startsWith(u8, name, "sthree-")) return Error.InvalidBucketName;

    // Rules 9 + 10: forbidden suffixes.
    if (std.mem.endsWith(u8, name, "-s3alias")) return Error.InvalidBucketName;
    if (std.mem.endsWith(u8, name, "--ol-s3")) return Error.InvalidBucketName;
}

fn isAlphaNumLower(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
}

fn looksLikeIpv4(s: []const u8) bool {
    var parts: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (i == s.len or s[i] == '.') {
            const seg = s[start..i];
            if (seg.len == 0 or seg.len > 3) return false;
            for (seg) |c| {
                if (c < '0' or c > '9') return false;
            }
            const n = std.fmt.parseInt(u16, seg, 10) catch return false;
            if (n > 255) return false;
            parts += 1;
            start = i + 1;
        }
    }
    return parts == 4;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "valid: minimal length" {
    try validateBucketName("abc");
}

test "valid: typical name" {
    try validateBucketName("my-bucket-2026");
}

test "valid: dots between labels" {
    try validateBucketName("my.bucket.name");
}

test "invalid: too short" {
    try testing.expectError(Error.InvalidBucketName, validateBucketName("ab"));
}

test "invalid: too long" {
    const s = "a" ** 64;
    try testing.expectError(Error.InvalidBucketName, validateBucketName(s));
}

test "invalid: uppercase" {
    try testing.expectError(Error.InvalidBucketName, validateBucketName("MyBucket"));
}

test "invalid: underscore" {
    try testing.expectError(Error.InvalidBucketName, validateBucketName("my_bucket"));
}

test "invalid: leading hyphen" {
    try testing.expectError(Error.InvalidBucketName, validateBucketName("-bucket"));
}

test "invalid: trailing hyphen" {
    try testing.expectError(Error.InvalidBucketName, validateBucketName("bucket-"));
}

test "invalid: leading dot" {
    try testing.expectError(Error.InvalidBucketName, validateBucketName(".bucket"));
}

test "invalid: trailing dot" {
    try testing.expectError(Error.InvalidBucketName, validateBucketName("bucket."));
}

test "invalid: consecutive dots" {
    try testing.expectError(Error.InvalidBucketName, validateBucketName("a..b"));
}

test "invalid: dot-hyphen sequence" {
    try testing.expectError(Error.InvalidBucketName, validateBucketName("a.-b"));
}

test "invalid: hyphen-dot sequence" {
    try testing.expectError(Error.InvalidBucketName, validateBucketName("a-.b"));
}

test "invalid: ipv4 literal" {
    try testing.expectError(Error.InvalidBucketName, validateBucketName("192.168.0.1"));
}

test "valid: looks numeric but not ipv4" {
    try validateBucketName("1.2.3");
}

test "invalid: xn-- prefix" {
    try testing.expectError(Error.InvalidBucketName, validateBucketName("xn--bucket"));
}

test "invalid: sthree- prefix" {
    try testing.expectError(Error.InvalidBucketName, validateBucketName("sthree-bucket"));
}

test "invalid: -s3alias suffix" {
    try testing.expectError(Error.InvalidBucketName, validateBucketName("my-bucket-s3alias"));
}

test "invalid: --ol-s3 suffix" {
    try testing.expectError(Error.InvalidBucketName, validateBucketName("my-bucket--ol-s3"));
}
