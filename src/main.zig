const std = @import("std");
const cli = @import("cli/mod.zig");
const core = @import("core/mod.zig");

pub fn main(init: std.process.Init) !void {
    core.runtime.setIo(init.io);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const exit_code = try cli.run(gpa.allocator(), init.minimal.args);
    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}
