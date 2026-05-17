//! DynamoDB Backups + PITR handlers (v0.2.5).
//!
//! Phase 1: CreateBackup, ListBackups, DescribeBackup, DeleteBackup.
//! Phase 2: RestoreTableFromBackup + the three PITR ops.
//!
//! Thin glue between wire-layer parsers + the storage backend's
//! createBackup / listBackups / describeBackup / deleteBackup vtable
//! entries (implemented in src/storage/fs.zig).

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const wire = @import("../../wire/dynamodb/backups.zig");
const errors = @import("../../wire/dynamodb/errors.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;
const ErrorBody = mod.ErrorBody;

pub fn createBackup(ctx: Context) Result {
    const req = wire.parseCreateBackup(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    const summary = ctx.backend.createBackup(ctx.allocator, .{
        .table_name = req.table_name,
        .backup_name = req.backup_name,
        .region = ctx.region,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const body = wire.renderCreateBackup(ctx.allocator, summary) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn listBackups(ctx: Context) Result {
    const req = wire.parseListBackups(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    const out = ctx.backend.listBackups(ctx.allocator, .{
        .table_name = req.table_name,
        .limit = req.limit orelse 100,
        .exclusive_start_backup_arn = req.exclusive_start_backup_arn,
        .region = ctx.region,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const body = wire.renderListBackups(ctx.allocator, out) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn describeBackup(ctx: Context) Result {
    const arn = wire.parseDescribeBackup(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    const desc = ctx.backend.describeBackup(ctx.allocator, arn) catch |err|
        return .{ .err = mapStorageErr(err) };

    const body = wire.renderDescribeBackup(ctx.allocator, desc) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn deleteBackup(ctx: Context) Result {
    const arn = wire.parseDeleteBackup(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    const desc = ctx.backend.deleteBackup(ctx.allocator, arn) catch |err|
        return .{ .err = mapStorageErr(err) };

    const body = wire.renderDeleteBackup(ctx.allocator, desc) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn restoreTableFromBackup(ctx: Context) Result {
    const req = wire.parseRestoreTableFromBackup(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    const slot = ctx.backend.restoreTableFromBackup(ctx.allocator, .{
        .backup_arn = req.backup_arn,
        .target_table_name = req.target_table_name,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const body = wire.renderTableDescriptionMin(ctx.allocator, "TableDescription", slot) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn updateContinuousBackups(ctx: Context) Result {
    const req = wire.parseUpdateContinuousBackups(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    const desc = ctx.backend.updateContinuousBackups(.{
        .table_name = req.table_name,
        .pitr_enabled = req.pitr_enabled,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const body = wire.renderContinuousBackups(ctx.allocator, desc) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn describeContinuousBackups(ctx: Context) Result {
    const table_name = wire.parseDescribeContinuousBackups(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    const desc = ctx.backend.describeContinuousBackups(table_name) catch |err|
        return .{ .err = mapStorageErr(err) };

    const body = wire.renderContinuousBackups(ctx.allocator, desc) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn restoreTableToPointInTime(ctx: Context) Result {
    const req = wire.parseRestoreTableToPointInTime(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    const slot = ctx.backend.restoreTableToPointInTime(ctx.allocator, .{
        .source_table_name = req.source_table_name,
        .target_table_name = req.target_table_name,
        .restore_date_time = req.restore_date_time,
        .use_latest_restorable_time = req.use_latest_restorable_time,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const body = wire.renderTableDescriptionMin(ctx.allocator, "TableDescription", slot) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

// ---------------------------------------------------------------------------
// Error mapping

fn mapParseErr(e: wire.ParseError) ErrorBody {
    return switch (e) {
        wire.ParseError.OutOfMemory => .{ .code = .internal_server_error },
        wire.ParseError.Malformed => .{ .code = .validation_exception, .message = "Request body is malformed." },
        wire.ParseError.InvalidLimit => .{ .code = .validation_exception, .message = "Limit out of range." },
    };
}

fn mapStorageErr(e: storage.Error) ErrorBody {
    return switch (e) {
        storage.Error.TableNotFound => .{ .code = .resource_not_found_exception },
        storage.Error.TableAlreadyExists => .{ .code = .resource_in_use_exception },
        storage.Error.BackupNotFound => .{ .code = .backup_not_found_exception },
        storage.Error.InvalidBackupArn => .{ .code = .validation_exception, .message = "Invalid BackupArn." },
        storage.Error.OutOfMemory => .{ .code = .internal_server_error },
        storage.Error.Io => .{ .code = .internal_server_error },
        else => .{ .code = .internal_server_error },
    };
}
