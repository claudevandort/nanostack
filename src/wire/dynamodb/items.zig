//! DynamoDB item-op wire parsers/renderers.
//!
//! GetItem / PutItem / DeleteItem request bodies share an Item shape:
//!
//!   {"<attr_name>": <AttributeValue>, ...}
//!
//! Each AttributeValue is `{"S":"...", ...}` per `attribute_value.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const av = @import("attribute_value.zig");

pub const ParseError = error{
    Malformed,
    Unsupported,
    OutOfMemory,
};

pub const ReturnValues = enum {
    none,
    all_old,
    /// UpdateItem-only options. Surfaced here so the wire enum is one
    /// place; service layer rejects them on PutItem / DeleteItem.
    all_new,
    updated_old,
    updated_new,

    pub fn fromAws(s: []const u8) ?ReturnValues {
        if (std.mem.eql(u8, s, "NONE")) return .none;
        if (std.mem.eql(u8, s, "ALL_OLD")) return .all_old;
        if (std.mem.eql(u8, s, "ALL_NEW")) return .all_new;
        if (std.mem.eql(u8, s, "UPDATED_OLD")) return .updated_old;
        if (std.mem.eql(u8, s, "UPDATED_NEW")) return .updated_new;
        return null;
    }
};

pub const PutItemRequest = struct {
    table: []const u8,
    item: storage.Item,
    return_values: ReturnValues = .none,
};

pub const GetItemRequest = struct {
    table: []const u8,
    key: storage.Item,
};

pub const DeleteItemRequest = struct {
    table: []const u8,
    key: storage.Item,
    return_values: ReturnValues = .none,
};

/// Parse the top-level JSON body to a std.json.Value tree owned by the
/// caller's allocator (typically an arena).
fn parseRoot(allocator: Allocator, body: []const u8) ParseError!std.json.Value {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    // Transfer ownership: we want the Value to outlive `parsed`, but
    // std.json.Parsed holds an arena that's freed on deinit. Easiest:
    // re-parse via parseFromSliceLeaky which uses the caller's arena
    // directly.
    parsed.deinit();
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch
        ParseError.Malformed;
}

fn parseItem(allocator: Allocator, v: std.json.Value) ParseError!storage.Item {
    if (v != .object) return ParseError.Malformed;
    const obj = v.object;
    const n = obj.count();
    const names = try allocator.alloc([]const u8, n);
    var names_done: usize = 0;
    errdefer {
        for (names[0..names_done]) |s| allocator.free(s);
        allocator.free(names);
    }
    const values = try allocator.alloc(av.AttributeValue, n);
    var values_done: usize = 0;
    errdefer {
        for (values[0..values_done]) |*val| {
            var copy = val.*;
            av.deinit(allocator, &copy);
        }
        allocator.free(values);
    }
    var it = obj.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        names[i] = try allocator.dupe(u8, entry.key_ptr.*);
        names_done = i + 1;
        values[i] = av.parseValue(allocator, entry.value_ptr.*) catch return ParseError.Malformed;
        values_done = i + 1;
    }
    return .{ .names = names, .values = values };
}

pub fn parsePutItem(allocator: Allocator, body: []const u8) ParseError!PutItemRequest {
    const root = try parseRoot(allocator, body);
    if (root != .object) return ParseError.Malformed;
    const obj = root.object;
    const name_v = obj.get("TableName") orelse return ParseError.Malformed;
    if (name_v != .string) return ParseError.Malformed;
    const item_v = obj.get("Item") orelse return ParseError.Malformed;
    const item = try parseItem(allocator, item_v);
    var rv: ReturnValues = .none;
    if (obj.get("ReturnValues")) |rv_v| {
        if (rv_v != .string) return ParseError.Malformed;
        rv = ReturnValues.fromAws(rv_v.string) orelse return ParseError.Malformed;
    }
    return .{
        .table = try allocator.dupe(u8, name_v.string),
        .item = item,
        .return_values = rv,
    };
}

