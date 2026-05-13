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
const etag_mod = @import("etag.zig");

const Fs = @This();

const registry_version: u32 = 1;
const default_region = "us-east-1";

const PartMeta = struct {
    part_number: u32,
    size: u64,
    etag: []u8, // quoted MD5
    last_modified_unix: i64,
};

const MultipartState = struct {
    key: []u8,
    content_type: []u8,
    user_metadata: []storage.Header,
    initiated_unix: i64,
    parts: std.AutoHashMap(u32, PartMeta),

    fn deinit(self: *MultipartState, gpa: Allocator) void {
        gpa.free(self.key);
        gpa.free(self.content_type);
        for (self.user_metadata) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(self.user_metadata);
        var it = self.parts.iterator();
        while (it.next()) |entry| gpa.free(entry.value_ptr.etag);
        self.parts.deinit();
        self.* = undefined;
    }
};

/// One entry in a versioned key's chain. M8.
const VersionEntry = struct {
    version_id: []u8, // owned by backend allocator
    is_delete_marker: bool,
    etag: []u8, // includes surrounding quotes; empty for delete markers
    size: u64,
    content_type: []u8, // empty for delete markers
    last_modified_unix: i64,
    user_metadata: []storage.Header,

    fn deinit(self: *VersionEntry, gpa: Allocator) void {
        gpa.free(self.version_id);
        gpa.free(self.etag);
        gpa.free(self.content_type);
        for (self.user_metadata) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(self.user_metadata);
        self.* = undefined;
    }
};

/// Per-key chain. Sorted newest-first (index 0 is the current version).
const VersionChain = std.ArrayList(VersionEntry);

