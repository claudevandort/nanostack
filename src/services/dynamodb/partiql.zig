//! DynamoDB PartiQL handlers (v0.2.4).
//!
//! Three ops on the core DDB service: ExecuteStatement, ExecuteTransaction,
//! BatchExecuteStatement. Phase 1 ships ExecuteStatement for SELECT only.
//! Later phases extend with INSERT/UPDATE/DELETE and the batch/transaction
//! variants.
//!
//! Architecture: parse the PartiQL string into our small native AST
//! (`wire/dynamodb/partiql/ast.zig`), then dispatch by statement kind.
//! For SELECT we call `backend.query` directly with key + filter
//! predicates built from the AST + the request's positional `Parameters`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const attribute_value = @import("../../wire/dynamodb/attribute_value.zig");
const AttributeValue = attribute_value.AttributeValue;
const items_wire = @import("../../wire/dynamodb/items.zig");
const partiql_parser = @import("../../wire/dynamodb/partiql/parser.zig");
const partiql_ast = @import("../../wire/dynamodb/partiql/ast.zig");
const condition_mod = @import("../../wire/dynamodb/expressions/condition.zig");
const errors = @import("../../wire/dynamodb/errors.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;
const ErrorBody = mod.ErrorBody;

pub fn executeStatement(ctx: Context) Result {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.request.body, .{}) catch
        return .{ .err = .{ .code = .validation_exception, .message = "Could not parse the request body as JSON." } };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .err = .{ .code = .validation_exception } };
    const root = parsed.value.object;

    const stmt_v = root.get("Statement") orelse
        return .{ .err = .{ .code = .validation_exception, .message = "Statement is required." } };
    if (stmt_v != .string) return .{ .err = .{ .code = .validation_exception } };

    // Decode Parameters array (positional, 0-indexed).
    const params = parseParameters(ctx.allocator, root.get("Parameters")) catch
        return .{ .err = .{ .code = .validation_exception, .message = "Invalid Parameters array." } };

    const ast_doc = partiql_parser.parse(ctx.allocator, stmt_v.string) catch |err|
        return .{ .err = mapParseErr(err) };

    if (ast_doc.placeholder_count != @as(u32, @intCast(params.len))) {
        return .{ .err = .{
            .code = .validation_exception,
            .message = "Number of Parameters does not match the number of `?` placeholders in the Statement.",
        } };
    }

    return switch (ast_doc.statement) {
        .select => |sel| executeSelect(ctx, sel, params, root),
        .insert => |ins| executeInsert(ctx, ins, params),
        .update => |upd| executeUpdate(ctx, upd, params),
        .delete => |del| executeDelete(ctx, del, params),
    };
}

pub fn executeTransaction(ctx: Context) Result {
    _ = ctx;
    return unsupported("ExecuteTransaction lands in Phase 3 of v0.2.4.");
}

pub fn batchExecuteStatement(ctx: Context) Result {
    _ = ctx;
    return unsupported("BatchExecuteStatement lands in Phase 3 of v0.2.4.");
}

fn unsupported(msg: []const u8) Result {
    return .{ .err = .{ .code = .validation_exception, .message = msg } };
}

// ---------------------------------------------------------------------------
// SELECT

