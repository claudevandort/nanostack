//! Parser for the AWS `PutBucketVersioning` request body:
//!
//!   <?xml version="1.0" encoding="UTF-8"?>
//!   <VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
//!     <Status>Enabled</Status>
//!     <!-- Optional <MfaDelete>Enabled|Disabled</MfaDelete> — accepted and ignored. -->
//!   </VersioningConfiguration>
//!
//! Driven by `ianprime0509/zig-xml`. Only the `<Status>` value is
//! interpreted; `<MfaDelete>` is ignored (M8 deferral, documented in
//! SUPPORT.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml");
const storage = @import("../storage/mod.zig");

pub const ParseError = error{
    InvalidBody,
    OutOfMemory,
};

/// Returns the parsed VersioningStatus. Note that the wire format never
/// carries `none` — that's the implicit initial state — so we only ever
/// return `.enabled` or `.suspended`. A body with no `<Status>` or one
/// containing an unrecognised value is rejected with `InvalidBody`.
pub fn parse(allocator: Allocator, body: []const u8) ParseError!storage.VersioningStatus {
    var static_reader: xml.Reader.Static = .init(allocator, body, .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    while (true) {
        const node = reader.read() catch return ParseError.InvalidBody;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "Status")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.InvalidBody;
                    defer allocator.free(txt);
                    const trimmed = std.mem.trim(u8, txt, " \t\r\n");
                    if (std.mem.eql(u8, trimmed, "Enabled")) return .enabled;
                    if (std.mem.eql(u8, trimmed, "Suspended")) return .suspended;
                    return ParseError.InvalidBody;
                }
            },
            else => {},
        }
    }
    return ParseError.InvalidBody;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parse: Enabled" {
    const body =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>
    ;
    try testing.expectEqual(storage.VersioningStatus.enabled, try parse(testing.allocator, body));
}

test "parse: Suspended" {
    const body =
        \\<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>
    ;
    try testing.expectEqual(storage.VersioningStatus.suspended, try parse(testing.allocator, body));
}

test "parse: unknown status → InvalidBody" {
    const body = "<VersioningConfiguration><Status>Off</Status></VersioningConfiguration>";
    try testing.expectError(ParseError.InvalidBody, parse(testing.allocator, body));
}

test "parse: no Status element → InvalidBody" {
    const body = "<VersioningConfiguration></VersioningConfiguration>";
    try testing.expectError(ParseError.InvalidBody, parse(testing.allocator, body));
}

test "parse: MfaDelete is ignored" {
    const body =
        \\<VersioningConfiguration>
        \\  <MfaDelete>Enabled</MfaDelete>
        \\  <Status>Enabled</Status>
        \\</VersioningConfiguration>
    ;
    try testing.expectEqual(storage.VersioningStatus.enabled, try parse(testing.allocator, body));
}
