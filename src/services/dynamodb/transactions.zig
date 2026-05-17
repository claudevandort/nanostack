//! DynamoDB transactional service handlers (M15-tx, Phase 9).
//!
//! TransactGetItems: up to 100 reads atomically under the mutex.
//! TransactWriteItems: up to 100 ops (Put / Update / Delete /
//! ConditionCheck) all-or-nothing — every condition is evaluated under
//! the mutex; if any fails the transaction is cancelled with
//! TransactionCanceledException + per-op CancellationReasons.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const av = @import("../../wire/dynamodb/attribute_value.zig");
const items_wire = @import("../../wire/dynamodb/items.zig");
const condition_mod = @import("../../wire/dynamodb/expressions/condition.zig");
const update_mod = @import("../../wire/dynamodb/expressions/update.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

const MAX_TX_OPS: usize = 100;

pub fn transactGetItems(ctx: Context) Result {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.request.body, .{}) catch
        return validationErr("Could not parse the TransactGetItems request body.");
    defer parsed.deinit();
    if (parsed.value != .object) return validationErr("Request body must be an object.");

    const trans_items_v = parsed.value.object.get("TransactItems") orelse
        return validationErr("TransactItems is required.");
    if (trans_items_v != .array) return validationErr("TransactItems must be an array.");
    if (trans_items_v.array.items.len > MAX_TX_OPS) return validationErr("Too many TransactItems (max 100).");

    var ops: std.ArrayList(storage.TxGetItem) = .empty;
    defer ops.deinit(ctx.allocator);
    for (trans_items_v.array.items) |op_v| {
        if (op_v != .object) return validationErr("Each TransactItem must be an object.");
        const get_v = op_v.object.get("Get") orelse return validationErr("Each TransactItem requires a Get block.");
        if (get_v != .object) return validationErr("Get must be an object.");
        const tn_v = get_v.object.get("TableName") orelse return validationErr("Get.TableName is required.");
        const key_v = get_v.object.get("Key") orelse return validationErr("Get.Key is required.");
        if (tn_v != .string) return validationErr("Get.TableName must be a string.");

        const table = ctx.allocator.dupe(u8, tn_v.string) catch return internalErr();
        const key_ptr = ctx.allocator.create(storage.Item) catch return internalErr();
        key_ptr.* = parseItem(ctx.allocator, key_v) catch return validationErr("Failed to parse Get.Key.");
        ops.append(ctx.allocator, .{ .table = table, .key = key_ptr }) catch return internalErr();
    }

    const result = ctx.backend.transactGetItems(ctx.allocator, ops.items) catch |err|
        return .{ .err = mapStorageErr(err) };

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.beginObject() catch return internalErr();
    s.objectField("Responses") catch return internalErr();
    s.beginArray() catch return internalErr();
    for (result.items) |maybe_item| {
        s.beginObject() catch return internalErr();
        if (maybe_item) |it| {
            s.objectField("Item") catch return internalErr();
            items_wire.renderItem(&s, ctx.allocator, &it) catch return internalErr();
        }
        s.endObject() catch return internalErr();
    }
    s.endArray() catch return internalErr();
    s.endObject() catch return internalErr();

    const body = aw.toOwnedSlice() catch return internalErr();
    return .{ .ok = .{ .body = body } };
}

