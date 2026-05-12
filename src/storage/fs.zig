//! Filesystem storage backend.
//!
//! Layout (PRD §9):
//!   <base_dir>/s3/buckets.json                      -- bucket registry
//!   <base_dir>/s3/<bucket>/objects/<key-hash>/data
//!   <base_dir>/s3/<bucket>/objects/<key-hash>/meta.json
//!
//! M1 owns the registry; M3 fills the per-bucket `objects/` directory.
//! Each object lives in its own subdirectory keyed by `sha256(key)` (hex)
//! so we sidestep filesystem path constraints on the user-supplied key.
//! Both `data` and `meta.json` are written atomically (createFileAtomic +
//! replace), and the bucket's sorted in-memory key index is updated under
//! the same mutex.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const storage = @import("mod.zig");
const util = @import("util.zig");
const mem_backend = @import("mem.zig");

const Fs = @This();

const registry_version: u32 = 1;
const default_region = "us-east-1";

const BucketSlot = struct {
    meta: storage.Bucket,
    /// Sorted in-memory view of all keys present in this bucket. Mutated
    /// on every PutObject / DeleteObject so M4 ListObjects can read it
    /// directly without an FS walk.
    key_index: std.ArrayList([]const u8),

    fn deinit(self: *BucketSlot, gpa: Allocator) void {
        gpa.free(self.meta.name);
        gpa.free(self.meta.region);
        for (self.key_index.items) |k| gpa.free(k);
        self.key_index.deinit(gpa);
        self.* = undefined;
    }
};

allocator: Allocator,
io: Io,
base_dir: []u8,
mutex: Io.Mutex,
buckets: std.ArrayList(BucketSlot),

pub const InitError = error{
    OutOfMemory,
    Io,
};

pub fn init(allocator: Allocator, io: Io, base_dir: []const u8) InitError!*Fs {
    const self = try allocator.create(Fs);
    errdefer allocator.destroy(self);

    const base_owned = try allocator.dupe(u8, base_dir);
    errdefer allocator.free(base_owned);

    self.* = .{
        .allocator = allocator,
        .io = io,
        .base_dir = base_owned,
        .mutex = .init,
        .buckets = .empty,
    };

    ensureS3Dir(self) catch return InitError.Io;
    loadRegistry(self) catch return InitError.Io;
    return self;
}

pub fn deinit(self: *Fs) void {
    for (self.buckets.items) |*b| b.deinit(self.allocator);
    self.buckets.deinit(self.allocator);
    self.allocator.free(self.base_dir);
    self.allocator.destroy(self);
}

pub fn backend(self: *Fs) storage.Backend {
    return .{ .ctx = self, .vtable = &vtable };
}

// ---------------------------------------------------------------------------
// VTable thunks

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

pub fn createBucket(self: *Fs, name: []const u8) storage.Error!void {
    try util.validateBucketName(name);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    for (self.buckets.items) |b| {
        if (std.mem.eql(u8, b.meta.name, name)) return storage.Error.BucketAlreadyOwnedByYou;
    }

    var buf: [4096]u8 = undefined;
    const objects_path = std.fmt.bufPrint(&buf, "{s}/s3/{s}/objects", .{ self.base_dir, name }) catch return storage.Error.Io;
    Io.Dir.cwd().createDirPath(self.io, objects_path) catch return storage.Error.Io;

    const name_owned = self.allocator.dupe(u8, name) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(name_owned);
    const region_owned = self.allocator.dupe(u8, default_region) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(region_owned);

    self.buckets.append(self.allocator, .{
        .meta = .{
            .name = name_owned,
            .region = region_owned,
            .created_unix = nowUnixSeconds(self.io),
        },
        .key_index = .empty,
    }) catch return storage.Error.OutOfMemory;

    saveRegistry(self) catch return storage.Error.Io;
}

