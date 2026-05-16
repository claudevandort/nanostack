//! In-memory DynamoDB state managed by `Fs` (M15).
//!
//! Each table has a `TableSlot` carrying the schema metadata + an
//! `items` map. Items persist at
//! `<data_dir>/profiles/<profile>/dynamodb/tables/<name>/items/<key_hash>.json`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const attribute_value = @import("../wire/dynamodb/attribute_value.zig");
pub const AttributeValue = attribute_value.AttributeValue;

pub const KeyType = enum {
    hash,
    range,

    pub fn toAws(self: KeyType) []const u8 {
        return switch (self) {
            .hash => "HASH",
            .range => "RANGE",
        };
    }

    pub fn fromAws(s: []const u8) ?KeyType {
        if (std.mem.eql(u8, s, "HASH")) return .hash;
        if (std.mem.eql(u8, s, "RANGE")) return .range;
        return null;
    }
};

/// Scalar attribute types — the only ones AWS allows on key columns.
/// (Document types like M/L/SS exist but can't be keys.)
pub const ScalarType = enum {
    string,
    number,
    binary,

    pub fn toAws(self: ScalarType) []const u8 {
        return switch (self) {
            .string => "S",
            .number => "N",
            .binary => "B",
        };
    }

    pub fn fromAws(s: []const u8) ?ScalarType {
        if (s.len != 1) return null;
        return switch (s[0]) {
            'S' => .string,
            'N' => .number,
            'B' => .binary,
            else => null,
        };
    }
};

pub const ProjectionType = enum {
    all,
    keys_only,
    include,

    pub fn toAws(self: ProjectionType) []const u8 {
        return switch (self) {
            .all => "ALL",
            .keys_only => "KEYS_ONLY",
            .include => "INCLUDE",
        };
    }

    pub fn fromAws(s: []const u8) ?ProjectionType {
        if (std.mem.eql(u8, s, "ALL")) return .all;
        if (std.mem.eql(u8, s, "KEYS_ONLY")) return .keys_only;
        if (std.mem.eql(u8, s, "INCLUDE")) return .include;
        return null;
    }
};

pub const BillingMode = enum {
    provisioned,
    pay_per_request,

    pub fn toAws(self: BillingMode) []const u8 {
        return switch (self) {
            .provisioned => "PROVISIONED",
            .pay_per_request => "PAY_PER_REQUEST",
        };
    }

    pub fn fromAws(s: []const u8) ?BillingMode {
        if (std.mem.eql(u8, s, "PROVISIONED")) return .provisioned;
        if (std.mem.eql(u8, s, "PAY_PER_REQUEST")) return .pay_per_request;
        return null;
    }
};

/// One entry in a `KeySchema` list. AWS keys are exactly 1 HASH or
/// (1 HASH + 1 RANGE); the validator enforces that on Put.
pub const KeyAttribute = struct {
    name: []const u8,
    key_type: KeyType,
};

pub const AttributeDef = struct {
    name: []const u8,
    type: ScalarType,
};

pub const Projection = struct {
    type: ProjectionType,
    /// Only populated when `type == .include`. Owned by the slot's allocator.
    non_key_attributes: []const []const u8 = &.{},
};

pub const GsiDef = struct {
    name: []const u8,
    key_schema: []const KeyAttribute,
    projection: Projection,
};

pub const LsiDef = struct {
    name: []const u8,
    key_schema: []const KeyAttribute,
    projection: Projection,
};

pub const Tag = struct {
    key: []const u8,
    value: []const u8,
};

/// One DynamoDB item — a map of attribute name → AttributeValue. The
/// names array preserves insertion order; lookups go through
/// `attributeValue()`.
pub const Item = struct {
    names: []const []const u8,
    values: []AttributeValue,

    pub fn attributeValue(self: *const Item, name: []const u8) ?*const AttributeValue {
        for (self.names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return &self.values[i];
        }
        return null;
    }

    pub fn deinit(self: *Item, allocator: Allocator) void {
        for (self.names) |n| allocator.free(n);
        allocator.free(self.names);
        for (self.values) |*v| {
            var copy = v.*;
            attribute_value.deinit(allocator, &copy);
        }
        allocator.free(self.values);
    }
};

