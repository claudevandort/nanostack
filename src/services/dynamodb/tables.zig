//! DynamoDB table-management service handlers (M15-tables, Phase 2).
//!
//! Five ops: CreateTable, DescribeTable, ListTables, UpdateTable,
//! DeleteTable. All consume JSON bodies via `wire/dynamodb/tables.zig`,
//! talk to `storage.DynamoBackend`, and render responses via the same
//! wire module.

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const tables_wire = @import("../../wire/dynamodb/tables.zig");
const errors = @import("../../wire/dynamodb/errors.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn createTable(ctx: Context) Result {
    const req = tables_wire.parseCreateTable(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    ctx.backend.createTable(.{
        .name = req.name,
        .key_schema = req.key_schema,
        .attribute_definitions = req.attribute_definitions,
        .billing_mode = req.billing_mode,
        .global_secondary_indexes = req.global_secondary_indexes,
        .local_secondary_indexes = req.local_secondary_indexes,
        .tags = req.tags,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    // CreateTable's response shape carries the same fields as DescribeTable
    // but wrapped in `TableDescription` instead of `Table`.
    const slot = ctx.backend.describeTable(req.name) catch |err|
        return .{ .err = mapStorageErr(err) };
    const body = tables_wire.renderTableDescription(ctx.allocator, slot, "TableDescription") catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn describeTable(ctx: Context) Result {
    const req = parseTableNameOnly(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };
    const slot = ctx.backend.describeTable(req) catch |err|
        return .{ .err = mapStorageErr(err) };
    const body = tables_wire.renderTableDescription(ctx.allocator, slot, "Table") catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn deleteTable(ctx: Context) Result {
    const req = parseTableNameOnly(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };
    // Snapshot the slot BEFORE delete so we can render the response.
    const slot = ctx.backend.describeTable(req) catch |err|
        return .{ .err = mapStorageErr(err) };
    const body = tables_wire.renderTableDescription(ctx.allocator, slot, "TableDescription") catch
        return .{ .err = .{ .code = .internal_server_error } };
    ctx.backend.deleteTable(req) catch |err| return .{ .err = mapStorageErr(err) };
    return .{ .ok = .{ .body = body } };
}

pub fn updateTable(ctx: Context) Result {
    const req = tables_wire.parseUpdateTable(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };
    const slot = ctx.backend.updateTable(.{
        .name = req.name,
        .billing_mode = req.billing_mode,
    }) catch |err| return .{ .err = mapStorageErr(err) };
    const body = tables_wire.renderTableDescription(ctx.allocator, slot, "TableDescription") catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn listTables(ctx: Context) Result {
    const req = tables_wire.parseListTables(ctx.allocator, ctx.request.body) catch |err|
        return .{ .err = mapParseErr(err) };

    const all = ctx.backend.listTables(ctx.allocator) catch |err|
        return .{ .err = mapStorageErr(err) };

    // Apply the ExclusiveStartTableName cursor (start strictly after).
    var start_idx: usize = 0;
    if (req.exclusive_start_table_name) |cursor| {
        for (all, 0..) |n, i| {
            if (std.mem.lessThan(u8, cursor, n) or std.mem.eql(u8, cursor, n)) {
                start_idx = if (std.mem.eql(u8, cursor, n)) i + 1 else i;
                break;
            }
        } else {
            start_idx = all.len; // cursor past all entries
        }
    }

    const end_idx = @min(start_idx + req.limit, all.len);
    const page = all[start_idx..end_idx];

    // LastEvaluatedTableName is set when there's more after the page.
    const next_token: ?[]const u8 = if (end_idx < all.len) all[end_idx - 1] else null;

    const body = tables_wire.renderListTables(ctx.allocator, page, next_token) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

// ---------------------------------------------------------------------------
// Helpers

fn parseTableNameOnly(allocator: std.mem.Allocator, body: []const u8) tables_wire.ParseError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return tables_wire.ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return tables_wire.ParseError.Malformed;
    const name_v = parsed.value.object.get("TableName") orelse return tables_wire.ParseError.Malformed;
    if (name_v != .string) return tables_wire.ParseError.Malformed;
    return allocator.dupe(u8, name_v.string) catch return tables_wire.ParseError.OutOfMemory;
}

fn mapParseErr(e: tables_wire.ParseError) mod.ErrorBody {
    return switch (e) {
        tables_wire.ParseError.OutOfMemory => .{ .code = .internal_server_error },
        else => .{
            .code = .validation_exception,
            .message = parseErrorMessage(e),
        },
    };
}

fn parseErrorMessage(e: tables_wire.ParseError) []const u8 {
    return switch (e) {
        tables_wire.ParseError.Malformed => "Could not parse the request body as JSON.",
        tables_wire.ParseError.InvalidName => "Table or attribute name failed validation.",
        tables_wire.ParseError.InvalidKeyType => "KeyType must be HASH or RANGE.",
        tables_wire.ParseError.InvalidScalarType => "AttributeType must be S, N, or B.",
        tables_wire.ParseError.InvalidBillingMode => "BillingMode must be PROVISIONED or PAY_PER_REQUEST.",
        tables_wire.ParseError.InvalidProjectionType => "ProjectionType must be ALL, KEYS_ONLY, or INCLUDE.",
        tables_wire.ParseError.KeyReferencesUndeclaredAttribute => "Every key-schema attribute must appear in AttributeDefinitions.",
        tables_wire.ParseError.InvalidKeySchema => "KeySchema must have exactly one HASH key and at most one RANGE key.",
        tables_wire.ParseError.OutOfMemory => "Out of memory.",
    };
}

fn mapStorageErr(e: storage.Error) mod.ErrorBody {
    return switch (e) {
        storage.Error.TableAlreadyExists => .{ .code = .resource_in_use_exception },
        storage.Error.TableNotFound => .{ .code = .resource_not_found_exception },
        storage.Error.OutOfMemory => .{ .code = .internal_server_error },
        storage.Error.Io => .{ .code = .internal_server_error },
        else => .{ .code = .internal_server_error },
    };
}
