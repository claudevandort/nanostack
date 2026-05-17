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
const batch_handler = @import("batch.zig");
const tx_handler = @import("transactions.zig");
const misc_handler = @import("misc.zig");
const streams_handler = @import("streams.zig");
const partiql_handler = @import("partiql.zig");

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

pub const SubService = enum { core, streams };

pub const RequestData = struct {
    headers: []const storage.Header = &.{},
    body: []const u8 = "",
    /// X-Amz-Target value, post-prefix-strip — e.g. `ListTables`.
    target: []const u8 = "",
    /// Which target prefix matched on the way in.
    sub_service: SubService = .core,
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
/// (v0.2.2).
pub const target_prefix = "DynamoDB_20120810.";
pub const streams_target_prefix = "DynamoDBStreams_20120810.";

/// Dispatch a request based on the matched sub-service + the
/// X-Amz-Target suffix. The HTTP layer strips whichever prefix matched
/// and routes here.
pub fn handle(ctx: Context) Result {
    return switch (ctx.request.sub_service) {
        .core => handleCore(ctx),
        .streams => handleStreams(ctx),
    };
}

fn handleCore(ctx: Context) Result {
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

    // Batch ops (M15-batch, Phase 7).
    if (std.mem.eql(u8, target, "BatchGetItem")) return batch_handler.batchGetItem(ctx);
    if (std.mem.eql(u8, target, "BatchWriteItem")) return batch_handler.batchWriteItem(ctx);

    // Transactions (M15-tx, Phase 9).
    if (std.mem.eql(u8, target, "TransactGetItems")) return tx_handler.transactGetItems(ctx);
    if (std.mem.eql(u8, target, "TransactWriteItems")) return tx_handler.transactWriteItems(ctx);

    // Misc + metadata (M15-polish, Phase 10).
    if (std.mem.eql(u8, target, "DescribeLimits")) return misc_handler.describeLimits(ctx);
    if (std.mem.eql(u8, target, "TagResource")) return misc_handler.tagResource(ctx);
    if (std.mem.eql(u8, target, "UntagResource")) return misc_handler.untagResource(ctx);
    if (std.mem.eql(u8, target, "ListTagsOfResource")) return misc_handler.listTagsOfResource(ctx);

    // TTL (v0.2.3) — UpdateTimeToLive / DescribeTimeToLive.
    if (std.mem.eql(u8, target, "UpdateTimeToLive")) return tables.updateTimeToLive(ctx);
    if (std.mem.eql(u8, target, "DescribeTimeToLive")) return tables.describeTimeToLive(ctx);

    // PartiQL (v0.2.4).
    if (std.mem.eql(u8, target, "ExecuteStatement")) return partiql_handler.executeStatement(ctx);
    if (std.mem.eql(u8, target, "ExecuteTransaction")) return partiql_handler.executeTransaction(ctx);
    if (std.mem.eql(u8, target, "BatchExecuteStatement")) return partiql_handler.batchExecuteStatement(ctx);

    // Kinesis-streaming-destination ops are on the core DDB service
    // (not the Streams sub-service). We explicitly reject them so they
    // don't fall through to "Unsupported operation" — Kinesis isn't
    // emulated and we want consumers to see the precise reason.
    if (std.mem.eql(u8, target, "EnableKinesisStreamingDestination") or
        std.mem.eql(u8, target, "DisableKinesisStreamingDestination"))
    {
        const owned = ctx.allocator.dupe(u8, "Kinesis service is not enabled on this nanostack instance.") catch
            return .{ .err = .{ .code = .internal_server_error } };
        return .{ .err = .{ .code = .validation_exception, .message = owned } };
    }

    // Anything else gets 400 ValidationException with a message that
    // names the unsupported target. AWS-correct: unknown targets return
    // ValidationException, not 404.
    return unsupportedTarget(ctx, target);
}

/// Phase 3 stub for the DynamoDBStreams sub-service. Phases 4 + 5 fill
/// in ListStreams / DescribeStream / GetShardIterator / GetRecords.
/// Kinesis-tee ops (Enable/DisableKinesisStreamingDestination) are
/// explicitly rejected in Phase 7 — they're handled here so we don't
/// silently accept them.
fn handleStreams(ctx: Context) Result {
    const target = ctx.request.target;
    if (std.mem.eql(u8, target, "ListStreams")) return streams_handler.listStreams(ctx);
    if (std.mem.eql(u8, target, "DescribeStream")) return streams_handler.describeStream(ctx);
    if (std.mem.eql(u8, target, "GetShardIterator")) return streams_handler.getShardIterator(ctx);
    if (std.mem.eql(u8, target, "GetRecords")) return streams_handler.getRecords(ctx);
    return unsupportedTarget(ctx, target);
}

fn unsupportedTarget(ctx: Context, target: []const u8) Result {
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
            .transactGetItems = stubTxGet,
            .transactWriteItems = stubTxWrite,
            .listStreams = stubListStreams,
            .describeStream = stubDescribeStream,
            .getShardIterator = stubGetShardIterator,
            .getRecords = stubGetRecords,
            .updateTimeToLive = stubUpdateTimeToLive,
            .describeTimeToLive = stubDescribeTimeToLive,
        } };
    }
    fn stubUpdateTimeToLive(_: *anyopaque, _: storage.UpdateTimeToLiveInput) storage.Error!storage.dynamo_state.TimeToLiveSpec {
        unreachable;
    }
    fn stubDescribeTimeToLive(_: *anyopaque, _: []const u8) storage.Error!?storage.dynamo_state.TimeToLiveSpec {
        unreachable;
    }
    fn stubListStreams(_: *anyopaque, _: Allocator, _: storage.ListStreamsInput) storage.Error!storage.ListStreamsOutput {
        unreachable;
    }
    fn stubDescribeStream(_: *anyopaque, _: Allocator, _: storage.DescribeStreamInput) storage.Error!storage.DescribeStreamOutput {
        unreachable;
    }
    fn stubGetShardIterator(_: *anyopaque, _: Allocator, _: storage.GetShardIteratorInput) storage.Error![]const u8 {
        unreachable;
    }
    fn stubGetRecords(_: *anyopaque, _: Allocator, _: storage.GetRecordsInput) storage.Error!storage.GetRecordsOutput {
        unreachable;
    }
    fn stubQuery(_: *anyopaque, _: Allocator, _: storage.QueryInput) storage.Error!storage.QueryResult {
        unreachable;
    }
    fn stubTxGet(_: *anyopaque, _: Allocator, _: []const storage.TxGetItem) storage.Error!storage.TxGetResult {
        unreachable;
    }
    fn stubTxWrite(_: *anyopaque, _: Allocator, _: []const storage.TxWriteOp, _: *[]?[]const u8) storage.Error!void {
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
