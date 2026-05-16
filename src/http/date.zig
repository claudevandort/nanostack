//! RFC 7231 / RFC 9110 §5.6.7 HTTP-date parser — accepts all three forms.
//!
//! Inverse of `wire/s3_responses.zig` `formatHttpDate`. Used to parse
//! `If-Modified-Since` / `If-Unmodified-Since` request headers.
//!
//! Modern clients (boto3, aws-cli) emit IMF-fixdate exclusively; the legacy
//! RFC 850 and asctime parsers are here for spec parity with AWS (which
//! accepts all three per RFC 7231 §7.1.1.1).

const std = @import("std");

pub const ParseError = error{
    InvalidFormat,
    InvalidValue,
};

const month_names = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

const dow_names_short = [_][]const u8{
    "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat",
};

const dow_names_long = [_][]const u8{
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
};

/// Parse an HTTP-date in any of the three RFC 7231 formats:
///   - IMF-fixdate:  `Sun, 06 Nov 1994 08:49:37 GMT`
///   - RFC 850:      `Sunday, 06-Nov-94 08:49:37 GMT`
///   - asctime:      `Sun Nov  6 08:49:37 1994`
///
/// IMF-fixdate is tried first (overwhelmingly the most common form);
/// RFC 850 and asctime are fallbacks. Returns `InvalidFormat` only if
/// none of the three shapes match.
pub fn parseHttpDate(s: []const u8) ParseError!i64 {
    if (parseImfFixdate(s)) |v| return v else |err| switch (err) {
        ParseError.InvalidFormat => {},
        ParseError.InvalidValue => return ParseError.InvalidValue,
    }
    if (parseRfc850(s)) |v| return v else |err| switch (err) {
        ParseError.InvalidFormat => {},
        ParseError.InvalidValue => return ParseError.InvalidValue,
    }
    return parseAsctime(s);
}

fn parseImfFixdate(s: []const u8) ParseError!i64 {
    // Exact length: "Xxx, dd Xxx YYYY HH:MM:SS GMT" — 29 bytes.
    if (s.len != 29) return ParseError.InvalidFormat;
    if (!std.mem.endsWith(u8, s, " GMT")) return ParseError.InvalidFormat;
    if (s[3] != ',' or s[4] != ' ') return ParseError.InvalidFormat;
    if (s[7] != ' ' or s[11] != ' ' or s[16] != ' ') return ParseError.InvalidFormat;
    if (s[19] != ':' or s[22] != ':') return ParseError.InvalidFormat;

    if (!isKnownDowShort(s[0..3])) return ParseError.InvalidFormat;

    const day = parseTwoDigit(s[5..7]) catch return ParseError.InvalidFormat;
    const month = monthIndex(s[8..11]) orelse return ParseError.InvalidFormat;
    const year = parseFourDigit(s[12..16]) catch return ParseError.InvalidFormat;
    const hour = parseTwoDigit(s[17..19]) catch return ParseError.InvalidFormat;
    const min = parseTwoDigit(s[20..22]) catch return ParseError.InvalidFormat;
    const sec = parseTwoDigit(s[23..25]) catch return ParseError.InvalidFormat;

    return finalize(year, month, day, hour, min, sec);
}

