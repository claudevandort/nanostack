//! Wire parsers + renderers for DynamoDB table operations.
//!
//! Translates AWS PascalCase JSON request bodies to typed storage inputs
//! and renders TableDescription / TableNames response bodies.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const dynamo_state = @import("../../storage/dynamo_state.zig");

pub const ParseError = error{
    Malformed, // malformed JSON or missing required field
    InvalidName, // table or attribute name fails validation
    InvalidKeyType, // unrecognised HASH/RANGE
    InvalidScalarType, // attribute type not S/N/B
    InvalidBillingMode,
    InvalidProjectionType,
    KeyReferencesUndeclaredAttribute,
    InvalidKeySchema, // wrong number of keys, missing HASH, etc.
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// CreateTable request

pub const CreateTableRequest = struct {
    name: []const u8,
    key_schema: []const dynamo_state.KeyAttribute,
    attribute_definitions: []const dynamo_state.AttributeDef,
    billing_mode: dynamo_state.BillingMode,
    global_secondary_indexes: []const dynamo_state.GsiDef,
    local_secondary_indexes: []const dynamo_state.LsiDef,
    tags: []const dynamo_state.Tag,
};

/// Parse a CreateTable request body. All slices are allocated via the
/// caller's allocator (typically a per-request arena), so caller is
/// responsible for freeing — but the typical pattern is "arena frees
/// everything when the response is sent."
pub fn parseCreateTable(allocator: Allocator, body: []const u8) ParseError!CreateTableRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();

    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;

    const name_v = root.get("TableName") orelse return ParseError.Malformed;
    if (name_v != .string) return ParseError.Malformed;
    dynamo_state.validateTableName(name_v.string) catch return ParseError.InvalidName;
    const name = try allocator.dupe(u8, name_v.string);

    const key_schema = try parseKeySchema(allocator, root.get("KeySchema") orelse return ParseError.Malformed);
    const attr_defs = try parseAttributeDefinitions(allocator, root.get("AttributeDefinitions") orelse return ParseError.Malformed);

    // Each key-schema attribute must be in attribute_definitions.
    for (key_schema) |k| {
        var found = false;
        for (attr_defs) |a| {
            if (std.mem.eql(u8, a.name, k.name)) {
                found = true;
                break;
            }
        }
        if (!found) return ParseError.KeyReferencesUndeclaredAttribute;
    }

    // Key schema: exactly one HASH; optional RANGE; nothing else.
    if (key_schema.len < 1 or key_schema.len > 2) return ParseError.InvalidKeySchema;
    var hash_count: u8 = 0;
    var range_count: u8 = 0;
    for (key_schema) |k| switch (k.key_type) {
        .hash => hash_count += 1,
        .range => range_count += 1,
    };
    if (hash_count != 1 or range_count > 1) return ParseError.InvalidKeySchema;

    const billing_mode = if (root.get("BillingMode")) |bv| blk: {
        if (bv != .string) return ParseError.InvalidBillingMode;
        break :blk dynamo_state.BillingMode.fromAws(bv.string) orelse return ParseError.InvalidBillingMode;
    } else dynamo_state.BillingMode.pay_per_request;

    const gsis = if (root.get("GlobalSecondaryIndexes")) |g|
        try parseIndexes(allocator, g, dynamo_state.GsiDef, attr_defs)
    else
        try allocator.alloc(dynamo_state.GsiDef, 0);

    const lsis = if (root.get("LocalSecondaryIndexes")) |l|
        try parseIndexes(allocator, l, dynamo_state.LsiDef, attr_defs)
    else
        try allocator.alloc(dynamo_state.LsiDef, 0);

    const tags = if (root.get("Tags")) |t| try parseTags(allocator, t) else try allocator.alloc(dynamo_state.Tag, 0);

    return .{
        .name = name,
        .key_schema = key_schema,
        .attribute_definitions = attr_defs,
        .billing_mode = billing_mode,
        .global_secondary_indexes = gsis,
        .local_secondary_indexes = lsis,
        .tags = tags,
    };
}

