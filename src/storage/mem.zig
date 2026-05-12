//! In-memory storage backend (`--ephemeral`).
//!
//! Same contract as `fs.zig`. State lives in process memory and is lost
//! on exit. M3 adds object support: each bucket holds a string-keyed
//! `Object` map plus a sorted key index (kept sorted for ListObjects in M4).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Md5 = std.crypto.hash.Md5;

const storage = @import("mod.zig");
const util = @import("util.zig");
const fs = @import("fs.zig");

const Mem = @This();

allocator: Allocator,
io: Io,
mutex: Io.Mutex,
buckets: std.ArrayList(BucketSlot),

const StoredObject = struct {
    body: []u8,
    content_type: []u8,
    etag: []u8, // includes surrounding quotes
    last_modified_unix: i64,
    user_metadata: []storage.Header,

    fn deinit(self: *StoredObject, gpa: Allocator) void {
        gpa.free(self.body);
        gpa.free(self.content_type);
        gpa.free(self.etag);
        for (self.user_metadata) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(self.user_metadata);
        self.* = undefined;
    }
};

const BucketSlot = struct {
    meta: storage.Bucket,
    objects: std.StringHashMap(StoredObject),
    /// Sorted view of `objects` keys for M4 ListObjects + DeleteObjects.
    key_index: std.ArrayList([]const u8),

    fn deinit(self: *BucketSlot, gpa: Allocator) void {
        gpa.free(self.meta.name);
        gpa.free(self.meta.region);
        var it = self.objects.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            var obj = entry.value_ptr.*;
            obj.deinit(gpa);
        }
        self.objects.deinit();
        for (self.key_index.items) |k| gpa.free(k);
        self.key_index.deinit(gpa);
        self.* = undefined;
    }
};

pub fn init(allocator: Allocator, io: Io) !*Mem {
    const self = try allocator.create(Mem);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .mutex = .init,
        .buckets = .empty,
    };
    return self;
}

pub fn deinit(self: *Mem) void {
    for (self.buckets.items) |*b| b.deinit(self.allocator);
    self.buckets.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn backend(self: *Mem) storage.Backend {
    return .{ .ctx = self, .vtable = &vtable };
}

const vtable: storage.Backend.VTable = .{
    .createBucket = vtCreateBucket,
    .deleteBucket = vtDeleteBucket,
    .headBucket = vtHeadBucket,
    .listBuckets = vtListBuckets,
    .putObject = vtPutObject,
    .getObject = vtGetObject,
    .headObject = vtHeadObject,
    .deleteObject = vtDeleteObject,
    .listObjects = vtListObjects,
};

fn vtCreateBucket(ctx: *anyopaque, name: []const u8) storage.Error!void {
    return createBucket(@ptrCast(@alignCast(ctx)), name);
}
fn vtDeleteBucket(ctx: *anyopaque, name: []const u8) storage.Error!void {
    return deleteBucket(@ptrCast(@alignCast(ctx)), name);
}
fn vtHeadBucket(ctx: *anyopaque, name: []const u8) storage.Error!void {
    return headBucket(@ptrCast(@alignCast(ctx)), name);
}
fn vtListBuckets(ctx: *anyopaque, allocator: Allocator) storage.Error![]storage.Bucket {
    return listBuckets(@ptrCast(@alignCast(ctx)), allocator);
}
fn vtPutObject(ctx: *anyopaque, in: storage.PutObjectInput) storage.Error!storage.PutObjectOutput {
    return putObject(@ptrCast(@alignCast(ctx)), in);
}
fn vtGetObject(ctx: *anyopaque, allocator: Allocator, bucket: []const u8, key: []const u8) storage.Error!storage.GetObjectOutput {
    return getObject(@ptrCast(@alignCast(ctx)), allocator, bucket, key);
}
fn vtHeadObject(ctx: *anyopaque, allocator: Allocator, bucket: []const u8, key: []const u8) storage.Error!storage.Object {
    return headObject(@ptrCast(@alignCast(ctx)), allocator, bucket, key);
}
fn vtDeleteObject(ctx: *anyopaque, bucket: []const u8, key: []const u8) storage.Error!void {
    return deleteObject(@ptrCast(@alignCast(ctx)), bucket, key);
}
fn vtListObjects(ctx: *anyopaque, allocator: Allocator, in: storage.ListObjectsInput) storage.Error!storage.ListObjectsOutput {
    return listObjects(@ptrCast(@alignCast(ctx)), allocator, in);
}

// ---------------------------------------------------------------------------
// Bucket ops

pub fn createBucket(self: *Mem, name: []const u8) storage.Error!void {
    try util.validateBucketName(name);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    for (self.buckets.items) |b| {
        if (std.mem.eql(u8, b.meta.name, name)) return storage.Error.BucketAlreadyOwnedByYou;
    }

    const name_owned = self.allocator.dupe(u8, name) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(name_owned);
    const region_owned = self.allocator.dupe(u8, "us-east-1") catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(region_owned);

    self.buckets.append(self.allocator, .{
        .meta = .{
            .name = name_owned,
            .region = region_owned,
            .created_unix = fs.nowUnixSeconds(self.io),
        },
        .objects = std.StringHashMap(StoredObject).init(self.allocator),
        .key_index = .empty,
    }) catch return storage.Error.OutOfMemory;
}

pub fn deleteBucket(self: *Mem, name: []const u8) storage.Error!void {
    try util.validateBucketName(name);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, name) orelse return storage.Error.NoSuchBucket;
    if (self.buckets.items[idx].objects.count() > 0) return storage.Error.BucketNotEmpty;
    var removed = self.buckets.orderedRemove(idx);
    removed.deinit(self.allocator);
}

