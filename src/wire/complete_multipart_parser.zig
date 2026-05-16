//! Parser for the AWS `CompleteMultipartUpload` request body:
//!
//!   <?xml version="1.0" encoding="UTF-8"?>
//!   <CompleteMultipartUpload>
//!     <Part><PartNumber>1</PartNumber><ETag>"abc..."</ETag></Part>
//!     <Part><PartNumber>2</PartNumber><ETag>"def..."</ETag></Part>
//!   </CompleteMultipartUpload>
//!
//! Driven by `ianprime0509/zig-xml` (the M3 dep). Validates strict
//! ascending part numbers; out-of-order → `InvalidPartOrder`. Each
//! `<ETag>` is preserved verbatim (with quotes); the service layer
//! byte-compares it against the stored part etag.

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml");
const storage = @import("../storage/mod.zig");

pub const Result = struct {
    /// Caller owns the slice + each ETag string. PartNumbers are inline.
    parts: []storage.CompletePart,
};

pub const ParseError = error{
    InvalidBody,
    /// Body is well-formed XML but the structural rule fails (e.g. empty
    /// `<Part>` list). AWS uses `MalformedXML` for these — distinct from
    /// `InvalidRequest` (malformed XML *parse*).
    MalformedXml,
    InvalidPartOrder,
    OutOfMemory,
};

pub fn parse(allocator: Allocator, body: []const u8) ParseError!Result {
    var static_reader: xml.Reader.Static = .init(allocator, body, .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var parts: std.ArrayList(storage.CompletePart) = .empty;
    errdefer {
        for (parts.items) |p| allocator.free(p.etag);
        parts.deinit(allocator);
    }

    var depth: usize = 0;
    var in_part = false;
    var pending_part_number: ?u32 = null;
    var pending_etag: ?[]const u8 = null;

    while (true) {
        const node = reader.read() catch return ParseError.InvalidBody;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                depth += 1;
                if (std.mem.eql(u8, name, "Part")) {
                    in_part = true;
                    pending_part_number = null;
                    pending_etag = null;
                } else if (in_part and std.mem.eql(u8, name, "PartNumber")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.InvalidBody;
                    defer allocator.free(txt);
                    const trimmed = std.mem.trim(u8, txt, " \t\r\n");
                    const num = std.fmt.parseInt(u32, trimmed, 10) catch return ParseError.InvalidBody;
                    pending_part_number = num;
                    depth -= 1; // readElementTextAlloc consumed the matching .element_end
                } else if (in_part and std.mem.eql(u8, name, "ETag")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.InvalidBody;
                    if (std.mem.trim(u8, txt, " \t\r\n").len == 0) {
                        allocator.free(txt);
                        return ParseError.InvalidBody;
                    }
                    pending_etag = txt;
                    depth -= 1;
                }
            },
            .element_end => {
                const name = reader.elementName();
                depth -= 1;
                if (std.mem.eql(u8, name, "Part")) {
                    in_part = false;
                    const pn = pending_part_number orelse return ParseError.InvalidBody;
                    const et = pending_etag orelse return ParseError.InvalidBody;
                    if (parts.items.len > 0 and parts.items[parts.items.len - 1].part_number >= pn) {
                        allocator.free(et);
                        return ParseError.InvalidPartOrder;
                    }
                    parts.append(allocator, .{ .part_number = pn, .etag = et }) catch {
                        allocator.free(et);
                        return ParseError.OutOfMemory;
                    };
                    pending_part_number = null;
                    pending_etag = null;
                }
            },
            else => {},
        }
    }

    if (parts.items.len == 0) return ParseError.MalformedXml;
    return .{ .parts = parts.toOwnedSlice(allocator) catch return ParseError.OutOfMemory };
}

pub fn freeResult(allocator: Allocator, result: Result) void {
    for (result.parts) |p| allocator.free(p.etag);
    allocator.free(result.parts);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parse: two parts in order" {
    const body =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CompleteMultipartUpload>
        \\  <Part><PartNumber>1</PartNumber><ETag>"abc"</ETag></Part>
        \\  <Part><PartNumber>2</PartNumber><ETag>"def"</ETag></Part>
        \\</CompleteMultipartUpload>
    ;
    const result = try parse(testing.allocator, body);
    defer freeResult(testing.allocator, result);
    try testing.expectEqual(@as(usize, 2), result.parts.len);
    try testing.expectEqual(@as(u32, 1), result.parts[0].part_number);
    try testing.expectEqualStrings("\"abc\"", result.parts[0].etag);
    try testing.expectEqual(@as(u32, 2), result.parts[1].part_number);
    try testing.expectEqualStrings("\"def\"", result.parts[1].etag);
}

test "parse: descending → InvalidPartOrder" {
    const body =
        \\<CompleteMultipartUpload>
        \\  <Part><PartNumber>2</PartNumber><ETag>"x"</ETag></Part>
        \\  <Part><PartNumber>1</PartNumber><ETag>"y"</ETag></Part>
        \\</CompleteMultipartUpload>
    ;
    try testing.expectError(ParseError.InvalidPartOrder, parse(testing.allocator, body));
}

test "parse: duplicate part number → InvalidPartOrder" {
    const body =
        \\<CompleteMultipartUpload>
        \\  <Part><PartNumber>1</PartNumber><ETag>"x"</ETag></Part>
        \\  <Part><PartNumber>1</PartNumber><ETag>"y"</ETag></Part>
        \\</CompleteMultipartUpload>
    ;
    try testing.expectError(ParseError.InvalidPartOrder, parse(testing.allocator, body));
}

test "parse: empty <Part> list → MalformedXml" {
    const body = "<CompleteMultipartUpload></CompleteMultipartUpload>";
    try testing.expectError(ParseError.MalformedXml, parse(testing.allocator, body));
}

test "parse: malformed → InvalidBody" {
    try testing.expectError(ParseError.InvalidBody, parse(testing.allocator, "<CompleteMultipartUpload><Part>"));
}
