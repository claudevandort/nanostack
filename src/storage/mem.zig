//! In-memory storage backend (`--ephemeral`).
//!
//! Same contract as `fs.zig`: validate names, enforce duplicate / missing
//! rules, return ordered listings. Everything lives in process memory and
//! is lost on exit.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const storage = @import("mod.zig");
const util = @import("util.zig");
const fs = @import("fs.zig");

const Mem = @This();

allocator: Allocator,
io: Io,
mutex: Io.Mutex,
buckets: std.ArrayList(storage.Bucket),

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
    for (self.buckets.items) |*b| {
        self.allocator.free(b.name);
        self.allocator.free(b.region);
    }
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

pub fn createBucket(self: *Mem, name: []const u8) storage.Error!void {
    try util.validateBucketName(name);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    for (self.buckets.items) |b| {
        if (std.mem.eql(u8, b.name, name)) return storage.Error.BucketAlreadyOwnedByYou;
    }

    const name_owned = self.allocator.dupe(u8, name) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(name_owned);
    const region_owned = self.allocator.dupe(u8, "us-east-1") catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(region_owned);

    self.buckets.append(self.allocator, .{
        .name = name_owned,
        .region = region_owned,
        .created_unix = fs.nowUnixSeconds(self.io),
    }) catch return storage.Error.OutOfMemory;
}

pub fn deleteBucket(self: *Mem, name: []const u8) storage.Error!void {
    try util.validateBucketName(name);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, name) orelse return storage.Error.NoSuchBucket;
    // Mem has no objects yet (M3 lands those); never BucketNotEmpty in M1.
    const removed = self.buckets.orderedRemove(idx);
    self.allocator.free(removed.name);
    self.allocator.free(removed.region);
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
            .name = allocator.dupe(u8, b.name) catch return storage.Error.OutOfMemory,
            .region = allocator.dupe(u8, b.region) catch return storage.Error.OutOfMemory,
            .created_unix = b.created_unix,
        };
    }
    return out;
}

fn findBucket(self: *Mem, name: []const u8) ?usize {
    for (self.buckets.items, 0..) |b, i| {
        if (std.mem.eql(u8, b.name, name)) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "mem: create + head + list + delete" {
    var m = try Mem.init(testing.allocator, testing.io);
    defer m.deinit();

    try m.createBucket("alpha");
    try m.headBucket("alpha");

    const buckets = try m.listBuckets(testing.allocator);
    defer {
        for (buckets) |b| {
            testing.allocator.free(b.name);
            testing.allocator.free(b.region);
        }
        testing.allocator.free(buckets);
    }
    try testing.expectEqual(@as(usize, 1), buckets.len);
    try testing.expectEqualStrings("alpha", buckets[0].name);

    try m.deleteBucket("alpha");
    try testing.expectError(storage.Error.NoSuchBucket, m.headBucket("alpha"));
}

test "mem: duplicate create returns BucketAlreadyOwnedByYou" {
    var m = try Mem.init(testing.allocator, testing.io);
    defer m.deinit();
    try m.createBucket("dupes");
    try testing.expectError(storage.Error.BucketAlreadyOwnedByYou, m.createBucket("dupes"));
}

test "mem: delete missing returns NoSuchBucket" {
    var m = try Mem.init(testing.allocator, testing.io);
    defer m.deinit();
    try testing.expectError(storage.Error.NoSuchBucket, m.deleteBucket("ghost"));
}

test "mem: invalid bucket name is rejected" {
    var m = try Mem.init(testing.allocator, testing.io);
    defer m.deinit();
    try testing.expectError(storage.Error.InvalidBucketName, m.createBucket("Bad_Name"));
}