pub fn headBucket(self: *Mem, name: []const u8) storage.Error!void {
    try util.validateBucketName(name);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (findBucket(self, name) == null) return storage.Error.NoSuchBucket;
}

pub fn listBuckets(self: *Mem, allocator: Allocator) storage.Error![]storage.Bucket {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var out = allocator.alloc(storage.Bucket, self.buckets.items.len) catch return storage.Error.OutOfMemory;
    errdefer allocator.free(out);
    for (self.buckets.items, 0..) |b, i| {
        out[i] = .{
            .name = allocator.dupe(u8, b.meta.name) catch return storage.Error.OutOfMemory,
            .region = allocator.dupe(u8, b.meta.region) catch return storage.Error.OutOfMemory,
            .created_unix = b.meta.created_unix,
        };
    }
    return out;
}

// ---------------------------------------------------------------------------
// Object ops

pub fn putObject(self: *Mem, in: storage.PutObjectInput) storage.Error!storage.PutObjectOutput {
    try storage.validateObjectKey(in.key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];

    const etag = computeEtag(self.allocator, in.body) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(etag);
    const body_copy = self.allocator.dupe(u8, in.body) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(body_copy);
    const ct_copy = self.allocator.dupe(u8, in.content_type) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(ct_copy);
    const meta_copy = dupeHeaders(self.allocator, in.user_metadata) catch return storage.Error.OutOfMemory;
    errdefer freeHeaders(self.allocator, meta_copy);

    const stored: StoredObject = .{
        .body = body_copy,
        .content_type = ct_copy,
        .etag = etag,
        .last_modified_unix = fs.nowUnixSeconds(self.io),
        .user_metadata = meta_copy,
    };

    // Overwrite if the key exists.
    if (slot.objects.fetchRemove(in.key)) |kv| {
        self.allocator.free(kv.key);
        var old = kv.value;
        old.deinit(self.allocator);
        // Key was already in the index — keep it.
    } else {
        // New key: insert into sorted index.
        const key_for_index = self.allocator.dupe(u8, in.key) catch return storage.Error.OutOfMemory;
        errdefer self.allocator.free(key_for_index);
        const pos = std.sort.upperBound([]const u8, slot.key_index.items, in.key, orderSlices);
        slot.key_index.insert(self.allocator, pos, key_for_index) catch return storage.Error.OutOfMemory;
    }

    const map_key = self.allocator.dupe(u8, in.key) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(map_key);
    slot.objects.put(map_key, stored) catch return storage.Error.OutOfMemory;

    return .{ .etag = etag };
}