fn parseKeySchema(allocator: Allocator, v: std.json.Value) ParseError![]const dynamo_state.KeyAttribute {
    if (v != .array) return ParseError.Malformed;
    const items = v.array.items;
    const out = try allocator.alloc(dynamo_state.KeyAttribute, items.len);
    for (items, 0..) |item, i| {
        if (item != .object) return ParseError.Malformed;
        const name_v = item.object.get("AttributeName") orelse return ParseError.Malformed;
        const kt_v = item.object.get("KeyType") orelse return ParseError.Malformed;
        if (name_v != .string or kt_v != .string) return ParseError.Malformed;
        dynamo_state.validateAttributeName(name_v.string) catch return ParseError.InvalidName;
        out[i] = .{
            .name = try allocator.dupe(u8, name_v.string),
            .key_type = dynamo_state.KeyType.fromAws(kt_v.string) orelse return ParseError.InvalidKeyType,
        };
    }
    return out;
}

fn parseAttributeDefinitions(allocator: Allocator, v: std.json.Value) ParseError![]const dynamo_state.AttributeDef {
    if (v != .array) return ParseError.Malformed;
    const items = v.array.items;
    const out = try allocator.alloc(dynamo_state.AttributeDef, items.len);
    for (items, 0..) |item, i| {
        if (item != .object) return ParseError.Malformed;
        const name_v = item.object.get("AttributeName") orelse return ParseError.Malformed;
        const type_v = item.object.get("AttributeType") orelse return ParseError.Malformed;
        if (name_v != .string or type_v != .string) return ParseError.Malformed;
        dynamo_state.validateAttributeName(name_v.string) catch return ParseError.InvalidName;
        out[i] = .{
            .name = try allocator.dupe(u8, name_v.string),
            .type = dynamo_state.ScalarType.fromAws(type_v.string) orelse return ParseError.InvalidScalarType,
        };
    }
    return out;
}

fn parseIndexes(
    allocator: Allocator,
    v: std.json.Value,
    comptime T: type,
    attr_defs: []const dynamo_state.AttributeDef,
) ParseError![]const T {
    if (v != .array) return ParseError.Malformed;
    const items = v.array.items;
    const out = try allocator.alloc(T, items.len);
    for (items, 0..) |item, i| {
        if (item != .object) return ParseError.Malformed;
        const name_v = item.object.get("IndexName") orelse return ParseError.Malformed;
        if (name_v != .string) return ParseError.Malformed;
        dynamo_state.validateAttributeName(name_v.string) catch return ParseError.InvalidName;
        const ks = try parseKeySchema(allocator, item.object.get("KeySchema") orelse return ParseError.Malformed);
        // Each index-key attribute must be in attribute_definitions.
        for (ks) |k| {
            var found = false;
            for (attr_defs) |a| if (std.mem.eql(u8, a.name, k.name)) {
                found = true;
                break;
            };
            if (!found) return ParseError.KeyReferencesUndeclaredAttribute;
        }
        const proj_v = item.object.get("Projection") orelse return ParseError.Malformed;
        const proj = try parseProjection(allocator, proj_v);
        out[i] = .{
            .name = try allocator.dupe(u8, name_v.string),
            .key_schema = ks,
            .projection = proj,
        };
    }
    return out;
}

