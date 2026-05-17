//! DynamoDB JSON error renderer.
//!
//! Different shape from S3's XML `<Error>` body — DDB uses:
//!
//!   {"__type": "com.amazonaws.dynamodb.v20120810#<ErrorCode>",
//!    "message": "<human-readable>"}
//!
//! The `__type` namespace is `com.amazonaws.dynamodb.v20120810#` for the
//! main service. Some errors carry extra fields (notably
//! `TransactionCanceledException`'s `CancellationReasons` array) — those
//! are rendered op-side; this module covers the common shape.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// DDB error codes nanostack emits. The Smithy surface is larger; we
/// cover the ones the v0.2.0 op set can produce.
pub const Code = enum {
    /// Generic 400-class validation failure — bad shape, missing field,
    /// reserved word in expression, etc.
    validation_exception,
    /// Table / index / item not found.
    resource_not_found_exception,
    /// Table already exists (CreateTable on a name that's in use).
    resource_in_use_exception,
    /// `ConditionExpression` on Put/Update/Delete evaluated to false.
    conditional_check_failed_exception,
    /// `TransactWriteItems` cancelled — at least one condition failed.
    /// Caller fills in `CancellationReasons`; this module renders only
    /// the top-level shape.
    transaction_canceled_exception,
    /// Throttle (nanostack doesn't actually throttle — kept for shape
    /// parity).
    provisioned_throughput_exceeded_exception,
    /// Account-level limit hit (e.g. table count).
    limit_exceeded_exception,
    /// Backup ARN doesn't match any known backup (v0.2.5).
    backup_not_found_exception,
    /// Continuous backups (PITR) state precondition failed — e.g.
    /// RestoreTableToPointInTime called against a table that never had
    /// PITR enabled (v0.2.5).
    continuous_backups_unavailable_exception,
    /// Op recognised by the dispatcher but not yet implemented.
    not_implemented,
    /// Generic 500.
    internal_server_error,

    pub fn awsCode(self: Code) []const u8 {
        return switch (self) {
            .validation_exception => "ValidationException",
            .resource_not_found_exception => "ResourceNotFoundException",
            .resource_in_use_exception => "ResourceInUseException",
            .conditional_check_failed_exception => "ConditionalCheckFailedException",
            .transaction_canceled_exception => "TransactionCanceledException",
            .provisioned_throughput_exceeded_exception => "ProvisionedThroughputExceededException",
            .limit_exceeded_exception => "LimitExceededException",
            .backup_not_found_exception => "BackupNotFoundException",
            .continuous_backups_unavailable_exception => "ContinuousBackupsUnavailableException",
            .not_implemented => "InternalServerError", // AWS doesn't expose "NotImplemented" on DDB
            .internal_server_error => "InternalServerError",
        };
    }

    pub fn defaultMessage(self: Code) []const u8 {
        return switch (self) {
            .validation_exception => "The request is invalid.",
            .resource_not_found_exception => "Requested resource not found",
            .resource_in_use_exception => "The resource is already in use.",
            .conditional_check_failed_exception => "The conditional request failed",
            .transaction_canceled_exception => "Transaction cancelled, please refer to cancellation reasons for specific reasons",
            .provisioned_throughput_exceeded_exception => "The level of configured provisioned throughput for the table was exceeded.",
            .limit_exceeded_exception => "An account-level limit was exceeded.",
            .backup_not_found_exception => "Backup not found.",
            .continuous_backups_unavailable_exception => "Continuous backups are not enabled on this table.",
            .not_implemented => "This operation is not implemented in nanostack.",
            .internal_server_error => "An error occurred on the server side.",
        };
    }

    /// HTTP status. DynamoDB collapses most client errors onto 400, with
    /// a few exceptions (Throughput → 400, Throttling-class → 400, the
    /// Conditional-failure shape is 400 too — DDB really does flatten this
    /// hard).
    pub fn httpStatus(self: Code) u16 {
        return switch (self) {
            .internal_server_error, .not_implemented => 500,
            else => 400,
        };
    }
};

/// Render a DynamoDB error JSON body to an owned buffer.
/// Pass `null` for `message` to use the code's default message.
pub fn render(allocator: Allocator, code: Code, message: ?[]const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("__type");
    // The wire format prepends the service namespace and a `#` separator.
    var type_buf: [128]u8 = undefined;
    const type_str = try std.fmt.bufPrint(&type_buf, "com.amazonaws.dynamodb.v20120810#{s}", .{code.awsCode()});
    try s.write(type_str);
    try s.objectField("message");
    try s.write(message orelse code.defaultMessage());
    try s.endObject();
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "render: ResourceNotFoundException with default message" {
    const got = try render(testing.allocator, .resource_not_found_exception, null);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "{\"__type\":\"com.amazonaws.dynamodb.v20120810#ResourceNotFoundException\",\"message\":\"Requested resource not found\"}",
        got,
    );
}

test "render: ValidationException with custom message" {
    const got = try render(testing.allocator, .validation_exception, "Invalid attribute type");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "{\"__type\":\"com.amazonaws.dynamodb.v20120810#ValidationException\",\"message\":\"Invalid attribute type\"}",
        got,
    );
}

test "httpStatus: most are 400" {
    try testing.expectEqual(@as(u16, 400), Code.validation_exception.httpStatus());
    try testing.expectEqual(@as(u16, 400), Code.resource_not_found_exception.httpStatus());
    try testing.expectEqual(@as(u16, 400), Code.conditional_check_failed_exception.httpStatus());
    try testing.expectEqual(@as(u16, 500), Code.internal_server_error.httpStatus());
}
