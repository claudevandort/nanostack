//! SQS JSON error renderer (v0.3.0).
//!
//! Same shape as the DDB error renderer but with SQS-specific `__type`
//! namespace:
//!
//!   {"__type": "com.amazonaws.sqs#<ErrorCode>",
//!    "message": "<human-readable>"}

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Code = enum {
    invalid_parameter_value,
    missing_parameter,
    queue_does_not_exist,
    queue_name_exists,
    queue_deleted_recently,
    receipt_handle_is_invalid,
    invalid_message_contents,
    too_many_entries_in_batch_request,
    batch_entry_ids_not_distinct,
    empty_batch_request,
    invalid_attribute_value,
    access_denied,
    not_implemented,
    internal_server_error,

    pub fn awsCode(self: Code) []const u8 {
        return switch (self) {
            .invalid_parameter_value => "InvalidParameterValue",
            .missing_parameter => "MissingParameter",
            .queue_does_not_exist => "AWS.SimpleQueueService.NonExistentQueue",
            .queue_name_exists => "AWS.SimpleQueueService.QueueNameExists",
            .queue_deleted_recently => "AWS.SimpleQueueService.QueueDeletedRecently",
            .receipt_handle_is_invalid => "ReceiptHandleIsInvalid",
            .invalid_message_contents => "InvalidMessageContents",
            .too_many_entries_in_batch_request => "AWS.SimpleQueueService.TooManyEntriesInBatchRequest",
            .batch_entry_ids_not_distinct => "AWS.SimpleQueueService.BatchEntryIdsNotDistinct",
            .empty_batch_request => "AWS.SimpleQueueService.EmptyBatchRequest",
            .invalid_attribute_value => "InvalidAttributeValue",
            .access_denied => "AccessDenied",
            .not_implemented => "InternalFailure",
            .internal_server_error => "InternalFailure",
        };
    }

    pub fn defaultMessage(self: Code) []const u8 {
        return switch (self) {
            .invalid_parameter_value => "The request contains an invalid parameter value.",
            .missing_parameter => "The request is missing a required parameter.",
            .queue_does_not_exist => "The specified queue does not exist.",
            .queue_name_exists => "A queue with this name already exists.",
            .queue_deleted_recently => "You must wait 60 seconds after deleting a queue before you can create another with the same name.",
            .receipt_handle_is_invalid => "The specified receipt handle is not valid.",
            .invalid_message_contents => "The message contains characters outside the allowed set.",
            .too_many_entries_in_batch_request => "The batch request contains more entries than permissible (10).",
            .batch_entry_ids_not_distinct => "Two or more batch entries have the same Id.",
            .empty_batch_request => "The batch request doesn't contain any entries.",
            .invalid_attribute_value => "The specified attribute value is invalid.",
            .access_denied => "Access to the resource is denied.",
            .not_implemented => "This operation is not implemented in nanostack.",
            .internal_server_error => "An error occurred on the server side.",
        };
    }

    pub fn httpStatus(self: Code) u16 {
        return switch (self) {
            .internal_server_error, .not_implemented => 500,
            .access_denied => 403,
            else => 400,
        };
    }
};

pub fn render(allocator: Allocator, code: Code, message: ?[]const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("__type");
    {
        var ns_buf: [128]u8 = undefined;
        const ns = try std.fmt.bufPrint(&ns_buf, "com.amazonaws.sqs#{s}", .{code.awsCode()});
        try s.write(ns);
    }
    try s.objectField("message");
    try s.write(message orelse code.defaultMessage());
    try s.endObject();
    return aw.toOwnedSlice();
}