pub fn transactWriteItems(ctx: Context) Result {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.request.body, .{}) catch
        return validationErr("Could not parse the TransactWriteItems request body.");
    defer parsed.deinit();
    if (parsed.value != .object) return validationErr("Request body must be an object.");

    const trans_items_v = parsed.value.object.get("TransactItems") orelse
        return validationErr("TransactItems is required.");
    if (trans_items_v != .array) return validationErr("TransactItems must be an array.");
    if (trans_items_v.array.items.len > MAX_TX_OPS) return validationErr("Too many TransactItems (max 100).");

    // Re-parse body leaky so values/names survive parsed.deinit().
    const body_leaky = std.json.parseFromSliceLeaky(std.json.Value, ctx.allocator, ctx.request.body, .{}) catch
        return validationErr("Could not parse the TransactWriteItems request body (leaky).");

    var ops: std.ArrayList(storage.TxWriteOp) = .empty;
    defer ops.deinit(ctx.allocator);

    // We need closure storage to outlive this scope; allocate from arena.
    // Each tx-op carries its own ConditionHolder + UpdateApplyState.
    const ConditionHolder = struct {
        doc: ?*condition_mod.Document = null,
        values: ?std.json.Value = null,
        allocator: Allocator = undefined,

        fn evaluate(opaque_ctx: *anyopaque, existing: ?*const storage.Item) bool {
            const self: *@This() = @ptrCast(@alignCast(opaque_ctx));
            const doc = self.doc orelse return true;
            return condition_mod.evaluate(doc.root, .{
                .item = existing,
                .values = self.values,
                .allocator = self.allocator,
            }) catch false;
        }
    };

    const UpdateState = struct {
        update_doc: *update_mod.Document,
        values: ?std.json.Value,
        allocator: Allocator,

        fn run(opaque_ctx: *anyopaque, item: *storage.Item) bool {
            const self: *@This() = @ptrCast(@alignCast(opaque_ctx));
            update_mod.apply(self.update_doc.*, item, .{
                .allocator = self.allocator,
                .values = self.values,
            }) catch return false;
            return true;
        }
    };

    // Walk each op and prepare a TxWriteOp.
    const tx_items_leaky = (body_leaky.object.get("TransactItems") orelse return validationErr("TransactItems missing in leaky parse.")).array.items;
    for (tx_items_leaky) |op_v| {
        if (op_v != .object) return validationErr("Each TransactItem must be an object.");
        const op_obj = op_v.object;

        var prepared: storage.TxWriteOp = undefined;
        var found = false;

        if (op_obj.get("Put")) |put_v| {
            if (put_v != .object) return validationErr("Put must be an object.");
            const tn_v = put_v.object.get("TableName") orelse return validationErr("Put.TableName is required.");
            const item_v = put_v.object.get("Item") orelse return validationErr("Put.Item is required.");
            if (tn_v != .string) return validationErr("Put.TableName must be a string.");
            const item_ptr = ctx.allocator.create(storage.Item) catch return internalErr();
            item_ptr.* = parseItem(ctx.allocator, item_v) catch return validationErr("Failed to parse Put.Item.");
            prepared = .{
                .kind = .put,
                .table = ctx.allocator.dupe(u8, tn_v.string) catch return internalErr(),
                .item_or_key = item_ptr,
                .condition = buildCondition(ctx.allocator, put_v.object, ConditionHolder) catch return validationErr("Failed to parse ConditionExpression on Put."),
            };
            found = true;
        } else if (op_obj.get("Delete")) |del_v| {
            if (del_v != .object) return validationErr("Delete must be an object.");
            const tn_v = del_v.object.get("TableName") orelse return validationErr("Delete.TableName is required.");
            const key_v = del_v.object.get("Key") orelse return validationErr("Delete.Key is required.");
            if (tn_v != .string) return validationErr("Delete.TableName must be a string.");
            const key_ptr = ctx.allocator.create(storage.Item) catch return internalErr();
            key_ptr.* = parseItem(ctx.allocator, key_v) catch return validationErr("Failed to parse Delete.Key.");
            prepared = .{
                .kind = .delete,
                .table = ctx.allocator.dupe(u8, tn_v.string) catch return internalErr(),
                .item_or_key = key_ptr,
                .condition = buildCondition(ctx.allocator, del_v.object, ConditionHolder) catch return validationErr("Failed to parse ConditionExpression on Delete."),
            };
            found = true;
        } else if (op_obj.get("ConditionCheck")) |cc_v| {
            if (cc_v != .object) return validationErr("ConditionCheck must be an object.");
            const tn_v = cc_v.object.get("TableName") orelse return validationErr("ConditionCheck.TableName is required.");
            const key_v = cc_v.object.get("Key") orelse return validationErr("ConditionCheck.Key is required.");
            if (tn_v != .string) return validationErr("ConditionCheck.TableName must be a string.");
            const key_ptr = ctx.allocator.create(storage.Item) catch return internalErr();
            key_ptr.* = parseItem(ctx.allocator, key_v) catch return validationErr("Failed to parse ConditionCheck.Key.");
            const condition = buildCondition(ctx.allocator, cc_v.object, ConditionHolder) catch
                return validationErr("ConditionCheck requires a ConditionExpression.");
            if (condition == null) return validationErr("ConditionCheck requires a ConditionExpression.");
            prepared = .{
                .kind = .condition_check,
                .table = ctx.allocator.dupe(u8, tn_v.string) catch return internalErr(),
                .item_or_key = key_ptr,
                .condition = condition,
            };
            found = true;
        } else if (op_obj.get("Update")) |upd_v| {
            if (upd_v != .object) return validationErr("Update must be an object.");
            const tn_v = upd_v.object.get("TableName") orelse return validationErr("Update.TableName is required.");
            const key_v = upd_v.object.get("Key") orelse return validationErr("Update.Key is required.");
            const ue_v = upd_v.object.get("UpdateExpression") orelse return validationErr("Update.UpdateExpression is required.");
            if (tn_v != .string or ue_v != .string) return validationErr("Update fields must be strings.");
            const key_ptr = ctx.allocator.create(storage.Item) catch return internalErr();
            key_ptr.* = parseItem(ctx.allocator, key_v) catch return validationErr("Failed to parse Update.Key.");

            const update_doc_ptr = ctx.allocator.create(update_mod.Document) catch return internalErr();
            update_doc_ptr.* = update_mod.parse(ctx.allocator, ue_v.string, upd_v.object.get("ExpressionAttributeNames")) catch
                return validationErr("Update.UpdateExpression is malformed.");

            const upd_state = ctx.allocator.create(UpdateState) catch return internalErr();
            upd_state.* = .{
                .update_doc = update_doc_ptr,
                .values = upd_v.object.get("ExpressionAttributeValues"),
                .allocator = ctx.allocator,
            };

            prepared = .{
                .kind = .update,
                .table = ctx.allocator.dupe(u8, tn_v.string) catch return internalErr(),
                .item_or_key = key_ptr,
                .condition = buildCondition(ctx.allocator, upd_v.object, ConditionHolder) catch return validationErr("Failed to parse ConditionExpression on Update."),
                .apply_fn = UpdateState.run,
                .apply_ctx = @ptrCast(upd_state),
            };
            found = true;
        }

        if (!found) return validationErr("Each TransactItem must have Put, Update, Delete, or ConditionCheck.");
        ops.append(ctx.allocator, prepared) catch return internalErr();
    }

    var reasons_out: []?[]const u8 = &.{};
    ctx.backend.transactWriteItems(ctx.allocator, ops.items, &reasons_out) catch |err| switch (err) {
        storage.Error.TransactionCanceled => return renderTransactionCanceled(ctx, reasons_out),
        else => return .{ .err = mapStorageErr(err) },
    };

    // Success: empty body.
    const body = ctx.allocator.dupe(u8, "{}") catch return internalErr();
    return .{ .ok = .{ .body = body } };
}

