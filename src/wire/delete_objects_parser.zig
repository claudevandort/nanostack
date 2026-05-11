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
//! XML parser with a proper build.zig.zon). We ignore `<VersionId>`
//! for now — versioning is post-v1.

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml");

pub const Result = struct {
    /// Caller owns the slice + each element.
    keys: [][]const u8,
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

    var keys: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
    }
    var quiet = false;

    while (true) {
        const node = reader.read() catch return ParseError.InvalidBody;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "Key")) {
                    const owned = reader.readElementTextAlloc(allocator) catch return ParseError.InvalidBody;
                    keys.append(allocator, owned) catch {
                        allocator.free(owned);
                        return ParseError.OutOfMemory;
                    };
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
        .keys = keys.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
        .quiet = quiet,
    };
}

pub fn freeResult(allocator: Allocator, result: Result) void {
    for (result.keys) |k| allocator.free(k);
    allocator.free(result.keys);
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
    try testing.expectEqual(@as(usize, 2), result.keys.len);
    try testing.expectEqualStrings("alpha", result.keys[0]);
    try testing.expectEqualStrings("beta", result.keys[1]);
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
    try testing.expectEqual(@as(usize, 1), result.keys.len);
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

test "parse: VersionId is ignored" {
    const body =
        \\<Delete>
        \\  <Object><Key>x</Key><VersionId>v1</VersionId></Object>
        \\</Delete>
    ;
    const result = try parse(testing.allocator, body);
    defer freeResult(testing.allocator, result);
    try testing.expectEqual(@as(usize, 1), result.keys.len);
    try testing.expectEqualStrings("x", result.keys[0]);
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
    try testing.expectEqual(@as(usize, 1), result.keys.len);
    try testing.expectEqualStrings("a&b", result.keys[0]);
}
