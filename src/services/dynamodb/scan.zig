//! DynamoDB Scan service handler (M15-scan, Phase 6).
//!
//! Full table iteration with optional FilterExpression. Reuses
//! storage.DynamoBackend.query with a tautology key predicate.
//! Parallel scan (`TotalSegments > 1`) is explicitly rejected.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const condition_mod = @import("../../wire/dynamodb/expressions/condition.zig");
const items_wire = @import("../../wire/dynamodb/items.zig");
const errors = @import("../../wire/dynamodb/errors.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn scan(ctx: Context) Result {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.request.body, .{}) catch
        return .{ .err = .{ .code = .validation_exception, .message = "Could not parse the Scan request body." } };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .err = .{ .code = .validation_exception } };
    const root = parsed.value.object;

    const name_v = root.get("TableName") orelse
        return .{ .err = .{ .code = .validation_exception, .message = "TableName is required." } };
    if (name_v != .string) return .{ .err = .{ .code = .validation_exception } };
    const table = ctx.allocator.dupe(u8, name_v.string) catch return .{ .err = .{ .code = .internal_server_error } };

    // Parallel scan: not supported in v0.2.0.
    if (root.get("TotalSegments")) |ts_v| {
        if (ts_v == .integer and ts_v.integer > 1) {
            return .{ .err = .{
                .code = .validation_exception,
                .message = "Parallel scan (TotalSegments > 1) is not supported in v0.2.0.",
            } };
        }
    }

    const names_json = root.get("ExpressionAttributeNames");
    const values_leaky = leakyAttrValues(ctx.allocator, ctx.request.body) catch null;

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

    var start_key: ?[]const u8 = null;
    if (root.get("ExclusiveStartKey")) |esk_v| {
        if (esk_v != .object) return .{ .err = .{ .code = .validation_exception } };
        if (esk_v.object.get("_ck")) |v| {
            if (v == .object) {
                if (v.object.get("S")) |s_v| {
                    if (s_v == .string) {
                        start_key = ctx.allocator.dupe(u8, s_v.string) catch return .{ .err = .{ .code = .internal_server_error } };
                    }
                }
            }
        }
    }

    const limit: u32 = if (root.get("Limit")) |l_v| switch (l_v) {
        .integer => |n| if (n < 1 or n > 1_000_000) 0 else @intCast(n),
        else => 0,
    } else 0;

    // Tautology key predicate — matches every item.
    const TautologyState = struct {
        fn matchEverything(_: *anyopaque, _: *const storage.Item) bool {
            return true;
        }
    };
    var dummy: u8 = 0;
    const key_pred: storage.ItemPredicate = .{
        .ctx = @ptrCast(&dummy),
        .match_fn = TautologyState.matchEverything,
    };

    var filter_holder: FilterHolder = .{
        .doc = if (filter_doc_opt) |*d| d else null,
        .values = values_leaky,
        .allocator = ctx.allocator,
    };
    const filter_pred: ?storage.ItemPredicate = if (filter_doc_opt != null) .{
        .ctx = @ptrCast(&filter_holder),
        .match_fn = FilterHolder.match,
    } else null;

    const result = ctx.backend.query(ctx.allocator, .{
        .table = table,
        .key_predicate = key_pred,
        .filter_predicate = filter_pred,
        .forward = true,
        .limit = limit,
        .exclusive_start_key = start_key,
    }) catch |err| return .{ .err = mapStorageErr(err) };

    const body = renderScanResponse(ctx.allocator, result) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

fn renderScanResponse(allocator: Allocator, result: storage.QueryResult) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();

    try s.objectField("Items");
    try s.beginArray();
    for (result.items) |item| try items_wire.renderItem(&s, allocator, &item);
    try s.endArray();

    try s.objectField("Count");
    try s.write(result.count);
    try s.objectField("ScannedCount");
    try s.write(result.scanned_count);

    if (result.last_evaluated_key) |_| {
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

const FilterHolder = struct {
    doc: ?*condition_mod.Document,
    values: ?std.json.Value,
    allocator: Allocator,

    fn match(opaque_ctx: *anyopaque, item: *const storage.Item) bool {
        const self: *FilterHolder = @ptrCast(@alignCast(opaque_ctx));
        const doc = self.doc orelse return true;
        return condition_mod.evaluate(doc.root, .{
            .item = item,
            .values = self.values,
            .allocator = self.allocator,
        }) catch false;
    }
};

fn leakyAttrValues(allocator: Allocator, body: []const u8) !?std.json.Value {
    const leaky = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch return null;
    if (leaky != .object) return null;
    return leaky.object.get("ExpressionAttributeValues");
}

fn mapStorageErr(e: storage.Error) mod.ErrorBody {
    return switch (e) {
        storage.Error.TableNotFound => .{ .code = .resource_not_found_exception },
        else => .{ .code = .internal_server_error },
    };
}
