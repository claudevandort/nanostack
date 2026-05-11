const std = @import("std");
const cli = @import("cli.zig");
const server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const config = cli.parse(args) catch |err| {
        std.log.err("cli parse failed: {s}", .{@errorName(err)});
        return err;
    };

    try server.run(arena, &config, init);
}
