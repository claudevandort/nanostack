//! DynamoDB AttributeValue codec.
//!
//! AttributeValue is DynamoDB's tagged-union value type. The JSON wire
//! form is an object with exactly one key indicating the type:
//!
//!   {"S":   "hello"}                       — String
//!   {"N":   "123.45"}                      — Number (encoded as string to preserve 38-digit precision)
//!   {"B":   "dGV4dA=="}                    — Binary (base64)
//!   {"BOOL": true}                         — Boolean
//!   {"NULL": true}                         — Null
//!   {"L":   [{"S":"a"}, {"N":"1"}]}        — List (heterogeneous)
//!   {"M":   {"k1": {"S":"v1"}, ...}}       — Map
//!   {"SS":  ["a","b","c"]}                 — String Set (deduplicated, non-empty)
//!   {"NS":  ["1","2","3"]}                 — Number Set
//!   {"BS":  ["...", "..."]}                — Binary Set
//!
//! N values are stored as `[]const u8` (the literal JSON text), NOT
//! parsed to f64 — DynamoDB's 38-digit decimal precision exceeds IEEE
//! 754 and clients can send valid numbers we'd otherwise round-trip
//! lossily. Arithmetic (SET x = x + :v) happens via decimal string
//! arithmetic in `expressions/update.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ParseError = error{
    Malformed, // wrong shape, unknown type tag, or invalid inner JSON
    EmptySet, // SS / NS / BS with zero elements
    DuplicateInSet, // SS / NS / BS with a duplicate
    OutOfMemory,
};

/// One DynamoDB attribute value.
pub const AttributeValue = union(enum) {
    /// String. Empty string is allowed by DynamoDB (since 2020).
    s: []const u8,
    /// Number, as the literal decimal string the client sent. Validated
    /// for shape but not parsed to a native numeric.
    n: []const u8,
    /// Binary, decoded from base64 in the wire form.
    b: []const u8,
    bool: bool,
    null,
    list: []AttributeValue,
    map: Map,
    /// String set. Deduplicated, non-empty. Insertion order preserved
    /// for stable output; semantics are set-equality.
    ss: []const []const u8,
    ns: []const []const u8,
    bs: []const []const u8,

    pub const Map = struct {
        names: []const []const u8,
        values: []AttributeValue,
    };
};

// ---------------------------------------------------------------------------
// Parse: std.json.Value → AttributeValue

/// Parse one attribute-value JSON object (with exactly one type tag).
/// The result owns its string/byte slices and any nested allocations
/// (heap-allocated via `allocator`). Free with `deinit`.
pub fn parseValue(allocator: Allocator, node: std.json.Value) ParseError!AttributeValue {
    if (node != .object) return ParseError.Malformed;
    const obj = node.object;
    if (obj.count() != 1) return ParseError.Malformed;

    var it = obj.iterator();
    const entry = it.next().?;
    const tag = entry.key_ptr.*;
    const v = entry.value_ptr.*;

    if (std.mem.eql(u8, tag, "S")) {
        if (v != .string) return ParseError.Malformed;
        return .{ .s = try allocator.dupe(u8, v.string) };
    }
    if (std.mem.eql(u8, tag, "N")) {
        if (v != .string) return ParseError.Malformed;
        if (!isValidDecimalNumber(v.string)) return ParseError.Malformed;
        return .{ .n = try allocator.dupe(u8, v.string) };
    }
    if (std.mem.eql(u8, tag, "B")) {
        if (v != .string) return ParseError.Malformed;
        const dec = base64Decode(allocator, v.string) catch return ParseError.Malformed;
        return .{ .b = dec };
    }
    if (std.mem.eql(u8, tag, "BOOL")) {
        if (v != .bool) return ParseError.Malformed;
        return .{ .bool = v.bool };
    }
    if (std.mem.eql(u8, tag, "NULL")) {
        if (v != .bool or !v.bool) return ParseError.Malformed;
        return .null;
    }
    if (std.mem.eql(u8, tag, "L")) {
        if (v != .array) return ParseError.Malformed;
        const items = try allocator.alloc(AttributeValue, v.array.items.len);
        var done: usize = 0;
        errdefer {
            for (items[0..done]) |*it_| deinit(allocator, it_);
            allocator.free(items);
        }
        for (v.array.items, 0..) |child, i| {
            items[i] = try parseValue(allocator, child);
            done = i + 1;
        }
        return .{ .list = items };
    }
    if (std.mem.eql(u8, tag, "M")) {
        if (v != .object) return ParseError.Malformed;
        const n = v.object.count();
        const names = try allocator.alloc([]const u8, n);
        var names_done: usize = 0;
        errdefer {
            for (names[0..names_done]) |s| allocator.free(s);
            allocator.free(names);
        }
        const values = try allocator.alloc(AttributeValue, n);
        var values_done: usize = 0;
        errdefer {
            for (values[0..values_done]) |*vit| deinit(allocator, vit);
            allocator.free(values);
        }
        var iter = v.object.iterator();
        var i: usize = 0;
        while (iter.next()) |e| : (i += 1) {
            names[i] = try allocator.dupe(u8, e.key_ptr.*);
            names_done = i + 1;
            values[i] = try parseValue(allocator, e.value_ptr.*);
            values_done = i + 1;
        }
        return .{ .map = .{ .names = names, .values = values } };
    }
    if (std.mem.eql(u8, tag, "SS")) return parseStringSet(allocator, v, .string_set);
    if (std.mem.eql(u8, tag, "NS")) return parseStringSet(allocator, v, .number_set);
    if (std.mem.eql(u8, tag, "BS")) return parseStringSet(allocator, v, .binary_set);

    return ParseError.Malformed;
}

