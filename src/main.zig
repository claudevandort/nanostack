const std = @import("std");
const Allocator = std.mem.Allocator;

const cli = @import("cli.zig");
const server = @import("server.zig");
const storage = @import("storage/mod.zig");
const FsBackend = @import("storage/fs.zig");
const version = @import("version.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var config = cli.parse(args) catch |err| {
        std.log.err("cli parse failed: {s}", .{@errorName(err)});
        return err;
    };

    if (config.print_version) {
        const line = try std.fmt.allocPrint(arena, "nanostack v{s}\n", .{version.string});
        var buf: [128]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &buf);
        try stdout.interface.writeAll(line);
        try stdout.interface.flush();
        return;
    }

    const data_dir = try resolveDataDir(arena, init.environ_map, config.data_dir);
    config.data_dir = data_dir;

    const profile_root = try std.fmt.allocPrint(arena, "{s}/profiles/{s}", .{ data_dir, config.profile });
    const fs = try FsBackend.initWithOptions(arena, init.io, profile_root, .{
        .ttl_sweep_interval_seconds = config.ttl_sweep_interval_seconds,
    });
    defer fs.deinit();

    // DynamoDB backend is opt-in via --services. Default `s3` keeps the
    // M15 surface invisible until the user asks for it.
    const dynamo_backend: ?storage.DynamoBackend = if (config.hasService("dynamodb"))
        fs.dynamoBackend()
    else
        null;

    try server.run(arena, &config, init, fs.backend(), dynamo_backend);
}

fn resolveDataDir(
    allocator: Allocator,
    env: *std.process.Environ.Map,
    cli_value: ?[]const u8,
) ![]const u8 {
    const raw = cli_value orelse "~/.nanostack";
    if (std.mem.startsWith(u8, raw, "~/")) {
        const home = env.get("HOME") orelse return error.HomeNotSet;
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, raw[2..] });
    }
    if (std.mem.eql(u8, raw, "~")) {
        const home = env.get("HOME") orelse return error.HomeNotSet;
        return allocator.dupe(u8, home);
    }
    return allocator.dupe(u8, raw);
}