pub fn getObject(self: *Mem, allocator: Allocator, bucket: []const u8, key: []const u8) storage.Error!storage.GetObjectOutput {
    try storage.validateObjectKey(key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const obj = self.buckets.items[idx].objects.get(key) orelse return storage.Error.NoSuchKey;

    return .{
        .meta = try cloneObjectMeta(allocator, key, obj),
        .body = allocator.dupe(u8, obj.body) catch return storage.Error.OutOfMemory,
    };
}

pub fn headObject(self: *Mem, allocator: Allocator, bucket: []const u8, key: []const u8) storage.Error!storage.Object {
    try storage.validateObjectKey(key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const obj = self.buckets.items[idx].objects.get(key) orelse return storage.Error.NoSuchKey;
    return cloneObjectMeta(allocator, key, obj);
}

pub fn listObjects(self: *Mem, allocator: Allocator, in: storage.ListObjectsInput) storage.Error!storage.ListObjectsOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    var contents: std.ArrayList(storage.Object) = .empty;
    errdefer {
        for (contents.items) |o| freeObjectMeta(allocator, o);
        contents.deinit(allocator);
    }
    var prefixes: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (prefixes.items) |p| allocator.free(p);
        prefixes.deinit(allocator);
    }

    var i: usize = 0;
    var last_key: []const u8 = "";
    var truncated = false;
    const limit: usize = if (in.max_keys > 1000) 1000 else in.max_keys;

    while (i < slot.key_index.items.len) : (i += 1) {
        const k = slot.key_index.items[i];
        if (in.start_after.len > 0 and std.mem.lessThan(u8, k, in.start_after) or (in.start_after.len > 0 and std.mem.eql(u8, k, in.start_after))) {
            continue;
        }
        if (in.prefix.len > 0 and !std.mem.startsWith(u8, k, in.prefix)) continue;

        if (in.delimiter.len > 0) {
            const after = k[in.prefix.len..];
            if (std.mem.indexOf(u8, after, in.delimiter)) |off| {
                const cp_end = in.prefix.len + off + in.delimiter.len;
                const cp = k[0..cp_end];
                if (contents.items.len + prefixes.items.len >= limit) {
                    truncated = true;
                    break;
                }
                const owned = allocator.dupe(u8, cp) catch return storage.Error.OutOfMemory;
                prefixes.append(allocator, owned) catch {
                    allocator.free(owned);
                    return storage.Error.OutOfMemory;
                };
                last_key = k;
                // Skip all subsequent keys sharing this common prefix.
                while (i + 1 < slot.key_index.items.len and std.mem.startsWith(u8, slot.key_index.items[i + 1], cp)) : (i += 1) {
                    last_key = slot.key_index.items[i + 1];
                }
                continue;
            }
        }

        if (contents.items.len + prefixes.items.len >= limit) {
            truncated = true;
            break;
        }
        const obj = slot.objects.get(k) orelse continue;
        const cloned = cloneObjectMeta(allocator, k, obj) catch return storage.Error.OutOfMemory;
        contents.append(allocator, cloned) catch {
            freeObjectMeta(allocator, cloned);
            return storage.Error.OutOfMemory;
        };
        last_key = k;
    }

    const next_key_owned: []const u8 = if (truncated) blk: {
        break :blk allocator.dupe(u8, last_key) catch return storage.Error.OutOfMemory;
    } else "";

    return .{
        .contents = contents.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory,
        .common_prefixes = prefixes.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory,
        .is_truncated = truncated,
        .next_key = next_key_owned,
    };
}

fn freeObjectMeta(gpa: Allocator, o: storage.Object) void {
    gpa.free(o.key);
    gpa.free(o.etag);
    gpa.free(o.content_type);
    for (o.user_metadata) |h| {
        gpa.free(h.name);
        gpa.free(h.value);
    }
    gpa.free(o.user_metadata);
}

pub fn deleteObject(self: *Mem, bucket: []const u8, key: []const u8) storage.Error!void {
    try storage.validateObjectKey(key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    if (slot.objects.fetchRemove(key)) |kv| {
        self.allocator.free(kv.key);
        var old = kv.value;
        old.deinit(self.allocator);
        // Remove from sorted index.
        for (slot.key_index.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                self.allocator.free(slot.key_index.orderedRemove(i));
                break;
            }
        }
    }
    // Idempotent: missing key is not an error per AWS semantics.
}

// ---------------------------------------------------------------------------
// Internals

fn findBucket(self: *Mem, name: []const u8) ?usize {
    for (self.buckets.items, 0..) |b, i| {
        if (std.mem.eql(u8, b.meta.name, name)) return i;
    }
    return null;
}

fn orderSlices(key: []const u8, item: []const u8) std.math.Order {
    return std.mem.order(u8, key, item);
}

fn cloneObjectMeta(allocator: Allocator, key: []const u8, obj: StoredObject) storage.Error!storage.Object {
    return .{
        .key = allocator.dupe(u8, key) catch return storage.Error.OutOfMemory,
        .size = obj.body.len,
        .etag = allocator.dupe(u8, obj.etag) catch return storage.Error.OutOfMemory,
        .content_type = allocator.dupe(u8, obj.content_type) catch return storage.Error.OutOfMemory,
        .last_modified_unix = obj.last_modified_unix,
        .user_metadata = dupeHeaders(allocator, obj.user_metadata) catch return storage.Error.OutOfMemory,
    };
}