/// RFC 850: `Sunday, 06-Nov-94 08:49:37 GMT`. Day-name length varies;
/// year is 2-digit, expanded per RFC 7231 §7.1.1.1 (we use a fixed
/// 1950..2049 window — sufficient for any HTTP date in practice).
fn parseRfc850(s: []const u8) ParseError!i64 {
    if (s.len < 7) return ParseError.InvalidFormat;
    if (!std.mem.endsWith(u8, s, " GMT")) return ParseError.InvalidFormat;

    const comma = std.mem.indexOfScalar(u8, s, ',') orelse return ParseError.InvalidFormat;
    if (!isKnownDowLong(s[0..comma])) return ParseError.InvalidFormat;

    // After the comma: " dd-Xxx-YY HH:MM:SS GMT" — 23 bytes.
    const rest = s[comma + 1 ..];
    if (rest.len != 23) return ParseError.InvalidFormat;
    if (rest[0] != ' ' or rest[3] != '-' or rest[7] != '-' or rest[10] != ' ') return ParseError.InvalidFormat;
    if (rest[13] != ':' or rest[16] != ':') return ParseError.InvalidFormat;

    const day = parseTwoDigit(rest[1..3]) catch return ParseError.InvalidFormat;
    const month = monthIndex(rest[4..7]) orelse return ParseError.InvalidFormat;
    const year2 = parseTwoDigit(rest[8..10]) catch return ParseError.InvalidFormat;
    const hour = parseTwoDigit(rest[11..13]) catch return ParseError.InvalidFormat;
    const min = parseTwoDigit(rest[14..16]) catch return ParseError.InvalidFormat;
    const sec = parseTwoDigit(rest[17..19]) catch return ParseError.InvalidFormat;

    // 1950..2049 window: 00..49 → 2000..2049; 50..99 → 1950..1999.
    const year: u16 = if (year2 < 50) @as(u16, 2000) + year2 else @as(u16, 1900) + year2;

    return finalize(year, month, day, hour, min, sec);
}

/// asctime: `Sun Nov  6 08:49:37 1994`. Single-digit days are
/// space-padded ("Nov  6"). No timezone field — UTC by RFC 7231.
fn parseAsctime(s: []const u8) ParseError!i64 {
    // Exact length: "Xxx Xxx _d HH:MM:SS YYYY" — 24 bytes.
    if (s.len != 24) return ParseError.InvalidFormat;
    if (s[3] != ' ' or s[7] != ' ' or s[10] != ' ' or s[19] != ' ') return ParseError.InvalidFormat;
    if (s[13] != ':' or s[16] != ':') return ParseError.InvalidFormat;

    if (!isKnownDowShort(s[0..3])) return ParseError.InvalidFormat;
    const month = monthIndex(s[4..7]) orelse return ParseError.InvalidFormat;

    // Day field is 2 bytes, space-padded for single digits.
    const day_field = s[8..10];
    const day: u8 = if (day_field[0] == ' ') blk: {
        if (!std.ascii.isDigit(day_field[1])) return ParseError.InvalidFormat;
        break :blk day_field[1] - '0';
    } else parseTwoDigit(day_field) catch return ParseError.InvalidFormat;

    const hour = parseTwoDigit(s[11..13]) catch return ParseError.InvalidFormat;
    const min = parseTwoDigit(s[14..16]) catch return ParseError.InvalidFormat;
    const sec = parseTwoDigit(s[17..19]) catch return ParseError.InvalidFormat;
    const year = parseFourDigit(s[20..24]) catch return ParseError.InvalidFormat;

    return finalize(year, month, day, hour, min, sec);
}

fn finalize(year: u16, month: u8, day: u8, hour: u8, min: u8, sec: u8) ParseError!i64 {
    if (year < 1970) return ParseError.InvalidValue;
    if (hour > 23 or min > 59 or sec > 60) return ParseError.InvalidValue;
    if (day == 0 or day > daysInMonth(year, month)) return ParseError.InvalidValue;

    const days_since_epoch = daysFromEpoch(year, month, day);
    return @as(i64, days_since_epoch) * 86_400 +
        @as(i64, hour) * 3_600 +
        @as(i64, min) * 60 +
        @as(i64, sec);
}

fn isKnownDowShort(s: []const u8) bool {
    for (dow_names_short) |name| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

fn isKnownDowLong(s: []const u8) bool {
    for (dow_names_long) |name| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

fn monthIndex(s: []const u8) ?u8 {
    for (month_names, 0..) |name, i| {
        if (std.mem.eql(u8, s, name)) return @intCast(i + 1);
    }
    return null;
}

fn parseTwoDigit(s: []const u8) !u8 {
    if (s.len != 2) return error.Bad;
    if (!std.ascii.isDigit(s[0]) or !std.ascii.isDigit(s[1])) return error.Bad;
    return (s[0] - '0') * 10 + (s[1] - '0');
}

fn parseFourDigit(s: []const u8) !u16 {
    if (s.len != 4) return error.Bad;
    var v: u16 = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return error.Bad;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) @as(u8, 29) else @as(u8, 28),
        else => 0,
    };
}