/// One DynamoDB table's persisted state. Strings + slices live in the
/// `Fs.allocator` long-lived arena and are freed via `deinit`.
pub const TableSlot = struct {
    name: []const u8,
    key_schema: []const KeyAttribute,
    attribute_definitions: []const AttributeDef,
    billing_mode: BillingMode = .pay_per_request,
    global_secondary_indexes: []const GsiDef = &.{},
    local_secondary_indexes: []const LsiDef = &.{},
    tags: []const Tag = &.{},
    created_unix: i64,
    /// In-memory item store, keyed on a stable composite "<pk>|<sk?>"
    /// string. Populated by ddbPutItem on every write and rebuilt on
    /// startup by walking the items/ directory.
    items: std.StringHashMapUnmanaged(*Item) = .empty,

    pub fn deinit(self: *TableSlot, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.key_schema) |k| allocator.free(k.name);
        allocator.free(self.key_schema);
        for (self.attribute_definitions) |a| allocator.free(a.name);
        allocator.free(self.attribute_definitions);
        for (self.global_secondary_indexes) |g| freeIndex(allocator, g.name, g.key_schema, g.projection);
        allocator.free(self.global_secondary_indexes);
        for (self.local_secondary_indexes) |l| freeIndex(allocator, l.name, l.key_schema, l.projection);
        allocator.free(self.local_secondary_indexes);
        for (self.tags) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
        allocator.free(self.tags);
        var it = self.items.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
            allocator.destroy(entry.value_ptr.*);
        }
        self.items.deinit(allocator);
    }

    fn freeIndex(allocator: Allocator, name: []const u8, key_schema: []const KeyAttribute, projection: Projection) void {
        allocator.free(name);
        for (key_schema) |k| allocator.free(k.name);
        allocator.free(key_schema);
        for (projection.non_key_attributes) |a| allocator.free(a);
        allocator.free(projection.non_key_attributes);
    }

    /// Convenience: look up the partition key attribute.
    pub fn partitionKey(self: *const TableSlot) KeyAttribute {
        for (self.key_schema) |k| if (k.key_type == .hash) return k;
        unreachable; // validated on insert
    }

    /// Convenience: look up the sort key attribute (or null if absent).
    pub fn sortKey(self: *const TableSlot) ?KeyAttribute {
        for (self.key_schema) |k| if (k.key_type == .range) return k;
        return null;
    }

    /// Find the declared `ScalarType` for an attribute name, or null if
    /// the name isn't in `attribute_definitions`.
    pub fn attributeType(self: *const TableSlot, name: []const u8) ?ScalarType {
        for (self.attribute_definitions) |a| if (std.mem.eql(u8, a.name, name)) return a.type;
        return null;
    }
};

// ---------------------------------------------------------------------------
// Table name validation
//
// AWS rules (per the DynamoDB docs):
//   - 3-255 characters
//   - allowed chars: a-z, A-Z, 0-9, underscore, hyphen, period
//   - case-sensitive
//
// We enforce the same. The error path is mapped to `ValidationException`
// by the service layer.

pub const ValidateNameError = error{InvalidTableName};

pub fn validateTableName(name: []const u8) ValidateNameError!void {
    if (name.len < 3 or name.len > 255) return error.InvalidTableName;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
        if (!ok) return error.InvalidTableName;
    }
}

/// AWS attribute names: 1-65535 bytes of UTF-8.
pub fn validateAttributeName(name: []const u8) ValidateNameError!void {
    if (name.len == 0 or name.len > 65535) return error.InvalidTableName;
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidTableName;
}

// ---------------------------------------------------------------------------
// Composite-key helpers
//
// Maps need a stable string key per (PK, SK) pair. We serialise the key
// attribute values as `<type>:<value>` separated by `|`. Type-tagging
// the bytes ensures e.g. {"S":"42"} and {"N":"42"} don't collide.

pub const KeyError = error{
    MissingKey, // item is missing a key attribute declared on the table
    InvalidKeyType, // key attribute is not a scalar S/N/B
    OutOfMemory,
};