fn dupeHeaders(allocator: Allocator, src: []const storage.Header) ![]storage.Header {
    const out = try allocator.alloc(storage.Header, src.len);
    errdefer allocator.free(out);
    var made: usize = 0;
    errdefer for (out[0..made]) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    };
    for (src) |h| {
        out[made] = .{
            .name = try allocator.dupe(u8, h.name),
            .value = try allocator.dupe(u8, h.value),
        };
        made += 1;
    }
    return out;
}

fn freeHeaders(allocator: Allocator, hs: []storage.Header) void {
    for (hs) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    allocator.free(hs);
}

/// Compute `"<md5-hex>"` (double-quoted) for the body. Caller owns.
pub fn computeEtag(allocator: Allocator, body: []const u8) ![]u8 {
    var digest: [16]u8 = undefined;
    Md5.hash(body, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var out = try allocator.alloc(u8, hex.len + 2);
    out[0] = '"';
    @memcpy(out[1 .. 1 + hex.len], &hex);
    out[out.len - 1] = '"';
    return out;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "mem: bucket lifecycle still works" {
    var m = try Mem.init(testing.allocator, testing.io);
    defer m.deinit();
    try m.createBucket("alpha");
    try m.headBucket("alpha");
    try m.deleteBucket("alpha");
    try testing.expectError(storage.Error.NoSuchBucket, m.headBucket("alpha"));
}

test "mem: put + head + get + delete object" {
    var m = try Mem.init(testing.allocator, testing.io);
    defer m.deinit();
    try m.createBucket("bkt");

    const out = try m.putObject(.{
        .bucket = "bkt",
        .key = "hello.txt",
        .body = "hello world",
        .content_type = "text/plain",
    });
    try testing.expect(std.mem.startsWith(u8, out.etag, "\""));

    {
        const meta = try m.headObject(testing.allocator, "bkt", "hello.txt");
        defer {
            testing.allocator.free(meta.key);
            testing.allocator.free(meta.etag);
            testing.allocator.free(meta.content_type);
            for (meta.user_metadata) |h| {
                testing.allocator.free(h.name);
                testing.allocator.free(h.value);
            }
            testing.allocator.free(meta.user_metadata);
        }
        try testing.expectEqual(@as(u64, "hello world".len), meta.size);
        try testing.expectEqualStrings("text/plain", meta.content_type);
    }

    {
        const got = try m.getObject(testing.allocator, "bkt", "hello.txt");
        defer {
            testing.allocator.free(got.body);
            testing.allocator.free(got.meta.key);
            testing.allocator.free(got.meta.etag);
            testing.allocator.free(got.meta.content_type);
            for (got.meta.user_metadata) |h| {
                testing.allocator.free(h.name);
                testing.allocator.free(h.value);
            }
            testing.allocator.free(got.meta.user_metadata);
        }
        try testing.expectEqualStrings("hello world", got.body);
    }

    try m.deleteObject("bkt", "hello.txt");
    try testing.expectError(storage.Error.NoSuchKey, m.headObject(testing.allocator, "bkt", "hello.txt"));
    // Idempotent delete.
    try m.deleteObject("bkt", "hello.txt");
}

test "mem: put overwrite returns new etag, key index stays length 1" {
    var m = try Mem.init(testing.allocator, testing.io);
    defer m.deinit();
    try m.createBucket("bkt");

    const a = try m.putObject(.{ .bucket = "bkt", .key = "k", .body = "v1", .content_type = "text/plain" });
    const b = try m.putObject(.{ .bucket = "bkt", .key = "k", .body = "v2-different", .content_type = "text/plain" });
    try testing.expect(!std.mem.eql(u8, a.etag, b.etag));

    const idx = findBucket(m, "bkt").?;
    try testing.expectEqual(@as(usize, 1), m.buckets.items[idx].key_index.items.len);
}

test "mem: put on missing bucket → NoSuchBucket" {
    var m = try Mem.init(testing.allocator, testing.io);
    defer m.deinit();
    try testing.expectError(storage.Error.NoSuchBucket, m.putObject(.{
        .bucket = "no-such",
        .key = "k",
        .body = "",
        .content_type = "application/octet-stream",
    }));
}

test "mem: deleteBucket with object → BucketNotEmpty" {
    var m = try Mem.init(testing.allocator, testing.io);
    defer m.deinit();
    try m.createBucket("bkt");
    _ = try m.putObject(.{ .bucket = "bkt", .key = "k", .body = "v", .content_type = "text/plain" });
    try testing.expectError(storage.Error.BucketNotEmpty, m.deleteBucket("bkt"));
}

test "computeEtag: known MD5 of 'hello'" {
    const etag = try computeEtag(testing.allocator, "hello");
    defer testing.allocator.free(etag);
    try testing.expectEqualStrings("\"5d41402abc4b2a76b9719d911017c592\"", etag);
}
