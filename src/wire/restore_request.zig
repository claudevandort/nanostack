//! RestoreRequest XML parser (M13). RestoreObject ignores most of the
//! body (GlacierJobParameters/Tier/etc.); we only need <Days>.
//!
//! Body shape:
//!   <RestoreRequest>
//!     <Days>1</Days>
//!     <GlacierJobParameters><Tier>Standard</Tier></GlacierJobParameters>
//!   </RestoreRequest>

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml_lib = @import("xml");

pub const ParseError = error{
    MalformedXml,
    OutOfMemory,
};

pub fn parseBody(allocator: Allocator, body: []const u8) ParseError!u32 {
    // Empty body → default 1-day restore (per AWS).
    if (std.mem.trim(u8, body, " \t\r\n").len == 0) return 1;

    var static_reader: xml_lib.Reader.Static = .init(allocator, body, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    while (true) {
        const node = reader.read() catch return ParseError.MalformedXml;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "Days")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    return std.fmt.parseInt(u32, txt, 10) catch return ParseError.MalformedXml;
                }
            },
            else => {},
        }
    }
    return 1;
}

const testing = std.testing;

test "parseBody: Days=7" {
    const body = "<RestoreRequest><Days>7</Days></RestoreRequest>";
    try testing.expectEqual(@as(u32, 7), try parseBody(testing.allocator, body));
}

test "parseBody: empty body → 1 day default" {
    try testing.expectEqual(@as(u32, 1), try parseBody(testing.allocator, ""));
}

test "parseBody: full body with GlacierJobParameters" {
    const body =
        \\<RestoreRequest>
        \\  <Days>3</Days>
        \\  <GlacierJobParameters><Tier>Bulk</Tier></GlacierJobParameters>
        \\</RestoreRequest>
    ;
    try testing.expectEqual(@as(u32, 3), try parseBody(testing.allocator, body));
}
