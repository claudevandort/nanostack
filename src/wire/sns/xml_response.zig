//! SNS XML response envelope (v0.4.0).
//!
//! Every successful SNS response has this shape:
//!
//!   <?xml version="1.0"?>
//!   <{Action}Response xmlns="http://sns.amazonaws.com/doc/2010-03-31/">
//!     <{Action}Result>
//!       ... per-op body ...
//!     </{Action}Result>
//!     <ResponseMetadata>
//!       <RequestId>...</RequestId>
//!     </ResponseMetadata>
//!   </{Action}Response>
//!
//! The "Result" tag is sometimes omitted (e.g., DeleteTopic just has the
//! empty body inside `<DeleteTopicResponse>`). Callers pass `inner_result`
//! as the bytes between the Result open/close — empty string for ops with
//! no return values.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ns = "http://sns.amazonaws.com/doc/2010-03-31/";

/// Wrap `inner_result` (the per-op body) in the standard SNS XML
/// response envelope. `action` is the op name as it appears on the wire
/// ("CreateTopic", "Publish", etc.).
///
/// If `inner_result` is empty, the `<XxxResult/>` element is self-closing.
pub fn render(allocator: Allocator, action: []const u8, inner_result: []const u8, request_id: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print("<?xml version=\"1.0\"?>\n<{s}Response xmlns=\"{s}\">\n", .{ action, ns });
    if (inner_result.len == 0) {
        try aw.writer.print("  <{s}Result/>\n", .{action});
    } else {
        try aw.writer.print("  <{s}Result>\n{s}\n  </{s}Result>\n", .{ action, inner_result, action });
    }
    try aw.writer.print("  <ResponseMetadata>\n    <RequestId>{s}</RequestId>\n  </ResponseMetadata>\n</{s}Response>", .{ request_id, action });
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "render: with result body" {
    const body = try render(testing.allocator, "CreateTopic", "    <TopicArn>arn:aws:sns:us-east-1:000000000000:foo</TopicArn>", "req-1");
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<CreateTopicResponse") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<CreateTopicResult>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<TopicArn>arn:aws:sns:us-east-1:000000000000:foo</TopicArn>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<RequestId>req-1</RequestId>") != null);
}

test "render: empty result body (self-closing)" {
    const body = try render(testing.allocator, "DeleteTopic", "", "req-2");
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<DeleteTopicResult/>") != null);
}
