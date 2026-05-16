//! DynamoDB service dispatch.
//!
//! Unlike S3, DynamoDB uses one HTTP endpoint and dispatches operations
//! via the `X-Amz-Target` header (e.g. `DynamoDB_20120810.ListTables`).
//! Method is always `POST`; path is always `/`; body is always JSON
//! (`application/x-amz-json-1.0`).
//!
//! Phase 1 (M15-scaffold) ships only a stub `ListTables`. Subsequent
//! phases extend the dispatch table.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const errors = @import("../../wire/dynamodb/errors.zig");
const tables = @import("tables.zig");
const items_handler = @import("items.zig");
const query_handler = @import("query.zig");
const scan_handler = @import("scan.zig");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Successful op output. Body is JSON; the HTTP layer adds the
/// `application/x-amz-json-1.0` content type.
pub const Output = struct {
    status: u16 = 200,
    body: []const u8,
    extra_headers: []const Header = &.{},
};

pub const ErrorBody = struct {
    code: errors.Code,
    message: ?[]const u8 = null,
};

pub const Result = union(enum) {
    ok: Output,
    err: ErrorBody,
};

pub const RequestData = struct {
    headers: []const storage.Header = &.{},
    body: []const u8 = "",
    /// X-Amz-Target value, post-prefix-strip — e.g. `ListTables`.
    target: []const u8 = "",
};

pub const Context = struct {
    backend: storage.DynamoBackend,
    /// Per-request arena, owned by the HTTP server.
    allocator: Allocator,
    /// Configured server region. Mirrors s3.Context.region.
    region: []const u8 = "us-east-1",
    request: RequestData = .{},
};

/// Service-wide target prefix. AWS uses `DynamoDB_20120810.` for the
/// core service; `DynamoDBStreams_20120810.` is the Streams sub-service
/// (deferred to v0.3).
pub const target_prefix = "DynamoDB_20120810.";

