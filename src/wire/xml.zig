//! Minimal XML emitter for S3 response bodies.
//!
//! S3 responses are a small, fixed shape: nested elements, attributes,
//! text leaves, an `xmlns` on the root, and the standard XML prolog.
//! No mixed content, no namespaces beyond a fixed `xmlns`, no PIs.
//!
//! We hand-roll this because `nektro/zig-xml` is parser-only and the
//! emit surface here is ~five primitives.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

pub const Node = union(enum) {
    element: *Element,
    text: []const u8,
};

pub const Element = struct {
    name: []const u8,
    attrs: []const Attr = &.{},
    children: []const Node = &.{},
    text: ?[]const u8 = null,

    pub fn renderRoot(self: *const Element, writer: *Writer) Writer.Error!void {
        try writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        try self.render(writer);
    }

    pub fn render(self: *const Element, writer: *Writer) Writer.Error!void {
        try writer.writeByte('<');
        try writer.writeAll(self.name);
        for (self.attrs) |a| {
            try writer.writeByte(' ');
            try writer.writeAll(a.name);
            try writer.writeAll("=\"");
            try writeEscapedAttr(writer, a.value);
            try writer.writeByte('"');
        }

        const has_text_intent = self.text != null;
        const has_text = has_text_intent and self.text.?.len > 0;
        const has_children = self.children.len > 0;
        // Self-close only when neither text nor children were attached.
        // An explicitly-empty text (`text = ""`) yields paired tags
        // (`<Foo></Foo>`), matching AWS-exact XML responses for fields like
        // empty `<Prefix>` / `<Delimiter>` / `<KeyMarker>`.
        if (!has_text_intent and !has_children) {
            try writer.writeAll("/>");
            return;
        }
        try writer.writeByte('>');
        if (has_text) try writeEscapedText(writer, self.text.?);
        for (self.children) |c| switch (c) {
            .element => |e| try e.render(writer),
            .text => |t| try writeEscapedText(writer, t),
        };
        try writer.writeAll("</");
        try writer.writeAll(self.name);
        try writer.writeByte('>');
    }
};

fn writeEscapedText(writer: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '&' => try writer.writeAll("&amp;"),
        else => try writer.writeByte(c),
    };
}

fn writeEscapedAttr(writer: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '&' => try writer.writeAll("&amp;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&apos;"),
        else => try writer.writeByte(c),
    };
}

/// Convenience: render `root` (with XML prolog) into a freshly allocated buffer.
pub fn renderToOwnedSlice(allocator: Allocator, root: *const Element) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try root.renderRoot(&aw.writer);
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "renders empty self-closing element" {
    const e: Element = .{ .name = "Foo" };
    const got = try renderToOwnedSlice(testing.allocator, &e);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Foo/>",
        got,
    );
}

test "renders element with text and attributes" {
    const e: Element = .{
        .name = "Code",
        .attrs = &.{.{ .name = "lang", .value = "en" }},
        .text = "NotImplemented",
    };
    const got = try renderToOwnedSlice(testing.allocator, &e);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Code lang=\"en\">NotImplemented</Code>",
        got,
    );
}

test "escapes text content" {
    const e: Element = .{ .name = "Msg", .text = "a < b & c > d" };
    const got = try renderToOwnedSlice(testing.allocator, &e);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Msg>a &lt; b &amp; c &gt; d</Msg>",
        got,
    );
}

test "escapes attribute quotes" {
    const e: Element = .{
        .name = "X",
        .attrs = &.{.{ .name = "v", .value = "he said \"hi\" & left" }},
    };
    const got = try renderToOwnedSlice(testing.allocator, &e);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<X v=\"he said &quot;hi&quot; &amp; left\"/>",
        got,
    );
}

test "renders nested children" {
    var code: Element = .{ .name = "Code", .text = "NoSuchBucket" };
    var msg: Element = .{ .name = "Message", .text = "The specified bucket does not exist" };
    const err: Element = .{
        .name = "Error",
        .children = &.{
            .{ .element = &code },
            .{ .element = &msg },
        },
    };
    const got = try renderToOwnedSlice(testing.allocator, &err);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Error><Code>NoSuchBucket</Code><Message>The specified bucket does not exist</Message></Error>",
        got,
    );
}