fn parseProjection(allocator: Allocator, v: std.json.Value) ParseError!dynamo_state.Projection {
    if (v != .object) return ParseError.Malformed;
    const type_v = v.object.get("ProjectionType") orelse return ParseError.Malformed;
    if (type_v != .string) return ParseError.Malformed;
    const ptype = dynamo_state.ProjectionType.fromAws(type_v.string) orelse return ParseError.InvalidProjectionType;
    const nka: []const []const u8 = if (v.object.get("NonKeyAttributes")) |nv| blk: {
        if (nv != .array) return ParseError.Malformed;
        const items = nv.array.items;
        const out = try allocator.alloc([]const u8, items.len);
        for (items, 0..) |item, i| {
            if (item != .string) return ParseError.Malformed;
            out[i] = try allocator.dupe(u8, item.string);
        }
        break :blk out;
    } else try allocator.alloc([]const u8, 0);
    return .{ .type = ptype, .non_key_attributes = nka };
}

fn parseTags(allocator: Allocator, v: std.json.Value) ParseError![]const dynamo_state.Tag {
    if (v != .array) return ParseError.Malformed;
    const items = v.array.items;
    const out = try allocator.alloc(dynamo_state.Tag, items.len);
    for (items, 0..) |item, i| {
        if (item != .object) return ParseError.Malformed;
        const key_v = item.object.get("Key") orelse return ParseError.Malformed;
        const value_v = item.object.get("Value") orelse return ParseError.Malformed;
        if (key_v != .string or value_v != .string) return ParseError.Malformed;
        out[i] = .{
            .key = try allocator.dupe(u8, key_v.string),
            .value = try allocator.dupe(u8, value_v.string),
        };
    }
    return out;
}

// ---------------------------------------------------------------------------
// UpdateTable request

pub const UpdateTableRequest = struct {
    name: []const u8,
    billing_mode: ?dynamo_state.BillingMode = null,
};

pub fn parseUpdateTable(allocator: Allocator, body: []const u8) ParseError!UpdateTableRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;

    const name_v = root.get("TableName") orelse return ParseError.Malformed;
    if (name_v != .string) return ParseError.Malformed;
    const name = try allocator.dupe(u8, name_v.string);

    var billing_mode: ?dynamo_state.BillingMode = null;
    if (root.get("BillingMode")) |bv| {
        if (bv != .string) return ParseError.InvalidBillingMode;
        billing_mode = dynamo_state.BillingMode.fromAws(bv.string) orelse return ParseError.InvalidBillingMode;
    }
    return .{ .name = name, .billing_mode = billing_mode };
}

// ---------------------------------------------------------------------------
// ListTables request (paginated)

pub const ListTablesRequest = struct {
    limit: u32 = 100,
    exclusive_start_table_name: ?[]const u8 = null,
};

pub fn parseListTables(allocator: Allocator, body: []const u8) ParseError!ListTablesRequest {
    // ListTables accepts an empty body — boto3 sometimes sends "{}".
    if (body.len == 0) return .{};

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return ParseError.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return ParseError.Malformed;
    const root = parsed.value.object;

    var req: ListTablesRequest = .{};
    if (root.get("Limit")) |lv| switch (lv) {
        .integer => |n| {
            if (n < 1 or n > 100) return ParseError.Malformed;
            req.limit = @intCast(n);
        },
        else => return ParseError.Malformed,
    };
    if (root.get("ExclusiveStartTableName")) |sv| {
        if (sv != .string) return ParseError.Malformed;
        req.exclusive_start_table_name = try allocator.dupe(u8, sv.string);
    }
    return req;
}

// ---------------------------------------------------------------------------
// Responses

