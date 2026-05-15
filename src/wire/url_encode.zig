//! RFC 3986 percent-encoder used when AWS S3 listing responses opt into
//! `encoding-type=url`. Encodes every byte outside the unreserved set
//! `[A-Za-z0-9-_.~]`, **including `/`** — what `decodeURIComponent`
//! round-trips. Returns an arena-owned slice.

const std = @import("std");
const Allocator = std.mem.Allocator;

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}

pub fn percentEncode(arena: Allocator, raw: []const u8) ![]u8 {
    // First pass: count non-unreserved bytes so we can size the output.
    var extra: usize = 0;
    for (raw) |c| {
        if (!isUnreserved(c)) extra += 2; // each becomes 3 bytes; +2 over the original 1.
    }
    if (extra == 0) {
        return arena.dupe(u8, raw);
    }
    var out = try arena.alloc(u8, raw.len + extra);
    var j: usize = 0;
    for (raw) |c| {
        if (isUnreserved(c)) {
            out[j] = c;
            j += 1;
        } else {
            const hex = "0123456789ABCDEF";
            out[j] = '%';
            out[j + 1] = hex[(c >> 4) & 0xF];
            out[j + 2] = hex[c & 0xF];
            j += 3;
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "percentEncode: empty string roundtrips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try percentEncode(arena.allocator(), "");
    try testing.expectEqualStrings("", got);
}

test "percentEncode: all-unreserved roundtrips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try percentEncode(arena.allocator(), "abcXYZ-._~0123");
    try testing.expectEqualStrings("abcXYZ-._~0123", got);
}

test "percentEncode: slash becomes %2F" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try percentEncode(arena.allocator(), "a/b/c");
    try testing.expectEqualStrings("a%2Fb%2Fc", got);
}

test "percentEncode: space + ampersand + plus" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try percentEncode(arena.allocator(), "a b&c+d");
    try testing.expectEqualStrings("a%20b%26c%2Bd", got);
}

test "percentEncode: multi-byte UTF-8 each byte encoded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // U+00E9 (é) in UTF-8 is 0xC3 0xA9 → %C3%A9
    const got = try percentEncode(arena.allocator(), "caf\u{00E9}");
    try testing.expectEqualStrings("caf%C3%A9", got);
}

test "percentEncode: AWS S3 example — encoding-type=url result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // A typical hostile key: control char, slash, space.
    const got = try percentEncode(arena.allocator(), "foo bar/baz\nqux");
    try testing.expectEqualStrings("foo%20bar%2Fbaz%0Aqux", got);
}
