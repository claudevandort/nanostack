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
const dynamo_state = @import("../../storage/dynamo_state.zig");

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

    var key_doc = key_condition_mod.parse(ctx.allocator, kce_v.string, names_json) catch |err| switch (err) {
        key_condition_mod.ParseError.ReservedWord => return .{ .err = .{
            .code = .validation_exception,
            .message = "Reserved keyword used as a bare attribute name in KeyConditionExpression; alias via ExpressionAttributeNames.",
        } },
        else => return .{ .err = .{ .code = .validation_exception, .message = "KeyConditionExpression is malformed." } },
    };
    defer key_doc.deinit();

    // Optional IndexName: route the Query through a GSI / LSI (Phase 8).
    const index_name: ?[]const u8 = if (root.get("IndexName")) |iv| switch (iv) {
        .string => |s| s,
        else => return .{ .err = .{ .code = .validation_exception, .message = "IndexName must be a string." } },
    } else null;

    var filter_doc_opt: ?condition_mod.Document = null;
    if (root.get("FilterExpression")) |fe_v| {
        if (fe_v != .string) return .{ .err = .{ .code = .validation_exception } };
        filter_doc_opt = condition_mod.parse(ctx.allocator, fe_v.string, names_json) catch |err| switch (err) {
            condition_mod.ParseError.ReservedWord => return .{ .err = .{
                .code = .validation_exception,
                .message = "Reserved keyword used as a bare attribute name in FilterExpression; alias via ExpressionAttributeNames.",
            } },
            else => return .{ .err = .{ .code = .validation_exception, .message = "FilterExpression is malformed." } },
        };
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
    if (index_name) |idx_name| {
        return queryViaIndex(ctx, .{
            .table = table,
            .index_name = idx_name,
            .key_doc = &key_doc,
            .filter_doc = if (filter_doc_opt) |*d| d else null,
            .values = values_leaky,
            .forward = forward,
            .limit = limit,
            .start_key = start_key,
        });
    }

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

// ---------------------------------------------------------------------------
// GSI / LSI query path (Phase 8)
//
// Implementation strategy: rather than maintaining separate index data
// structures, we walk the base table once (via storage.query with a
// tautology predicate), re-key each item by the index's PK/SK, sort,
// filter, project, paginate. O(N) per query but adequate for dev-sized
// tables (typical ≤ 100K items). A real per-index sorted structure can
// land later if needed.

const IndexQueryParams = struct {
    table: []const u8,
    index_name: []const u8,
    key_doc: *key_condition_mod.Document,
    filter_doc: ?*condition_mod.Document,
    values: ?std.json.Value,
    forward: bool,
    limit: u32,
    start_key: ?[]const u8,
};

fn queryViaIndex(ctx: Context, p: IndexQueryParams) Result {
    // Find the table slot + index def.
    const slot = ctx.backend.describeTable(p.table) catch |err| return .{ .err = mapStorageErr(err) };

    const index_keys: []const dynamo_state.KeyAttribute, const projection: dynamo_state.Projection = blk: {
        for (slot.global_secondary_indexes) |g| {
            if (std.mem.eql(u8, g.name, p.index_name)) break :blk .{ g.key_schema, g.projection };
        }
        for (slot.local_secondary_indexes) |l| {
            if (std.mem.eql(u8, l.name, p.index_name)) break :blk .{ l.key_schema, l.projection };
        }
        return .{ .err = .{
            .code = .validation_exception,
            .message = "IndexName references an index that doesn't exist on this table.",
        } };
    };

    // Pull every item from the base table (tautology predicate).
    const TautologyState = struct {
        fn matchAll(_: *anyopaque, _: *const storage.Item) bool {
            return true;
        }
    };
    var dummy: u8 = 0;
    const all = ctx.backend.query(ctx.allocator, .{
        .table = p.table,
        .key_predicate = .{ .ctx = @ptrCast(&dummy), .match_fn = TautologyState.matchAll },
        .filter_predicate = null,
        .forward = true,
        .limit = 0,
        .exclusive_start_key = null,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    // Identify the index's PK and SK attributes.
    var idx_pk_name: []const u8 = "";
    var idx_sk_name: ?[]const u8 = null;
    for (index_keys) |k| switch (k.key_type) {
        .hash => idx_pk_name = k.name,
        .range => idx_sk_name = k.name,
    };

    // Filter: each item must (a) have the index PK attribute, (b) match
    // the KeyCondition's PK clause, (c) match the SK predicate if any.
    var key_holder: KeyPredicateHolder = .{
        .doc = p.key_doc,
        .values = p.values,
        .allocator = ctx.allocator,
    };

    var matched: std.ArrayList(storage.Item) = .empty;
    defer matched.deinit(ctx.allocator);
    var matched_keys: std.ArrayList([]const u8) = .empty;
    defer matched_keys.deinit(ctx.allocator);

    for (all.items) |item| {
        // Item must have index PK attribute.
        if (item.attributeValue(idx_pk_name) == null) continue;
        // Verify key condition holds (the holder uses doc.cond.pk_name/sk_name,
        // which the parser produced from the KeyConditionExpression — i.e.
        // the *index*'s key names, since clients use those in the query).
        const matches = key_holder.matchInner(&item) catch false;
        if (!matches) continue;

        // Build a composite key string for sorting using index's PK+SK.
        const composite = buildIndexKey(ctx.allocator, idx_pk_name, idx_sk_name, &item) catch
            return .{ .err = .{ .code = .internal_server_error } };
        matched.append(ctx.allocator, item) catch return .{ .err = .{ .code = .internal_server_error } };
        matched_keys.append(ctx.allocator, composite) catch return .{ .err = .{ .code = .internal_server_error } };
    }

    // Sort by index composite key. std.sort.insertionContext expects
    // lessThan + swap methods on the context.
    const SortCtx = struct {
        items: []storage.Item,
        keys: [][]const u8,
        forward: bool,

        pub fn lessThan(self: @This(), a: usize, b: usize) bool {
            const ord = std.mem.lessThan(u8, self.keys[a], self.keys[b]);
            return if (self.forward) ord else !ord;
        }
        pub fn swap(self: @This(), a: usize, b: usize) void {
            std.mem.swap(storage.Item, &self.items[a], &self.items[b]);
            std.mem.swap([]const u8, &self.keys[a], &self.keys[b]);
        }
    };
    const sort_ctx: SortCtx = .{
        .items = matched.items,
        .keys = matched_keys.items,
        .forward = p.forward,
    };
    std.sort.insertionContext(0, matched.items.len, sort_ctx);

    // Cursor: skip items <= start_key (forward) or >= start_key (reverse).
    var start_idx: usize = 0;
    if (p.start_key) |sk| {
        for (matched_keys.items, 0..) |k, i| {
            const past = if (p.forward)
                std.mem.lessThan(u8, sk, k)
            else
                std.mem.lessThan(u8, k, sk);
            if (past) {
                start_idx = i;
                break;
            }
        } else start_idx = matched_keys.items.len;
    }

    // Apply filter + limit + projection.
    var filter_holder: ConditionFilterHolder = .{
        .doc = p.filter_doc,
        .values = p.values,
        .allocator = ctx.allocator,
    };

    var emitted: std.ArrayList(storage.Item) = .empty;
    errdefer {
        for (emitted.items) |*it| {
            var copy = it.*;
            copy.deinit(ctx.allocator);
        }
        emitted.deinit(ctx.allocator);
    }
    var scanned: u32 = 0;
    var idx: usize = start_idx;
    var last_key: ?[]const u8 = null;
    while (idx < matched.items.len) : (idx += 1) {
        const item = matched.items[idx];
        scanned += 1;
        if (p.filter_doc != null and !ConditionFilterHolder.match(@ptrCast(&filter_holder), &item)) continue;
        const projected = projectItem(ctx.allocator, &item, slot, index_keys, projection) catch
            return .{ .err = .{ .code = .internal_server_error } };
        emitted.append(ctx.allocator, projected) catch
            return .{ .err = .{ .code = .internal_server_error } };
        last_key = matched_keys.items[idx];
        if (p.limit != 0 and emitted.items.len >= p.limit) {
            idx += 1;
            break;
        }
    }
    const truncated = idx < matched.items.len;
    const cursor_out: ?[]const u8 = if (truncated and last_key != null)
        ctx.allocator.dupe(u8, last_key.?) catch return .{ .err = .{ .code = .internal_server_error } }
    else
        null;

    const count: u32 = @intCast(emitted.items.len);
    const items = emitted.toOwnedSlice(ctx.allocator) catch
        return .{ .err = .{ .code = .internal_server_error } };

    const body = renderQueryResponse(ctx.allocator, .{
        .items = items,
        .count = count,
        .scanned_count = scanned,
        .last_evaluated_key = cursor_out,
    }) catch return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

fn buildIndexKey(
    allocator: Allocator,
    pk_name: []const u8,
    sk_name: ?[]const u8,
    item: *const storage.Item,
) ![]u8 {
    const pk_val = item.attributeValue(pk_name) orelse return error.MissingKey;
    const pk_part = try encodePart(allocator, pk_val);
    defer allocator.free(pk_part);
    if (sk_name) |sn| {
        if (item.attributeValue(sn)) |sk_val| {
            const sk_part = try encodePart(allocator, sk_val);
            defer allocator.free(sk_part);
            return std.fmt.allocPrint(allocator, "{s}|{s}", .{ pk_part, sk_part });
        }
    }
    return allocator.dupe(u8, pk_part);
}

fn encodePart(allocator: Allocator, v: *const av.AttributeValue) ![]u8 {
    return switch (v.*) {
        .s => |s| std.fmt.allocPrint(allocator, "S:{s}", .{s}),
        .n => |s| std.fmt.allocPrint(allocator, "N:{s}", .{s}),
        .b => |bytes| std.fmt.allocPrint(allocator, "B:{x}", .{bytes}),
        else => error.InvalidKeyType,
    };
}

/// Project an item per the index's ProjectionType.
fn projectItem(
    allocator: Allocator,
    item: *const storage.Item,
    slot: *const storage.TableSlot,
    index_keys: []const dynamo_state.KeyAttribute,
    projection: dynamo_state.Projection,
) !storage.Item {
    // Determine which attribute names to keep.
    // We collect names into a list-set first.
    var keep: std.StringHashMap(void) = .init(allocator);
    defer keep.deinit();

    // Always: base-table key attributes + index key attributes.
    for (slot.key_schema) |k| try keep.put(k.name, {});
    for (index_keys) |k| try keep.put(k.name, {});

    switch (projection.type) {
        .all => {
            // Add every attribute.
            for (item.names) |n| try keep.put(n, {});
        },
        .keys_only => {}, // base + index keys only — already added
        .include => {
            for (projection.non_key_attributes) |n| try keep.put(n, {});
        },
    }

    // Build the projected item preserving the source item's order.
    var names: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList(av.AttributeValue) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
        for (values.items) |*vv| {
            var copy = vv.*;
            av.deinit(allocator, &copy);
        }
        values.deinit(allocator);
    }
    for (item.names, item.values) |name, value| {
        if (!keep.contains(name)) continue;
        try names.append(allocator, try allocator.dupe(u8, name));
        try values.append(allocator, try cloneAv(allocator, value));
    }
    return .{
        .names = try names.toOwnedSlice(allocator),
        .values = try values.toOwnedSlice(allocator),
    };
}

fn cloneAv(allocator: Allocator, v: av.AttributeValue) !av.AttributeValue {
    return switch (v) {
        .s => |s| .{ .s = try allocator.dupe(u8, s) },
        .n => |s| .{ .n = try allocator.dupe(u8, s) },
        .b => |bytes| .{ .b = try allocator.dupe(u8, bytes) },
        .bool => |b| .{ .bool = b },
        .null => .null,
        .list => |items| blk: {
            const out = try allocator.alloc(av.AttributeValue, items.len);
            for (items, 0..) |child, i| out[i] = try cloneAv(allocator, child);
            break :blk .{ .list = out };
        },
        .map => |m| blk: {
            const names = try allocator.alloc([]const u8, m.names.len);
            for (m.names, 0..) |n, i| names[i] = try allocator.dupe(u8, n);
            const values = try allocator.alloc(av.AttributeValue, m.values.len);
            for (m.values, 0..) |child, i| values[i] = try cloneAv(allocator, child);
            break :blk .{ .map = .{ .names = names, .values = values } };
        },
        .ss => |elems| .{ .ss = try dupSlices(allocator, elems) },
        .ns => |elems| .{ .ns = try dupSlices(allocator, elems) },
        .bs => |elems| .{ .bs = try dupSlices(allocator, elems) },
    };
}

fn dupSlices(allocator: Allocator, src: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, src.len);
    for (src, 0..) |s, i| out[i] = try allocator.dupe(u8, s);
    return out;
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