const BucketSlot = struct {
    meta: storage.Bucket,
    /// Sorted in-memory view of all keys present in this bucket. Mutated
    /// on every PutObject / DeleteObject so M4 ListObjects can read it
    /// directly without an FS walk. For versioned buckets, a key is in
    /// the index iff its chain has a non-delete-marker entry visible.
    key_index: std.ArrayList([]const u8),
    /// Keyed by upload_id (owned). M6.
    uploads: std.StringHashMap(MultipartState),
    /// Bucket versioning state. M8.
    versioning_status: storage.VersioningStatus = .none,
    /// Per-key version chain. Keys are owned strings duped from the
    /// caller's key on first insert. Only populated when versioning has
    /// ever been enabled on this bucket.
    versions: std.StringHashMap(VersionChain),

    fn deinit(self: *BucketSlot, gpa: Allocator) void {
        gpa.free(self.meta.name);
        gpa.free(self.meta.region);
        for (self.key_index.items) |k| gpa.free(k);
        self.key_index.deinit(gpa);
        var it = self.uploads.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            var st = entry.value_ptr.*;
            st.deinit(gpa);
        }
        self.uploads.deinit();
        var vit = self.versions.iterator();
        while (vit.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            var chain = entry.value_ptr.*;
            for (chain.items) |*v| v.deinit(gpa);
            chain.deinit(gpa);
        }
        self.versions.deinit();
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
    .initiateMultipartUpload = vtInitiateMultipartUpload,
    .uploadPart = vtUploadPart,
    .completeMultipartUpload = vtCompleteMultipartUpload,
    .abortMultipartUpload = vtAbortMultipartUpload,
    .listMultipartUploads = vtListMultipartUploads,
    .listParts = vtListParts,
    .getBucketVersioning = vtGetBucketVersioning,
    .putBucketVersioning = vtPutBucketVersioning,
    .listObjectVersions = vtListObjectVersions,
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
fn vtGetObject(ctx: *anyopaque, allocator: Allocator, in: storage.GetObjectInput) storage.Error!storage.GetObjectOutput {
    return getObject(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtHeadObject(ctx: *anyopaque, allocator: Allocator, in: storage.HeadObjectInput) storage.Error!storage.Object {
    return headObject(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtDeleteObject(ctx: *anyopaque, in: storage.DeleteObjectInput) storage.Error!storage.DeleteObjectOutput {
    return deleteObject(@ptrCast(@alignCast(ctx)), in);
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
fn vtGetBucketVersioning(ctx: *anyopaque, bucket: []const u8) storage.Error!storage.VersioningStatus {
    return getBucketVersioning(@ptrCast(@alignCast(ctx)), bucket);
}
fn vtPutBucketVersioning(ctx: *anyopaque, bucket: []const u8, status: storage.VersioningStatus) storage.Error!void {
    return putBucketVersioning(@ptrCast(@alignCast(ctx)), bucket, status);
}
fn vtListObjectVersions(ctx: *anyopaque, allocator: Allocator, in: storage.ListObjectVersionsInput) storage.Error!storage.ListObjectVersionsOutput {
    return listObjectVersions(@ptrCast(@alignCast(ctx)), allocator, in);
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
        .uploads = std.StringHashMap(MultipartState).init(self.allocator),
        .versions = std.StringHashMap(VersionChain).init(self.allocator),
    }) catch return storage.Error.OutOfMemory;

    saveRegistry(self) catch return storage.Error.Io;
}

pub fn deleteBucket(self: *Fs, name: []const u8) storage.Error!void {
    try util.validateBucketName(name);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, name) orelse return storage.Error.NoSuchBucket;

    if (self.buckets.items[idx].key_index.items.len > 0) return storage.Error.BucketNotEmpty;
    if (self.buckets.items[idx].uploads.count() > 0) return storage.Error.BucketNotEmpty;

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
    const slot = &self.buckets.items[idx];

    return switch (slot.versioning_status) {
        .none => putObjectFlat(self, slot, in),
        .enabled => putObjectVersioned(self, slot, in, false),
        .suspended => putObjectVersioned(self, slot, in, true),
    };
}

fn putObjectFlat(self: *Fs, slot: *BucketSlot, in: storage.PutObjectInput) storage.Error!storage.PutObjectOutput {
    const etag = etag_mod.computeEtag(self.allocator, in.body) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(etag);

    const hash = keyHash(in.key);
    var dir_buf: [4096]u8 = undefined;
    const key_dir = std.fmt.bufPrint(&dir_buf, "{s}/s3/{s}/objects/{s}", .{ self.base_dir, in.bucket, &hash }) catch return storage.Error.Io;
    Io.Dir.cwd().createDirPath(self.io, key_dir) catch return storage.Error.Io;

    var data_buf: [4096]u8 = undefined;
    const data_path = std.fmt.bufPrint(&data_buf, "{s}/data", .{key_dir}) catch return storage.Error.Io;
    writeAtomic(self.io, data_path, in.body) catch return storage.Error.Io;

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

    if (!keyIndexContains(slot, in.key)) {
        const owned = self.allocator.dupe(u8, in.key) catch return storage.Error.OutOfMemory;
        errdefer self.allocator.free(owned);
        const pos = std.sort.upperBound([]const u8, slot.key_index.items, in.key, orderSlices);
        slot.key_index.insert(self.allocator, pos, owned) catch return storage.Error.OutOfMemory;
    }

    return .{ .etag = etag };
}

fn putObjectVersioned(self: *Fs, slot: *BucketSlot, in: storage.PutObjectInput, suspended: bool) storage.Error!storage.PutObjectOutput {
    const etag = etag_mod.computeEtag(self.allocator, in.body) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(etag);

    // versionId: real id on Enabled; literal "null" on Suspended.
    const version_id_owned: []u8 = if (suspended)
        try self.allocator.dupe(u8, "null")
    else
        try newVersionId(self.io, self.allocator);
    errdefer self.allocator.free(version_id_owned);

    const hash = keyHash(in.key);
    var versions_dir_buf: [4096]u8 = undefined;
    const versions_dir = std.fmt.bufPrint(&versions_dir_buf, "{s}/s3/{s}/objects/{s}/versions/{s}", .{ self.base_dir, in.bucket, &hash, version_id_owned }) catch return storage.Error.Io;
    Io.Dir.cwd().createDirPath(self.io, versions_dir) catch return storage.Error.Io;

    // 1. Write data.
    var data_buf: [4096]u8 = undefined;
    const data_path = std.fmt.bufPrint(&data_buf, "{s}/data", .{versions_dir}) catch return storage.Error.Io;
    writeAtomic(self.io, data_path, in.body) catch return storage.Error.Io;

    // 2. Write meta.json.
    const now = nowUnixSeconds(self.io);
    const meta_doc = VersionedMetaDoc{
        .key = in.key,
        .size = in.body.len,
        .etag = etag,
        .content_type = in.content_type,
        .last_modified_unix = now,
        .user_metadata = in.user_metadata,
        .is_delete_marker = false,
    };
    var meta_buf: [4096]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_buf, "{s}/meta.json", .{versions_dir}) catch return storage.Error.Io;
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    std.json.fmt(meta_doc, .{}).format(&aw.writer) catch return storage.Error.Io;
    writeAtomic(self.io, meta_path, aw.written()) catch return storage.Error.Io;

    // 3. Update `current` pointer.
    var key_dir_buf: [4096]u8 = undefined;
    const key_dir = std.fmt.bufPrint(&key_dir_buf, "{s}/s3/{s}/objects/{s}", .{ self.base_dir, in.bucket, &hash }) catch return storage.Error.Io;
    var current_path_buf: [4096]u8 = undefined;
    const current_path = std.fmt.bufPrint(&current_path_buf, "{s}/current", .{key_dir}) catch return storage.Error.Io;
    writeAtomic(self.io, current_path, version_id_owned) catch return storage.Error.Io;

    // 4. In-memory chain update.
    const chain_entry: VersionEntry = .{
        .version_id = version_id_owned,
        .is_delete_marker = false,
        .etag = self.allocator.dupe(u8, etag) catch return storage.Error.OutOfMemory,
        .size = in.body.len,
        .content_type = self.allocator.dupe(u8, in.content_type) catch return storage.Error.OutOfMemory,
        .last_modified_unix = now,
        .user_metadata = try dupeHeadersStorage(self.allocator, in.user_metadata),
    };

    if (slot.versions.getPtr(in.key)) |chain| {
        if (suspended) {
            // Suspended: any prior "null" version gets overwritten on disk
            // and replaced in the chain.
            var i: usize = 0;
            while (i < chain.items.len) : (i += 1) {
                if (std.mem.eql(u8, chain.items[i].version_id, "null")) {
                    var old = chain.orderedRemove(i);
                    old.deinit(self.allocator);
                    break;
                }
            }
        }
        chain.insert(self.allocator, 0, chain_entry) catch return storage.Error.OutOfMemory;
    } else {
        var chain: VersionChain = .empty;
        chain.append(self.allocator, chain_entry) catch return storage.Error.OutOfMemory;
        const key_owned = self.allocator.dupe(u8, in.key) catch return storage.Error.OutOfMemory;
        slot.versions.put(key_owned, chain) catch return storage.Error.OutOfMemory;
    }

    // 5. Maintain sorted key_index (mirrors flat behaviour; presence ==
    //    "key has a non-delete-marker current version visible").
    if (!keyIndexContains(slot, in.key)) {
        const owned = self.allocator.dupe(u8, in.key) catch return storage.Error.OutOfMemory;
        const pos = std.sort.upperBound([]const u8, slot.key_index.items, in.key, orderSlices);
        slot.key_index.insert(self.allocator, pos, owned) catch return storage.Error.OutOfMemory;
    }

    return .{
        .etag = etag,
        .version_id = self.allocator.dupe(u8, version_id_owned) catch return storage.Error.OutOfMemory,
    };
}

/// Generate a 22-char base64-url-no-pad versionId from 16 random bytes.
/// Same generator as multipart upload_id (PRD §M6 + §M8).
fn newVersionId(io: Io, allocator: Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    io.random(&raw);
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(raw.len));
    _ = enc.encode(out, &raw);
    return out;
}

pub fn getObject(self: *Fs, allocator: Allocator, in: storage.GetObjectInput) storage.Error!storage.GetObjectOutput {
    try storage.validateObjectKey(in.key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    if (slot.versioning_status == .none) {
        // Flat read.
        if (in.version_id) |_| return storage.Error.NoSuchKey; // versionId on unversioned bucket
        const meta = readMeta(self, allocator, in.bucket, in.key) catch |err| switch (err) {
            error.FileNotFound => return storage.Error.NoSuchKey,
            else => return storage.Error.Io,
        };
        const hash = keyHash(in.key);
        var path_buf: [4096]u8 = undefined;
        const data_path = std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/objects/{s}/data", .{ self.base_dir, in.bucket, &hash }) catch return storage.Error.Io;
        const body = Io.Dir.cwd().readFileAlloc(self.io, data_path, allocator, .limited(5 * 1024 * 1024 * 1024)) catch return storage.Error.Io;
        return .{ .meta = meta, .body = body };
    }

    // Versioned read.
    const chain = slot.versions.get(in.key) orelse return storage.Error.NoSuchKey;
    if (chain.items.len == 0) return storage.Error.NoSuchKey;
    const v: VersionEntry = blk: {
        if (in.version_id) |vid| {
            for (chain.items) |entry| {
                if (std.mem.eql(u8, entry.version_id, vid)) break :blk entry;
            }
            return storage.Error.NoSuchKey;
        }
        break :blk chain.items[0]; // current = newest
    };

    // Surface delete markers via Object.is_delete_marker; caller (service
    // layer) translates to 404 + headers.
    const meta = try cloneVersionedMeta(allocator, in.key, v);
    if (v.is_delete_marker) {
        return .{ .meta = meta, .body = "" };
    }

    const hash = keyHash(in.key);
    var path_buf: [4096]u8 = undefined;
    const data_path = std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/objects/{s}/versions/{s}/data", .{ self.base_dir, in.bucket, &hash, v.version_id }) catch return storage.Error.Io;
    const body = Io.Dir.cwd().readFileAlloc(self.io, data_path, allocator, .limited(5 * 1024 * 1024 * 1024)) catch return storage.Error.Io;
    return .{ .meta = meta, .body = body };
}

pub fn headObject(self: *Fs, allocator: Allocator, in: storage.HeadObjectInput) storage.Error!storage.Object {
    try storage.validateObjectKey(in.key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    if (slot.versioning_status == .none) {
        if (in.version_id) |_| return storage.Error.NoSuchKey;
        return readMeta(self, allocator, in.bucket, in.key) catch |err| switch (err) {
            error.FileNotFound => storage.Error.NoSuchKey,
            else => storage.Error.Io,
        };
    }

    const chain = slot.versions.get(in.key) orelse return storage.Error.NoSuchKey;
    if (chain.items.len == 0) return storage.Error.NoSuchKey;
    const v: VersionEntry = blk: {
        if (in.version_id) |vid| {
            for (chain.items) |entry| {
                if (std.mem.eql(u8, entry.version_id, vid)) break :blk entry;
            }
            return storage.Error.NoSuchKey;
        }
        break :blk chain.items[0];
    };
    return cloneVersionedMeta(allocator, in.key, v);
}

fn cloneVersionedMeta(allocator: Allocator, key: []const u8, v: VersionEntry) storage.Error!storage.Object {
    return .{
        .key = allocator.dupe(u8, key) catch return storage.Error.OutOfMemory,
        .size = v.size,
        .etag = allocator.dupe(u8, v.etag) catch return storage.Error.OutOfMemory,
        .content_type = allocator.dupe(u8, v.content_type) catch return storage.Error.OutOfMemory,
        .last_modified_unix = v.last_modified_unix,
        .user_metadata = try dupeHeadersStorage(allocator, v.user_metadata),
        .version_id = allocator.dupe(u8, v.version_id) catch return storage.Error.OutOfMemory,
        .is_delete_marker = v.is_delete_marker,
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

pub fn deleteObject(self: *Fs, in: storage.DeleteObjectInput) storage.Error!storage.DeleteObjectOutput {
    try storage.validateObjectKey(in.key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    if (slot.versioning_status == .none) return deleteObjectFlat(self, slot, in);

    // Versioned bucket.
    if (in.version_id) |vid| {
        return deleteVersion(self, slot, in.bucket, in.key, vid);
    }
    return createDeleteMarker(self, slot, in.bucket, in.key);
}

fn deleteObjectFlat(self: *Fs, slot: *BucketSlot, in: storage.DeleteObjectInput) storage.Error!storage.DeleteObjectOutput {
    const hash = keyHash(in.key);
    var path_buf: [4096]u8 = undefined;
    const key_dir = std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/objects/{s}", .{ self.base_dir, in.bucket, &hash }) catch return storage.Error.Io;
    Io.Dir.cwd().deleteTree(self.io, key_dir) catch return storage.Error.Io;

    for (slot.key_index.items, 0..) |k, i| {
        if (std.mem.eql(u8, k, in.key)) {
            self.allocator.free(slot.key_index.orderedRemove(i));
            break;
        }
    }
    return .{ .version_id = "", .delete_marker = false };
}

/// Permanently remove one specific version. If it was the current version,
/// the next-newest version becomes current (or the key is fully removed if
/// no versions remain).
fn deleteVersion(self: *Fs, slot: *BucketSlot, bucket: []const u8, key: []const u8, version_id: []const u8) storage.Error!storage.DeleteObjectOutput {
    const chain = slot.versions.getPtr(key) orelse return storage.Error.NoSuchKey;
    var removed_idx: ?usize = null;
    for (chain.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.version_id, version_id)) {
            removed_idx = i;
            break;
        }
    }
    const idx = removed_idx orelse return storage.Error.NoSuchKey;
    const was_delete_marker = chain.items[idx].is_delete_marker;
    var removed = chain.orderedRemove(idx);
    removed.deinit(self.allocator);

    // Remove the on-disk version dir.
    const hash = keyHash(key);
    var path_buf: [4096]u8 = undefined;
    const version_dir = std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/objects/{s}/versions/{s}", .{ self.base_dir, bucket, &hash, version_id }) catch return storage.Error.Io;
    Io.Dir.cwd().deleteTree(self.io, version_dir) catch {};

    // If the chain is now empty, also remove the key entry and the
    // `current` pointer file.
    var key_dir_buf: [4096]u8 = undefined;
    const key_dir = std.fmt.bufPrint(&key_dir_buf, "{s}/s3/{s}/objects/{s}", .{ self.base_dir, bucket, &hash }) catch return storage.Error.Io;
    if (chain.items.len == 0) {
        Io.Dir.cwd().deleteTree(self.io, key_dir) catch {};
        // Drop from versions map.
        if (slot.versions.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            var c = kv.value;
            c.deinit(self.allocator);
        }
        // Drop from key_index.
        for (slot.key_index.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                self.allocator.free(slot.key_index.orderedRemove(i));
                break;
            }
        }
    } else {
        // Rewrite the `current` pointer to the new newest version.
        const new_current = chain.items[0].version_id;
        var current_path_buf: [4096]u8 = undefined;
        const current_path = std.fmt.bufPrint(&current_path_buf, "{s}/current", .{key_dir}) catch return storage.Error.Io;
        writeAtomic(self.io, current_path, new_current) catch return storage.Error.Io;
        // If the new current is a delete marker, the key shouldn't appear
        // in ListObjects; pull it from key_index.
        const new_is_marker = chain.items[0].is_delete_marker;
        if (new_is_marker) {
            for (slot.key_index.items, 0..) |k, i| {
                if (std.mem.eql(u8, k, key)) {
                    self.allocator.free(slot.key_index.orderedRemove(i));
                    break;
                }
            }
        } else if (!keyIndexContains(slot, key)) {
            const owned = self.allocator.dupe(u8, key) catch return storage.Error.OutOfMemory;
            const pos = std.sort.upperBound([]const u8, slot.key_index.items, key, orderSlices);
            slot.key_index.insert(self.allocator, pos, owned) catch return storage.Error.OutOfMemory;
        }
    }

    return .{
        .version_id = self.allocator.dupe(u8, version_id) catch return storage.Error.OutOfMemory,
        .delete_marker = was_delete_marker,
    };
}

/// Insert a delete-marker version. Generates a fresh versionId, writes a
/// tombstone meta.json (no data file), updates the `current` pointer,
/// and pulls the key out of `key_index` (so ListObjects hides it).
fn createDeleteMarker(self: *Fs, slot: *BucketSlot, bucket: []const u8, key: []const u8) storage.Error!storage.DeleteObjectOutput {
    const suspended = slot.versioning_status == .suspended;
    const version_id_owned: []u8 = if (suspended)
        try self.allocator.dupe(u8, "null")
    else
        try newVersionId(self.io, self.allocator);
    errdefer self.allocator.free(version_id_owned);

    const hash = keyHash(key);
    var dir_buf: [4096]u8 = undefined;
    const version_dir = std.fmt.bufPrint(&dir_buf, "{s}/s3/{s}/objects/{s}/versions/{s}", .{ self.base_dir, bucket, &hash, version_id_owned }) catch return storage.Error.Io;
    Io.Dir.cwd().createDirPath(self.io, version_dir) catch return storage.Error.Io;

    const now = nowUnixSeconds(self.io);
    const meta_doc = VersionedMetaDoc{
        .key = key,
        .size = 0,
        .etag = "",
        .content_type = "",
        .last_modified_unix = now,
        .user_metadata = &.{},
        .is_delete_marker = true,
    };
    var meta_buf: [4096]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_buf, "{s}/meta.json", .{version_dir}) catch return storage.Error.Io;
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    std.json.fmt(meta_doc, .{}).format(&aw.writer) catch return storage.Error.Io;
    writeAtomic(self.io, meta_path, aw.written()) catch return storage.Error.Io;

    // Update `current`.
    var key_dir_buf: [4096]u8 = undefined;
    const key_dir = std.fmt.bufPrint(&key_dir_buf, "{s}/s3/{s}/objects/{s}", .{ self.base_dir, bucket, &hash }) catch return storage.Error.Io;
    Io.Dir.cwd().createDirPath(self.io, key_dir) catch return storage.Error.Io;
    var current_path_buf: [4096]u8 = undefined;
    const current_path = std.fmt.bufPrint(&current_path_buf, "{s}/current", .{key_dir}) catch return storage.Error.Io;
    writeAtomic(self.io, current_path, version_id_owned) catch return storage.Error.Io;

    // In-memory chain: prepend new delete marker. For Suspended, overwrite
    // any prior "null".
    const chain_entry: VersionEntry = .{
        .version_id = version_id_owned,
        .is_delete_marker = true,
        .etag = self.allocator.dupe(u8, "") catch return storage.Error.OutOfMemory,
        .size = 0,
        .content_type = self.allocator.dupe(u8, "") catch return storage.Error.OutOfMemory,
        .last_modified_unix = now,
        .user_metadata = try dupeHeadersStorage(self.allocator, &.{}),
    };

    if (slot.versions.getPtr(key)) |chain| {
        if (suspended) {
            var i: usize = 0;
            while (i < chain.items.len) : (i += 1) {
                if (std.mem.eql(u8, chain.items[i].version_id, "null")) {
                    var old = chain.orderedRemove(i);
                    old.deinit(self.allocator);
                    break;
                }
            }
        }
        chain.insert(self.allocator, 0, chain_entry) catch return storage.Error.OutOfMemory;
    } else {
        var chain: VersionChain = .empty;
        chain.append(self.allocator, chain_entry) catch return storage.Error.OutOfMemory;
        const key_owned = self.allocator.dupe(u8, key) catch return storage.Error.OutOfMemory;
        slot.versions.put(key_owned, chain) catch return storage.Error.OutOfMemory;
    }

    // Pull the key from key_index — its current version is now a delete
    // marker, so it shouldn't show up in ListObjects.
    for (slot.key_index.items, 0..) |k, i| {
        if (std.mem.eql(u8, k, key)) {
            self.allocator.free(slot.key_index.orderedRemove(i));
            break;
        }
    }

    return .{
        .version_id = self.allocator.dupe(u8, version_id_owned) catch return storage.Error.OutOfMemory,
        .delete_marker = true,
    };
}

// ---------------------------------------------------------------------------
// Versioning (M8)

pub fn getBucketVersioning(self: *Fs, bucket: []const u8) storage.Error!storage.VersioningStatus {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    return self.buckets.items[idx].versioning_status;
}

pub fn putBucketVersioning(self: *Fs, bucket: []const u8, status: storage.VersioningStatus) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];

    // PutBucketVersioning never resets to `.none` (AWS doesn't expose that
    // in the wire format). Callers should reject `.none` at the service
    // layer; we treat it as a no-op here defensively.
    if (status == .none) return;

    const prev = slot.versioning_status;
    if (prev == .none and status == .enabled) {
        // Migrate every existing object under this bucket from flat
        // `<key-hash>/{data,meta.json}` to `<key-hash>/versions/null/{...}`
        // and populate the in-memory chain.
        migrateNoneToEnabled(self, slot) catch return storage.Error.Io;
    }
    slot.versioning_status = status;
    saveRegistry(self) catch return storage.Error.Io;
}

