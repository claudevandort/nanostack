//! In-memory DynamoDB state managed by `Fs` (M15).
//!
//! Each table has a `TableSlot` carrying the schema metadata + an
//! `items` map. Items persist at
//! `<data_dir>/profiles/<profile>/dynamodb/tables/<name>/items/<key_hash>.json`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const attribute_value = @import("../wire/dynamodb/attribute_value.zig");
const dynamo_streams = @import("dynamo_streams.zig");
pub const AttributeValue = attribute_value.AttributeValue;
pub const Stream = dynamo_streams.Stream;

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

/// DynamoDB Streams view-type, controls what each StreamRecord carries.
pub const StreamViewType = enum {
    new_image,
    old_image,
    new_and_old_images,
    keys_only,

    pub fn toAws(self: StreamViewType) []const u8 {
        return switch (self) {
            .new_image => "NEW_IMAGE",
            .old_image => "OLD_IMAGE",
            .new_and_old_images => "NEW_AND_OLD_IMAGES",
            .keys_only => "KEYS_ONLY",
        };
    }

    pub fn fromAws(s: []const u8) ?StreamViewType {
        if (std.mem.eql(u8, s, "NEW_IMAGE")) return .new_image;
        if (std.mem.eql(u8, s, "OLD_IMAGE")) return .old_image;
        if (std.mem.eql(u8, s, "NEW_AND_OLD_IMAGES")) return .new_and_old_images;
        if (std.mem.eql(u8, s, "KEYS_ONLY")) return .keys_only;
        return null;
    }
};

/// StreamSpecification on a table. AWS allows `StreamEnabled=false` with
/// or without a view-type; when `enabled=true` the view-type is required
/// (default `NEW_AND_OLD_IMAGES`).
pub const StreamSpecification = struct {
    enabled: bool,
    view_type: StreamViewType,
};

/// DynamoDB TTL status. AWS shows ENABLING / DISABLING transient states
/// for ~1h while the change propagates; nanostack snaps directly to the
/// terminal state (documented divergence).
pub const TimeToLiveStatus = enum {
    enabling,
    enabled,
    disabling,
    disabled,

    pub fn toAws(self: TimeToLiveStatus) []const u8 {
        return switch (self) {
            .enabling => "ENABLING",
            .enabled => "ENABLED",
            .disabling => "DISABLING",
            .disabled => "DISABLED",
        };
    }
};

/// Persisted TTL config on a table. When `status == .enabled`, the
/// background sweeper evicts items whose `attribute_name` is a Number
/// attribute ≤ wall-clock unix seconds. Wrong-type or missing
/// attributes are ignored per AWS semantics.
pub const TimeToLiveSpec = struct {
    status: TimeToLiveStatus,
    /// Owned by the parent `TableSlot`'s allocator. Non-empty when
    /// `status ∈ {.enabling, .enabled}`; empty string allowed when
    /// disabled (matches the spec being cleared on disable).
    attribute_name: []const u8,
};

/// PITR (point-in-time recovery) status. AWS shows ENABLED / DISABLED
/// only; we snap to terminal state (no ENABLING/DISABLING transients).
pub const PitrStatus = enum {
    enabled,
    disabled,

    pub fn toAws(self: PitrStatus) []const u8 {
        return switch (self) {
            .enabled => "ENABLED",
            .disabled => "DISABLED",
        };
    }
};

