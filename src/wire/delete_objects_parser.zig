//! Parser for the AWS `DeleteObjects` request body:
//!
//!   <?xml version="1.0" encoding="UTF-8"?>
//!   <Delete>
//!     <Object><Key>k1</Key></Object>
//!     <Object><Key>k2</Key><VersionId>...</VersionId></Object>
//!     <Quiet>true</Quiet>
//!   </Delete>
//!
//! Driven by `ianprime0509/zig-xml` (the only Zig 0.16-compatible
//! XML parser with a proper build.zig.zon). `<VersionId>` is captured
//! per `<Object>` and threaded through to the storage call — versioned
//! batch deletes hit the requested version exactly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml");

pub const Entry = struct {
    /// Owned key string.
    key: []const u8,
    /// Owned version id string (or null when the request omitted it).
    version_id: ?[]const u8 = null,
};

pub const Result = struct {
    /// Caller owns the slice + every string inside each Entry.
    objects: []Entry,
    quiet: bool,
};

pub const ParseError = error{
    InvalidBody,
    OutOfMemory,
};

pub fn parse(allocator: Allocator, body: []const u8) ParseError!Result {
    var static_reader: xml.Reader.Static = .init(allocator, body, .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.key);
            if (e.version_id) |v| allocator.free(v);
        }
        entries.deinit(allocator);
    }
    var quiet = false;

    while (true) {
        const node = reader.read() catch return ParseError.InvalidBody;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "Object")) {
                    // Reserve a slot the inner <Key>/<VersionId> will populate.
                    entries.append(allocator, .{ .key = "" }) catch return ParseError.OutOfMemory;
                } else if (std.mem.eql(u8, name, "Key")) {
                    const owned = reader.readElementTextAlloc(allocator) catch return ParseError.InvalidBody;
                    if (entries.items.len == 0) {
                        // Stray <Key> outside <Object> — malformed.
                        allocator.free(owned);
                        return ParseError.InvalidBody;
                    }
                    entries.items[entries.items.len - 1].key = owned;
                } else if (std.mem.eql(u8, name, "VersionId")) {
                    const owned = reader.readElementTextAlloc(allocator) catch return ParseError.InvalidBody;
                    if (entries.items.len == 0) {
                        allocator.free(owned);
                        return ParseError.InvalidBody;
                    }
                    entries.items[entries.items.len - 1].version_id = owned;
                } else if (std.mem.eql(u8, name, "Quiet")) {
                    const owned = reader.readElementTextAlloc(allocator) catch return ParseError.InvalidBody;
                    defer allocator.free(owned);
                    const trimmed = std.mem.trim(u8, owned, " \t\r\n");
                    if (std.mem.eql(u8, trimmed, "true")) quiet = true;
                }
            },
            else => {},
        }
    }

    return .{
        .objects = entries.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
        .quiet = quiet,
    };
}

pub fn freeResult(allocator: Allocator, result: Result) void {
    for (result.objects) |e| {
        allocator.free(e.key);
        if (e.version_id) |v| allocator.free(v);
    }
    allocator.free(result.objects);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parse: minimal two-key Delete" {
    const body =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Delete>
        \\  <Object><Key>alpha</Key></Object>
        \\  <Object><Key>beta</Key></Object>
        \\</Delete>
    ;
    const result = try parse(testing.allocator, body);
    defer freeResult(testing.allocator, result);
    try testing.expectEqual(@as(usize, 2), result.objects.len);
    try testing.expectEqualStrings("alpha", result.objects[0].key);
    try testing.expectEqual(@as(?[]const u8, null), result.objects[0].version_id);
    try testing.expectEqualStrings("beta", result.objects[1].key);
    try testing.expect(!result.quiet);
}

test "parse: with Quiet=true" {
    const body =
        \\<Delete>
        \\  <Object><Key>x</Key></Object>
        \\  <Quiet>true</Quiet>
        \\</Delete>
    ;
    const result = try parse(testing.allocator, body);
    defer freeResult(testing.allocator, result);
    try testing.expect(result.quiet);
    try testing.expectEqual(@as(usize, 1), result.objects.len);
}

test "parse: Quiet=false" {
    const body =
        \\<Delete>
        \\  <Object><Key>x</Key></Object>
        \\  <Quiet>false</Quiet>
        \\</Delete>
    ;
    const result = try parse(testing.allocator, body);
    defer freeResult(testing.allocator, result);
    try testing.expect(!result.quiet);
}

test "parse: VersionId captured per Object" {
    const body =
        \\<Delete>
        \\  <Object><Key>x</Key><VersionId>v1</VersionId></Object>
        \\  <Object><Key>y</Key></Object>
        \\  <Object><Key>z</Key><VersionId>v3</VersionId></Object>
        \\</Delete>
    ;
    const result = try parse(testing.allocator, body);
    defer freeResult(testing.allocator, result);
    try testing.expectEqual(@as(usize, 3), result.objects.len);
    try testing.expectEqualStrings("x", result.objects[0].key);
    try testing.expectEqualStrings("v1", result.objects[0].version_id.?);
    try testing.expectEqualStrings("y", result.objects[1].key);
    try testing.expectEqual(@as(?[]const u8, null), result.objects[1].version_id);
    try testing.expectEqualStrings("z", result.objects[2].key);
    try testing.expectEqualStrings("v3", result.objects[2].version_id.?);
}

test "parse: malformed → InvalidBody" {
    try testing.expectError(ParseError.InvalidBody, parse(testing.allocator, "<Delete><Object><Key>k"));
}

test "parse: keys with entities are decoded" {
    const body =
        \\<Delete>
        \\  <Object><Key>a&amp;b</Key></Object>
        \\</Delete>
    ;
    const result = try parse(testing.allocator, body);
    defer freeResult(testing.allocator, result);
    try testing.expectEqual(@as(usize, 1), result.objects.len);
    try testing.expectEqualStrings("a&b", result.objects[0].key);
}