/// Walks every object directory under the bucket, moves the flat
/// `{data, meta.json}` pair into `versions/null/`, writes `current = "null"`,
/// and populates the in-memory `versions` chain. Idempotent: if a key
/// already has a `versions/` subdir, it's left alone.
fn migrateNoneToEnabled(self: *Fs, slot: *BucketSlot) !void {
    var buf: [4096]u8 = undefined;
    const objects_path = try std.fmt.bufPrint(&buf, "{s}/s3/{s}/objects", .{ self.base_dir, slot.meta.name });
    var dir = Io.Dir.cwd().openDir(self.io, objects_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return, // no objects yet
        else => return err,
    };
    defer dir.close(self.io);

    var it = dir.iterate();
    while (try it.next(self.io)) |entry| {
        if (entry.kind != .directory) continue;
        var key_dir_buf: [4096]u8 = undefined;
        const key_dir = try std.fmt.bufPrint(&key_dir_buf, "{s}/{s}", .{ objects_path, entry.name });
        var vbuf: [4096]u8 = undefined;
        const versions_dir = try std.fmt.bufPrint(&vbuf, "{s}/versions/null", .{key_dir});

        // Skip if already migrated.
        if (dirExists(self.io, versions_dir)) continue;

        // Read the existing meta.json to populate the in-memory chain.
        var meta_path_buf: [4096]u8 = undefined;
        const meta_path = try std.fmt.bufPrint(&meta_path_buf, "{s}/meta.json", .{key_dir});
        const meta_bytes = Io.Dir.cwd().readFileAlloc(self.io, meta_path, self.allocator, .limited(4 * 1024 * 1024)) catch continue;
        defer self.allocator.free(meta_bytes);
        var parsed = std.json.parseFromSlice(MetaDoc, self.allocator, meta_bytes, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        const md = parsed.value;

        // Move both files into versions/null/. Use createDirPath +
        // rename (atomic on same fs).
        Io.Dir.cwd().createDirPath(self.io, versions_dir) catch return storage.Error.Io;

        var src_data: [4096]u8 = undefined;
        const src_data_path = try std.fmt.bufPrint(&src_data, "{s}/data", .{key_dir});
        var dst_data: [4096]u8 = undefined;
        const dst_data_path = try std.fmt.bufPrint(&dst_data, "{s}/data", .{versions_dir});
        Io.Dir.renameAbsolute(src_data_path, dst_data_path, self.io) catch return storage.Error.Io;

        var dst_meta: [4096]u8 = undefined;
        const dst_meta_path = try std.fmt.bufPrint(&dst_meta, "{s}/meta.json", .{versions_dir});
        Io.Dir.renameAbsolute(meta_path, dst_meta_path, self.io) catch return storage.Error.Io;

        // Write the `current` pointer.
        var current_path_buf: [4096]u8 = undefined;
        const current_path = try std.fmt.bufPrint(&current_path_buf, "{s}/current", .{key_dir});
        try writeAtomic(self.io, current_path, "null");

        // Populate in-memory chain (newest-first; chain has one entry).
        var chain: VersionChain = .empty;
        const v: VersionEntry = .{
            .version_id = try self.allocator.dupe(u8, "null"),
            .is_delete_marker = false,
            .etag = try self.allocator.dupe(u8, md.etag),
            .size = md.size,
            .content_type = try self.allocator.dupe(u8, md.content_type),
            .last_modified_unix = md.last_modified_unix,
            .user_metadata = try dupeHeadersStorage(self.allocator, md.user_metadata),
        };
        try chain.append(self.allocator, v);
        const key_owned = try self.allocator.dupe(u8, md.key);
        try slot.versions.put(key_owned, chain);
    }
}

fn dirExists(io: Io, path: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// On startup, walks `<bucket>/objects/*/versions/*/` for each key and
/// populates `slot.versions` with the chain (newest-first by
/// `last_modified_unix`).
fn rebuildVersionIndex(self: *Fs, slot: *BucketSlot) !void {
    var buf: [4096]u8 = undefined;
    const objects_path = try std.fmt.bufPrint(&buf, "{s}/s3/{s}/objects", .{ self.base_dir, slot.meta.name });
    var top = Io.Dir.cwd().openDir(self.io, objects_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer top.close(self.io);

    var top_it = top.iterate();
    while (try top_it.next(self.io)) |entry| {
        if (entry.kind != .directory) continue;
        var versions_buf: [4096]u8 = undefined;
        const versions_path = std.fmt.bufPrint(&versions_buf, "{s}/{s}/versions", .{ objects_path, entry.name }) catch continue;
        var versions_dir = Io.Dir.cwd().openDir(self.io, versions_path, .{ .iterate = true }) catch continue;
        defer versions_dir.close(self.io);

        var chain: VersionChain = .empty;
        errdefer {
            for (chain.items) |*v| v.deinit(self.allocator);
            chain.deinit(self.allocator);
        }

        var key_buf: ?[]u8 = null;
        var vit = versions_dir.iterate();
        while (try vit.next(self.io)) |v_entry| {
            if (v_entry.kind != .directory) continue;
            var meta_buf: [4096]u8 = undefined;
            const meta_path = std.fmt.bufPrint(&meta_buf, "{s}/{s}/meta.json", .{ versions_path, v_entry.name }) catch continue;
            const meta_bytes = Io.Dir.cwd().readFileAlloc(self.io, meta_path, self.allocator, .limited(4 * 1024 * 1024)) catch continue;
            defer self.allocator.free(meta_bytes);

            var parsed = std.json.parseFromSlice(VersionedMetaDoc, self.allocator, meta_bytes, .{ .ignore_unknown_fields = true }) catch continue;
            defer parsed.deinit();
            const md = parsed.value;

            if (key_buf == null) key_buf = try self.allocator.dupe(u8, md.key);

            const v: VersionEntry = .{
                .version_id = try self.allocator.dupe(u8, v_entry.name),
                .is_delete_marker = md.is_delete_marker,
                .etag = try self.allocator.dupe(u8, md.etag),
                .size = md.size,
                .content_type = try self.allocator.dupe(u8, md.content_type),
                .last_modified_unix = md.last_modified_unix,
                .user_metadata = try dupeHeadersStorage(self.allocator, md.user_metadata),
            };
            try chain.append(self.allocator, v);
        }

        if (chain.items.len == 0 or key_buf == null) {
            chain.deinit(self.allocator);
            if (key_buf) |k| self.allocator.free(k);
            continue;
        }
        // Sort newest-first by last_modified_unix.
        std.mem.sort(VersionEntry, chain.items, {}, struct {
            fn lt(_: void, a: VersionEntry, b: VersionEntry) bool {
                return a.last_modified_unix > b.last_modified_unix;
            }
        }.lt);
        try slot.versions.put(key_buf.?, chain);
    }
}

/// On-disk version meta.json schema. Same fields as the flat MetaDoc plus
/// `is_delete_marker` so we can persist tombstones.
const VersionedMetaDoc = struct {
    key: []const u8,
    size: usize,
    etag: []const u8,
    content_type: []const u8,
    last_modified_unix: i64,
    user_metadata: []const storage.Header,
    is_delete_marker: bool = false,
};

pub fn listObjectVersions(self: *Fs, allocator: Allocator, in: storage.ListObjectVersionsInput) storage.Error!storage.ListObjectVersionsOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    // Collect every (key, version) into a flat list, sort by (key asc,
    // version newest-first within key). For unversioned buckets the
    // result is empty.
    var keys_sorted: std.ArrayList([]const u8) = .empty;
    defer keys_sorted.deinit(allocator);
    {
        var it = slot.versions.iterator();
        while (it.next()) |entry| {
            keys_sorted.append(allocator, entry.key_ptr.*) catch return storage.Error.OutOfMemory;
        }
    }
    std.mem.sort([]const u8, keys_sorted.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    var out: std.ArrayList(storage.ObjectVersion) = .empty;
    errdefer {
        for (out.items) |v| {
            allocator.free(v.key);
            allocator.free(v.version_id);
            allocator.free(v.etag);
        }
        out.deinit(allocator);
    }
    var prefixes: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (prefixes.items) |p| allocator.free(p);
        prefixes.deinit(allocator);
    }

    var truncated = false;
    var last_key: []const u8 = "";
    var last_vid: []const u8 = "";
    const limit: usize = if (in.max_keys > 1000) 1000 else in.max_keys;

    outer: for (keys_sorted.items) |k| {
        if (in.prefix.len > 0 and !std.mem.startsWith(u8, k, in.prefix)) continue;

        // Delimiter rollup — group every key whose suffix (after prefix) contains
        // the delimiter, contribute one CommonPrefixes entry.
        if (in.delimiter.len > 0) {
            const after = k[in.prefix.len..];
            if (std.mem.indexOf(u8, after, in.delimiter)) |off| {
                const cp_end = in.prefix.len + off + in.delimiter.len;
                const cp = k[0..cp_end];
                if (prefixes.items.len == 0 or !std.mem.eql(u8, prefixes.items[prefixes.items.len - 1], cp)) {
                    if (out.items.len + prefixes.items.len >= limit) {
                        truncated = true;
                        break :outer;
                    }
                    const owned = allocator.dupe(u8, cp) catch return storage.Error.OutOfMemory;
                    prefixes.append(allocator, owned) catch return storage.Error.OutOfMemory;
                    last_key = k;
                    last_vid = "";
                }
                continue;
            }
        }

        const chain = slot.versions.get(k).?;
        for (chain.items, 0..) |v, i| {
            // Pagination: skip entries on or before (key_marker, version_id_marker).
            if (in.key_marker.len > 0) {
                const cmp = std.mem.order(u8, k, in.key_marker);
                if (cmp == .lt) continue;
                if (cmp == .eq and in.version_id_marker.len > 0) {
                    // We need to skip up through and including version_id_marker.
                    // Use linear scan within the chain: only emit entries that
                    // appear *after* version_id_marker in newest-first order.
                    var seen_marker = false;
                    for (chain.items[0..i]) |earlier| {
                        if (std.mem.eql(u8, earlier.version_id, in.version_id_marker)) {
                            seen_marker = true;
                            break;
                        }
                    }
                    if (!seen_marker) continue;
                }
            }

            if (out.items.len + prefixes.items.len >= limit) {
                truncated = true;
                break :outer;
            }
            const k_dup = allocator.dupe(u8, k) catch return storage.Error.OutOfMemory;
            const id_dup = allocator.dupe(u8, v.version_id) catch {
                allocator.free(k_dup);
                return storage.Error.OutOfMemory;
            };
            const etag_dup = allocator.dupe(u8, v.etag) catch {
                allocator.free(k_dup);
                allocator.free(id_dup);
                return storage.Error.OutOfMemory;
            };
            out.append(allocator, .{
                .key = k_dup,
                .version_id = id_dup,
                .is_latest = (i == 0),
                .is_delete_marker = v.is_delete_marker,
                .last_modified_unix = v.last_modified_unix,
                .etag = etag_dup,
                .size = v.size,
            }) catch {
                allocator.free(k_dup);
                allocator.free(id_dup);
                allocator.free(etag_dup);
                return storage.Error.OutOfMemory;
            };
            last_key = k;
            last_vid = v.version_id;
        }
    }

    const next_key_owned: []const u8 = if (truncated) (allocator.dupe(u8, last_key) catch return storage.Error.OutOfMemory) else "";
    const next_vid_owned: []const u8 = if (truncated) (allocator.dupe(u8, last_vid) catch return storage.Error.OutOfMemory) else "";

    return .{
        .versions = out.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory,
        .common_prefixes = prefixes.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory,
        .is_truncated = truncated,
        .next_key_marker = next_key_owned,
        .next_version_id_marker = next_vid_owned,
    };
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
    /// M8. Missing/null on records from earlier versions is treated as
    /// `.none` (default for unversioned buckets).
    versioning: ?[]const u8 = null,
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
        const versioning: storage.VersioningStatus = if (rec.versioning) |v|
            (if (std.mem.eql(u8, v, "enabled")) .enabled else if (std.mem.eql(u8, v, "suspended")) .suspended else .none)
        else
            .none;
        var slot: BucketSlot = .{
            .meta = .{
                .name = name_owned,
                .region = region_owned,
                .created_unix = rec.created_unix,
            },
            .key_index = .empty,
            .uploads = std.StringHashMap(MultipartState).init(self.allocator),
            .versioning_status = versioning,
            .versions = std.StringHashMap(VersionChain).init(self.allocator),
        };
        // Walk objects/ to rebuild the in-memory key index from meta.json files.
        try rebuildKeyIndex(self, &slot);
        // Walk multipart/ to repopulate the in-memory upload index from manifests.
        try rebuildUploadIndex(self, &slot);
        // For versioned buckets, walk objects/*/versions/* to rebuild the chains.
        if (versioning != .none) try rebuildVersionIndex(self, &slot);
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
        const versioning_str: ?[]const u8 = switch (b.versioning_status) {
            .none => null,
            .enabled => "enabled",
            .suspended => "suspended",
        };
        records[i] = .{
            .name = b.meta.name,
            .region = b.meta.region,
            .created_unix = b.meta.created_unix,
            .versioning = versioning_str,
        };
    }
    const doc: RegistryDoc = .{ .version = registry_version, .buckets = records };

    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    try std.json.fmt(doc, .{ .whitespace = .indent_2 }).format(&aw.writer);
    try writeAtomic(self.io, path, aw.written());
}

// ---------------------------------------------------------------------------
// Multipart upload (M6)
//
// Layout:  <base>/s3/<bucket>/multipart/<upload_id>/{manifest.json, part-NNNNN}
// In-memory: BucketSlot.uploads is the source of truth; the on-disk
// manifest is the persistent shadow.

const Md5 = std.crypto.hash.Md5;

const ManifestDoc = struct {
    key: []const u8,
    content_type: []const u8,
    user_metadata: []const storage.Header,
    initiated_unix: i64,
    parts: []const ManifestPart,
};

const ManifestPart = struct {
    part_number: u32,
    size: u64,
    etag: []const u8,
    last_modified_unix: i64,
};

pub fn initiateMultipartUpload(self: *Fs, allocator: Allocator, in: storage.InitiateMultipartUploadInput) storage.Error!storage.InitiateMultipartUploadOutput {
    try storage.validateObjectKey(in.key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];

    const upload_id = newUploadId(self.io, allocator) catch return storage.Error.OutOfMemory;
    errdefer allocator.free(upload_id);

    // On-disk: create the per-upload directory.
    var dir_buf: [4096]u8 = undefined;
    const upload_dir = std.fmt.bufPrint(&dir_buf, "{s}/s3/{s}/multipart/{s}", .{ self.base_dir, in.bucket, upload_id }) catch return storage.Error.Io;
    Io.Dir.cwd().createDirPath(self.io, upload_dir) catch return storage.Error.Io;

    // In-memory state.
    const key_owned = self.allocator.dupe(u8, in.key) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(key_owned);
    const ct_owned = self.allocator.dupe(u8, in.content_type) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(ct_owned);
    const meta_owned = dupeHeadersStorage(self.allocator, in.user_metadata) catch return storage.Error.OutOfMemory;
    errdefer freeHeadersStorage(self.allocator, meta_owned);

    const state: MultipartState = .{
        .key = key_owned,
        .content_type = ct_owned,
        .user_metadata = meta_owned,
        .initiated_unix = nowUnixSeconds(self.io),
        .parts = std.AutoHashMap(u32, PartMeta).init(self.allocator),
    };

    const id_for_map = self.allocator.dupe(u8, upload_id) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(id_for_map);
    slot.uploads.put(id_for_map, state) catch return storage.Error.OutOfMemory;

    // Persist manifest.
    writeManifest(self, in.bucket, upload_id, &state) catch return storage.Error.Io;

    return .{ .upload_id = upload_id };
}

pub fn uploadPart(self: *Fs, in: storage.UploadPartInput) storage.Error!storage.UploadPartOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    var state = slot.uploads.getPtr(in.upload_id) orelse return storage.Error.NoSuchUpload;

    const etag = etag_mod.computeEtag(self.allocator, in.body) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(etag);

    // Atomically write the part file.
    var path_buf: [4096]u8 = undefined;
    const part_path = std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/multipart/{s}/part-{d:0>5}", .{ self.base_dir, in.bucket, in.upload_id, in.part_number }) catch return storage.Error.Io;
    writeAtomic(self.io, part_path, in.body) catch return storage.Error.Io;

    // Replace any prior part meta for this part_number.
    if (state.parts.fetchRemove(in.part_number)) |kv| {
        self.allocator.free(kv.value.etag);
    }
    state.parts.put(in.part_number, .{
        .part_number = in.part_number,
        .size = in.body.len,
        .etag = etag,
        .last_modified_unix = nowUnixSeconds(self.io),
    }) catch return storage.Error.OutOfMemory;

    writeManifest(self, in.bucket, in.upload_id, state) catch return storage.Error.Io;

    return .{ .etag = self.allocator.dupe(u8, etag) catch return storage.Error.OutOfMemory };
}

