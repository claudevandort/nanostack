//! DynamoDB item-op service handlers (M15-items, Phase 3).
//!
//! Phase 3 ships GetItem / PutItem / DeleteItem without expressions.
//! ReturnValues NONE / ALL_OLD are supported on the modify ops.
//! ConditionExpression + the UPDATED_* return values land in Phase 4.

const std = @import("std");
const storage = @import("../../storage/mod.zig");
const items_wire = @import("../../wire/dynamodb/items.zig");
const errors = @import("../../wire/dynamodb/errors.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn putItem(ctx: Context) Result {
    const req = items_wire.parsePutItem(ctx.allocator, ctx.request.body) catch
        return .{ .err = .{ .code = .validation_exception, .message = "Could not parse the PutItem request body." } };

    // Phase 3 doesn't support the UPDATED_* return values on PutItem.
    if (req.return_values == .updated_old or req.return_values == .updated_new or req.return_values == .all_new) {
        return .{ .err = .{
            .code = .validation_exception,
            .message = "PutItem supports ReturnValues NONE or ALL_OLD only.",
        } };
    }

    var result = ctx.backend.putItem(ctx.allocator, .{
        .table = req.table,
        .item = &req.item,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const old_item_ptr: ?*const storage.Item =
        if (req.return_values == .all_old and result.old_item != null) &result.old_item.? else null;

    const body = items_wire.renderModifyResponse(ctx.allocator, "Attributes", old_item_ptr) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn getItem(ctx: Context) Result {
    const req = items_wire.parseGetItem(ctx.allocator, ctx.request.body) catch
        return .{ .err = .{ .code = .validation_exception, .message = "Could not parse the GetItem request body." } };

    var result = ctx.backend.getItem(ctx.allocator, .{
        .table = req.table,
        .key = &req.key,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const item_ptr: ?*const storage.Item = if (result.item != null) &result.item.? else null;
    const body = items_wire.renderGetItemResponse(ctx.allocator, item_ptr) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn deleteItem(ctx: Context) Result {
    const req = items_wire.parseDeleteItem(ctx.allocator, ctx.request.body) catch
        return .{ .err = .{ .code = .validation_exception, .message = "Could not parse the DeleteItem request body." } };

    if (req.return_values == .updated_old or req.return_values == .updated_new or req.return_values == .all_new) {
        return .{ .err = .{
            .code = .validation_exception,
            .message = "DeleteItem supports ReturnValues NONE or ALL_OLD only.",
        } };
    }

    var result = ctx.backend.deleteItem(ctx.allocator, .{
        .table = req.table,
        .key = &req.key,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const old_item_ptr: ?*const storage.Item =
        if (req.return_values == .all_old and result.old_item != null) &result.old_item.? else null;
    const body = items_wire.renderModifyResponse(ctx.allocator, "Attributes", old_item_ptr) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

fn mapStorageErr(e: storage.Error) mod.ErrorBody {
    return switch (e) {
        storage.Error.TableNotFound => .{ .code = .resource_not_found_exception },
        storage.Error.OutOfMemory, storage.Error.Io => .{ .code = .internal_server_error },
        else => .{ .code = .internal_server_error },
    };
}
