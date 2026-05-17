//! Wire parsers + renderers for the DynamoDB Backups + PITR ops (v0.2.5).
//!
//! All eight ops are on the core DDB service. Phase 1 covers:
//!   CreateBackup / ListBackups / DescribeBackup / DeleteBackup
//! Phase 2 adds RestoreTableFromBackup / UpdateContinuousBackups /
//! DescribeContinuousBackups / RestoreTableToPointInTime.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");

pub const ParseError = error{
    Malformed,
    InvalidLimit,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// CreateBackup

pub const CreateBackupRequest = struct {
    table_name: []const u8,
    backup_name: []const u8,
};

pub fn parseCreateBackup(allocator: Allocator, body: []const u8) ParseError!CreateBackupRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    const tn_v = root.get("TableName") orelse return ParseError.Malformed;
    const bn_v = root.get("BackupName") orelse return ParseError.Malformed;
    if (tn_v != .string or bn_v != .string) return ParseError.Malformed;
    if (tn_v.string.len == 0 or bn_v.string.len == 0) return ParseError.Malformed;
    return .{
        .table_name = try allocator.dupe(u8, tn_v.string),
        .backup_name = try allocator.dupe(u8, bn_v.string),
    };
}

pub fn renderCreateBackup(allocator: Allocator, summary: storage.BackupSummary) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("BackupDetails");
    try writeBackupDetails(&s, summary);
    try s.endObject();
    return aw.toOwnedSlice();
}

fn writeBackupDetails(s: *std.json.Stringify, summary: storage.BackupSummary) !void {
    try s.beginObject();
    try s.objectField("BackupArn");
    try s.write(summary.arn);
    try s.objectField("BackupName");
    try s.write(summary.name);
    try s.objectField("BackupSizeBytes");
    try s.write(summary.size_bytes);
    try s.objectField("BackupStatus");
    try s.write(summary.status.toAws());
    try s.objectField("BackupType");
    try s.write(summary.backup_type.toAws());
    try s.objectField("BackupCreationDateTime");
    try s.print("{d}", .{@as(f64, @floatFromInt(summary.creation_unix))});
    try s.endObject();
}

// ---------------------------------------------------------------------------
// ListBackups

pub const ListBackupsRequest = struct {
    table_name: ?[]const u8 = null,
    limit: ?u32 = null,
    exclusive_start_backup_arn: ?[]const u8 = null,
};

pub fn parseListBackups(allocator: Allocator, body: []const u8) ParseError!ListBackupsRequest {
    if (body.len == 0) return .{};
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    var req: ListBackupsRequest = .{};
    if (root.get("TableName")) |v| {
        if (v != .string) return ParseError.Malformed;
        req.table_name = try allocator.dupe(u8, v.string);
    }
    if (root.get("Limit")) |v| switch (v) {
        .integer => |n| {
            if (n < 1 or n > 100) return ParseError.InvalidLimit;
            req.limit = @intCast(n);
        },
        else => return ParseError.Malformed,
    };
    if (root.get("ExclusiveStartBackupArn")) |v| {
        if (v != .string) return ParseError.Malformed;
        req.exclusive_start_backup_arn = try allocator.dupe(u8, v.string);
    }
    return req;
}

pub fn renderListBackups(allocator: Allocator, out: storage.ListBackupsOutput) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("BackupSummaries");
    try s.beginArray();
    for (out.backups) |b| {
        try s.beginObject();
        try s.objectField("TableName");
        try s.write(b.table_name);
        try s.objectField("BackupArn");
        try s.write(b.arn);
        try s.objectField("BackupName");
        try s.write(b.name);
        try s.objectField("BackupStatus");
        try s.write(b.status.toAws());
        try s.objectField("BackupType");
        try s.write(b.backup_type.toAws());
        try s.objectField("BackupCreationDateTime");
        try s.print("{d}", .{@as(f64, @floatFromInt(b.creation_unix))});
        try s.objectField("BackupSizeBytes");
        try s.write(b.size_bytes);
        try s.endObject();
    }
    try s.endArray();
    if (out.last_evaluated_backup_arn) |arn| {
        try s.objectField("LastEvaluatedBackupArn");
        try s.write(arn);
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// DescribeBackup

pub fn parseDescribeBackup(allocator: Allocator, body: []const u8) ParseError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const arn_v = parsed.value.object.get("BackupArn") orelse return ParseError.Malformed;
    if (arn_v != .string) return ParseError.Malformed;
    return try allocator.dupe(u8, arn_v.string);
}