pub fn completeMultipartUpload(self: *Fs, allocator: Allocator, in: storage.CompleteMultipartUploadInput) storage.Error!storage.CompleteMultipartUploadOutput {
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
        total_size += stored.size;
    }

    // Concatenate parts from disk into the final body buffer + collect digests.
    const body = self.allocator.alloc(u8, total_size) catch return storage.Error.OutOfMemory;
    defer self.allocator.free(body);
    var digests = self.allocator.alloc([16]u8, in.parts.len) catch return storage.Error.OutOfMemory;
    defer self.allocator.free(digests);
    var off: usize = 0;
    for (in.parts, 0..) |p, i| {
        var part_buf: [4096]u8 = undefined;
        const part_path = std.fmt.bufPrint(&part_buf, "{s}/s3/{s}/multipart/{s}/part-{d:0>5}", .{ self.base_dir, in.bucket, in.upload_id, p.part_number }) catch return storage.Error.Io;
        const part_bytes = Io.Dir.cwd().readFileAlloc(self.io, part_path, self.allocator, .limited(5 * 1024 * 1024 * 1024)) catch return storage.Error.Io;
        defer self.allocator.free(part_bytes);
        @memcpy(body[off .. off + part_bytes.len], part_bytes);
        off += part_bytes.len;
        Md5.hash(part_bytes, &digests[i], .{});
    }

    const final_etag = etag_mod.computeMultipartEtag(self.allocator, digests, @intCast(in.parts.len)) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(final_etag);

    // Write the final object (data + meta.json) atomically.
    const hash = keyHash(state.key);
    var dir_buf: [4096]u8 = undefined;
    const key_dir = std.fmt.bufPrint(&dir_buf, "{s}/s3/{s}/objects/{s}", .{ self.base_dir, in.bucket, &hash }) catch return storage.Error.Io;
    Io.Dir.cwd().createDirPath(self.io, key_dir) catch return storage.Error.Io;

    var data_buf: [4096]u8 = undefined;
    const data_path = std.fmt.bufPrint(&data_buf, "{s}/data", .{key_dir}) catch return storage.Error.Io;
    writeAtomic(self.io, data_path, body) catch return storage.Error.Io;

    const meta_doc = MetaDoc{
        .key = state.key,
        .size = total_size,
        .etag = final_etag,
        .content_type = state.content_type,
        .last_modified_unix = nowUnixSeconds(self.io),
        .user_metadata = state.user_metadata,
    };
    var meta_buf: [4096]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_buf, "{s}/meta.json", .{key_dir}) catch return storage.Error.Io;
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    std.json.fmt(meta_doc, .{}).format(&aw.writer) catch return storage.Error.Io;
    writeAtomic(self.io, meta_path, aw.written()) catch return storage.Error.Io;

    // Update sorted key index.
    if (!keyIndexContains(slot, state.key)) {
        const owned = self.allocator.dupe(u8, state.key) catch return storage.Error.OutOfMemory;
        errdefer self.allocator.free(owned);
        const pos = std.sort.upperBound([]const u8, slot.key_index.items, state.key, orderSlices);
        slot.key_index.insert(self.allocator, pos, owned) catch return storage.Error.OutOfMemory;
    }

    // Remove upload state + on-disk dir.
    var upload_dir_buf: [4096]u8 = undefined;
    const upload_dir = std.fmt.bufPrint(&upload_dir_buf, "{s}/s3/{s}/multipart/{s}", .{ self.base_dir, in.bucket, in.upload_id }) catch return storage.Error.Io;
    Io.Dir.cwd().deleteTree(self.io, upload_dir) catch {};

    const id_owned = entry.key_ptr.*;
    var state_copy = entry.value_ptr.*;
    _ = slot.uploads.remove(in.upload_id);
    self.allocator.free(id_owned);
    state_copy.deinit(self.allocator);

    return .{ .etag = allocator.dupe(u8, final_etag) catch return storage.Error.OutOfMemory };
}