pub fn deleteBucket(self: *Fs, name: []const u8) storage.Error!void {
    try util.validateBucketName(name);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, name) orelse return storage.Error.NoSuchBucket;

    if (self.buckets.items[idx].key_index.items.len > 0) return storage.Error.BucketNotEmpty;

    var buf: [4096]u8 = undefined;
    const bucket_path = std.fmt.bufPrint(&buf, "{s}/s3/{s}", .{ self.base_dir, name }) catch return storage.Error.Io;
    Io.Dir.cwd().deleteTree(self.io, bucket_path) catch return storage.Error.Io;

    var removed = self.buckets.orderedRemove(idx);
    removed.deinit(self.allocator);

    saveRegistry(self) catch return storage.Error.Io;
}

pub fn headBucket(self: *Fs, name: []const u8) storage.Error!void {
    try util.validateBucketName(name);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (findBucket(self, name) == null) return storage.Error.NoSuchBucket;
}

pub fn listBuckets(self: *Fs, allocator: Allocator) storage.Error![]storage.Bucket {
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

pub fn putObject(self: *Fs, in: storage.PutObjectInput) storage.Error!storage.PutObjectOutput {
    try storage.validateObjectKey(in.key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];

    const etag = mem_backend.computeEtag(self.allocator, in.body) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(etag);

    // Ensure the per-key dir exists.
    const hash = keyHash(in.key);
    var dir_buf: [4096]u8 = undefined;
    const key_dir = std.fmt.bufPrint(&dir_buf, "{s}/s3/{s}/objects/{s}", .{ self.base_dir, in.bucket, &hash }) catch return storage.Error.Io;
    Io.Dir.cwd().createDirPath(self.io, key_dir) catch return storage.Error.Io;

    // 1. Atomically write data.
    var data_buf: [4096]u8 = undefined;
    const data_path = std.fmt.bufPrint(&data_buf, "{s}/data", .{key_dir}) catch return storage.Error.Io;
    writeAtomic(self.io, data_path, in.body) catch return storage.Error.Io;

    // 2. Atomically write meta.json.
    const meta_doc = MetaDoc{
        .key = in.key,
        .size = in.body.len,
        .etag = etag,
        .content_type = in.content_type,
        .last_modified_unix = nowUnixSeconds(self.io),
        .user_metadata = in.user_metadata,
    };
    var meta_buf: [4096]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_buf, "{s}/meta.json", .{key_dir}) catch return storage.Error.Io;
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    std.json.fmt(meta_doc, .{}).format(&aw.writer) catch return storage.Error.Io;
    writeAtomic(self.io, meta_path, aw.written()) catch return storage.Error.Io;

    // 3. Insert into the sorted key index (only if new).
    if (!keyIndexContains(slot, in.key)) {
        const owned = self.allocator.dupe(u8, in.key) catch return storage.Error.OutOfMemory;
        errdefer self.allocator.free(owned);
        const pos = std.sort.upperBound([]const u8, slot.key_index.items, in.key, orderSlices);
        slot.key_index.insert(self.allocator, pos, owned) catch return storage.Error.OutOfMemory;
    }

    // Return etag owned by caller's allocator? — caller already saw it via the
    // backend response; we hand back a copy that the caller frees. The slot
    // doesn't retain `etag` (it's reloaded from meta.json on head/get).
    return .{ .etag = etag };
}