/// Render a `ListTables` response body. `next_token` is the
/// LastEvaluatedTableName cursor when more results remain.
pub fn renderListTables(
    allocator: Allocator,
    names: []const []const u8,
    next_token: ?[]const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("TableNames");
    try s.beginArray();
    for (names) |n| try s.write(n);
    try s.endArray();
    if (next_token) |t| {
        try s.objectField("LastEvaluatedTableName");
        try s.write(t);
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

/// Render a `{ "TableDescription": {...} }` body — used by CreateTable,
/// DeleteTable, UpdateTable. Mirrors most of DescribeTable but wrapped
/// in `TableDescription` instead of `Table`.
pub fn renderTableDescription(
    allocator: Allocator,
    slot: *const storage.TableSlot,
    wrapper_key: []const u8, // "Table" or "TableDescription"
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField(wrapper_key);
    try s.beginObject();

    try s.objectField("TableName");
    try s.write(slot.name);

    try s.objectField("TableStatus");
    try s.write("ACTIVE");

    try s.objectField("CreationDateTime");
    // AWS sends this as a float of unix seconds with millisecond precision.
    try s.print("{d}", .{@as(f64, @floatFromInt(slot.created_unix))});

    try s.objectField("KeySchema");
    try s.beginArray();
    for (slot.key_schema) |k| try writeKeyAttr(&s, k);
    try s.endArray();

    try s.objectField("AttributeDefinitions");
    try s.beginArray();
    for (slot.attribute_definitions) |a| {
        try s.beginObject();
        try s.objectField("AttributeName");
        try s.write(a.name);
        try s.objectField("AttributeType");
        try s.write(a.type.toAws());
        try s.endObject();
    }
    try s.endArray();

    try s.objectField("BillingModeSummary");
    try s.beginObject();
    try s.objectField("BillingMode");
    try s.write(slot.billing_mode.toAws());
    try s.endObject();

    try s.objectField("ItemCount");
    try s.write(0); // Phase 2 doesn't track items yet.

    try s.objectField("TableSizeBytes");
    try s.write(0);

    if (slot.global_secondary_indexes.len > 0) {
        try s.objectField("GlobalSecondaryIndexes");
        try s.beginArray();
        for (slot.global_secondary_indexes) |g| try writeIndex(&s, g.name, g.key_schema, g.projection);
        try s.endArray();
    }
    if (slot.local_secondary_indexes.len > 0) {
        try s.objectField("LocalSecondaryIndexes");
        try s.beginArray();
        for (slot.local_secondary_indexes) |l| try writeIndex(&s, l.name, l.key_schema, l.projection);
        try s.endArray();
    }

    try s.endObject(); // wrapper inner
    try s.endObject(); // root
    return aw.toOwnedSlice();
}

fn writeKeyAttr(s: *std.json.Stringify, k: dynamo_state.KeyAttribute) !void {
    try s.beginObject();
    try s.objectField("AttributeName");
    try s.write(k.name);
    try s.objectField("KeyType");
    try s.write(k.key_type.toAws());
    try s.endObject();
}

fn writeIndex(
    s: *std.json.Stringify,
    name: []const u8,
    key_schema: []const dynamo_state.KeyAttribute,
    projection: dynamo_state.Projection,
) !void {
    try s.beginObject();
    try s.objectField("IndexName");
    try s.write(name);
    try s.objectField("KeySchema");
    try s.beginArray();
    for (key_schema) |k| try writeKeyAttr(s, k);
    try s.endArray();
    try s.objectField("Projection");
    try s.beginObject();
    try s.objectField("ProjectionType");
    try s.write(projection.type.toAws());
    if (projection.non_key_attributes.len > 0) {
        try s.objectField("NonKeyAttributes");
        try s.beginArray();
        for (projection.non_key_attributes) |a| try s.write(a);
        try s.endArray();
    }
    try s.endObject();
    // ItemCount + IndexSizeBytes left out — synthetic anyway.
    try s.endObject();
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parseCreateTable: simple HASH key" {
    const body =
        \\{"TableName":"Music","KeySchema":[{"AttributeName":"Artist","KeyType":"HASH"}],
        \\"AttributeDefinitions":[{"AttributeName":"Artist","AttributeType":"S"}],
        \\"BillingMode":"PAY_PER_REQUEST"}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = try parseCreateTable(arena.allocator(), body);
    try testing.expectEqualStrings("Music", req.name);
    try testing.expectEqual(@as(usize, 1), req.key_schema.len);
    try testing.expectEqualStrings("Artist", req.key_schema[0].name);
    try testing.expectEqual(dynamo_state.KeyType.hash, req.key_schema[0].key_type);
    try testing.expectEqual(dynamo_state.BillingMode.pay_per_request, req.billing_mode);
}

test "parseCreateTable: HASH + RANGE" {
    const body =
        \\{"TableName":"Movies","KeySchema":[{"AttributeName":"pk","KeyType":"HASH"},{"AttributeName":"sk","KeyType":"RANGE"}],
        \\"AttributeDefinitions":[{"AttributeName":"pk","AttributeType":"S"},{"AttributeName":"sk","AttributeType":"N"}]}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = try parseCreateTable(arena.allocator(), body);
    try testing.expectEqual(@as(usize, 2), req.key_schema.len);
    try testing.expectEqual(dynamo_state.KeyType.hash, req.key_schema[0].key_type);
    try testing.expectEqual(dynamo_state.KeyType.range, req.key_schema[1].key_type);
}

test "parseCreateTable: rejects undeclared key attribute" {
    const body =
        \\{"TableName":"Movies","KeySchema":[{"AttributeName":"pk","KeyType":"HASH"}],
        \\"AttributeDefinitions":[{"AttributeName":"other","AttributeType":"S"}]}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ParseError.KeyReferencesUndeclaredAttribute, parseCreateTable(arena.allocator(), body));
}

test "parseCreateTable: rejects bad table name" {
    const body =
        \\{"TableName":"a","KeySchema":[{"AttributeName":"pk","KeyType":"HASH"}],
        \\"AttributeDefinitions":[{"AttributeName":"pk","AttributeType":"S"}]}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ParseError.InvalidName, parseCreateTable(arena.allocator(), body));
}