pub fn abortMultipartUpload(self: *Fs, bucket: []const u8, key: []const u8, upload_id: []const u8) storage.Error!void {
    _ = key;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    if (slot.uploads.fetchRemove(upload_id)) |kv| {
        self.allocator.free(kv.key);
        var st = kv.value;
        st.deinit(self.allocator);

        var buf: [4096]u8 = undefined;
        const upload_dir = std.fmt.bufPrint(&buf, "{s}/s3/{s}/multipart/{s}", .{ self.base_dir, bucket, upload_id }) catch return storage.Error.Io;
        Io.Dir.cwd().deleteTree(self.io, upload_dir) catch return storage.Error.Io;
        return;
    }
    return storage.Error.NoSuchUpload;
}

pub fn listMultipartUploads(self: *Fs, allocator: Allocator, in: storage.ListMultipartUploadsInput) storage.Error!storage.ListMultipartUploadsOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    // Snapshot uploads sorted by (key, upload_id).
    const Row = struct { id: []const u8, key: []const u8, initiated_unix: i64 };
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(allocator);
    var it = slot.uploads.iterator();
    while (it.next()) |entry| {
        rows.append(allocator, .{
            .id = entry.key_ptr.*,
            .key = entry.value_ptr.key,
            .initiated_unix = entry.value_ptr.initiated_unix,
        }) catch return storage.Error.OutOfMemory;
    }
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
        if (in.key_marker.len > 0) {
            const cmp = std.mem.order(u8, row.key, in.key_marker);
            if (cmp == .lt) continue;
            if (cmp == .eq) {
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

pub fn listParts(self: *Fs, allocator: Allocator, in: storage.ListPartsInput) storage.Error!storage.ListPartsOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];
    const state = slot.uploads.get(in.upload_id) orelse return storage.Error.NoSuchUpload;

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
            .size = stored.size,
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

fn writeManifest(self: *Fs, bucket: []const u8, upload_id: []const u8, state: *const MultipartState) !void {
    // Snapshot parts into a flat slice for serialization.
    var parts = try self.allocator.alloc(ManifestPart, state.parts.count());
    defer self.allocator.free(parts);
    var i: usize = 0;
    var it = state.parts.iterator();
    while (it.next()) |entry| : (i += 1) {
        const p = entry.value_ptr.*;
        parts[i] = .{
            .part_number = p.part_number,
            .size = p.size,
            .etag = p.etag,
            .last_modified_unix = p.last_modified_unix,
        };
    }
    const doc: ManifestDoc = .{
        .key = state.key,
        .content_type = state.content_type,
        .user_metadata = state.user_metadata,
        .initiated_unix = state.initiated_unix,
        .parts = parts,
    };
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    try std.json.fmt(doc, .{}).format(&aw.writer);

    var path_buf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/multipart/{s}/manifest.json", .{ self.base_dir, bucket, upload_id });
    try writeAtomic(self.io, path, aw.written());
}

fn rebuildUploadIndex(self: *Fs, slot: *BucketSlot) !void {
    var buf: [4096]u8 = undefined;
    const multipart_path = try std.fmt.bufPrint(&buf, "{s}/s3/{s}/multipart", .{ self.base_dir, slot.meta.name });
    var dir = Io.Dir.cwd().openDir(self.io, multipart_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(self.io);

    var it = dir.iterate();
    while (try it.next(self.io)) |entry| {
        if (entry.kind != .directory) continue;
        var path_buf: [4096]u8 = undefined;
        const manifest_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/manifest.json", .{ multipart_path, entry.name });
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, manifest_path, self.allocator, .limited(4 * 1024 * 1024)) catch continue;
        defer self.allocator.free(bytes);

        var parsed = std.json.parseFromSlice(ManifestDoc, self.allocator, bytes, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        const value = parsed.value;

        var state: MultipartState = .{
            .key = try self.allocator.dupe(u8, value.key),
            .content_type = try self.allocator.dupe(u8, value.content_type),
            .user_metadata = try dupeHeadersStorage(self.allocator, value.user_metadata),
            .initiated_unix = value.initiated_unix,
            .parts = std.AutoHashMap(u32, PartMeta).init(self.allocator),
        };
        for (value.parts) |p| {
            const etag_owned = try self.allocator.dupe(u8, p.etag);
            try state.parts.put(p.part_number, .{
                .part_number = p.part_number,
                .size = p.size,
                .etag = etag_owned,
                .last_modified_unix = p.last_modified_unix,
            });
        }

        const id_owned = try self.allocator.dupe(u8, entry.name);
        try slot.uploads.put(id_owned, state);
    }
}

fn dupeHeadersStorage(allocator: Allocator, src: []const storage.Header) ![]storage.Header {
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

fn freeHeadersStorage(allocator: Allocator, hs: []storage.Header) void {
    for (hs) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    allocator.free(hs);
}

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
        const meta = try fs.headObject(testing.allocator, .{ .bucket = "bkt", .key = "hello.txt" });
        defer freeObjectMeta(meta);
        try testing.expectEqual(@as(u64, "hello world".len), meta.size);
        try testing.expectEqualStrings("text/plain", meta.content_type);
    }

    {
        const got = try fs.getObject(testing.allocator, .{ .bucket = "bkt", .key = "hello.txt" });
        defer {
            testing.allocator.free(got.body);
            freeObjectMeta(got.meta);
        }
        try testing.expectEqualStrings("hello world", got.body);
    }

    _ = try fs.deleteObject(.{ .bucket = "bkt", .key = "hello.txt" });
    try testing.expectError(storage.Error.NoSuchKey, fs.headObject(testing.allocator, .{ .bucket = "bkt", .key = "hello.txt" }));
    _ = try fs.deleteObject(.{ .bucket = "bkt", .key = "hello.txt" }); // idempotent
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
