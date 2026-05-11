const std = @import("std");
const Allocator = std.mem.Allocator;

const cli = @import("cli.zig");
const server = @import("server.zig");
const storage = @import("storage/mod.zig");
const FsBackend = @import("storage/fs.zig");
const MemBackend = @import("storage/mem.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var config = cli.parse(args) catch |err| {
        std.log.err("cli parse failed: {s}", .{@errorName(err)});
        return err;
    };

    const data_dir = try resolveDataDir(arena, init.environ_map, config.data_dir);
    config.data_dir = data_dir;

    if (config.ephemeral) {
        const mem = try MemBackend.init(arena, init.io);
        defer mem.deinit();
        try server.run(arena, &config, init, mem.backend());
        return;
    }

    const profile_root = try std.fmt.allocPrint(arena, "{s}/profiles/{s}", .{ data_dir, config.profile });
    const fs = try FsBackend.init(arena, init.io, profile_root);
    defer fs.deinit();
    try server.run(arena, &config, init, fs.backend());
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