/// Render the AWS-shape TransactionCanceledException error body, which
/// includes a CancellationReasons array.
fn renderTransactionCanceled(ctx: Context, reasons: []?[]const u8) Result {
    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.beginObject() catch return internalErr();
    s.objectField("__type") catch return internalErr();
    s.write("com.amazonaws.dynamodb.v20120810#TransactionCanceledException") catch return internalErr();
    s.objectField("Message") catch return internalErr();
    s.write("Transaction cancelled, please refer to cancellation reasons for specific reasons") catch return internalErr();
    s.objectField("CancellationReasons") catch return internalErr();
    s.beginArray() catch return internalErr();
    for (reasons) |r| {
        s.beginObject() catch return internalErr();
        if (r) |code| {
            s.objectField("Code") catch return internalErr();
            s.write(code) catch return internalErr();
        } else {
            s.objectField("Code") catch return internalErr();
            s.write("None") catch return internalErr();
        }
        s.endObject() catch return internalErr();
    }
    s.endArray() catch return internalErr();
    s.endObject() catch return internalErr();
    const body = aw.toOwnedSlice() catch return internalErr();

    // Return as an error with a custom body. Hack: surface via the
    // standard error path by using a custom Code variant. We don't have
    // that yet; use validation_exception code but inject the JSON body
    // through the message field. Actually simpler: return ok with a 400.
    // We'll surface this as an err.message and override the rendering at
    // the wire level. But the error renderer ignores our shape — so
    // instead, return the body via Output but set status 400.
    return .{ .ok = .{ .body = body, .status = 400 } };
}

fn buildCondition(allocator: Allocator, op_obj: std.json.ObjectMap, comptime HolderType: type) !?storage.ConditionPredicate {
    const ce_v = op_obj.get("ConditionExpression") orelse return null;
    if (ce_v != .string) return error.Malformed;

    const names_json = op_obj.get("ExpressionAttributeNames");
    const values_json = op_obj.get("ExpressionAttributeValues");

    const doc_ptr = try allocator.create(condition_mod.Document);
    doc_ptr.* = try condition_mod.parse(allocator, ce_v.string, names_json);

    const holder = try allocator.create(HolderType);
    holder.* = .{
        .doc = doc_ptr,
        .values = values_json,
        .allocator = allocator,
    };
    return .{
        .ctx = @ptrCast(holder),
        .evaluate_fn = HolderType.evaluate,
    };
}

fn parseItem(allocator: Allocator, v: std.json.Value) !storage.Item {
    if (v != .object) return error.Malformed;
    const obj = v.object;
    const n = obj.count();
    const names = try allocator.alloc([]const u8, n);
    const values = try allocator.alloc(av.AttributeValue, n);
    var it = obj.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        names[i] = try allocator.dupe(u8, entry.key_ptr.*);
        values[i] = try av.parseValue(allocator, entry.value_ptr.*);
    }
    return .{ .names = names, .values = values };
}

fn validationErr(msg: []const u8) Result {
    return .{ .err = .{ .code = .validation_exception, .message = msg } };
}

fn internalErr() Result {
    return .{ .err = .{ .code = .internal_server_error } };
}

fn mapStorageErr(e: storage.Error) mod.ErrorBody {
    return switch (e) {
        storage.Error.TableNotFound => .{ .code = .resource_not_found_exception },
        storage.Error.TransactionCanceled => .{ .code = .transaction_canceled_exception },
        else => .{ .code = .internal_server_error },
    };
}