/// Continuous backups (PITR) config. Default = disabled.
pub const ContinuousBackupSpec = struct {
    /// Whether PITR is enabled. Continuous-backups-as-a-feature is
    /// always reported as ENABLED to clients (matches AWS — the
    /// feature is on at the account level); only the PITR sub-status
    /// reflects this field.
    pitr_status: PitrStatus = .disabled,
    /// Wall-clock unix seconds when PITR was last enabled. null when
    /// never enabled. Used to compute `EarliestRestorableDateTime`.
    enabled_unix: ?i64 = null,
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

/// Deep-clone an `Item` into the given allocator. Companion to
/// `Item.deinit` — every allocation here must have a matching free
/// there.
pub fn cloneItem(allocator: Allocator, src: *const Item) !Item {
    const names = try allocator.alloc([]const u8, src.names.len);
    var names_done: usize = 0;
    errdefer {
        for (names[0..names_done]) |n| allocator.free(n);
        allocator.free(names);
    }
    for (src.names, 0..) |n, i| {
        names[i] = try allocator.dupe(u8, n);
        names_done = i + 1;
    }

    const values = try allocator.alloc(AttributeValue, src.values.len);
    var values_done: usize = 0;
    errdefer {
        for (values[0..values_done]) |*v| {
            var copy = v.*;
            attribute_value.deinit(allocator, &copy);
        }
        allocator.free(values);
    }
    for (src.values, 0..) |v, i| {
        values[i] = try attribute_value.cloneValue(allocator, v);
        values_done = i + 1;
    }
    return .{ .names = names, .values = values };
}

/// Project an Item down to only its key attributes (as defined by the
/// table's KeySchema). The returned Item owns its slices via the given
/// allocator; freeing is via `Item.deinit`.
pub fn projectKeys(allocator: Allocator, slot: *const TableSlot, src: *const Item) !Item {
    const names = try allocator.alloc([]const u8, slot.key_schema.len);
    var names_done: usize = 0;
    errdefer {
        for (names[0..names_done]) |n| allocator.free(n);
        allocator.free(names);
    }
    const values = try allocator.alloc(AttributeValue, slot.key_schema.len);
    var values_done: usize = 0;
    errdefer {
        for (values[0..values_done]) |*v| {
            var copy = v.*;
            attribute_value.deinit(allocator, &copy);
        }
        allocator.free(values);
    }
    for (slot.key_schema, 0..) |k, i| {
        const src_v = src.attributeValue(k.name) orelse return error.MissingKey;
        names[i] = try allocator.dupe(u8, k.name);
        names_done = i + 1;
        values[i] = try attribute_value.cloneValue(allocator, src_v.*);
        values_done = i + 1;
    }
    return .{ .names = names, .values = values };
}

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
    /// Streams config + the wall-clock time the spec was last set.
    /// `stream_enabled_unix` is null when streams were never enabled;
    /// non-null even after a disable so the latest label/ARN can still
    /// be derived. DescribeTable only emits LatestStreamLabel / ARN
    /// when `stream_spec != null and stream_spec.enabled`.
    stream_spec: ?StreamSpecification = null,
    stream_enabled_unix: ?i64 = null,
    /// In-memory streams ring buffer. Allocated when streams are first
    /// enabled; freed when disabled or the table is deleted. Records
    /// are lost on restart (Phase 2 design — see dynamo_streams.zig).
    stream: ?*Stream = null,
    /// TTL config (v0.2.3). Null when never configured. The background
    /// sweeper in fs.zig consults this on each tick.
    ttl_spec: ?TimeToLiveSpec = null,
    /// PITR config (v0.2.5). Defaults to "disabled".
    continuous_backup: ContinuousBackupSpec = .{},
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
        if (self.stream) |stream| {
            stream.deinit();
            allocator.destroy(stream);
        }
        if (self.ttl_spec) |spec| {
            allocator.free(spec.attribute_name);
        }
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

test "TimeToLiveStatus.toAws" {
    try testing.expectEqualStrings("ENABLED", TimeToLiveStatus.enabled.toAws());
    try testing.expectEqualStrings("DISABLED", TimeToLiveStatus.disabled.toAws());
    try testing.expectEqualStrings("ENABLING", TimeToLiveStatus.enabling.toAws());
    try testing.expectEqualStrings("DISABLING", TimeToLiveStatus.disabling.toAws());
}

test "StreamViewType.fromAws / toAws round-trip" {
    try testing.expectEqual(StreamViewType.new_image, StreamViewType.fromAws("NEW_IMAGE").?);
    try testing.expectEqual(StreamViewType.old_image, StreamViewType.fromAws("OLD_IMAGE").?);
    try testing.expectEqual(StreamViewType.new_and_old_images, StreamViewType.fromAws("NEW_AND_OLD_IMAGES").?);
    try testing.expectEqual(StreamViewType.keys_only, StreamViewType.fromAws("KEYS_ONLY").?);
    try testing.expectEqual(@as(?StreamViewType, null), StreamViewType.fromAws("OTHER"));
    try testing.expectEqualStrings("NEW_AND_OLD_IMAGES", StreamViewType.new_and_old_images.toAws());
}

test "ProjectionType.fromAws" {
    try testing.expectEqual(ProjectionType.all, ProjectionType.fromAws("ALL").?);
    try testing.expectEqual(ProjectionType.keys_only, ProjectionType.fromAws("KEYS_ONLY").?);
    try testing.expectEqual(ProjectionType.include, ProjectionType.fromAws("INCLUDE").?);
    try testing.expectEqual(@as(?ProjectionType, null), ProjectionType.fromAws("BOGUS"));
}