test "parseCreateTable: rejects key-schema with no HASH" {
    const body =
        \\{"TableName":"Movies","KeySchema":[{"AttributeName":"pk","KeyType":"RANGE"}],
        \\"AttributeDefinitions":[{"AttributeName":"pk","AttributeType":"S"}]}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ParseError.InvalidKeySchema, parseCreateTable(arena.allocator(), body));
}

test "parseCreateTable: rejects unknown ScalarType" {
    const body =
        \\{"TableName":"Music","KeySchema":[{"AttributeName":"pk","KeyType":"HASH"}],
        \\"AttributeDefinitions":[{"AttributeName":"pk","AttributeType":"SS"}]}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ParseError.InvalidScalarType, parseCreateTable(arena.allocator(), body));
}

test "parseListTables: empty body → defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = try parseListTables(arena.allocator(), "");
    try testing.expectEqual(@as(u32, 100), req.limit);
    try testing.expectEqual(@as(?[]const u8, null), req.exclusive_start_table_name);
}

test "parseListTables: Limit + ExclusiveStartTableName" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = try parseListTables(arena.allocator(),
        \\{"Limit":10,"ExclusiveStartTableName":"prev"}
    );
    try testing.expectEqual(@as(u32, 10), req.limit);
    try testing.expectEqualStrings("prev", req.exclusive_start_table_name.?);
}

test "renderListTables: empty + populated + with-cursor shapes" {
    const got_empty = try renderListTables(testing.allocator, &.{}, null);
    defer testing.allocator.free(got_empty);
    try testing.expectEqualStrings("{\"TableNames\":[]}", got_empty);

    const names = [_][]const u8{ "a", "b" };
    const got_two = try renderListTables(testing.allocator, &names, null);
    defer testing.allocator.free(got_two);
    try testing.expectEqualStrings("{\"TableNames\":[\"a\",\"b\"]}", got_two);

    const got_cursor = try renderListTables(testing.allocator, &names, "b");
    defer testing.allocator.free(got_cursor);
    try testing.expectEqualStrings("{\"TableNames\":[\"a\",\"b\"],\"LastEvaluatedTableName\":\"b\"}", got_cursor);
}