/// Dispatch a request based on its `X-Amz-Target` suffix.
pub fn handle(ctx: Context) Result {
    const target = ctx.request.target;

    // Table management (M15-tables, Phase 2).
    if (std.mem.eql(u8, target, "ListTables")) return tables.listTables(ctx);
    if (std.mem.eql(u8, target, "CreateTable")) return tables.createTable(ctx);
    if (std.mem.eql(u8, target, "DescribeTable")) return tables.describeTable(ctx);
    if (std.mem.eql(u8, target, "DeleteTable")) return tables.deleteTable(ctx);
    if (std.mem.eql(u8, target, "UpdateTable")) return tables.updateTable(ctx);

    // Item CRUD (M15-items, Phase 3).
    if (std.mem.eql(u8, target, "GetItem")) return items_handler.getItem(ctx);
    if (std.mem.eql(u8, target, "PutItem")) return items_handler.putItem(ctx);
    if (std.mem.eql(u8, target, "DeleteItem")) return items_handler.deleteItem(ctx);

    // UpdateItem + ConditionExpression on Put/Delete (M15-expressions, Phase 4).
    if (std.mem.eql(u8, target, "UpdateItem")) return items_handler.updateItem(ctx);

    // Query + KeyConditionExpression + FilterExpression (M15-query, Phase 5).
    if (std.mem.eql(u8, target, "Query")) return query_handler.query(ctx);

    // Scan (M15-scan, Phase 6).
    if (std.mem.eql(u8, target, "Scan")) return scan_handler.scan(ctx);

    // Anything else gets 400 ValidationException with a message that
    // names the unsupported target. AWS-correct: unknown targets return
    // ValidationException, not 404.
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Unsupported operation: {s}", .{target}) catch
        return .{ .err = .{ .code = .validation_exception } };
    const owned = ctx.allocator.dupe(u8, msg) catch
        return .{ .err = .{ .code = .internal_server_error } };
    return .{ .err = .{ .code = .validation_exception, .message = owned } };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

// Stub backend that returns a fixed list of table names.
const StubBackend = struct {
    names: []const []const u8,

    pub fn backend(self: *const StubBackend) storage.DynamoBackend {
        return .{ .ctx = @ptrCast(@constCast(self)), .vtable = &.{
            .listTables = stubListTables,
            .createTable = stubCreateTable,
            .describeTable = stubDescribeTable,
            .deleteTable = stubDeleteTable,
            .updateTable = stubUpdateTable,
            .putItem = stubPutItem,
            .getItem = stubGetItem,
            .deleteItem = stubDeleteItem,
            .updateItem = stubUpdateItem,
            .query = stubQuery,
        } };
    }
    fn stubQuery(_: *anyopaque, _: Allocator, _: storage.QueryInput) storage.Error!storage.QueryResult {
        unreachable;
    }

    fn stubPutItem(_: *anyopaque, _: Allocator, _: storage.PutItemInput) storage.Error!storage.PutItemResult {
        unreachable;
    }
    fn stubGetItem(_: *anyopaque, _: Allocator, _: storage.GetItemInput) storage.Error!storage.GetItemResult {
        unreachable;
    }
    fn stubDeleteItem(_: *anyopaque, _: Allocator, _: storage.DeleteItemInput) storage.Error!storage.DeleteItemResult {
        unreachable;
    }
    fn stubUpdateItem(_: *anyopaque, _: Allocator, _: storage.UpdateItemInput) storage.Error!storage.UpdateItemResult {
        unreachable;
    }

    fn stubListTables(ctx: *anyopaque, allocator: Allocator) storage.Error![]const []const u8 {
        const self: *const StubBackend = @ptrCast(@alignCast(ctx));
        // Caller (ctx.allocator) frees the outer slice and the inner strings.
        const out = try allocator.alloc([]const u8, self.names.len);
        for (self.names, 0..) |n, i| out[i] = try allocator.dupe(u8, n);
        return out;
    }

    fn stubCreateTable(_: *anyopaque, _: storage.CreateTableInput) storage.Error!void {
        unreachable;
    }
    fn stubDescribeTable(_: *anyopaque, _: []const u8) storage.Error!*const storage.TableSlot {
        unreachable;
    }
    fn stubDeleteTable(_: *anyopaque, _: []const u8) storage.Error!void {
        unreachable;
    }
    fn stubUpdateTable(_: *anyopaque, _: storage.UpdateTableInput) storage.Error!*const storage.TableSlot {
        unreachable;
    }
};

test "handle ListTables: empty list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub: StubBackend = .{ .names = &.{} };
    const ctx: Context = .{
        .backend = stub.backend(),
        .allocator = arena.allocator(),
        .request = .{ .target = "ListTables" },
    };
    const result = handle(ctx);
    switch (result) {
        .ok => |out| {
            try testing.expectEqualStrings("{\"TableNames\":[]}", out.body);
            try testing.expectEqual(@as(u16, 200), out.status);
        },
        .err => |e| {
            std.debug.print("unexpected err: {s}\n", .{e.code.awsCode()});
            return error.TestUnexpectedError;
        },
    }
}

test "handle ListTables: populated list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const names = [_][]const u8{ "alpha", "beta" };
    var stub: StubBackend = .{ .names = &names };
    const ctx: Context = .{
        .backend = stub.backend(),
        .allocator = arena.allocator(),
        .request = .{ .target = "ListTables" },
    };
    const result = handle(ctx);
    switch (result) {
        .ok => |out| {
            try testing.expectEqualStrings("{\"TableNames\":[\"alpha\",\"beta\"]}", out.body);
        },
        .err => return error.TestUnexpectedError,
    }
}

test "handle: unknown target → ValidationException" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub: StubBackend = .{ .names = &.{} };
    const ctx: Context = .{
        .backend = stub.backend(),
        .allocator = arena.allocator(),
        .request = .{ .target = "BogusOperation" },
    };
    const result = handle(ctx);
    switch (result) {
        .ok => return error.TestUnexpectedSuccess,
        .err => |e| {
            try testing.expectEqual(errors.Code.validation_exception, e.code);
            try testing.expect(e.message != null);
            try testing.expect(std.mem.indexOf(u8, e.message.?, "BogusOperation") != null);
        },
    }
}
