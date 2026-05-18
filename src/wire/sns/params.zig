//! `application/x-www-form-urlencoded` body decoder for the SNS query
//! protocol (v0.4.0). SNS, unlike DDB / modern SQS, hasn't migrated to
//! JSON+`X-Amz-Target` — bodies look like:
//!
//!   Action=Publish&TopicArn=arn%3Aaws%3Asns%3A...%3Atopic&Message=hi
//!
//! Decoding:
//!   - split by `&`
//!   - each pair splits by `=`
//!   - URL-decode `+` → space, `%XX` → byte
//!   - build an ordered list of (key, value) pairs
//!
//! Some SNS shapes use `.member.N.` indexed list keys (e.g.
//! `MessageAttributes.entry.1.Name`, `PublishBatchRequestEntries.member.1.Id`).
//! We expose those as raw keys; callers iterate by walking the prefix.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Param = struct {
    key: []const u8,
    value: []const u8,
};

pub const ParseError = error{
    Malformed,
    OutOfMemory,
};

/// Decode a `application/x-www-form-urlencoded` body into a slice of
/// (key, value) pairs. Keys + values are allocated copies, owned by
/// the caller's allocator (typically the per-request arena).
pub fn parse(allocator: Allocator, body: []const u8) ParseError![]Param {
    var out: std.ArrayList(Param) = .empty;
    errdefer out.deinit(allocator);
    if (body.len == 0) return try out.toOwnedSlice(allocator);

    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const raw_k = if (eq) |i| pair[0..i] else pair;
        const raw_v = if (eq) |i| pair[i + 1 ..] else "";
        const k = try urlDecode(allocator, raw_k);
        errdefer allocator.free(k);
        const v = try urlDecode(allocator, raw_v);
        try out.append(allocator, .{ .key = k, .value = v });
    }
    return try out.toOwnedSlice(allocator);
}

/// Lookup the first value for `key`. Linear scan — fine for typical
/// SNS bodies that have <30 params.
pub fn get(params: []const Param, key: []const u8) ?[]const u8 {
    for (params) |p| {
        if (std.mem.eql(u8, p.key, key)) return p.value;
    }
    return null;
}

/// Iterate the `prefix` keys (e.g., `MessageAttributes.entry.`). For
/// each unique numeric index, yields the index. Callers then look up
/// `<prefix><n>.<subkey>` to read fields.
///
/// Example:
///   listIndices(params, "MessageAttributes.entry.") → [1, 2, 3]
///
/// The returned indices are deduplicated + sorted ascending. Caller
/// owns the slice.
pub fn listIndices(allocator: Allocator, params: []const Param, prefix: []const u8) ![]const u32 {
    var seen: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(allocator);
    for (params) |p| {
        if (!std.mem.startsWith(u8, p.key, prefix)) continue;
        const rest = p.key[prefix.len..];
        // Parse the leading integer.
        var end: usize = 0;
        while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}
        if (end == 0) continue;
        const n = std.fmt.parseInt(u32, rest[0..end], 10) catch continue;
        try seen.put(allocator, n, {});
    }
    var out: std.ArrayList(u32) = .empty;
    var it = seen.iterator();
    while (it.next()) |entry| try out.append(allocator, entry.key_ptr.*);
    std.mem.sort(u32, out.items, {}, struct {
        fn lt(_: void, a: u32, b: u32) bool {
            return a < b;
        }
    }.lt);
    return try out.toOwnedSlice(allocator);
}

/// URL-decode `input`: `+` → space, `%XX` → byte. Returns an allocated
/// copy in `allocator`.
pub fn urlDecode(allocator: Allocator, input: []const u8) ParseError![]const u8 {
    var out = allocator.alloc(u8, input.len) catch return ParseError.OutOfMemory;
    errdefer allocator.free(out);
    var w: usize = 0;
    var r: usize = 0;
    while (r < input.len) : (r += 1) {
        const c = input[r];
        if (c == '+') {
            out[w] = ' ';
            w += 1;
        } else if (c == '%' and r + 2 < input.len) {
            const hi = hexDigit(input[r + 1]) orelse return ParseError.Malformed;
            const lo = hexDigit(input[r + 2]) orelse return ParseError.Malformed;
            out[w] = (hi << 4) | lo;
            w += 1;
            r += 2;
        } else {
            out[w] = c;
            w += 1;
        }
    }
    // Truncate to actual length.
    return allocator.realloc(out, w) catch out[0..w];
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parse: empty body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const params = try parse(arena.allocator(), "");
    try testing.expectEqual(@as(usize, 0), params.len);
}

test "parse: simple Action=Foo" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const params = try parse(arena.allocator(), "Action=CreateTopic&Name=foo");
    try testing.expectEqual(@as(usize, 2), params.len);
    try testing.expectEqualStrings("Action", params[0].key);
    try testing.expectEqualStrings("CreateTopic", params[0].value);
    try testing.expectEqualStrings("Name", params[1].key);
    try testing.expectEqualStrings("foo", params[1].value);
}

test "parse: percent-encoded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const params = try parse(arena.allocator(),
        "TopicArn=arn%3Aaws%3Asns%3Aus-east-1%3A000000000000%3Atopic1");
    try testing.expectEqual(@as(usize, 1), params.len);
    try testing.expectEqualStrings("arn:aws:sns:us-east-1:000000000000:topic1", params[0].value);
}

test "parse: plus is space" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const params = try parse(arena.allocator(), "Message=hello+world");
    try testing.expectEqualStrings("hello world", params[0].value);
}

test "get: linear lookup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const params = try parse(arena.allocator(), "A=1&B=2&A=3");
    try testing.expectEqualStrings("1", get(params, "A").?);
    try testing.expectEqualStrings("2", get(params, "B").?);
    try testing.expect(get(params, "C") == null);
}

test "listIndices: dedup + sort" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const params = try parse(arena.allocator(),
        "MessageAttributes.entry.2.Name=x&MessageAttributes.entry.1.Name=y&MessageAttributes.entry.2.Value=v");
    const indices = try listIndices(arena.allocator(), params, "MessageAttributes.entry.");
    try testing.expectEqual(@as(usize, 2), indices.len);
    try testing.expectEqual(@as(u32, 1), indices[0]);
    try testing.expectEqual(@as(u32, 2), indices[1]);
}

test "urlDecode: %XX edge cases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a:b", try urlDecode(arena.allocator(), "a%3Ab"));
    try testing.expectEqualStrings("100%", try urlDecode(arena.allocator(), "100%25"));
}