pub fn renderDescribeBackup(allocator: Allocator, desc: storage.BackupDescription) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("BackupDescription");
    try s.beginObject();

    try s.objectField("BackupDetails");
    try writeBackupDetails(&s, desc.summary);

    try s.objectField("SourceTableDetails");
    try s.beginObject();
    try s.objectField("TableName");
    try s.write(desc.table_name);
    try s.objectField("TableCreationDateTime");
    try s.print("{d}", .{@as(f64, @floatFromInt(desc.table_created_unix))});
    try s.objectField("ItemCount");
    try s.write(desc.item_count);
    try s.objectField("BillingMode");
    try s.write(desc.billing_mode.toAws());
    try s.objectField("KeySchema");
    try s.beginArray();
    for (desc.key_schema) |k| {
        try s.beginObject();
        try s.objectField("AttributeName");
        try s.write(k.name);
        try s.objectField("KeyType");
        try s.write(k.key_type.toAws());
        try s.endObject();
    }
    try s.endArray();
    try s.endObject(); // SourceTableDetails
    // AttributeDefinitions are NOT part of the BackupDescription
    // response per AWS API model; clients call DescribeTable on the
    // restored table if they need the schema.

    try s.endObject(); // BackupDescription
    try s.endObject();
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// DeleteBackup

pub fn parseDeleteBackup(allocator: Allocator, body: []const u8) ParseError![]const u8 {
    return parseDescribeBackup(allocator, body);
}

pub fn renderDeleteBackup(allocator: Allocator, desc: storage.BackupDescription) ![]u8 {
    // AWS-real: DeleteBackup returns the same BackupDescription shape
    // as DescribeBackup, with BackupStatus = DELETED.
    return renderDescribeBackup(allocator, desc);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parseCreateBackup: required fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try parseCreateBackup(arena.allocator(),
        \\{"TableName":"t","BackupName":"daily"}
    );
    try testing.expectEqualStrings("t", r.table_name);
    try testing.expectEqualStrings("daily", r.backup_name);
}

test "parseCreateBackup: missing TableName → Malformed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ParseError.Malformed, parseCreateBackup(arena.allocator(),
        \\{"BackupName":"daily"}
    ));
}

test "parseCreateBackup: empty BackupName → Malformed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ParseError.Malformed, parseCreateBackup(arena.allocator(),
        \\{"TableName":"t","BackupName":""}
    ));
}

test "parseListBackups: empty body → defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try parseListBackups(arena.allocator(), "");
    try testing.expect(r.table_name == null);
    try testing.expect(r.limit == null);
}

test "parseListBackups: with filter + limit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try parseListBackups(arena.allocator(),
        \\{"TableName":"t","Limit":5}
    );
    try testing.expectEqualStrings("t", r.table_name.?);
    try testing.expectEqual(@as(u32, 5), r.limit.?);
}

test "parseDescribeBackup: BackupArn required" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ParseError.Malformed, parseDescribeBackup(arena.allocator(), "{}"));
    const arn = try parseDescribeBackup(arena.allocator(),
        \\{"BackupArn":"arn:aws:dynamodb:us-east-1:0:table/t/backup/abc-123"}
    );
    try testing.expectEqualStrings("arn:aws:dynamodb:us-east-1:0:table/t/backup/abc-123", arn);
}
