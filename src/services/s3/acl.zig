//! S3 ACL service handlers (M10).
//!
//! 4 handlers: Put/Get on bucket and object. AWS has no DeleteAcl op;
//! the canned `private` value resets an ACL.
//!
//! Accept-store-roundtrip — no enforcement.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const acl_parser = @import("../../wire/acl_parser.zig");
const acl_responses = @import("../../wire/acl_responses.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

/// Parse the request body OR (if body is empty) the `x-amz-acl` + grant
/// headers into a freshly-owned Acl. Caller owns the result.
fn parseAclFromRequest(ctx: Context) ParseOutcome {
    // Prefer the XML body when present.
    const has_body = ctx.request.body.len > 0;
    if (has_body) {
        const acl = acl_parser.parseBody(ctx.allocator, ctx.request.body) catch |err| switch (err) {
            acl_parser.ParseError.MalformedAcl => return .{ .err = .malformed_acl_error },
            acl_parser.ParseError.UnknownCannedAcl => return .{ .err = .invalid_argument },
            acl_parser.ParseError.OutOfMemory => return .{ .err = .internal_error },
        };
        return .{ .ok = acl };
    }
    // Header-only path: canned + grants.
    const canned_str = mod.findHeader(ctx.request.headers, "x-amz-acl") orelse "private";
    const canned = acl_parser.parseCanned(canned_str) catch return .{ .err = .invalid_argument };
    var acl = acl_parser.cannedToAcl(ctx.allocator, canned) catch return .{ .err = .internal_error };

    // Fold grant headers in.
    const Pair = struct { name: []const u8, perm: storage.Permission };
    const headers = [_]Pair{
        .{ .name = "x-amz-grant-read", .perm = .READ },
        .{ .name = "x-amz-grant-write", .perm = .WRITE },
        .{ .name = "x-amz-grant-read-acp", .perm = .READ_ACP },
        .{ .name = "x-amz-grant-write-acp", .perm = .WRITE_ACP },
        .{ .name = "x-amz-grant-full-control", .perm = .FULL_CONTROL },
    };
    for (headers) |h| {
        const v = mod.findHeader(ctx.request.headers, h.name) orelse continue;
        const extras = acl_parser.parseGrantHeader(ctx.allocator, v, h.perm) catch {
            acl_parser.freeAclOwned(ctx.allocator, acl);
            return .{ .err = .malformed_acl_error };
        };
        acl = acl_parser.mergeGrants(ctx.allocator, acl, extras) catch {
            acl_parser.freeAclOwned(ctx.allocator, acl);
            return .{ .err = .internal_error };
        };
    }
    return .{ .ok = acl };
}

const ParseOutcome = union(enum) {
    ok: storage.Acl,
    err: mod.errors.Code,
};

pub fn putBucketAcl(ctx: Context, bucket: []const u8) Result {
    switch (parseAclFromRequest(ctx)) {
        .err => |c| return .{ .err = c },
        .ok => |acl| {
            defer acl_parser.freeAclOwned(ctx.allocator, acl);
            ctx.backend.putBucketAcl(bucket, acl) catch |err| return .{ .err = mod.mapStorageErr(err) };
            return .{ .ok = .{ .status = 200, .body = "" } };
        },
    }
}

pub fn getBucketAcl(ctx: Context, bucket: []const u8) Result {
    const acl = ctx.backend.getBucketAcl(ctx.allocator, bucket) catch |err| return .{ .err = mod.mapStorageErr(err) };
    defer acl_parser.freeAclOwned(ctx.allocator, acl);
    const body = acl_responses.renderAccessControlPolicy(ctx.allocator, acl) catch return .{ .err = .internal_error };
    return .{ .ok = .{ .status = 200, .body = body } };
}

pub fn putObjectAcl(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const version_id = mod.queryValue(ctx.allocator, ctx.request.query, "versionId") catch return .{ .err = .internal_error };
    switch (parseAclFromRequest(ctx)) {
        .err => |c| return .{ .err = c },
        .ok => |acl| {
            defer acl_parser.freeAclOwned(ctx.allocator, acl);
            ctx.backend.putObjectAcl(bucket, key, version_id, acl) catch |err| return .{ .err = mod.mapStorageErr(err) };
            if (version_id) |vid| {
                const hs = ctx.allocator.dupe(mod.Header, &.{
                    .{ .name = "x-amz-version-id", .value = vid },
                }) catch return .{ .err = .internal_error };
                return .{ .ok = .{ .status = 200, .body = "", .extra_headers = hs } };
            }
            return .{ .ok = .{ .status = 200, .body = "" } };
        },
    }
}

pub fn getObjectAcl(ctx: Context, bucket: []const u8, key: []const u8) Result {
    const version_id = mod.queryValue(ctx.allocator, ctx.request.query, "versionId") catch return .{ .err = .internal_error };
    const acl = ctx.backend.getObjectAcl(ctx.allocator, bucket, key, version_id) catch |err| return .{ .err = mod.mapStorageErr(err) };
    defer acl_parser.freeAclOwned(ctx.allocator, acl);
    const body = acl_responses.renderAccessControlPolicy(ctx.allocator, acl) catch return .{ .err = .internal_error };
    if (version_id) |vid| {
        const hs = ctx.allocator.dupe(mod.Header, &.{
            .{ .name = "x-amz-version-id", .value = vid },
        }) catch return .{ .err = .internal_error };
        return .{ .ok = .{ .status = 200, .body = body, .extra_headers = hs } };
    }
    return .{ .ok = .{ .status = 200, .body = body } };
}
