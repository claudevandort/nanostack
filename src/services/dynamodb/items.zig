//! DynamoDB item-op service handlers.
//!
//! M15-items (Phase 3): GetItem / PutItem / DeleteItem.
//! M15-expressions (Phase 4): adds ConditionExpression on Put/Delete,
//! plus the full UpdateItem handler with UpdateExpression.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const items_wire = @import("../../wire/dynamodb/items.zig");
const condition = @import("../../wire/dynamodb/expressions/condition.zig");
const update_mod = @import("../../wire/dynamodb/expressions/update.zig");
const errors = @import("../../wire/dynamodb/errors.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn putItem(ctx: Context) Result {
    const req = items_wire.parsePutItem(ctx.allocator, ctx.request.body) catch
        return .{ .err = .{ .code = .validation_exception, .message = "Could not parse the PutItem request body." } };

    if (req.return_values == .updated_old or req.return_values == .updated_new or req.return_values == .all_new) {
        return .{ .err = .{
            .code = .validation_exception,
            .message = "PutItem supports ReturnValues NONE or ALL_OLD only.",
        } };
    }

    var cond_holder = ConditionHolder.empty();
    const cond_predicate = parseConditionFromBody(ctx.allocator, ctx.request.body, &cond_holder) catch |err|
        return .{ .err = mapExprParseErr(err) };

    var result = ctx.backend.putItem(ctx.allocator, .{
        .table = req.table,
        .item = &req.item,
        .condition = cond_predicate,
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

    var cond_holder = ConditionHolder.empty();
    const cond_predicate = parseConditionFromBody(ctx.allocator, ctx.request.body, &cond_holder) catch |err|
        return .{ .err = mapExprParseErr(err) };

    var result = ctx.backend.deleteItem(ctx.allocator, .{
        .table = req.table,
        .key = &req.key,
        .condition = cond_predicate,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const old_item_ptr: ?*const storage.Item =
        if (req.return_values == .all_old and result.old_item != null) &result.old_item.? else null;
    const body = items_wire.renderModifyResponse(ctx.allocator, "Attributes", old_item_ptr) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn updateItem(ctx: Context) Result {
    // Parse JSON root once; pull TableName, Key, UpdateExpression,
    // ConditionExpression, ExpressionAttributeNames / Values, ReturnValues.
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.request.body, .{}) catch
        return .{ .err = .{ .code = .validation_exception, .message = "Could not parse the UpdateItem request body." } };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .err = .{ .code = .validation_exception } };
    const root = parsed.value.object;

    const name_v = root.get("TableName") orelse
        return .{ .err = .{ .code = .validation_exception, .message = "TableName is required." } };
    if (name_v != .string) return .{ .err = .{ .code = .validation_exception } };
    const table = ctx.allocator.dupe(u8, name_v.string) catch return .{ .err = .{ .code = .internal_server_error } };

    const key_v = root.get("Key") orelse
        return .{ .err = .{ .code = .validation_exception, .message = "Key is required." } };
    const key = parseKey(ctx.allocator, key_v) catch
        return .{ .err = .{ .code = .validation_exception, .message = "Failed to parse Key." } };

    const update_expr_v = root.get("UpdateExpression") orelse
        return .{ .err = .{ .code = .validation_exception, .message = "UpdateExpression is required." } };
    if (update_expr_v != .string) return .{ .err = .{ .code = .validation_exception } };

    const names_json = root.get("ExpressionAttributeNames");
    const values_json = root.get("ExpressionAttributeValues");

    var update_doc = update_mod.parse(ctx.allocator, update_expr_v.string, names_json) catch |err|
        return .{ .err = mapUpdateParseErr(err) };
    defer update_doc.deinit();

    // Optional ConditionExpression.
    var cond_doc_owned: ?condition.Document = null;
    if (root.get("ConditionExpression")) |ce_v| {
        if (ce_v != .string) return .{ .err = .{ .code = .validation_exception } };
        cond_doc_owned = condition.parse(ctx.allocator, ce_v.string, names_json) catch |err|
            return .{ .err = mapExprParseErr(err) };
    }
    defer if (cond_doc_owned) |*d| d.deinit();

    // ReturnValues parsing.
    var rv: items_wire.ReturnValues = .none;
    if (root.get("ReturnValues")) |rv_v| {
        if (rv_v != .string) return .{ .err = .{ .code = .validation_exception } };
        rv = items_wire.ReturnValues.fromAws(rv_v.string) orelse return .{ .err = .{ .code = .validation_exception } };
    }

    // Build the apply closure context.
    var apply_state: UpdateApplyState = .{
        .allocator = ctx.allocator,
        .update_doc = &update_doc,
        .values = values_json,
    };

    // Build the optional condition predicate.
    var cond_holder = ConditionHolder.empty();
    var cond_predicate: ?storage.ConditionPredicate = null;
    if (cond_doc_owned) |*d| {
        cond_holder = .{
            .doc = d,
            .values = values_json,
            .allocator = ctx.allocator,
        };
        cond_predicate = .{
            .ctx = @ptrCast(@constCast(&cond_holder)),
            .evaluate_fn = ConditionHolder.evaluate,
        };
    }

    var result = ctx.backend.updateItem(ctx.allocator, .{
        .table = table,
        .key = &key,
        .apply_fn = UpdateApplyState.run,
        .apply_ctx = @ptrCast(&apply_state),
        .condition = cond_predicate,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    // Render response per ReturnValues.
    const field: ?[]const u8 = switch (rv) {
        .none => null,
        .all_old, .all_new, .updated_old, .updated_new => "Attributes",
    };
    const ret_ptr: ?*const storage.Item = switch (rv) {
        .none => null,
        .all_old, .updated_old => if (result.old_item != null) &result.old_item.? else null,
        .all_new, .updated_new => if (result.new_item != null) &result.new_item.? else null,
    };
    const body = items_wire.renderModifyResponse(ctx.allocator, field, ret_ptr) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

// ---------------------------------------------------------------------------
// Helpers: parse key, build condition predicate, run update applier

fn parseKey(allocator: Allocator, key_v: std.json.Value) !storage.Item {
    if (key_v != .object) return error.Malformed;
    const obj = key_v.object;
    const n = obj.count();
    const names = try allocator.alloc([]const u8, n);
    const values = try allocator.alloc(@import("../../wire/dynamodb/attribute_value.zig").AttributeValue, n);
    var it = obj.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        names[i] = try allocator.dupe(u8, entry.key_ptr.*);
        values[i] = try @import("../../wire/dynamodb/attribute_value.zig").parseValue(allocator, entry.value_ptr.*);
    }
    return .{ .names = names, .values = values };
}

/// Carries a parsed ConditionExpression Document into the storage layer
/// via the type-erased ConditionPredicate.
const ConditionHolder = struct {
    doc: ?*condition.Document = null,
    values: ?std.json.Value = null,
    allocator: Allocator = undefined,

    fn empty() ConditionHolder {
        return .{};
    }

    fn evaluate(opaque_ctx: *anyopaque, existing: ?*const storage.Item) bool {
        const self: *ConditionHolder = @ptrCast(@alignCast(opaque_ctx));
        const doc = self.doc orelse return true;
        return condition.evaluate(doc.root, .{
            .item = existing,
            .values = self.values,
            .allocator = self.allocator,
        }) catch false;
    }
};

/// Parse the ConditionExpression from a request body (PutItem/DeleteItem
/// shape) and build a ConditionPredicate that closes over the parsed
/// Document. Returns null if no ConditionExpression is present.
fn parseConditionFromBody(allocator: Allocator, body: []const u8, holder: *ConditionHolder) !?storage.ConditionPredicate {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const root = parsed.value.object;

    const ce_v = root.get("ConditionExpression") orelse return null;
    if (ce_v != .string) return null;

    const names = root.get("ExpressionAttributeNames");
    const values = root.get("ExpressionAttributeValues");

    const doc_ptr = try allocator.create(condition.Document);
    errdefer allocator.destroy(doc_ptr);
    doc_ptr.* = try condition.parse(allocator, ce_v.string, names);

    // We need values to persist past parsed.deinit(). std.json.Value points
    // into parsed's arena, so we must re-parse "leaky" against the caller's
    // allocator (the request arena). Cheap on small bodies.
    const values_leaky: ?std.json.Value = blk: {
        if (values == null) break :blk null;
        var p2 = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch break :blk null;
        if (p2 != .object) break :blk null;
        break :blk p2.object.get("ExpressionAttributeValues");
    };

    holder.* = .{
        .doc = doc_ptr,
        .values = values_leaky,
        .allocator = allocator,
    };
    return .{
        .ctx = @ptrCast(holder),
        .evaluate_fn = ConditionHolder.evaluate,
    };
}

const UpdateApplyState = struct {
    allocator: Allocator,
    update_doc: *update_mod.Document,
    values: ?std.json.Value,

    fn run(opaque_ctx: *anyopaque, item: *storage.Item) bool {
        const self: *UpdateApplyState = @ptrCast(@alignCast(opaque_ctx));
        update_mod.apply(self.update_doc.*, item, .{
            .allocator = self.allocator,
            .values = self.values,
        }) catch return false;
        return true;
    }
};

fn mapStorageErr(e: storage.Error) mod.ErrorBody {
    return switch (e) {
        storage.Error.TableNotFound => .{ .code = .resource_not_found_exception },
        storage.Error.ConditionalCheckFailed => .{ .code = .conditional_check_failed_exception },
        storage.Error.OutOfMemory, storage.Error.Io => .{ .code = .internal_server_error },
        else => .{ .code = .internal_server_error },
    };
}

fn mapExprParseErr(e: condition.ParseError) mod.ErrorBody {
    return switch (e) {
        condition.ParseError.UnknownFunction => .{
            .code = .validation_exception,
            .message = "Unknown function in ConditionExpression.",
        },
        condition.ParseError.ReservedWord => .{
            .code = .validation_exception,
            .message = "Reserved keyword used as a bare attribute name in ConditionExpression; alias via ExpressionAttributeNames (e.g. `#x` mapped to `\"Status\"`).",
        },
        condition.ParseError.OutOfMemory => .{ .code = .internal_server_error },
        else => .{ .code = .validation_exception, .message = "ConditionExpression is malformed." },
    };
}

fn mapUpdateParseErr(e: update_mod.ParseError) mod.ErrorBody {
    return switch (e) {
        update_mod.ParseError.UnknownFunction => .{
            .code = .validation_exception,
            .message = "Unknown function in UpdateExpression.",
        },
        update_mod.ParseError.ReservedWord => .{
            .code = .validation_exception,
            .message = "Reserved keyword used as a bare attribute name in UpdateExpression; alias via ExpressionAttributeNames.",
        },
        update_mod.ParseError.OutOfMemory => .{ .code = .internal_server_error },
        else => .{ .code = .validation_exception, .message = "UpdateExpression is malformed." },
    };
}
