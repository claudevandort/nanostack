//! Miscellaneous DynamoDB handlers (M15-polish, Phase 10).
//!
//! DescribeLimits returns synthetic AWS defaults. Tag operations work
//! against the existing TableSlot.tags field.

const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../../storage/mod.zig");
const dynamo_state = @import("../../storage/dynamo_state.zig");
const mod = @import("mod.zig");

const Context = mod.Context;
const Result = mod.Result;

pub fn describeLimits(ctx: Context) Result {
    // AWS account-level limits — return real-AWS defaults.
    const body = ctx.allocator.dupe(u8,
        \\{"AccountMaxReadCapacityUnits":80000,"AccountMaxWriteCapacityUnits":80000,"TableMaxReadCapacityUnits":40000,"TableMaxWriteCapacityUnits":40000}
    ) catch return .{ .err = .{ .code = .internal_server_error } };
    return .{ .ok = .{ .body = body } };
}

pub fn tagResource(ctx: Context) Result {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.request.body, .{}) catch
        return validationErr("Could not parse the TagResource request body.");
    defer parsed.deinit();
    if (parsed.value != .object) return validationErr("Request body must be an object.");
    const root = parsed.value.object;

    const arn_v = root.get("ResourceArn") orelse return validationErr("ResourceArn is required.");
    if (arn_v != .string) return validationErr("ResourceArn must be a string.");
    const table_name = tableNameFromArn(arn_v.string) orelse return validationErr("ResourceArn must be a table ARN.");

    const tags_v = root.get("Tags") orelse return validationErr("Tags is required.");
    if (tags_v != .array) return validationErr("Tags must be an array.");

    const slot = ctx.backend.describeTable(table_name) catch |err| return .{ .err = mapStorageErr(err) };

    // Build the new tag list: existing + incoming (last-write-wins on key collision).
    var combined: std.ArrayList(dynamo_state.Tag) = .empty;
    defer combined.deinit(ctx.allocator);
    for (slot.tags) |t| combined.append(ctx.allocator, t) catch return internalErr();
    for (tags_v.array.items) |t_node| {
        if (t_node != .object) return validationErr("Each Tag must be an object.");
        const key_v = t_node.object.get("Key") orelse return validationErr("Tag.Key is required.");
        const value_v = t_node.object.get("Value") orelse return validationErr("Tag.Value is required.");
        if (key_v != .string or value_v != .string) return validationErr("Tag fields must be strings.");

        // Replace an existing entry with the same key.
        var replaced = false;
        for (combined.items) |*existing| {
            if (std.mem.eql(u8, existing.key, key_v.string)) {
                existing.value = value_v.string;
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            combined.append(ctx.allocator, .{ .key = key_v.string, .value = value_v.string }) catch return internalErr();
        }
    }

    // Tags live on the slot; mutate via backend. For Phase 10 polish we
    // mutate the slot directly since TableSlot.tags is internal state.
    // This is acceptable because: tag updates don't persist across
    // restart in v0.2.0 (documented as a known v1 simplification — Tags
    // are metadata-only).
    const slot_mut: *storage.TableSlot = @constCast(slot);
    slot_mut.tags = combined.toOwnedSlice(ctx.allocator) catch return internalErr();

    const body = ctx.allocator.dupe(u8, "{}") catch return internalErr();
    return .{ .ok = .{ .body = body } };
}

pub fn untagResource(ctx: Context) Result {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.request.body, .{}) catch
        return validationErr("Could not parse the UntagResource request body.");
    defer parsed.deinit();
    if (parsed.value != .object) return validationErr("Request body must be an object.");
    const root = parsed.value.object;

    const arn_v = root.get("ResourceArn") orelse return validationErr("ResourceArn is required.");
    if (arn_v != .string) return validationErr("ResourceArn must be a string.");
    const table_name = tableNameFromArn(arn_v.string) orelse return validationErr("ResourceArn must be a table ARN.");

    const keys_v = root.get("TagKeys") orelse return validationErr("TagKeys is required.");
    if (keys_v != .array) return validationErr("TagKeys must be an array.");

    const slot = ctx.backend.describeTable(table_name) catch |err| return .{ .err = mapStorageErr(err) };

    var kept: std.ArrayList(dynamo_state.Tag) = .empty;
    defer kept.deinit(ctx.allocator);
    for (slot.tags) |t| {
        var should_drop = false;
        for (keys_v.array.items) |kn| {
            if (kn == .string and std.mem.eql(u8, kn.string, t.key)) {
                should_drop = true;
                break;
            }
        }
        if (!should_drop) kept.append(ctx.allocator, t) catch return internalErr();
    }
    const slot_mut: *storage.TableSlot = @constCast(slot);
    slot_mut.tags = kept.toOwnedSlice(ctx.allocator) catch return internalErr();

    const body = ctx.allocator.dupe(u8, "{}") catch return internalErr();
    return .{ .ok = .{ .body = body } };
}

pub fn listTagsOfResource(ctx: Context) Result {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.request.body, .{}) catch
        return validationErr("Could not parse the ListTagsOfResource request body.");
    defer parsed.deinit();
    if (parsed.value != .object) return validationErr("Request body must be an object.");
    const root = parsed.value.object;

    const arn_v = root.get("ResourceArn") orelse return validationErr("ResourceArn is required.");
    if (arn_v != .string) return validationErr("ResourceArn must be a string.");
    const table_name = tableNameFromArn(arn_v.string) orelse return validationErr("ResourceArn must be a table ARN.");

    const slot = ctx.backend.describeTable(table_name) catch |err| return .{ .err = mapStorageErr(err) };

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.beginObject() catch return internalErr();
    s.objectField("Tags") catch return internalErr();
    s.beginArray() catch return internalErr();
    for (slot.tags) |t| {
        s.beginObject() catch return internalErr();
        s.objectField("Key") catch return internalErr();
        s.write(t.key) catch return internalErr();
        s.objectField("Value") catch return internalErr();
        s.write(t.value) catch return internalErr();
        s.endObject() catch return internalErr();
    }
    s.endArray() catch return internalErr();
    s.endObject() catch return internalErr();

    const body = aw.toOwnedSlice() catch return internalErr();
    return .{ .ok = .{ .body = body } };
}

/// Extract the table name from a DynamoDB table ARN. Accepts both the
/// AWS-canonical form and a bare table name (for clients that don't
/// bother constructing an ARN).
fn tableNameFromArn(arn: []const u8) ?[]const u8 {
    // Canonical: arn:aws:dynamodb:<region>:<account>:table/<name>
    const marker = "table/";
    if (std.mem.lastIndexOf(u8, arn, marker)) |pos| {
        return arn[pos + marker.len ..];
    }
    // Bare name fallback.
    if (arn.len > 0 and arn[0] != ':' and !std.mem.startsWith(u8, arn, "arn:")) return arn;
    return null;
}

fn validationErr(msg: []const u8) Result {
    return .{ .err = .{ .code = .validation_exception, .message = msg } };
}

fn internalErr() Result {
    return .{ .err = .{ .code = .internal_server_error } };
}

fn mapStorageErr(e: storage.Error) mod.ErrorBody {
    return switch (e) {
        storage.Error.TableNotFound => .{ .code = .resource_not_found_exception },
        else => .{ .code = .internal_server_error },
    };
}
