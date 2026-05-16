//! DynamoDB batch operation handlers (M15-batch, Phase 7).
//!
//! BatchGetItem: up to 100 keys across N tables. Returns Responses
//! (table → list of items). UnprocessedKeys is always empty in v1.
//!
//! BatchWriteItem: up to 25 Put + Delete ops across N tables. Each op
//! is forwarded to PutItem / DeleteItem one at a time. UnprocessedItems
//! is always empty in v1.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const av = @import("../../wire/dynamodb/attribute_value.zig");
const items_wire = @import("../../wire/dynamodb/items.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

const BATCH_GET_CAP: usize = 100;
const BATCH_WRITE_CAP: usize = 25;

pub fn batchGetItem(ctx: Context) Result {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.request.body, .{}) catch
        return validationErr("Could not parse the BatchGetItem request body.");
    defer parsed.deinit();
    if (parsed.value != .object) return validationErr("Request body must be an object.");

    const request_items_v = parsed.value.object.get("RequestItems") orelse
        return validationErr("RequestItems is required.");
    if (request_items_v != .object) return validationErr("RequestItems must be an object.");

    // Count total keys across all tables.
    var total_keys: usize = 0;
    var it = request_items_v.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) return validationErr("Each table entry must be an object.");
        const keys_v = entry.value_ptr.object.get("Keys") orelse continue;
        if (keys_v != .array) return validationErr("Keys must be an array.");
        total_keys += keys_v.array.items.len;
    }
    if (total_keys > BATCH_GET_CAP) {
        return validationErr("Too many items requested for the BatchGetItem call (max 100).");
    }

    // Build the response: { Responses: { table: [items...] }, UnprocessedKeys: {} }
    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.beginObject() catch return internalErr();
    s.objectField("Responses") catch return internalErr();
    s.beginObject() catch return internalErr();

    it = request_items_v.object.iterator();
    while (it.next()) |entry| {
        const table_name = entry.key_ptr.*;
        s.objectField(table_name) catch return internalErr();
        s.beginArray() catch return internalErr();
        const keys_v = entry.value_ptr.object.get("Keys") orelse {
            s.endArray() catch return internalErr();
            continue;
        };
        for (keys_v.array.items) |key_node| {
            var key = parseKey(ctx.allocator, key_node) catch
                return validationErr("Failed to parse a key in BatchGetItem.");
            const get_result = ctx.backend.getItem(ctx.allocator, .{
                .table = table_name,
                .key = &key,
            }) catch |err| return .{ .err = mapStorageErr(err) };
            if (get_result.item) |item| {
                items_wire.renderItem(&s, ctx.allocator, &item) catch return internalErr();
            }
        }
        s.endArray() catch return internalErr();
    }

    s.endObject() catch return internalErr();
    s.objectField("UnprocessedKeys") catch return internalErr();
    s.beginObject() catch return internalErr();
    s.endObject() catch return internalErr();
    s.endObject() catch return internalErr();

    const body = aw.toOwnedSlice() catch return internalErr();
    return .{ .ok = .{ .body = body } };
}

pub fn batchWriteItem(ctx: Context) Result {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.request.body, .{}) catch
        return validationErr("Could not parse the BatchWriteItem request body.");
    defer parsed.deinit();
    if (parsed.value != .object) return validationErr("Request body must be an object.");

    const request_items_v = parsed.value.object.get("RequestItems") orelse
        return validationErr("RequestItems is required.");
    if (request_items_v != .object) return validationErr("RequestItems must be an object.");

    // Count total ops.
    var total_ops: usize = 0;
    var count_it = request_items_v.object.iterator();
    while (count_it.next()) |entry| {
        if (entry.value_ptr.* != .array) return validationErr("Each table entry must be an array.");
        total_ops += entry.value_ptr.array.items.len;
    }
    if (total_ops > BATCH_WRITE_CAP) {
        return validationErr("Too many items in BatchWriteItem (max 25).");
    }

    var it = request_items_v.object.iterator();
    while (it.next()) |entry| {
        const table_name = entry.key_ptr.*;
        for (entry.value_ptr.array.items) |op_node| {
            if (op_node != .object) return validationErr("Each request must be an object.");
            const op_obj = op_node.object;
            if (op_obj.get("PutRequest")) |pr_v| {
                if (pr_v != .object) return validationErr("PutRequest must be an object.");
                const item_v = pr_v.object.get("Item") orelse return validationErr("PutRequest.Item is required.");
                var item = parseKey(ctx.allocator, item_v) catch return validationErr("Failed to parse PutRequest.Item.");
                _ = ctx.backend.putItem(ctx.allocator, .{
                    .table = table_name,
                    .item = &item,
                }) catch |err| return .{ .err = mapStorageErr(err) };
                continue;
            }
            if (op_obj.get("DeleteRequest")) |dr_v| {
                if (dr_v != .object) return validationErr("DeleteRequest must be an object.");
                const key_v = dr_v.object.get("Key") orelse return validationErr("DeleteRequest.Key is required.");
                var key = parseKey(ctx.allocator, key_v) catch return validationErr("Failed to parse DeleteRequest.Key.");
                _ = ctx.backend.deleteItem(ctx.allocator, .{
                    .table = table_name,
                    .key = &key,
                }) catch |err| return .{ .err = mapStorageErr(err) };
                continue;
            }
            return validationErr("Each request must have PutRequest or DeleteRequest.");
        }
    }

    // Always empty: nanostack succeeds or fails the whole batch.
    const body = ctx.allocator.dupe(u8, "{\"UnprocessedItems\":{}}") catch return internalErr();
    return .{ .ok = .{ .body = body } };
}

fn parseKey(allocator: Allocator, key_v: std.json.Value) !storage.Item {
    if (key_v != .object) return error.Malformed;
    const obj = key_v.object;
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
        else => .{ .code = .internal_server_error },
    };
}