const SetKind = enum { string_set, number_set, binary_set };

fn parseStringSet(allocator: Allocator, v: std.json.Value, kind: SetKind) ParseError!AttributeValue {
    if (v != .array) return ParseError.Malformed;
    const arr = v.array.items;
    if (arr.len == 0) return ParseError.EmptySet;
    const owned = try allocator.alloc([]const u8, arr.len);
    var done: usize = 0;
    errdefer {
        for (owned[0..done]) |s| allocator.free(s);
        allocator.free(owned);
    }
    for (arr, 0..) |child, i| {
        if (child != .string) return ParseError.Malformed;
        const s = child.string;
        if (kind == .number_set and !isValidDecimalNumber(s)) return ParseError.Malformed;
        const decoded = if (kind == .binary_set)
            base64Decode(allocator, s) catch return ParseError.Malformed
        else
            try allocator.dupe(u8, s);
        owned[i] = decoded;
        done = i + 1;
        // Reject duplicates (O(N^2) is fine — DynamoDB sets are small).
        for (owned[0..i]) |existing| {
            if (std.mem.eql(u8, existing, decoded)) return ParseError.DuplicateInSet;
        }
    }
    return switch (kind) {
        .string_set => .{ .ss = owned },
        .number_set => .{ .ns = owned },
        .binary_set => .{ .bs = owned },
    };
}

// ---------------------------------------------------------------------------
// Render: AttributeValue → JSON via std.json.Stringify
//
// We render directly to a Stringify (which wraps a writer) rather than
// building an in-memory `std.json.Value` tree. Matches the
// `wire/xml.zig::renderToOwnedSlice` pattern and avoids the
// allocator-juggling that std.json.ObjectMap's Unmanaged shape requires.

/// Render one AttributeValue as one JSON `<value>` (which is always a
/// `{"<tag>": <inner>}` object). Caller owns the Stringify and surrounding
/// writes.
pub fn renderValue(s: *std.json.Stringify, allocator: Allocator, v: AttributeValue) !void {
    try s.beginObject();
    switch (v) {
        .s => |str| {
            try s.objectField("S");
            try s.write(str);
        },
        .n => |str| {
            try s.objectField("N");
            try s.write(str);
        },
        .b => |bytes| {
            try s.objectField("B");
            const encoded = try base64Encode(allocator, bytes);
            defer allocator.free(encoded);
            try s.write(encoded);
        },
        .bool => |b| {
            try s.objectField("BOOL");
            try s.write(b);
        },
        .null => {
            try s.objectField("NULL");
            try s.write(true);
        },
        .list => |items| {
            try s.objectField("L");
            try s.beginArray();
            for (items) |child| try renderValue(s, allocator, child);
            try s.endArray();
        },
        .map => |m| {
            try s.objectField("M");
            try s.beginObject();
            for (m.names, m.values) |name, value| {
                try s.objectField(name);
                try renderValue(s, allocator, value);
            }
            try s.endObject();
        },
        .ss, .ns, .bs => |elements| {
            try s.objectField(switch (v) {
                .ss => "SS",
                .ns => "NS",
                .bs => "BS",
                else => unreachable,
            });
            try s.beginArray();
            const is_b64 = (v == .bs);
            for (elements) |e| {
                if (is_b64) {
                    const encoded = try base64Encode(allocator, e);
                    defer allocator.free(encoded);
                    try s.write(encoded);
                } else {
                    try s.write(e);
                }
            }
            try s.endArray();
        },
    }
    try s.endObject();
}

/// Convenience: render a single AttributeValue to an owned JSON string.
pub fn renderToOwnedSlice(allocator: Allocator, v: AttributeValue) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try renderValue(&s, allocator, v);
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Deinit (deep-free)