pub fn parseGetItem(allocator: Allocator, body: []const u8) ParseError!GetItemRequest {
    const root = try parseRoot(allocator, body);
    if (root != .object) return ParseError.Malformed;
    const obj = root.object;
    const name_v = obj.get("TableName") orelse return ParseError.Malformed;
    if (name_v != .string) return ParseError.Malformed;
    const key_v = obj.get("Key") orelse return ParseError.Malformed;
    const key = try parseItem(allocator, key_v);
    return .{
        .table = try allocator.dupe(u8, name_v.string),
        .key = key,
    };
}

pub fn parseDeleteItem(allocator: Allocator, body: []const u8) ParseError!DeleteItemRequest {
    const root = try parseRoot(allocator, body);
    if (root != .object) return ParseError.Malformed;
    const obj = root.object;
    const name_v = obj.get("TableName") orelse return ParseError.Malformed;
    if (name_v != .string) return ParseError.Malformed;
    const key_v = obj.get("Key") orelse return ParseError.Malformed;
    const key = try parseItem(allocator, key_v);
    var rv: ReturnValues = .none;
    if (obj.get("ReturnValues")) |rv_v| {
        if (rv_v != .string) return ParseError.Malformed;
        rv = ReturnValues.fromAws(rv_v.string) orelse return ParseError.Malformed;
    }
    return .{
        .table = try allocator.dupe(u8, name_v.string),
        .key = key,
        .return_values = rv,
    };
}

// ---------------------------------------------------------------------------
// Renderers

/// Render an Item as `{<name>: <AttributeValue>, ...}` (no enclosing key).
pub fn renderItem(s: *std.json.Stringify, allocator: Allocator, item: *const storage.Item) !void {
    try s.beginObject();
    for (item.names, item.values) |name, value| {
        try s.objectField(name);
        try av.renderValue(s, allocator, value);
    }
    try s.endObject();
}

/// Render the GetItem response body: `{"Item": {...}}` when found,
/// `{}` when missing.
pub fn renderGetItemResponse(allocator: Allocator, item: ?*const storage.Item) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    if (item) |i| {
        try s.objectField("Item");
        try renderItem(&s, allocator, i);
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

/// Render a "modify"-op response (PutItem / DeleteItem). Caller passes
/// the `old_item` if ReturnValues asked for it; renders `{}` otherwise.
pub fn renderModifyResponse(allocator: Allocator, attribute_name: ?[]const u8, old: ?*const storage.Item) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    if (attribute_name) |field_name| {
        if (old) |o| {
            try s.objectField(field_name);
            try renderItem(&s, allocator, o);
        }
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parsePutItem: TableName + Item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = try parsePutItem(arena.allocator(),
        \\{"TableName":"Movies","Item":{"title":{"S":"x"},"year":{"N":"2020"}}}
    );
    try testing.expectEqualStrings("Movies", req.table);
    try testing.expectEqual(@as(usize, 2), req.item.names.len);
    try testing.expectEqual(ReturnValues.none, req.return_values);
}

test "parsePutItem: ReturnValues=ALL_OLD" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = try parsePutItem(arena.allocator(),
        \\{"TableName":"T","Item":{"k":{"S":"v"}},"ReturnValues":"ALL_OLD"}
    );
    try testing.expectEqual(ReturnValues.all_old, req.return_values);
}

test "parseGetItem: TableName + Key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = try parseGetItem(arena.allocator(),
        \\{"TableName":"T","Key":{"id":{"S":"k1"}}}
    );
    try testing.expectEqualStrings("T", req.table);
    try testing.expectEqual(@as(usize, 1), req.key.names.len);
}

test "renderGetItemResponse: present + absent shapes" {
    const names = try testing.allocator.alloc([]const u8, 1);
    names[0] = try testing.allocator.dupe(u8, "k");
    const values = try testing.allocator.alloc(av.AttributeValue, 1);
    values[0] = .{ .s = try testing.allocator.dupe(u8, "v") };
    var item: storage.Item = .{ .names = names, .values = values };
    defer item.deinit(testing.allocator);

    const present = try renderGetItemResponse(testing.allocator, &item);
    defer testing.allocator.free(present);
    try testing.expectEqualStrings("{\"Item\":{\"k\":{\"S\":\"v\"}}}", present);

    const absent = try renderGetItemResponse(testing.allocator, null);
    defer testing.allocator.free(absent);
    try testing.expectEqualStrings("{}", absent);
}
