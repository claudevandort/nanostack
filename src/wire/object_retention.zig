//! Object retention XML parser + renderer (M12).
//!
//! Body shape:
//!     <Retention>
//!       <Mode>GOVERNANCE</Mode>
//!       <RetainUntilDate>2026-12-31T23:59:59Z</RetainUntilDate>
//!     </Retention>

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml_lib = @import("xml");
const xml_out = @import("xml.zig");
const storage = @import("../storage/mod.zig");

const xmlns_attr: xml_out.Attr = .{ .name = "xmlns", .value = "http://s3.amazonaws.com/doc/2006-03-01/" };

pub const ParseError = error{
    MalformedXml,
    InvalidRetentionPeriod,
    OutOfMemory,
};

pub fn parseBody(allocator: Allocator, body: []const u8) ParseError!storage.ObjectRetention {
    var static_reader: xml_lib.Reader.Static = .init(allocator, body, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var mode: ?storage.RetentionMode = null;
    var retain_until: i64 = 0;

    while (true) {
        const node = reader.read() catch return ParseError.MalformedXml;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "Mode")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    mode = storage.retentionModeFromString(txt) catch return ParseError.MalformedXml;
                } else if (std.mem.eql(u8, name, "RetainUntilDate")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    retain_until = parseIsoOrUnix(txt) catch return ParseError.InvalidRetentionPeriod;
                }
            },
            else => {},
        }
    }

    const m = mode orelse return ParseError.MalformedXml;
    if (retain_until == 0) return ParseError.InvalidRetentionPeriod;
    return .{ .mode = m, .retain_until_unix = retain_until };
}

/// Parse a minimal ISO 8601 datetime to Unix seconds. Accepts the AWS
/// formats `YYYY-MM-DDTHH:MM:SS[.fff][Z|+HH:MM|-HH:MM]`. Fractional
/// seconds and timezone offsets are honoured; missing tz means UTC.
pub fn parseIsoOrUnix(s: []const u8) !i64 {
    if (s.len < 19) return error.BadFormat;
    const year = std.fmt.parseInt(i32, s[0..4], 10) catch return error.BadFormat;
    if (s[4] != '-') return error.BadFormat;
    const month = std.fmt.parseInt(u32, s[5..7], 10) catch return error.BadFormat;
    if (s[7] != '-') return error.BadFormat;
    const day = std.fmt.parseInt(u32, s[8..10], 10) catch return error.BadFormat;
    if (s[10] != 'T') return error.BadFormat;
    const hour = std.fmt.parseInt(u32, s[11..13], 10) catch return error.BadFormat;
    if (s[13] != ':') return error.BadFormat;
    const minute = std.fmt.parseInt(u32, s[14..16], 10) catch return error.BadFormat;
    if (s[16] != ':') return error.BadFormat;
    const second = std.fmt.parseInt(u32, s[17..19], 10) catch return error.BadFormat;

    // Optional fractional seconds + offset.
    var i: usize = 19;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    }
    var tz_off: i64 = 0;
    if (i < s.len) {
        if (s[i] == 'Z') {
            // zero offset
        } else if (s[i] == '+' or s[i] == '-') {
            if (i + 5 >= s.len) return error.BadFormat;
            const sign: i64 = if (s[i] == '+') 1 else -1;
            const tz_h = std.fmt.parseInt(u32, s[i + 1 .. i + 3], 10) catch return error.BadFormat;
            const colon = s[i + 3] == ':';
            const m_start: usize = if (colon) i + 4 else i + 3;
            const tz_m = std.fmt.parseInt(u32, s[m_start .. m_start + 2], 10) catch return error.BadFormat;
            tz_off = sign * (@as(i64, tz_h) * 3600 + @as(i64, tz_m) * 60);
        } else return error.BadFormat;
    }

    return daysFromCivil(year, @intCast(month), @intCast(day)) * 86400 +
        @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second) - tz_off;
}

/// Howard Hinnant's civil-to-days algorithm.
fn daysFromCivil(year: i32, month: i32, day: i32) i64 {
    const y: i64 = if (month <= 2) @intCast(year - 1) else @intCast(year);
    const era: i64 = if (y >= 0) @divFloor(y, 400) else @divFloor(y - 399, 400);
    const yoe: i64 = y - era * 400;
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);
    const doy = @divFloor((153 * (if (m > 2) m - 3 else m + 9) + 2), 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn formatIsoUnix(allocator: Allocator, unix_seconds: i64) ![]u8 {
    const z_secs: i64 = @mod(unix_seconds, 86400);
    const days: i64 = @divFloor(unix_seconds, 86400);
    const civ = civilFromDays(days);
    const hour: u32 = @intCast(@divFloor(z_secs, 3600));
    const minute: u32 = @intCast(@divFloor(@mod(z_secs, 3600), 60));
    const second: u32 = @intCast(@mod(z_secs, 60));
    const year_u: u32 = @intCast(civ.year);
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        year_u, civ.month, civ.day, hour, minute, second,
    });
}

const Civil = struct { year: i32, month: u32, day: u32 };
fn civilFromDays(days: i64) Civil {
    const z: i64 = days + 719468;
    const era: i64 = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
    const doe: i64 = z - era * 146097;
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: i64 = @divFloor(5 * doy + 2, 153);
    const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    const year: i32 = @intCast(if (m <= 2) y + 1 else y);
    return .{ .year = year, .month = @intCast(m), .day = @intCast(d) };
}

pub fn render(allocator: Allocator, retention: storage.ObjectRetention) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mode_el = try arena.create(xml_out.Element);
    mode_el.* = .{ .name = "Mode", .text = storage.retentionModeToString(retention.mode) };
    const date_el = try arena.create(xml_out.Element);
    date_el.* = .{ .name = "RetainUntilDate", .text = try formatIsoUnix(arena, retention.retain_until_unix) };

    const root: xml_out.Element = .{
        .name = "Retention",
        .attrs = &.{xmlns_attr},
        .children = try arena.dupe(xml_out.Node, &.{
            .{ .element = mode_el },
            .{ .element = date_el },
        }),
    };
    return xml_out.renderToOwnedSlice(allocator, &root);
}

const testing = std.testing;

test "parseBody: GOVERNANCE + future date" {
    const body = "<Retention><Mode>GOVERNANCE</Mode><RetainUntilDate>2099-01-01T00:00:00Z</RetainUntilDate></Retention>";
    const r = try parseBody(testing.allocator, body);
    try testing.expectEqual(storage.RetentionMode.GOVERNANCE, r.mode);
    try testing.expect(r.retain_until_unix > 0);
}

test "parseBody: missing Mode → MalformedXml" {
    const body = "<Retention><RetainUntilDate>2099-01-01T00:00:00Z</RetainUntilDate></Retention>";
    try testing.expectError(ParseError.MalformedXml, parseBody(testing.allocator, body));
}

test "render: round-trip" {
    const r: storage.ObjectRetention = .{ .mode = .COMPLIANCE, .retain_until_unix = 1_999_999_999 };
    const body = try render(testing.allocator, r);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<Mode>COMPLIANCE</Mode>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<RetainUntilDate>") != null);
}