/// Build a composite key string from an item's key attributes against
/// the slot's KeySchema. Caller owns the returned slice.
pub fn buildItemKey(allocator: Allocator, slot: *const TableSlot, item: *const Item) KeyError![]u8 {
    const pk = slot.partitionKey();
    const pk_val = item.attributeValue(pk.name) orelse return error.MissingKey;
    const pk_part = try encodeKeyPart(allocator, pk_val);
    defer allocator.free(pk_part);

    if (slot.sortKey()) |sk| {
        const sk_val = item.attributeValue(sk.name) orelse return error.MissingKey;
        const sk_part = try encodeKeyPart(allocator, sk_val);
        defer allocator.free(sk_part);
        return std.fmt.allocPrint(allocator, "{s}|{s}", .{ pk_part, sk_part }) catch return error.OutOfMemory;
    }
    return allocator.dupe(u8, pk_part) catch return error.OutOfMemory;
}

/// Build a composite key from explicit key attribute values (used by
/// GetItem / DeleteItem where the Item shape carries only the keys).
pub fn buildKeyFromAttrs(
    allocator: Allocator,
    slot: *const TableSlot,
    key_attrs: *const Item,
) KeyError![]u8 {
    return buildItemKey(allocator, slot, key_attrs);
}

fn encodeKeyPart(allocator: Allocator, v: *const AttributeValue) KeyError![]u8 {
    return switch (v.*) {
        .s => |s| std.fmt.allocPrint(allocator, "S:{s}", .{s}) catch error.OutOfMemory,
        .n => |s| std.fmt.allocPrint(allocator, "N:{s}", .{s}) catch error.OutOfMemory,
        .b => |bytes| blk: {
            // Hex-encode binary to keep the key string ASCII-safe.
            const out = allocator.alloc(u8, 2 + bytes.len * 2) catch return error.OutOfMemory;
            out[0] = 'B';
            out[1] = ':';
            const hex = "0123456789abcdef";
            for (bytes, 0..) |b, i| {
                out[2 + i * 2] = hex[(b >> 4) & 0xF];
                out[2 + i * 2 + 1] = hex[b & 0xF];
            }
            break :blk out;
        },
        else => error.InvalidKeyType,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "validateTableName: shapes" {
    try validateTableName("abc");
    try validateTableName("a-table.1_x");
    try testing.expectError(error.InvalidTableName, validateTableName(""));
    try testing.expectError(error.InvalidTableName, validateTableName("ab"));
    try testing.expectError(error.InvalidTableName, validateTableName("has space"));
    try testing.expectError(error.InvalidTableName, validateTableName("emoji-🚀"));
}

test "ScalarType.fromAws / toAws round-trip" {
    try testing.expectEqual(ScalarType.string, ScalarType.fromAws("S").?);
    try testing.expectEqual(ScalarType.number, ScalarType.fromAws("N").?);
    try testing.expectEqual(ScalarType.binary, ScalarType.fromAws("B").?);
    try testing.expectEqual(@as(?ScalarType, null), ScalarType.fromAws("X"));
    try testing.expectEqual(@as(?ScalarType, null), ScalarType.fromAws("SS"));
    try testing.expectEqualStrings("S", ScalarType.string.toAws());
}

test "KeyType.fromAws / toAws round-trip" {
    try testing.expectEqual(KeyType.hash, KeyType.fromAws("HASH").?);
    try testing.expectEqual(KeyType.range, KeyType.fromAws("RANGE").?);
    try testing.expectEqual(@as(?KeyType, null), KeyType.fromAws("hash")); // case-sensitive
}

test "ProjectionType.fromAws" {
    try testing.expectEqual(ProjectionType.all, ProjectionType.fromAws("ALL").?);
    try testing.expectEqual(ProjectionType.keys_only, ProjectionType.fromAws("KEYS_ONLY").?);
    try testing.expectEqual(ProjectionType.include, ProjectionType.fromAws("INCLUDE").?);
    try testing.expectEqual(@as(?ProjectionType, null), ProjectionType.fromAws("BOGUS"));
}