pub fn deinit(allocator: Allocator, v: *AttributeValue) void {
    switch (v.*) {
        .s => |s| allocator.free(s),
        .n => |s| allocator.free(s),
        .b => |bytes| allocator.free(bytes),
        .bool, .null => {},
        .list => |items| {
            for (items) |*item| {
                var copy = item.*;
                deinit(allocator, &copy);
            }
            allocator.free(items);
        },
        .map => |m| {
            for (m.names) |name| allocator.free(name);
            for (m.values) |*value| {
                var copy = value.*;
                deinit(allocator, &copy);
            }
            allocator.free(m.names);
            allocator.free(m.values);
        },
        .ss, .ns, .bs => |elements| {
            for (elements) |s| allocator.free(s);
            allocator.free(elements);
        },
    }
}

// ---------------------------------------------------------------------------
// Validators

/// Validate that `s` is a decimal number string DynamoDB would accept.
/// AWS rules: optional leading `-`, integer part (no leading zeros unless
/// the value is exactly "0"), optional fractional part, optional decimal
/// exponent. We accept the common forms used in the wild.
fn isValidDecimalNumber(s: []const u8) bool {
    if (s.len == 0 or s.len > 38 + 6) return false; // 38 digits + sign + dot + 'e' + exponent
    var i: usize = 0;
    if (s[i] == '-' or s[i] == '+') i += 1;
    if (i >= s.len) return false;

    // Integer part.
    const int_start = i;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
    const int_len = i - int_start;
    if (int_len == 0 and (i >= s.len or s[i] != '.')) return false;
    // Leading-zero rule: "0" ok, "0." ok, "01" not.
    if (int_len > 1 and s[int_start] == '0') return false;

    // Fractional part.
    if (i < s.len and s[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        if (i - frac_start == 0) return false;
    }

    // Exponent.
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const exp_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        if (i - exp_start == 0) return false;
    }

    return i == s.len;
}

// ---------------------------------------------------------------------------
// Base64 helpers (small wrappers around std.base64)

fn base64Decode(allocator: Allocator, encoded: []const u8) ![]u8 {
    const max_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidEncoding;
    const out = try allocator.alloc(u8, max_len);
    errdefer allocator.free(out);
    try std.base64.standard.Decoder.decode(out, encoded);
    return out;
}

