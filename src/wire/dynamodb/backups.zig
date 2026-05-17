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
// RestoreTableFromBackup

pub const RestoreFromBackupRequest = struct {
    backup_arn: []const u8,
    target_table_name: []const u8,
};

pub fn parseRestoreTableFromBackup(allocator: Allocator, body: []const u8) ParseError!RestoreFromBackupRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    const arn_v = root.get("BackupArn") orelse return ParseError.Malformed;
    const target_v = root.get("TargetTableName") orelse return ParseError.Malformed;
    if (arn_v != .string or target_v != .string) return ParseError.Malformed;
    if (target_v.string.len == 0) return ParseError.Malformed;
    return .{
        .backup_arn = try allocator.dupe(u8, arn_v.string),
        .target_table_name = try allocator.dupe(u8, target_v.string),
    };
}

// ---------------------------------------------------------------------------
// UpdateContinuousBackups + DescribeContinuousBackups

pub const UpdateContinuousBackupsRequest = struct {
    table_name: []const u8,
    pitr_enabled: bool,
};

pub fn parseUpdateContinuousBackups(allocator: Allocator, body: []const u8) ParseError!UpdateContinuousBackupsRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    const tn_v = root.get("TableName") orelse return ParseError.Malformed;
    if (tn_v != .string) return ParseError.Malformed;

    const pitr_spec_v = root.get("PointInTimeRecoverySpecification") orelse return ParseError.Malformed;
    if (pitr_spec_v != .object) return ParseError.Malformed;
    const enabled_v = pitr_spec_v.object.get("PointInTimeRecoveryEnabled") orelse return ParseError.Malformed;
    if (enabled_v != .bool) return ParseError.Malformed;

    return .{
        .table_name = try allocator.dupe(u8, tn_v.string),
        .pitr_enabled = enabled_v.bool,
    };
}

pub fn parseDescribeContinuousBackups(allocator: Allocator, body: []const u8) ParseError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const tn_v = parsed.value.object.get("TableName") orelse return ParseError.Malformed;
    if (tn_v != .string) return ParseError.Malformed;
    return try allocator.dupe(u8, tn_v.string);
}

pub fn renderContinuousBackups(allocator: Allocator, desc: storage.ContinuousBackupsDescription) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("ContinuousBackupsDescription");
    try s.beginObject();
    try s.objectField("ContinuousBackupsStatus");
    try s.write(switch (desc.continuous_backups_status) {
        .enabled => "ENABLED",
        .disabled => "DISABLED",
    });
    try s.objectField("PointInTimeRecoveryDescription");
    try s.beginObject();
    try s.objectField("PointInTimeRecoveryStatus");
    try s.write(desc.pitr_status.toAws());
    if (desc.pitr_status == .enabled) {
        try s.objectField("EarliestRestorableDateTime");
        try s.print("{d}", .{@as(f64, @floatFromInt(desc.earliest_restorable_unix))});
        try s.objectField("LatestRestorableDateTime");
        try s.print("{d}", .{@as(f64, @floatFromInt(desc.latest_restorable_unix))});
    }
    try s.endObject();
    try s.endObject();
    try s.endObject();
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// RestoreTableToPointInTime

pub const RestoreToPitRequest = struct {
    source_table_name: []const u8,
    target_table_name: []const u8,
    restore_date_time: ?i64 = null,
    use_latest_restorable_time: bool = false,
};

pub fn parseRestoreTableToPointInTime(allocator: Allocator, body: []const u8) ParseError!RestoreToPitRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;
    const src_v = root.get("SourceTableName") orelse return ParseError.Malformed;
    const dst_v = root.get("TargetTableName") orelse return ParseError.Malformed;
    if (src_v != .string or dst_v != .string) return ParseError.Malformed;
    var req: RestoreToPitRequest = .{
        .source_table_name = try allocator.dupe(u8, src_v.string),
        .target_table_name = try allocator.dupe(u8, dst_v.string),
    };
    if (root.get("RestoreDateTime")) |v| switch (v) {
        .float => |f| req.restore_date_time = @intFromFloat(f),
        .integer => |i| req.restore_date_time = i,
        else => {},
    };
    if (root.get("UseLatestRestorableTime")) |v| if (v == .bool) {
        req.use_latest_restorable_time = v.bool;
    };
    return req;
}

/// Render a TableDescription-wrapping response. We don't have the full
/// TableSlot here so we render the minimal subset: TableName +
/// TableStatus = ACTIVE + KeySchema + CreationDateTime. Clients call
/// DescribeTable on the restored table if they need the full schema.
pub fn renderTableDescriptionMin(
    allocator: Allocator,
    wrapper: []const u8,
    slot: *const storage.TableSlot,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField(wrapper);
    try s.beginObject();
    try s.objectField("TableName");
    try s.write(slot.name);
    try s.objectField("TableStatus");
    try s.write("ACTIVE");
    try s.objectField("CreationDateTime");
    try s.print("{d}", .{@as(f64, @floatFromInt(slot.created_unix))});
    try s.objectField("KeySchema");
    try s.beginArray();
    for (slot.key_schema) |k| {
        try s.beginObject();
        try s.objectField("AttributeName");
        try s.write(k.name);
        try s.objectField("KeyType");
        try s.write(k.key_type.toAws());
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("ItemCount");
    try s.write(slot.items.count());
    try s.endObject();
    try s.endObject();
    return aw.toOwnedSlice();
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