pub fn getObject(self: *Fs, allocator: Allocator, bucket: []const u8, key: []const u8) storage.Error!storage.GetObjectOutput {
    try storage.validateObjectKey(key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    _ = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const meta = readMeta(self, allocator, bucket, key) catch |err| switch (err) {
        error.FileNotFound => return storage.Error.NoSuchKey,
        else => return storage.Error.Io,
    };

    const hash = keyHash(key);
    var path_buf: [4096]u8 = undefined;
    const data_path = std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/objects/{s}/data", .{ self.base_dir, bucket, &hash }) catch return storage.Error.Io;
    const body = Io.Dir.cwd().readFileAlloc(self.io, data_path, allocator, .limited(5 * 1024 * 1024 * 1024)) catch return storage.Error.Io;
    return .{ .meta = meta, .body = body };
}

pub fn headObject(self: *Fs, allocator: Allocator, bucket: []const u8, key: []const u8) storage.Error!storage.Object {
    try storage.validateObjectKey(key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    _ = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    return readMeta(self, allocator, bucket, key) catch |err| switch (err) {
        error.FileNotFound => storage.Error.NoSuchKey,
        else => storage.Error.Io,
    };
}

pub fn listObjects(self: *Fs, allocator: Allocator, in: storage.ListObjectsInput) storage.Error!storage.ListObjectsOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    var contents: std.ArrayList(storage.Object) = .empty;
    errdefer {
        for (contents.items) |o| freeObjectMetaOwned(allocator, o);
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
        if (in.start_after.len > 0 and (std.mem.lessThan(u8, k, in.start_after) or std.mem.eql(u8, k, in.start_after))) continue;
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
        // Lazy-load per-key metadata from disk. Skip missing files silently
        // (the index is the source of truth for "key exists"; missing meta
        // is a stale-index bug that we'd rather not crash on).
        const obj = readMeta(self, allocator, in.bucket, k) catch continue;
        contents.append(allocator, obj) catch {
            freeObjectMetaOwned(allocator, obj);
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

fn freeObjectMetaOwned(gpa: Allocator, o: storage.Object) void {
    gpa.free(o.key);
    gpa.free(o.etag);
    gpa.free(o.content_type);
    for (o.user_metadata) |h| {
        gpa.free(h.name);
        gpa.free(h.value);
    }
    gpa.free(o.user_metadata);
}

pub fn deleteObject(self: *Fs, bucket: []const u8, key: []const u8) storage.Error!void {
    try storage.validateObjectKey(key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];

    const hash = keyHash(key);
    var path_buf: [4096]u8 = undefined;
    const key_dir = std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/objects/{s}", .{ self.base_dir, bucket, &hash }) catch return storage.Error.Io;
    // deleteTree is already idempotent on a missing path.
    Io.Dir.cwd().deleteTree(self.io, key_dir) catch return storage.Error.Io;

    // Remove from sorted index.
    for (slot.key_index.items, 0..) |k, i| {
        if (std.mem.eql(u8, k, key)) {
            self.allocator.free(slot.key_index.orderedRemove(i));
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// Internals

pub fn nowUnixSeconds(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
}

fn findBucket(self: *Fs, name: []const u8) ?usize {
    for (self.buckets.items, 0..) |b, i| {
        if (std.mem.eql(u8, b.meta.name, name)) return i;
    }
    return null;
}

fn keyIndexContains(slot: *const BucketSlot, key: []const u8) bool {
    for (slot.key_index.items) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

fn orderSlices(key: []const u8, item: []const u8) std.math.Order {
    return std.mem.order(u8, key, item);
}

fn keyHash(key: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(key, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn writeAtomic(io: Io, path: []const u8, body: []const u8) !void {
    var af = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer af.deinit(io);
    var buf: [4096]u8 = undefined;
    var fw = af.file.writer(io, &buf);
    try fw.interface.writeAll(body);
    try fw.interface.flush();
    try af.replace(io);
}

fn ensureS3Dir(self: *Fs) !void {
    var buf: [4096]u8 = undefined;
    const s3_path = try std.fmt.bufPrint(&buf, "{s}/s3", .{self.base_dir});
    try Io.Dir.cwd().createDirPath(self.io, s3_path);
}

fn registryPath(self: *Fs, buf: []u8) ![]u8 {
    return try std.fmt.bufPrint(buf, "{s}/s3/buckets.json", .{self.base_dir});
}

const RegistryDoc = struct {
    version: u32,
    buckets: []BucketRecord,
};

const BucketRecord = struct {
    name: []const u8,
    region: []const u8,
    created_unix: i64,
};

const MetaDoc = struct {
    key: []const u8,
    size: usize,
    etag: []const u8,
    content_type: []const u8,
    last_modified_unix: i64,
    user_metadata: []const storage.Header,
};

fn loadRegistry(self: *Fs) !void {
    var buf: [4096]u8 = undefined;
    const path = try registryPath(self, &buf);

    const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer self.allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(RegistryDoc, self.allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    for (parsed.value.buckets) |rec| {
        const name_owned = try self.allocator.dupe(u8, rec.name);
        errdefer self.allocator.free(name_owned);
        const region_owned = try self.allocator.dupe(u8, rec.region);
        errdefer self.allocator.free(region_owned);
        var slot: BucketSlot = .{
            .meta = .{
                .name = name_owned,
                .region = region_owned,
                .created_unix = rec.created_unix,
            },
            .key_index = .empty,
        };
        // Walk objects/ to rebuild the in-memory key index from meta.json files.
        try rebuildKeyIndex(self, &slot);
        try self.buckets.append(self.allocator, slot);
    }
}

fn rebuildKeyIndex(self: *Fs, slot: *BucketSlot) !void {
    var buf: [4096]u8 = undefined;
    const objects_path = try std.fmt.bufPrint(&buf, "{s}/s3/{s}/objects", .{ self.base_dir, slot.meta.name });
    var dir = Io.Dir.cwd().openDir(self.io, objects_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(self.io);

    var it = dir.iterate();
    while (try it.next(self.io)) |entry| {
        if (entry.kind != .directory) continue;
        var path_buf: [4096]u8 = undefined;
        const meta_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/meta.json", .{ objects_path, entry.name });
        const meta_bytes = Io.Dir.cwd().readFileAlloc(self.io, meta_path, self.allocator, .limited(4 * 1024 * 1024)) catch continue;
        defer self.allocator.free(meta_bytes);

        var parsed = std.json.parseFromSlice(struct { key: []const u8 }, self.allocator, meta_bytes, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        const key_owned = try self.allocator.dupe(u8, parsed.value.key);
        try slot.key_index.append(self.allocator, key_owned);
    }

    std.mem.sort([]const u8, slot.key_index.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
}

fn readMeta(self: *Fs, allocator: Allocator, bucket: []const u8, key: []const u8) !storage.Object {
    const hash = keyHash(key);
    var path_buf: [4096]u8 = undefined;
    const meta_path = try std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/objects/{s}/meta.json", .{ self.base_dir, bucket, &hash });
    const bytes = try Io.Dir.cwd().readFileAlloc(self.io, meta_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(MetaDoc, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const value = parsed.value;
    var headers = try allocator.alloc(storage.Header, value.user_metadata.len);
    errdefer allocator.free(headers);
    for (value.user_metadata, 0..) |h, i| {
        headers[i] = .{
            .name = try allocator.dupe(u8, h.name),
            .value = try allocator.dupe(u8, h.value),
        };
    }

    return .{
        .key = try allocator.dupe(u8, value.key),
        .size = @intCast(value.size),
        .etag = try allocator.dupe(u8, value.etag),
        .content_type = try allocator.dupe(u8, value.content_type),
        .last_modified_unix = value.last_modified_unix,
        .user_metadata = headers,
    };
}

fn saveRegistry(self: *Fs) !void {
    var path_buf: [4096]u8 = undefined;
    const path = try registryPath(self, &path_buf);

    var records = try self.allocator.alloc(BucketRecord, self.buckets.items.len);
    defer self.allocator.free(records);
    for (self.buckets.items, 0..) |b, i| {
        records[i] = .{ .name = b.meta.name, .region = b.meta.region, .created_unix = b.meta.created_unix };
    }
    const doc: RegistryDoc = .{ .version = registry_version, .buckets = records };

    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    try std.json.fmt(doc, .{ .whitespace = .indent_2 }).format(&aw.writer);
    try writeAtomic(self.io, path, aw.written());
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn newTestFs(tmp: *std.testing.TmpDir) !*Fs {
    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &buf);
    return try Fs.init(testing.allocator, testing.io, buf[0..len]);
}

fn freeObjectMeta(obj: storage.Object) void {
    testing.allocator.free(obj.key);
    testing.allocator.free(obj.etag);
    testing.allocator.free(obj.content_type);
    for (obj.user_metadata) |h| {
        testing.allocator.free(h.name);
        testing.allocator.free(h.value);
    }
    testing.allocator.free(obj.user_metadata);
}

test "fs: create + head + list + delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fs = try newTestFs(&tmp);
    defer fs.deinit();

    try fs.createBucket("alpha");
    try fs.headBucket("alpha");

    const buckets = try fs.listBuckets(testing.allocator);
    defer {
        for (buckets) |b| {
            testing.allocator.free(b.name);
            testing.allocator.free(b.region);
        }
        testing.allocator.free(buckets);
    }
    try testing.expectEqual(@as(usize, 1), buckets.len);
    try testing.expectEqualStrings("alpha", buckets[0].name);
    try testing.expectEqualStrings(default_region, buckets[0].region);

    try fs.deleteBucket("alpha");
    try testing.expectError(storage.Error.NoSuchBucket, fs.headBucket("alpha"));
}

test "fs: createBucket validates name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fs = try newTestFs(&tmp);
    defer fs.deinit();
    try testing.expectError(storage.Error.InvalidBucketName, fs.createBucket("Bad_Name"));
}

test "fs: duplicate create returns BucketAlreadyOwnedByYou" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fs = try newTestFs(&tmp);
    defer fs.deinit();
    try fs.createBucket("dupes");
    try testing.expectError(storage.Error.BucketAlreadyOwnedByYou, fs.createBucket("dupes"));
}

test "fs: delete missing returns NoSuchBucket" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fs = try newTestFs(&tmp);
    defer fs.deinit();
    try testing.expectError(storage.Error.NoSuchBucket, fs.deleteBucket("ghost"));
}

test "fs: registry survives reopen + key index rebuild" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &buf);
    const path = buf[0..len];

    {
        var fs1 = try Fs.init(testing.allocator, testing.io, path);
        defer fs1.deinit();
        try fs1.createBucket("persist-me");
        const out = try fs1.putObject(.{
            .bucket = "persist-me",
            .key = "alpha",
            .body = "v1",
            .content_type = "text/plain",
        });
        testing.allocator.free(out.etag);
    }
    {
        var fs2 = try Fs.init(testing.allocator, testing.io, path);
        defer fs2.deinit();
        try fs2.headBucket("persist-me");
        const idx = findBucket(fs2, "persist-me").?;
        try testing.expectEqual(@as(usize, 1), fs2.buckets.items[idx].key_index.items.len);
        try testing.expectEqualStrings("alpha", fs2.buckets.items[idx].key_index.items[0]);
    }
}

test "fs: put + head + get + delete object" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fs = try newTestFs(&tmp);
    defer fs.deinit();

    try fs.createBucket("bkt");
    const out = try fs.putObject(.{
        .bucket = "bkt",
        .key = "hello.txt",
        .body = "hello world",
        .content_type = "text/plain",
    });
    testing.allocator.free(out.etag);

    {
        const meta = try fs.headObject(testing.allocator, "bkt", "hello.txt");
        defer freeObjectMeta(meta);
        try testing.expectEqual(@as(u64, "hello world".len), meta.size);
        try testing.expectEqualStrings("text/plain", meta.content_type);
    }

    {
        const got = try fs.getObject(testing.allocator, "bkt", "hello.txt");
        defer {
            testing.allocator.free(got.body);
            freeObjectMeta(got.meta);
        }
        try testing.expectEqualStrings("hello world", got.body);
    }

    try fs.deleteObject("bkt", "hello.txt");
    try testing.expectError(storage.Error.NoSuchKey, fs.headObject(testing.allocator, "bkt", "hello.txt"));
    try fs.deleteObject("bkt", "hello.txt"); // idempotent
}

test "fs: deleteBucket with object → BucketNotEmpty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fs = try newTestFs(&tmp);
    defer fs.deinit();
    try fs.createBucket("bkt");
    const out = try fs.putObject(.{ .bucket = "bkt", .key = "k", .body = "v", .content_type = "text/plain" });
    testing.allocator.free(out.etag);
    try testing.expectError(storage.Error.BucketNotEmpty, fs.deleteBucket("bkt"));
}
