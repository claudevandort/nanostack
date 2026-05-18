//! SNS error response rendering (v0.4.0).
//!
//! SNS uses the AWS query protocol's XML error envelope:
//!
//!   <?xml version="1.0"?>
//!   <ErrorResponse xmlns="http://sns.amazonaws.com/doc/2010-03-31/">
//!     <Error>
//!       <Type>Sender</Type>
//!       <Code>InvalidParameter</Code>
//!       <Message>...</Message>
//!     </Error>
//!     <RequestId>...</RequestId>
//!   </ErrorResponse>

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Code = enum {
    invalid_parameter,
    invalid_action,
    not_found,
    authorization_error,
    topic_already_exists,
    subscription_not_found,
    invalid_security,
    internal_error,

    pub fn awsCode(self: Code) []const u8 {
        return switch (self) {
            .invalid_parameter => "InvalidParameter",
            .invalid_action => "InvalidAction",
            .not_found => "NotFound",
            .authorization_error => "AuthorizationError",
            .topic_already_exists => "InvalidParameter", // AWS reuses
            .subscription_not_found => "NotFound",
            .invalid_security => "InvalidSecurity",
            .internal_error => "InternalFailure",
        };
    }

    pub fn defaultMessage(self: Code) []const u8 {
        return switch (self) {
            .invalid_parameter => "Invalid parameter.",
            .invalid_action => "Invalid action.",
            .not_found => "Resource not found.",
            .authorization_error => "Not authorized to perform this operation.",
            .topic_already_exists => "A topic with this name already exists with different attributes.",
            .subscription_not_found => "Subscription does not exist.",
            .invalid_security => "The security token included in the request is invalid.",
            .internal_error => "Internal failure.",
        };
    }

    pub fn errorType(self: Code) []const u8 {
        return switch (self) {
            .internal_error => "Receiver",
            else => "Sender",
        };
    }

    pub fn httpStatus(self: Code) u16 {
        return switch (self) {
            .not_found, .subscription_not_found => 404,
            .authorization_error => 403,
            .invalid_security => 401,
            .internal_error => 500,
            else => 400,
        };
    }
};

pub fn render(allocator: Allocator, code: Code, message: ?[]const u8, request_id: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print(
        "<?xml version=\"1.0\"?>\n" ++
            "<ErrorResponse xmlns=\"http://sns.amazonaws.com/doc/2010-03-31/\">\n" ++
            "  <Error>\n" ++
            "    <Type>{s}</Type>\n" ++
            "    <Code>{s}</Code>\n" ++
            "    <Message>{s}</Message>\n" ++
            "  </Error>\n" ++
            "  <RequestId>{s}</RequestId>\n" ++
            "</ErrorResponse>",
        .{ code.errorType(), code.awsCode(), message orelse code.defaultMessage(), request_id },
    );
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "render: not_found" {
    const body = try render(testing.allocator, .not_found, null, "req-1");
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<Type>Sender</Type>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<Code>NotFound</Code>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<RequestId>req-1</RequestId>") != null);
}
