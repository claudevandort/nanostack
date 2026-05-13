//! Parsers for both forms of S3 tagging input (M9):
//!
//! 1. **XML body** — used by `PutBucketTagging` and `PutObjectTagging`:
//!
//!        <Tagging xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
//!          <TagSet>
//!            <Tag><Key>env</Key><Value>prod</Value></Tag>
//!            ...
//!          </TagSet>
//!        </Tagging>
//!
//! 2. **`x-amz-tagging` header** — used by PutObject, CopyObject,
//!    CreateMultipartUpload. URL-encoded query-string form
//!    (`team=alpha&env=prod`).
//!
//! Both forms feed through `storage.validateTagSet` before returning.

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml");
const storage = @import("../storage/mod.zig");

pub const ParseError = error{
    InvalidBody,
    InvalidTag,
    OutOfMemory,
};

/// Parse the XML body of PutBucketTagging or PutObjectTagging. Caller
/// owns the returned slice and every string within.
pub fn parseBody(allocator: Allocator, body: []const u8) ParseError![]storage.Tag {
    var static_reader: xml.Reader.Static = .init(allocator, body, .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var tags: std.ArrayList(storage.Tag) = .empty;
    errdefer {
        for (tags.items) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
        tags.deinit(allocator);
    }

    var in_tag = false;
    var pending_key: ?[]const u8 = null;
    var pending_value: ?[]const u8 = null;
    errdefer {
        if (pending_key) |k| allocator.free(k);
        if (pending_value) |v| allocator.free(v);
    }

    while (true) {
        const node = reader.read() catch return ParseError.InvalidBody;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "Tag")) {
                    in_tag = true;
                    pending_key = null;
                    pending_value = null;
                } else if (in_tag and std.mem.eql(u8, name, "Key")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.InvalidBody;
                    pending_key = txt;
                } else if (in_tag and std.mem.eql(u8, name, "Value")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.InvalidBody;
                    pending_value = txt;
                }
            },
            .element_end => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "Tag")) {
                    in_tag = false;
                    const key = pending_key orelse return ParseError.InvalidBody;
                    // <Value/> may legitimately be empty.
                    const value = pending_value orelse (allocator.dupe(u8, "") catch return ParseError.OutOfMemory);
                    tags.append(allocator, .{ .key = key, .value = value }) catch {
                        allocator.free(key);
                        allocator.free(value);
                        return ParseError.OutOfMemory;
                    };
                    pending_key = null;
                    pending_value = null;
                }
            },
            else => {},
        }
    }

    const out = tags.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
    storage.validateTagSet(out) catch {
        freeOwned(allocator, out);
        return ParseError.InvalidTag;
    };
    return out;
}

/// Parse the `x-amz-tagging` header value: `k1=v1&k2=v2` with `%`-decoded
/// keys and values.
pub fn parseHeader(allocator: Allocator, value: []const u8) ParseError![]storage.Tag {
    var tags: std.ArrayList(storage.Tag) = .empty;
    errdefer {
        for (tags.items) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
        tags.deinit(allocator);
    }

    if (value.len == 0) {
        const empty = tags.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
        storage.validateTagSet(empty) catch {
            freeOwned(allocator, empty);
            return ParseError.InvalidTag;
        };
        return empty;
    }

    var it = std.mem.splitScalar(u8, value, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return ParseError.InvalidTag;
        const raw_key = pair[0..eq];
        const raw_value = pair[eq + 1 ..];
        const key = pctDecode(allocator, raw_key) catch return ParseError.OutOfMemory;
        const val = pctDecode(allocator, raw_value) catch {
            allocator.free(key);
            return ParseError.OutOfMemory;
        };
        tags.append(allocator, .{ .key = key, .value = val }) catch {
            allocator.free(key);
            allocator.free(val);
            return ParseError.OutOfMemory;
        };
    }

    const out = tags.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
    storage.validateTagSet(out) catch {
        freeOwned(allocator, out);
        return ParseError.InvalidTag;
    };
    return out;
}

pub fn freeOwned(allocator: Allocator, tags: []storage.Tag) void {
    for (tags) |t| {
        allocator.free(t.key);
        allocator.free(t.value);
    }
    allocator.free(tags);
}

fn pctDecode(allocator: Allocator, in: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(allocator, in.len);
    var i: usize = 0;
    while (i < in.len) : (i += 1) {
        if (in[i] == '%' and i + 2 < in.len) {
            const hi = hexDigit(in[i + 1]) orelse {
                try out.append(allocator, in[i]);
                continue;
            };
            const lo = hexDigit(in[i + 2]) orelse {
                try out.append(allocator, in[i]);
                continue;
            };
            try out.append(allocator, (hi << 4) | lo);
            i += 2;
        } else if (in[i] == '+') {
            try out.append(allocator, ' ');
        } else {
            try out.append(allocator, in[i]);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parseBody: two tags" {
    const body =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Tagging>
        \\  <TagSet>
        \\    <Tag><Key>env</Key><Value>prod</Value></Tag>
        \\    <Tag><Key>team</Key><Value>alpha</Value></Tag>
        \\  </TagSet>
        \\</Tagging>
    ;
    const tags = try parseBody(testing.allocator, body);
    defer freeOwned(testing.allocator, tags);
    try testing.expectEqual(@as(usize, 2), tags.len);
    try testing.expectEqualStrings("env", tags[0].key);
    try testing.expectEqualStrings("prod", tags[0].value);
}

test "parseBody: empty TagSet" {
    const body = "<Tagging><TagSet></TagSet></Tagging>";
    const tags = try parseBody(testing.allocator, body);
    defer freeOwned(testing.allocator, tags);
    try testing.expectEqual(@as(usize, 0), tags.len);
}

test "parseBody: malformed → InvalidBody" {
    try testing.expectError(ParseError.InvalidBody, parseBody(testing.allocator, "<Tagging><TagSet><Tag><Key>k"));
}

test "parseBody: aws: prefix rejected" {
    const body = "<Tagging><TagSet><Tag><Key>aws:foo</Key><Value>v</Value></Tag></TagSet></Tagging>";
    try testing.expectError(ParseError.InvalidTag, parseBody(testing.allocator, body));
}

test "parseHeader: two tags" {
    const tags = try parseHeader(testing.allocator, "env=prod&team=alpha");
    defer freeOwned(testing.allocator, tags);
    try testing.expectEqual(@as(usize, 2), tags.len);
    try testing.expectEqualStrings("env", tags[0].key);
    try testing.expectEqualStrings("alpha", tags[1].value);
}

test "parseHeader: empty header → empty set" {
    const tags = try parseHeader(testing.allocator, "");
    defer freeOwned(testing.allocator, tags);
    try testing.expectEqual(@as(usize, 0), tags.len);
}

test "parseHeader: percent-decoded" {
    const tags = try parseHeader(testing.allocator, "key%20with%20space=value%2Fwith%2Fslash");
    defer freeOwned(testing.allocator, tags);
    try testing.expectEqualStrings("key with space", tags[0].key);
    try testing.expectEqualStrings("value/with/slash", tags[0].value);
}

test "parseHeader: missing = → InvalidTag" {
    try testing.expectError(ParseError.InvalidTag, parseHeader(testing.allocator, "justakey"));
}

test "parseHeader: duplicate keys rejected" {
    try testing.expectError(ParseError.InvalidTag, parseHeader(testing.allocator, "k=v1&k=v2"));
}