/// Count days from 1970-01-01 to year-month-day inclusive of start, exclusive of end (i.e. day_index = 0 → 1970-01-01).
fn daysFromEpoch(year: u16, month: u8, day: u8) i64 {
    var total: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) {
        total += if (isLeapYear(y)) @as(i64, 366) else @as(i64, 365);
    }
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        total += daysInMonth(year, m);
    }
    total += @as(i64, day) - 1;
    return total;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const s3_responses = @import("../wire/s3_responses.zig");

test "parseHttpDate: unix epoch" {
    try testing.expectEqual(@as(i64, 0), try parseHttpDate("Thu, 01 Jan 1970 00:00:00 GMT"));
}

test "parseHttpDate: 2026-05-15T13:00:00Z" {
    try testing.expectEqual(@as(i64, 1778850000), try parseHttpDate("Fri, 15 May 2026 13:00:00 GMT"));
}

test "parseHttpDate: leap day 2024-02-29" {
    // 2024-02-29T00:00:00Z = 1709164800
    try testing.expectEqual(@as(i64, 1709164800), try parseHttpDate("Thu, 29 Feb 2024 00:00:00 GMT"));
}

test "parseHttpDate: invalid leap day 2023-02-29 rejected" {
    try testing.expectError(ParseError.InvalidValue, parseHttpDate("Wed, 29 Feb 2023 00:00:00 GMT"));
}

test "parseHttpDate: accepts RFC 850 form (2-digit year, 2000+)" {
    // 1994-11-06T08:49:37Z = 784111777
    try testing.expectEqual(@as(i64, 784111777), try parseHttpDate("Sunday, 06-Nov-94 08:49:37 GMT"));
}

test "parseHttpDate: accepts RFC 850 form (2-digit year, 2020s)" {
    // 2024-02-29T12:34:56Z = 1709210096
    try testing.expectEqual(@as(i64, 1709210096), try parseHttpDate("Thursday, 29-Feb-24 12:34:56 GMT"));
}

test "parseHttpDate: accepts asctime form (single-digit day, space-padded)" {
    // 1994-11-06T08:49:37Z = 784111777
    try testing.expectEqual(@as(i64, 784111777), try parseHttpDate("Sun Nov  6 08:49:37 1994"));
}

test "parseHttpDate: accepts asctime form (two-digit day)" {
    // 2026-05-15T13:00:00Z = 1778850000
    try testing.expectEqual(@as(i64, 1778850000), try parseHttpDate("Fri May 15 13:00:00 2026"));
}

test "parseHttpDate: rejects non-GMT timezone" {
    try testing.expectError(ParseError.InvalidFormat, parseHttpDate("Fri, 15 May 2026 13:00:00 UTC"));
}

test "parseHttpDate: rejects pre-1970" {
    try testing.expectError(ParseError.InvalidValue, parseHttpDate("Sat, 01 Jan 1966 00:00:00 GMT"));
}

test "parseHttpDate: rejects malformed digits" {
    try testing.expectError(ParseError.InvalidFormat, parseHttpDate("Fri, ab May 2026 13:00:00 GMT"));
}

test "parseHttpDate <-> formatHttpDate round-trip" {
    const epochs = [_]i64{
        0,
        1_000_000,
        1_577_836_800, // 2020-01-01
        1_709_164_800, // 2024-02-29 (leap)
        1_778_850_000, // 2026-05-15
        2_147_483_647, // 2038-01-19
    };
    for (epochs) |e| {
        const formatted = try s3_responses.formatHttpDate(testing.allocator, e);
        defer testing.allocator.free(formatted);
        const back = try parseHttpDate(formatted);
        try testing.expectEqual(e, back);
    }
}