fn base64Encode(allocator: Allocator, raw: []const u8) ![]u8 {
    const enc_len = std.base64.standard.Encoder.calcSize(raw.len);
    const out = try allocator.alloc(u8, enc_len);
    _ = std.base64.standard.Encoder.encode(out, raw);
    return out;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn parseLiteral(allocator: Allocator, body: []const u8) !AttributeValue {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    return try parseValue(allocator, parsed.value);
}

test "parseValue: S round-trip" {
    var v = try parseLiteral(testing.allocator, "{\"S\":\"hello\"}");
    defer deinit(testing.allocator, &v);
    try testing.expectEqualStrings("hello", v.s);
}

test "parseValue: N preserves precision" {
    var v = try parseLiteral(testing.allocator, "{\"N\":\"123456789012345678901234567890\"}");
    defer deinit(testing.allocator, &v);
    try testing.expectEqualStrings("123456789012345678901234567890", v.n);
}

test "parseValue: BOOL true/false" {
    var t = try parseLiteral(testing.allocator, "{\"BOOL\":true}");
    defer deinit(testing.allocator, &t);
    try testing.expect(t.bool);
    var f = try parseLiteral(testing.allocator, "{\"BOOL\":false}");
    defer deinit(testing.allocator, &f);
    try testing.expect(!f.bool);
}

test "parseValue: NULL only accepts NULL:true" {
    var n = try parseLiteral(testing.allocator, "{\"NULL\":true}");
    defer deinit(testing.allocator, &n);
    try testing.expect(n == .null);
    try testing.expectError(ParseError.Malformed, parseLiteral(testing.allocator, "{\"NULL\":false}"));
}

test "parseValue: B base64 decodes" {
    var v = try parseLiteral(testing.allocator, "{\"B\":\"aGVsbG8=\"}");
    defer deinit(testing.allocator, &v);
    try testing.expectEqualStrings("hello", v.b);
}

test "parseValue: L heterogeneous" {
    var v = try parseLiteral(testing.allocator, "{\"L\":[{\"S\":\"a\"},{\"N\":\"1\"}]}");
    defer deinit(testing.allocator, &v);
    try testing.expectEqual(@as(usize, 2), v.list.len);
    try testing.expectEqualStrings("a", v.list[0].s);
    try testing.expectEqualStrings("1", v.list[1].n);
}

test "parseValue: M nested" {
    var v = try parseLiteral(testing.allocator, "{\"M\":{\"name\":{\"S\":\"Bob\"},\"age\":{\"N\":\"42\"}}}");
    defer deinit(testing.allocator, &v);
    try testing.expectEqual(@as(usize, 2), v.map.names.len);
    // Order isn't guaranteed by std.json's parser; look up by key.
    var found_name = false;
    var found_age = false;
    for (v.map.names, v.map.values) |name, value| {
        if (std.mem.eql(u8, name, "name")) {
            try testing.expectEqualStrings("Bob", value.s);
            found_name = true;
        } else if (std.mem.eql(u8, name, "age")) {
            try testing.expectEqualStrings("42", value.n);
            found_age = true;
        }
    }
    try testing.expect(found_name and found_age);
}

test "parseValue: SS deduplicates on insert via DuplicateInSet error" {
    try testing.expectError(ParseError.DuplicateInSet, parseLiteral(testing.allocator, "{\"SS\":[\"a\",\"a\"]}"));
}

test "parseValue: SS rejects empty" {
    try testing.expectError(ParseError.EmptySet, parseLiteral(testing.allocator, "{\"SS\":[]}"));
}

test "parseValue: NS validates each element as a number" {
    try testing.expectError(ParseError.Malformed, parseLiteral(testing.allocator, "{\"NS\":[\"1\",\"two\"]}"));
}

test "parseValue: rejects multi-key object" {
    try testing.expectError(ParseError.Malformed, parseLiteral(testing.allocator, "{\"S\":\"a\",\"N\":\"1\"}"));
}

test "parseValue: rejects unknown tag" {
    try testing.expectError(ParseError.Malformed, parseLiteral(testing.allocator, "{\"X\":\"a\"}"));
}

test "isValidDecimalNumber: shapes" {
    try testing.expect(isValidDecimalNumber("0"));
    try testing.expect(isValidDecimalNumber("-42"));
    try testing.expect(isValidDecimalNumber("3.14"));
    try testing.expect(isValidDecimalNumber("1e10"));
    try testing.expect(isValidDecimalNumber("-1.5e-2"));
    try testing.expect(!isValidDecimalNumber(""));
    try testing.expect(!isValidDecimalNumber("01")); // leading zero
    try testing.expect(!isValidDecimalNumber("."));
    try testing.expect(!isValidDecimalNumber("1."));
    try testing.expect(!isValidDecimalNumber("1e"));
    try testing.expect(!isValidDecimalNumber("abc"));
}

test "render round-trip: S" {
    var v: AttributeValue = .{ .s = try testing.allocator.dupe(u8, "hello") };
    defer deinit(testing.allocator, &v);
    const got = try renderToOwnedSlice(testing.allocator, v);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("{\"S\":\"hello\"}", got);
}

test "render: B re-encodes to base64" {
    var v: AttributeValue = .{ .b = try testing.allocator.dupe(u8, "hello") };
    defer deinit(testing.allocator, &v);
    const got = try renderToOwnedSlice(testing.allocator, v);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("{\"B\":\"aGVsbG8=\"}", got);
}

test "render: nested L with mixed types" {
    const items = try testing.allocator.alloc(AttributeValue, 2);
    items[0] = .{ .s = try testing.allocator.dupe(u8, "a") };
    items[1] = .{ .n = try testing.allocator.dupe(u8, "1") };
    var v: AttributeValue = .{ .list = items };
    defer deinit(testing.allocator, &v);
    const got = try renderToOwnedSlice(testing.allocator, v);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("{\"L\":[{\"S\":\"a\"},{\"N\":\"1\"}]}", got);
}

test "render: M preserves key order from input" {
    const names = try testing.allocator.alloc([]const u8, 2);
    names[0] = try testing.allocator.dupe(u8, "name");
    names[1] = try testing.allocator.dupe(u8, "age");
    const values = try testing.allocator.alloc(AttributeValue, 2);
    values[0] = .{ .s = try testing.allocator.dupe(u8, "Bob") };
    values[1] = .{ .n = try testing.allocator.dupe(u8, "42") };
    var v: AttributeValue = .{ .map = .{ .names = names, .values = values } };
    defer deinit(testing.allocator, &v);
    const got = try renderToOwnedSlice(testing.allocator, v);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("{\"M\":{\"name\":{\"S\":\"Bob\"},\"age\":{\"N\":\"42\"}}}", got);
}

test "render: SS round-trip" {
    const elements = try testing.allocator.alloc([]const u8, 2);
    elements[0] = try testing.allocator.dupe(u8, "x");
    elements[1] = try testing.allocator.dupe(u8, "y");
    var v: AttributeValue = .{ .ss = elements };
    defer deinit(testing.allocator, &v);
    const got = try renderToOwnedSlice(testing.allocator, v);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("{\"SS\":[\"x\",\"y\"]}", got);
}
