//! AWS X-Amz-Date helpers — `YYYYMMDDTHHMMSSZ` ⇄ unix seconds.
//!
//! Forward direction uses Howard Hinnant's civil-from-days algorithm
//! (well-known, branch-free apart from a leap-month guard). Reverse uses
//! the `std.time.epoch` decomposers since we already lean on those in
//! `wire/s3_responses.zig`.

const std = @import("std");

pub const Error = error{Malformed};

/// Parse `YYYYMMDDTHHMMSSZ` into unix-epoch seconds.
pub fn parseAmzDate(s: []const u8) Error!i64 {
    if (s.len != 16) return Error.Malformed;
    if (s[8] != 'T' or s[15] != 'Z') return Error.Malformed;

    const year = parseUnsigned(i32, s[0..4]) catch return Error.Malformed;
    const month = parseUnsigned(u32, s[4..6]) catch return Error.Malformed;
    const day = parseUnsigned(u32, s[6..8]) catch return Error.Malformed;
    const hour = parseUnsigned(u32, s[9..11]) catch return Error.Malformed;
    const min = parseUnsigned(u32, s[11..13]) catch return Error.Malformed;
    const sec = parseUnsigned(u32, s[13..15]) catch return Error.Malformed;

    if (year < 1970 or year > 9999) return Error.Malformed;
    if (month < 1 or month > 12) return Error.Malformed;
    if (day < 1 or day > daysInMonth(year, month)) return Error.Malformed;
    if (hour > 23 or min > 59 or sec > 60) return Error.Malformed;

    const days = daysFromCivil(year, month, day);
    const secs = days * 86_400 + @as(i64, hour) * 3_600 + @as(i64, min) * 60 + @as(i64, sec);
    return secs;
}

/// Format unix-epoch seconds as `YYYYMMDDTHHMMSSZ`.
pub fn formatAmzDate(buf: *[16]u8, unix_seconds: i64) void {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(unix_seconds) };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const day_secs = es.getDaySeconds();
    _ = std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        @as(u32, yd.year),
        @as(u32, @intFromEnum(md.month)),
        @as(u32, md.day_index) + 1,
        @as(u32, day_secs.getHoursIntoDay()),
        @as(u32, day_secs.getMinutesIntoHour()),
        @as(u32, day_secs.getSecondsIntoMinute()),
    }) catch unreachable; // 16 bytes is always enough.
}

/// Format the eight-character `YYYYMMDD` scope date.
pub fn formatScopeDate(buf: *[8]u8, unix_seconds: i64) void {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(unix_seconds) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    _ = std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}", .{
        @as(u32, yd.year),
        @as(u32, @intFromEnum(md.month)),
        @as(u32, md.day_index) + 1,
    }) catch unreachable;
}

// ---------------------------------------------------------------------------
// Internals

fn parseUnsigned(comptime T: type, s: []const u8) !T {
    return std.fmt.parseInt(T, s, 10);
}

fn isLeapYear(year: i32) bool {
    if (@mod(year, 4) != 0) return false;
    if (@mod(year, 100) != 0) return true;
    return @mod(year, 400) == 0;
}

fn daysInMonth(year: i32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) @as(u32, 29) else @as(u32, 28),
        else => 0,
    };
}

/// Howard Hinnant's days_from_civil — returns days since 1970-01-01 for
/// proleptic Gregorian (y, m, d). See:
/// https://howardhinnant.github.io/date_algorithms.html#days_from_civil
fn daysFromCivil(y: i32, m: u32, d: u32) i64 {
    const yshift: i32 = if (m <= 2) 1 else 0;
    const year = y - yshift;
    const era_year = if (year >= 0) year else year - 399;
    const era = @divTrunc(era_year, 400);
    const yoe: i32 = year - era * 400; // 0..399
    const m_adj: u32 = if (m > 2) m - 3 else m + 9; // March-indexed
    const doy = (@as(u32, 153) * m_adj + 2) / 5 + d - 1; // 0..365
    const doe: i32 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + @as(i32, @intCast(doy));
    return @as(i64, era) * 146_097 + @as(i64, doe) - 719_468;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parseAmzDate: AWS doc example" {
    // From the SigV4 docs: 2015-08-30T12:36:00Z = 1440938160
    try testing.expectEqual(@as(i64, 1440938160), try parseAmzDate("20150830T123600Z"));
}

test "parseAmzDate: epoch" {
    try testing.expectEqual(@as(i64, 0), try parseAmzDate("19700101T000000Z"));
}

test "parseAmzDate: leap year Feb 29" {
    // 2024-02-29T00:00:00 UTC
    try testing.expectEqual(@as(i64, 1709164800), try parseAmzDate("20240229T000000Z"));
}

test "parseAmzDate: malformed length" {
    try testing.expectError(Error.Malformed, parseAmzDate("20150830T12360"));
}

test "parseAmzDate: malformed separators" {
    try testing.expectError(Error.Malformed, parseAmzDate("20150830X123600Z"));
}

test "parseAmzDate: out-of-range month" {
    try testing.expectError(Error.Malformed, parseAmzDate("20150030T123600Z"));
}

test "parseAmzDate: Feb 30 → Malformed" {
    // Day-in-month must be honoured per the AWS spec.
    try testing.expectError(Error.Malformed, parseAmzDate("20260230T000000Z"));
}

test "parseAmzDate: Feb 29 in non-leap year → Malformed" {
    // 2023 is not a leap year.
    try testing.expectError(Error.Malformed, parseAmzDate("20230229T000000Z"));
}

test "parseAmzDate: Apr 31 → Malformed" {
    try testing.expectError(Error.Malformed, parseAmzDate("20240431T000000Z"));
}

test "parseAmzDate: leap-year edge — 2000 (div by 400) is leap" {
    try testing.expectEqual(@as(i64, 951782400), try parseAmzDate("20000229T000000Z"));
}

test "parseAmzDate: leap-year edge — 2100 (div by 100, not 400) is not leap" {
    try testing.expectError(Error.Malformed, parseAmzDate("21000229T000000Z"));
}

test "formatAmzDate: round trip" {
    var buf: [16]u8 = undefined;
    formatAmzDate(&buf, 1440938160);
    try testing.expectEqualStrings("20150830T123600Z", &buf);
}

test "formatAmzDate: epoch" {
    var buf: [16]u8 = undefined;
    formatAmzDate(&buf, 0);
    try testing.expectEqualStrings("19700101T000000Z", &buf);
}

test "formatScopeDate" {
    var buf: [8]u8 = undefined;
    formatScopeDate(&buf, 1440938160);
    try testing.expectEqualStrings("20150830", &buf);
}