fn executeSelect(ctx: Context, sel: partiql_ast.Select, params: []const AttributeValue, root: std.json.ObjectMap) Result {
    // Look up the table to learn its PK/SK names so we can decide
    // whether the WHERE clause is key-shaped (→ Query) or not (→ Scan
    // with filter).
    const slot = ctx.backend.describeTable(sel.table_name) catch |err|
        return .{ .err = mapStorageErr(err) };

    // Decode cursor + limit.
    const limit: u32 = if (root.get("Limit")) |l_v| switch (l_v) {
        .integer => |n| if (n < 1 or n > 1_000_000) 0 else @intCast(n),
        else => 0,
    } else 0;

    var start_key: ?[]const u8 = null;
    if (root.get("NextToken")) |nt| switch (nt) {
        .string => |s| {
            // Our NextToken is the opaque _ck cursor string used by Query.
            start_key = ctx.allocator.dupe(u8, s) catch
                return .{ .err = .{ .code = .internal_server_error } };
        },
        else => return .{ .err = .{ .code = .validation_exception, .message = "NextToken must be a string." } },
    };

    var holder: KeyPredicateHolder = .{
        .cond = sel.where_clause,
        .slot = slot,
        .params = params,
    };
    const key_pred: storage.ItemPredicate = .{
        .ctx = @ptrCast(&holder),
        .match_fn = KeyPredicateHolder.match,
    };

    const result = ctx.backend.query(ctx.allocator, .{
        .table = sel.table_name,
        .key_predicate = key_pred,
        .filter_predicate = null,
        .forward = true,
        .limit = limit,
        .exclusive_start_key = start_key,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const body = renderResponse(ctx.allocator, result, sel.columns) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

const KeyPredicateHolder = struct {
    cond: ?partiql_ast.KeyCondition,
    slot: *const storage.TableSlot,
    params: []const AttributeValue,

    fn match(opaque_ctx: *anyopaque, item: *const storage.Item) bool {
        const self: *KeyPredicateHolder = @ptrCast(@alignCast(opaque_ctx));
        return self.matchInner(item) catch false;
    }

    fn matchInner(self: *KeyPredicateHolder, item: *const storage.Item) !bool {
        const c = self.cond orelse return true; // no WHERE → scan-all

        // Resolve PK target value.
        const pk_target = resolveOperand(c.pk_value, self.params) orelse return false;
        const pk_actual_ptr = item.attributeValue(c.pk_name) orelse return false;
        if (!condition_mod.valuesEqual(pk_actual_ptr.*, pk_target)) return false;

        // Optional sort-key predicate.
        if (c.sk_name) |sk_name| {
            const sk_actual_ptr = item.attributeValue(sk_name) orelse return false;
            const sk_actual = sk_actual_ptr.*;
            const pred = c.sk_predicate orelse return true;
            return try evalSortPredicate(sk_actual, pred, self.params);
        }
        return true;
    }
};

fn evalSortPredicate(actual: AttributeValue, pred: partiql_ast.SortPredicate, params: []const AttributeValue) !bool {
    return switch (pred) {
        .eq => |op| {
            const v = resolveOperand(op, params) orelse return false;
            return condition_mod.valuesEqual(actual, v);
        },
        .lt => |op| {
            const v = resolveOperand(op, params) orelse return false;
            return (try condition_mod.compareValues(actual, v)) < 0;
        },
        .le => |op| {
            const v = resolveOperand(op, params) orelse return false;
            return (try condition_mod.compareValues(actual, v)) <= 0;
        },
        .gt => |op| {
            const v = resolveOperand(op, params) orelse return false;
            return (try condition_mod.compareValues(actual, v)) > 0;
        },
        .ge => |op| {
            const v = resolveOperand(op, params) orelse return false;
            return (try condition_mod.compareValues(actual, v)) >= 0;
        },
        .between => |b| {
            const lo = resolveOperand(b.lo, params) orelse return false;
            const hi = resolveOperand(b.hi, params) orelse return false;
            const ge_lo = (try condition_mod.compareValues(actual, lo)) >= 0;
            const le_hi = (try condition_mod.compareValues(actual, hi)) <= 0;
            return ge_lo and le_hi;
        },
        .begins_with => |op| {
            const prefix = resolveOperand(op, params) orelse return false;
            const s = switch (actual) {
                .s => |x| x,
                else => return false,
            };
            const p = switch (prefix) {
                .s => |x| x,
                else => return false,
            };
            return std.mem.startsWith(u8, s, p);
        },
    };
}

/// Resolve an operand to its concrete `AttributeValue`. Returns null
/// only if a `param_index` is out of bounds (the handler already checks
/// `placeholder_count == params.len`, so this should never happen — but
/// be defensive).
fn resolveOperand(op: partiql_ast.Operand, params: []const AttributeValue) ?AttributeValue {
    return switch (op) {
        .literal => |v| v,
        .param_index => |i| if (i < params.len) params[i] else null,
    };
}

// ---------------------------------------------------------------------------
// INSERT

fn executeInsert(ctx: Context, ins: partiql_ast.Insert, params: []const AttributeValue) Result {
    // Build the Item from the field list.
    const n = ins.fields.len;
    const names = ctx.allocator.alloc([]const u8, n) catch
        return .{ .err = .{ .code = .internal_server_error } };
    const values = ctx.allocator.alloc(AttributeValue, n) catch
        return .{ .err = .{ .code = .internal_server_error } };
    for (ins.fields, 0..) |f, i| {
        names[i] = f.name;
        const v = resolveOperand(f.value, params) orelse
            return .{ .err = .{ .code = .validation_exception, .message = "INSERT value references an unbound parameter." } };
        values[i] = v;
    }
    const item: storage.Item = .{ .names = names, .values = values };

    _ = ctx.backend.putItem(ctx.allocator, .{
        .table = ins.table_name,
        .item = &item,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    // AWS-real INSERT returns an empty body on success.
    return .{ .ok = .{ .body = "{}" } };
}

// ---------------------------------------------------------------------------
// UPDATE

const UpdateApplierCtx = struct {
    assignments: []const partiql_ast.UpdateAssignment,
    params: []const AttributeValue,
    allocator: Allocator,
};

fn updateApplyFn(ctx_ptr: *anyopaque, item: *storage.Item) bool {
    const uctx: *UpdateApplierCtx = @ptrCast(@alignCast(ctx_ptr));
    return applyAssignments(uctx, item) catch false;
}

fn applyAssignments(uctx: *UpdateApplierCtx, item: *storage.Item) !bool {
    for (uctx.assignments) |a| {
        const operand_val = resolveOperand(a.operand, uctx.params) orelse return false;
        const new_val: AttributeValue = switch (a.op) {
            .assign => operand_val,
            .add_to_col, .sub_from_col => blk: {
                // Atomic counter: numeric add/sub of operand to existing
                // column value. Reuses the existing decimal helper.
                const existing_av: AttributeValue = if (item.attributeValue(a.column)) |p|
                    p.*
                else
                    .{ .n = "0" };
                const lhs = switch (existing_av) {
                    .n => |s| s,
                    else => return false,
                };
                const rhs = switch (operand_val) {
                    .n => |s| s,
                    else => return false,
                };
                const a_f = std.fmt.parseFloat(f64, lhs) catch return false;
                const b_f = std.fmt.parseFloat(f64, rhs) catch return false;
                const result = if (a.op == .add_to_col) a_f + b_f else a_f - b_f;
                // Render — drop trailing .0 to match the existing
                // UpdateExpression arithmetic output where reasonable.
                const formatted = try std.fmt.allocPrint(uctx.allocator, "{d}", .{result});
                break :blk AttributeValue{ .n = formatted };
            },
        };
        try setItemAttribute(uctx.allocator, item, a.column, new_val);
    }
    return true;
}

fn setItemAttribute(allocator: Allocator, item: *storage.Item, name: []const u8, value: AttributeValue) !void {
    // Replace if present.
    for (item.names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) {
            item.values[i] = value;
            return;
        }
    }
    // Otherwise grow names + values.
    const new_names = try allocator.alloc([]const u8, item.names.len + 1);
    @memcpy(new_names[0..item.names.len], item.names);
    new_names[item.names.len] = name;
    const new_values = try allocator.alloc(AttributeValue, item.values.len + 1);
    @memcpy(new_values[0..item.values.len], item.values);
    new_values[item.values.len] = value;
    item.names = new_names;
    item.values = new_values;
}

fn executeUpdate(ctx: Context, upd: partiql_ast.Update, params: []const AttributeValue) Result {
    // Build a key-only Item from WHERE for the backend call.
    const key_item = buildKeyItem(ctx.allocator, upd.where_clause, params) catch |err| switch (err) {
        error.UnresolvableOperand => return .{ .err = .{
            .code = .validation_exception,
            .message = "WHERE clause references an unbound parameter.",
        } },
        else => return .{ .err = .{ .code = .internal_server_error } },
    };

    var applier_ctx: UpdateApplierCtx = .{
        .assignments = upd.assignments,
        .params = params,
        .allocator = ctx.allocator,
    };

    const result = ctx.backend.updateItem(ctx.allocator, .{
        .table = upd.table_name,
        .key = &key_item,
        .apply_fn = updateApplyFn,
        .apply_ctx = @ptrCast(&applier_ctx),
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const body = renderUpdateResult(ctx.allocator, result, upd.returning) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

// ---------------------------------------------------------------------------
// DELETE

fn executeDelete(ctx: Context, del: partiql_ast.Delete, params: []const AttributeValue) Result {
    const key_item = buildKeyItem(ctx.allocator, del.where_clause, params) catch |err| switch (err) {
        error.UnresolvableOperand => return .{ .err = .{
            .code = .validation_exception,
            .message = "WHERE clause references an unbound parameter.",
        } },
        else => return .{ .err = .{ .code = .internal_server_error } },
    };

    const result = ctx.backend.deleteItem(ctx.allocator, .{
        .table = del.table_name,
        .key = &key_item,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const body = renderDeleteResult(ctx.allocator, result, del.returning) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

// ---------------------------------------------------------------------------
// Shared helpers for UPDATE / DELETE WHERE → key-only Item

/// Build a key-only `Item` from a Phase-1 KeyCondition. Only handles
/// `pk = X` and `pk = X AND sk = Y` shapes (AWS PartiQL requires the
/// WHERE to identify a single item by key for UPDATE / DELETE).
fn buildKeyItem(allocator: Allocator, cond: partiql_ast.KeyCondition, params: []const AttributeValue) !storage.Item {
    var n: usize = 1;
    if (cond.sk_name != null) n += 1;
    const names = try allocator.alloc([]const u8, n);
    const values = try allocator.alloc(AttributeValue, n);
    names[0] = cond.pk_name;
    values[0] = resolveOperand(cond.pk_value, params) orelse return error.UnresolvableOperand;
    if (cond.sk_name) |sk_name| {
        const sk_pred = cond.sk_predicate orelse return error.UnresolvableOperand;
        const sk_value = switch (sk_pred) {
            .eq => |op| resolveOperand(op, params) orelse return error.UnresolvableOperand,
            else => return error.UnsupportedWhereForWrite,
        };
        names[1] = sk_name;
        values[1] = sk_value;
    }
    return .{ .names = names, .values = values };
}

fn renderUpdateResult(allocator: Allocator, result: storage.UpdateItemResult, ret: partiql_ast.ReturnValues) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    switch (ret) {
        .none => {},
        .all_old => if (result.old_item) |old| {
            try s.objectField("Items");
            try s.beginArray();
            try items_wire.renderItem(&s, allocator, &old);
            try s.endArray();
        },
        .all_new, .updated_new => if (result.new_item) |new| {
            try s.objectField("Items");
            try s.beginArray();
            try items_wire.renderItem(&s, allocator, &new);
            try s.endArray();
        },
        .updated_old => if (result.old_item) |old| {
            try s.objectField("Items");
            try s.beginArray();
            try items_wire.renderItem(&s, allocator, &old);
            try s.endArray();
        },
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

fn renderDeleteResult(allocator: Allocator, result: storage.DeleteItemResult, ret: partiql_ast.ReturnValues) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    if (ret == .all_old) {
        if (result.old_item) |old| {
            try s.objectField("Items");
            try s.beginArray();
            try items_wire.renderItem(&s, allocator, &old);
            try s.endArray();
        }
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Parameters parsing

fn parseParameters(allocator: Allocator, params_v: ?std.json.Value) ![]AttributeValue {
    const v = params_v orelse return allocator.alloc(AttributeValue, 0);
    if (v != .array) return error.InvalidParameters;
    const items = v.array.items;
    const out = try allocator.alloc(AttributeValue, items.len);
    for (items, 0..) |entry, i| {
        out[i] = try attribute_value.parseValue(allocator, entry);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Response rendering

fn renderResponse(allocator: Allocator, result: storage.QueryResult, columns: []const partiql_ast.ColumnRef) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();

    try s.objectField("Items");
    try s.beginArray();
    for (result.items) |item| {
        if (columns.len == 1 and columns[0] == .star) {
            try items_wire.renderItem(&s, allocator, &item);
        } else {
            try renderProjectedItem(&s, allocator, &item, columns);
        }
    }
    try s.endArray();

    if (result.last_evaluated_key) |ck| {
        try s.objectField("NextToken");
        try s.write(ck);
    }

    try s.endObject();
    return aw.toOwnedSlice();
}

fn renderProjectedItem(
    s: *std.json.Stringify,
    allocator: Allocator,
    item: *const storage.Item,
    columns: []const partiql_ast.ColumnRef,
) !void {
    try s.beginObject();
    for (columns) |col| {
        const name = switch (col) {
            .star => continue,
            .name => |n| n,
        };
        if (item.attributeValue(name)) |val| {
            try s.objectField(name);
            try attribute_value.renderValue(s, allocator, val.*);
        }
    }
    try s.endObject();
}

// ---------------------------------------------------------------------------
// Error mapping

fn mapParseErr(e: partiql_parser.ParseError) ErrorBody {
    return switch (e) {
        partiql_parser.ParseError.UnsupportedStatement => .{
            .code = .validation_exception,
            .message = "Statement type not supported by this PartiQL implementation.",
        },
        partiql_parser.ParseError.NumberLiteralInvalid => .{
            .code = .validation_exception,
            .message = "Invalid number literal in Statement.",
        },
        partiql_parser.ParseError.InvalidToken => .{
            .code = .validation_exception,
            .message = "Invalid character in Statement.",
        },
        partiql_parser.ParseError.OutOfMemory => .{ .code = .internal_server_error },
        partiql_parser.ParseError.Malformed => .{
            .code = .validation_exception,
            .message = "Statement is malformed.",
        },
    };
}

fn mapStorageErr(e: storage.Error) ErrorBody {
    return switch (e) {
        storage.Error.TableNotFound => .{ .code = .resource_not_found_exception },
        storage.Error.OutOfMemory, storage.Error.Io => .{ .code = .internal_server_error },
        else => .{ .code = .internal_server_error },
    };
}
