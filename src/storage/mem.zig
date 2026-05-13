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

const StoredPart = struct {
    body: []u8,
    etag: []u8, // quoted MD5
    last_modified_unix: i64,

    fn deinit(self: *StoredPart, gpa: Allocator) void {
        gpa.free(self.body);
        gpa.free(self.etag);
        self.* = undefined;
    }
};

const MultipartState = struct {
    key: []u8,
    content_type: []u8,
    user_metadata: []storage.Header,
    initiated_unix: i64,
    parts: std.AutoHashMap(u32, StoredPart),

    fn deinit(self: *MultipartState, gpa: Allocator) void {
        gpa.free(self.key);
        gpa.free(self.content_type);
        for (self.user_metadata) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(self.user_metadata);
        var it = self.parts.iterator();
        while (it.next()) |entry| {
            var p = entry.value_ptr.*;
            p.deinit(gpa);
        }
        self.parts.deinit();
        self.* = undefined;
    }
};

const BucketSlot = struct {
    meta: storage.Bucket,
    objects: std.StringHashMap(StoredObject),
    /// Sorted view of `objects` keys for M4 ListObjects + DeleteObjects.
    key_index: std.ArrayList([]const u8),
    /// Keyed by upload_id (owned). M6.
    uploads: std.StringHashMap(MultipartState),

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
        var uit = self.uploads.iterator();
        while (uit.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            var st = entry.value_ptr.*;
            st.deinit(gpa);
        }
        self.uploads.deinit();
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
    .initiateMultipartUpload = vtInitiateMultipartUpload,
    .uploadPart = vtUploadPart,
    .completeMultipartUpload = vtCompleteMultipartUpload,
    .abortMultipartUpload = vtAbortMultipartUpload,
    .listMultipartUploads = vtListMultipartUploads,
    .listParts = vtListParts,
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
fn vtInitiateMultipartUpload(ctx: *anyopaque, allocator: Allocator, in: storage.InitiateMultipartUploadInput) storage.Error!storage.InitiateMultipartUploadOutput {
    return initiateMultipartUpload(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtUploadPart(ctx: *anyopaque, in: storage.UploadPartInput) storage.Error!storage.UploadPartOutput {
    return uploadPart(@ptrCast(@alignCast(ctx)), in);
}
fn vtCompleteMultipartUpload(ctx: *anyopaque, allocator: Allocator, in: storage.CompleteMultipartUploadInput) storage.Error!storage.CompleteMultipartUploadOutput {
    return completeMultipartUpload(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtAbortMultipartUpload(ctx: *anyopaque, bucket: []const u8, key: []const u8, upload_id: []const u8) storage.Error!void {
    return abortMultipartUpload(@ptrCast(@alignCast(ctx)), bucket, key, upload_id);
}
fn vtListMultipartUploads(ctx: *anyopaque, allocator: Allocator, in: storage.ListMultipartUploadsInput) storage.Error!storage.ListMultipartUploadsOutput {
    return listMultipartUploads(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtListParts(ctx: *anyopaque, allocator: Allocator, in: storage.ListPartsInput) storage.Error!storage.ListPartsOutput {
    return listParts(@ptrCast(@alignCast(ctx)), allocator, in);
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
        .uploads = std.StringHashMap(MultipartState).init(self.allocator),
    }) catch return storage.Error.OutOfMemory;
}

pub fn deleteBucket(self: *Mem, name: []const u8) storage.Error!void {
    try util.validateBucketName(name);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, name) orelse return storage.Error.NoSuchBucket;
    if (self.buckets.items[idx].objects.count() > 0) return storage.Error.BucketNotEmpty;
    if (self.buckets.items[idx].uploads.count() > 0) return storage.Error.BucketNotEmpty;
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

/// AWS-style multipart ETag: `"<hex>-N"` where the hex is MD5 of the
/// *concatenated binary* MD5 digests of each part (not their hex form).
pub fn computeMultipartEtag(allocator: Allocator, part_digests: []const [16]u8, part_count: u32) ![]u8 {
    // Concat the raw 16-byte digests.
    const concat = try allocator.alloc(u8, part_digests.len * 16);
    defer allocator.free(concat);
    for (part_digests, 0..) |d, i| @memcpy(concat[i * 16 .. (i + 1) * 16], &d);
    var digest: [16]u8 = undefined;
    Md5.hash(concat, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "\"{s}-{d}\"", .{ hex, part_count });
}

// ---------------------------------------------------------------------------
// Multipart upload (M6)

pub fn initiateMultipartUpload(self: *Mem, allocator: Allocator, in: storage.InitiateMultipartUploadInput) storage.Error!storage.InitiateMultipartUploadOutput {
    try storage.validateObjectKey(in.key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];

    const upload_id = newUploadId(self.io, allocator) catch return storage.Error.OutOfMemory;
    errdefer allocator.free(upload_id);

    const key_owned = self.allocator.dupe(u8, in.key) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(key_owned);
    const ct_owned = self.allocator.dupe(u8, in.content_type) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(ct_owned);
    const meta_owned = dupeHeaders(self.allocator, in.user_metadata) catch return storage.Error.OutOfMemory;
    errdefer freeHeaders(self.allocator, meta_owned);

    const state: MultipartState = .{
        .key = key_owned,
        .content_type = ct_owned,
        .user_metadata = meta_owned,
        .initiated_unix = fs.nowUnixSeconds(self.io),
        .parts = std.AutoHashMap(u32, StoredPart).init(self.allocator),
    };

    const id_for_map = self.allocator.dupe(u8, upload_id) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(id_for_map);
    slot.uploads.put(id_for_map, state) catch return storage.Error.OutOfMemory;

    return .{ .upload_id = upload_id };
}

pub fn uploadPart(self: *Mem, in: storage.UploadPartInput) storage.Error!storage.UploadPartOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    var state = slot.uploads.getPtr(in.upload_id) orelse return storage.Error.NoSuchUpload;

    const etag = computeEtag(self.allocator, in.body) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(etag);
    const body_copy = self.allocator.dupe(u8, in.body) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(body_copy);

    // Overwrite an earlier upload of the same part_number (S3 allows this).
    if (state.parts.fetchRemove(in.part_number)) |kv| {
        var old = kv.value;
        old.deinit(self.allocator);
    }

    state.parts.put(in.part_number, .{
        .body = body_copy,
        .etag = etag,
        .last_modified_unix = fs.nowUnixSeconds(self.io),
    }) catch return storage.Error.OutOfMemory;

    // Return an ETag slice the caller owns separately so the stored copy
    // isn't freed when they free it. Dup it.
    const ret_etag = self.allocator.dupe(u8, etag) catch return storage.Error.OutOfMemory;
    return .{ .etag = ret_etag };
}

pub fn completeMultipartUpload(self: *Mem, allocator: Allocator, in: storage.CompleteMultipartUploadInput) storage.Error!storage.CompleteMultipartUploadOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    const entry = slot.uploads.getEntry(in.upload_id) orelse return storage.Error.NoSuchUpload;
    const state = entry.value_ptr;

    // Validate every requested part exists with the claimed etag.
    var total_size: usize = 0;
    for (in.parts) |p| {
        const stored = state.parts.get(p.part_number) orelse return storage.Error.NoSuchUpload;
        if (!std.mem.eql(u8, stored.etag, p.etag)) return storage.Error.NoSuchUpload;
        total_size += stored.body.len;
    }

    // Concatenate part bodies in the order given.
    const body = self.allocator.alloc(u8, total_size) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(body);
    var off: usize = 0;
    var digests = self.allocator.alloc([16]u8, in.parts.len) catch return storage.Error.OutOfMemory;
    defer self.allocator.free(digests);
    for (in.parts, 0..) |p, i| {
        const stored = state.parts.get(p.part_number).?;
        @memcpy(body[off .. off + stored.body.len], stored.body);
        off += stored.body.len;
        // Re-hash the part for the multipart-etag computation. Cheaper
        // than parsing the hex back out of stored.etag.
        Md5.hash(stored.body, &digests[i], .{});
    }

    const final_etag = computeMultipartEtag(self.allocator, digests, @intCast(in.parts.len)) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(final_etag);

    // Capture the upload's content_type + user_metadata for the new object,
    // then dispose of the upload state.
    const ct_owned = self.allocator.dupe(u8, state.content_type) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(ct_owned);
    const meta_owned = dupeHeaders(self.allocator, state.user_metadata) catch return storage.Error.OutOfMemory;
    errdefer freeHeaders(self.allocator, meta_owned);

    const stored: StoredObject = .{
        .body = body,
        .content_type = ct_owned,
        .etag = final_etag,
        .last_modified_unix = fs.nowUnixSeconds(self.io),
        .user_metadata = meta_owned,
    };

    // Overwrite if the key exists, otherwise insert into the sorted index.
    if (slot.objects.fetchRemove(state.key)) |kv| {
        self.allocator.free(kv.key);
        var old = kv.value;
        old.deinit(self.allocator);
    } else {
        const key_for_index = self.allocator.dupe(u8, state.key) catch return storage.Error.OutOfMemory;
        errdefer self.allocator.free(key_for_index);
        const pos = std.sort.upperBound([]const u8, slot.key_index.items, state.key, orderSlices);
        slot.key_index.insert(self.allocator, pos, key_for_index) catch return storage.Error.OutOfMemory;
    }

    const map_key = self.allocator.dupe(u8, state.key) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(map_key);
    slot.objects.put(map_key, stored) catch return storage.Error.OutOfMemory;

    // Delete the upload state.
    const id_owned = entry.key_ptr.*;
    var state_copy = entry.value_ptr.*;
    _ = slot.uploads.remove(in.upload_id);
    self.allocator.free(id_owned);
    state_copy.deinit(self.allocator);

    // Return an etag owned by the caller's allocator (the request arena).
    return .{ .etag = allocator.dupe(u8, final_etag) catch return storage.Error.OutOfMemory };
}

pub fn abortMultipartUpload(self: *Mem, bucket: []const u8, key: []const u8, upload_id: []const u8) storage.Error!void {
    _ = key;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    if (slot.uploads.fetchRemove(upload_id)) |kv| {
        self.allocator.free(kv.key);
        var st = kv.value;
        st.deinit(self.allocator);
        return;
    }
    return storage.Error.NoSuchUpload;
}

pub fn listMultipartUploads(self: *Mem, allocator: Allocator, in: storage.ListMultipartUploadsInput) storage.Error!storage.ListMultipartUploadsOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    // Snapshot uploads sorted by (key, upload_id).
    var rows: std.ArrayList(struct { id: []const u8, key: []const u8, initiated_unix: i64 }) = .empty;
    defer rows.deinit(allocator);
    var it = slot.uploads.iterator();
    while (it.next()) |entry| {
        rows.append(allocator, .{
            .id = entry.key_ptr.*,
            .key = entry.value_ptr.key,
            .initiated_unix = entry.value_ptr.initiated_unix,
        }) catch return storage.Error.OutOfMemory;
    }
    const Row = @TypeOf(rows.items[0]);
    std.mem.sort(Row, rows.items, {}, struct {
        fn lessThan(_: void, a: Row, b: Row) bool {
            const ord = std.mem.order(u8, a.key, b.key);
            if (ord != .eq) return ord == .lt;
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lessThan);

    var uploads: std.ArrayList(storage.MultipartUploadInfo) = .empty;
    errdefer {
        for (uploads.items) |u| {
            allocator.free(u.key);
            allocator.free(u.upload_id);
        }
        uploads.deinit(allocator);
    }
    var prefixes: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (prefixes.items) |p| allocator.free(p);
        prefixes.deinit(allocator);
    }

    var truncated = false;
    var last_key: []const u8 = "";
    var last_id: []const u8 = "";
    const limit: usize = if (in.max_uploads > 1000) 1000 else in.max_uploads;

    var i: usize = 0;
    while (i < rows.items.len) : (i += 1) {
        const row = rows.items[i];
        // Pagination: skip everything ≤ (key_marker, upload_id_marker).
        if (in.key_marker.len > 0) {
            const cmp = std.mem.order(u8, row.key, in.key_marker);
            if (cmp == .lt) continue;
            if (cmp == .eq) {
                // Same key — must be strictly greater upload_id_marker.
                if (in.upload_id_marker.len == 0) continue;
                if (!std.mem.lessThan(u8, in.upload_id_marker, row.id)) continue;
            }
        }
        if (in.prefix.len > 0 and !std.mem.startsWith(u8, row.key, in.prefix)) continue;

        if (in.delimiter.len > 0) {
            const after = row.key[in.prefix.len..];
            if (std.mem.indexOf(u8, after, in.delimiter)) |off| {
                const cp_end = in.prefix.len + off + in.delimiter.len;
                const cp = row.key[0..cp_end];
                // De-dupe consecutive common prefixes.
                if (prefixes.items.len == 0 or !std.mem.eql(u8, prefixes.items[prefixes.items.len - 1], cp)) {
                    if (uploads.items.len + prefixes.items.len >= limit) {
                        truncated = true;
                        break;
                    }
                    const owned = allocator.dupe(u8, cp) catch return storage.Error.OutOfMemory;
                    prefixes.append(allocator, owned) catch {
                        allocator.free(owned);
                        return storage.Error.OutOfMemory;
                    };
                    last_key = row.key;
                    last_id = row.id;
                }
                continue;
            }
        }

        if (uploads.items.len + prefixes.items.len >= limit) {
            truncated = true;
            break;
        }
        const k_dup = allocator.dupe(u8, row.key) catch return storage.Error.OutOfMemory;
        const id_dup = allocator.dupe(u8, row.id) catch {
            allocator.free(k_dup);
            return storage.Error.OutOfMemory;
        };
        uploads.append(allocator, .{
            .key = k_dup,
            .upload_id = id_dup,
            .initiated_unix = row.initiated_unix,
        }) catch {
            allocator.free(k_dup);
            allocator.free(id_dup);
            return storage.Error.OutOfMemory;
        };
        last_key = row.key;
        last_id = row.id;
    }

    const next_key: []const u8 = if (truncated) (allocator.dupe(u8, last_key) catch return storage.Error.OutOfMemory) else "";
    const next_id: []const u8 = if (truncated) (allocator.dupe(u8, last_id) catch return storage.Error.OutOfMemory) else "";

    return .{
        .uploads = uploads.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory,
        .common_prefixes = prefixes.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory,
        .is_truncated = truncated,
        .next_key_marker = next_key,
        .next_upload_id_marker = next_id,
    };
}

pub fn listParts(self: *Mem, allocator: Allocator, in: storage.ListPartsInput) storage.Error!storage.ListPartsOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];
    const state = slot.uploads.get(in.upload_id) orelse return storage.Error.NoSuchUpload;

    // Snapshot part_numbers sorted ascending.
    var nums: std.ArrayList(u32) = .empty;
    defer nums.deinit(allocator);
    var it = state.parts.iterator();
    while (it.next()) |entry| nums.append(allocator, entry.key_ptr.*) catch return storage.Error.OutOfMemory;
    std.mem.sort(u32, nums.items, {}, std.sort.asc(u32));

    var out: std.ArrayList(storage.PartInfo) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p.etag);
        out.deinit(allocator);
    }
    var truncated = false;
    var last: u32 = 0;
    const limit: usize = if (in.max_parts > 1000) 1000 else in.max_parts;

    for (nums.items) |n| {
        if (n <= in.part_number_marker) continue;
        if (out.items.len >= limit) {
            truncated = true;
            break;
        }
        const stored = state.parts.get(n).?;
        const etag_dup = allocator.dupe(u8, stored.etag) catch return storage.Error.OutOfMemory;
        out.append(allocator, .{
            .part_number = n,
            .size = stored.body.len,
            .etag = etag_dup,
            .last_modified_unix = stored.last_modified_unix,
        }) catch {
            allocator.free(etag_dup);
            return storage.Error.OutOfMemory;
        };
        last = n;
    }

    return .{
        .parts = out.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory,
        .is_truncated = truncated,
        .next_part_number_marker = if (truncated) last else 0,
    };
}

/// Generate a 22-char base64-url-no-pad upload id from 16 random bytes.
fn newUploadId(io: Io, allocator: Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    io.random(&raw);
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(raw.len));
    _ = enc.encode(out, &raw);
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
