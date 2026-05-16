//! DynamoDB Query service handler (M15-query, Phase 5).
//!
//! Parses KeyConditionExpression (required) and FilterExpression
//! (optional). Builds two ItemPredicates that close over the parsed
//! expressions + the request's ExpressionAttributeValues. Storage walks
//! all items, applies both predicates, sorts by sort key, paginates.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const av = @import("../../wire/dynamodb/attribute_value.zig");
const AttributeValue = av.AttributeValue;
const condition_mod = @import("../../wire/dynamodb/expressions/condition.zig");
const key_condition_mod = @import("../../wire/dynamodb/expressions/key_condition.zig");
const items_wire = @import("../../wire/dynamodb/items.zig");
const errors = @import("../../wire/dynamodb/errors.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn query(ctx: Context) Result {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.request.body, .{}) catch
        return .{ .err = .{ .code = .validation_exception, .message = "Could not parse the Query request body." } };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .err = .{ .code = .validation_exception } };
    const root = parsed.value.object;

    const name_v = root.get("TableName") orelse
        return .{ .err = .{ .code = .validation_exception, .message = "TableName is required." } };
    if (name_v != .string) return .{ .err = .{ .code = .validation_exception } };
    const table = ctx.allocator.dupe(u8, name_v.string) catch return .{ .err = .{ .code = .internal_server_error } };

    const kce_v = root.get("KeyConditionExpression") orelse
        return .{ .err = .{ .code = .validation_exception, .message = "KeyConditionExpression is required." } };
    if (kce_v != .string) return .{ .err = .{ .code = .validation_exception } };

    const names_json = root.get("ExpressionAttributeNames");
    // ExpressionAttributeValues must survive past parsed.deinit() — re-parse leaky.
    const values_leaky = leakyAttrValues(ctx.allocator, ctx.request.body) catch null;

    var key_doc = key_condition_mod.parse(ctx.allocator, kce_v.string, names_json) catch
        return .{ .err = .{ .code = .validation_exception, .message = "KeyConditionExpression is malformed." } };
    defer key_doc.deinit();

    var filter_doc_opt: ?condition_mod.Document = null;
    if (root.get("FilterExpression")) |fe_v| {
        if (fe_v != .string) return .{ .err = .{ .code = .validation_exception } };
        filter_doc_opt = condition_mod.parse(ctx.allocator, fe_v.string, names_json) catch
            return .{ .err = .{ .code = .validation_exception, .message = "FilterExpression is malformed." } };
    }
    defer if (filter_doc_opt) |*d| d.deinit();

    // Parse cursor.
    var start_key: ?[]const u8 = null;
    if (root.get("ExclusiveStartKey")) |esk_v| {
        if (esk_v != .object) return .{ .err = .{ .code = .validation_exception } };
        start_key = buildCursorString(ctx.allocator, esk_v) catch null;
    }

    const limit: u32 = if (root.get("Limit")) |l_v| switch (l_v) {
        .integer => |n| if (n < 1 or n > 1_000_000) 0 else @intCast(n),
        else => 0,
    } else 0;

    const forward: bool = if (root.get("ScanIndexForward")) |b_v| switch (b_v) {
        .bool => |b| b,
        else => true,
    } else true;

    // Build the key + filter predicates.
    var key_holder: KeyPredicateHolder = .{
        .doc = &key_doc,
        .values = values_leaky,
        .allocator = ctx.allocator,
    };
    var filter_holder: ConditionFilterHolder = .{
        .doc = if (filter_doc_opt) |*d| d else null,
        .values = values_leaky,
        .allocator = ctx.allocator,
    };

    const key_pred: storage.ItemPredicate = .{
        .ctx = @ptrCast(&key_holder),
        .match_fn = KeyPredicateHolder.match,
    };
    const filter_pred: ?storage.ItemPredicate = if (filter_doc_opt != null) .{
        .ctx = @ptrCast(&filter_holder),
        .match_fn = ConditionFilterHolder.match,
    } else null;

    const result = ctx.backend.query(ctx.allocator, .{
        .table = table,
        .key_predicate = key_pred,
        .filter_predicate = filter_pred,
        .forward = forward,
        .limit = limit,
        .exclusive_start_key = start_key,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const body = renderQueryResponse(ctx.allocator, result) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

fn renderQueryResponse(allocator: Allocator, result: storage.QueryResult) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();

    try s.objectField("Items");
    try s.beginArray();
    for (result.items) |item| {
        try items_wire.renderItem(&s, allocator, &item);
    }
    try s.endArray();

    try s.objectField("Count");
    try s.write(result.count);
    try s.objectField("ScannedCount");
    try s.write(result.scanned_count);

    if (result.last_evaluated_key) |_| {
        // The cursor stores our internal composite key string. AWS expects
        // a key-attribute map; we emit a single _ck attribute carrying the
        // string. Clients pass it back unchanged in ExclusiveStartKey.
        try s.objectField("LastEvaluatedKey");
        try s.beginObject();
        try s.objectField("_ck");
        try s.beginObject();
        try s.objectField("S");
        try s.write(result.last_evaluated_key.?);
        try s.endObject();
        try s.endObject();
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

fn buildCursorString(allocator: Allocator, esk_v: std.json.Value) !?[]const u8 {
    if (esk_v != .object) return null;
    const obj = esk_v.object;
    // If it's our `_ck` wrapper, unwrap it.
    if (obj.get("_ck")) |v| {
        if (v != .object) return null;
        const s_v = v.object.get("S") orelse return null;
        if (s_v != .string) return null;
        return try allocator.dupe(u8, s_v.string);
    }
    return null;
}

/// Re-parse the request body's ExpressionAttributeValues into a leaky
/// json.Value tree owned by the caller's arena. We need this because
/// the original parse's arena gets freed when we `defer parsed.deinit()`.
fn leakyAttrValues(allocator: Allocator, body: []const u8) !?std.json.Value {
    const leaky = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch return null;
    if (leaky != .object) return null;
    return leaky.object.get("ExpressionAttributeValues");
}

// ---------------------------------------------------------------------------
// Predicate holders

const KeyPredicateHolder = struct {
    doc: *key_condition_mod.Document,
    values: ?std.json.Value,
    allocator: Allocator,

    fn match(opaque_ctx: *anyopaque, item: *const storage.Item) bool {
        const self: *KeyPredicateHolder = @ptrCast(@alignCast(opaque_ctx));
        return self.matchInner(item) catch false;
    }

    fn matchInner(self: *KeyPredicateHolder, item: *const storage.Item) !bool {
        const cond = self.doc.cond;
        // Resolve the PK value from :placeholder.
        const pk_target = try condition_mod.resolveValue(cond.pk_value, .{
            .item = item,
            .values = self.values,
            .allocator = self.allocator,
        }) orelse return false;
        const pk_actual_ptr = item.attributeValue(cond.pk_name) orelse return false;
        if (!condition_mod.valuesEqual(pk_actual_ptr.*, pk_target)) return false;

        // Sort key predicate (optional).
        if (cond.sk_name) |sk_name| {
            const sk_actual_ptr = item.attributeValue(sk_name) orelse return false;
            const sk_actual = sk_actual_ptr.*;
            const pred = cond.sk_predicate orelse return true;
            switch (pred) {
                .eq => |o| {
                    const v = try condition_mod.resolveValue(o, ctxOf(self)) orelse return false;
                    return condition_mod.valuesEqual(sk_actual, v);
                },
                .lt => |o| {
                    const v = try condition_mod.resolveValue(o, ctxOf(self)) orelse return false;
                    return (try condition_mod.compareValues(sk_actual, v)) < 0;
                },
                .le => |o| {
                    const v = try condition_mod.resolveValue(o, ctxOf(self)) orelse return false;
                    return (try condition_mod.compareValues(sk_actual, v)) <= 0;
                },
                .gt => |o| {
                    const v = try condition_mod.resolveValue(o, ctxOf(self)) orelse return false;
                    return (try condition_mod.compareValues(sk_actual, v)) > 0;
                },
                .ge => |o| {
                    const v = try condition_mod.resolveValue(o, ctxOf(self)) orelse return false;
                    return (try condition_mod.compareValues(sk_actual, v)) >= 0;
                },
                .between => |b| {
                    const lo = try condition_mod.resolveValue(b.lo, ctxOf(self)) orelse return false;
                    const hi = try condition_mod.resolveValue(b.hi, ctxOf(self)) orelse return false;
                    const ge_lo = (try condition_mod.compareValues(sk_actual, lo)) >= 0;
                    const le_hi = (try condition_mod.compareValues(sk_actual, hi)) <= 0;
                    return ge_lo and le_hi;
                },
                .begins_with => |o| {
                    const prefix = try condition_mod.resolveValue(o, ctxOf(self)) orelse return false;
                    const s = switch (sk_actual) {
                        .s => |x| x,
                        else => return false,
                    };
                    const p = switch (prefix) {
                        .s => |x| x,
                        else => return false,
                    };
                    return std.mem.startsWith(u8, s, p);
                },
            }
        }
        return true;
    }

    fn ctxOf(self: *KeyPredicateHolder) condition_mod.EvalContext {
        return .{ .item = null, .values = self.values, .allocator = self.allocator };
    }
};

const ConditionFilterHolder = struct {
    doc: ?*condition_mod.Document,
    values: ?std.json.Value,
    allocator: Allocator,

    fn match(opaque_ctx: *anyopaque, item: *const storage.Item) bool {
        const self: *ConditionFilterHolder = @ptrCast(@alignCast(opaque_ctx));
        const doc = self.doc orelse return true;
        return condition_mod.evaluate(doc.root, .{
            .item = item,
            .values = self.values,
            .allocator = self.allocator,
        }) catch false;
    }
};

fn mapStorageErr(e: storage.Error) mod.ErrorBody {
    return switch (e) {
        storage.Error.TableNotFound => .{ .code = .resource_not_found_exception },
        storage.Error.OutOfMemory, storage.Error.Io => .{ .code = .internal_server_error },
        else => .{ .code = .internal_server_error },
    };
}
