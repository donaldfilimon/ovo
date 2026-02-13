const std = @import("std");
const args = @import("args.zig");
const dispatch = @import("command_dispatch.zig");
const Context = @import("context.zig").Context;

pub fn run(allocator: std.mem.Allocator, process_args: std.process.Args) !u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(arena_alloc);

    var iterator = try process_args.iterateAllocator(arena_alloc);
    defer iterator.deinit();
    while (iterator.next()) |arg| {
        try argv.append(arena_alloc, arg[0..arg.len]);
    }

    var parsed = try args.parse(argv.items);
    if (parsed.cwd) |cwd| {
        try std.Io.Threaded.chdir(cwd);
    }

    var ctx = Context{
        .allocator = arena_alloc,
        .cwd_path = ".",
        .profile = parsed.profile,
        .verbose = parsed.verbose,
        .quiet = parsed.quiet,
    };
    return dispatch.dispatch(&ctx, &parsed);
}
