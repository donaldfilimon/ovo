const std = @import("std");
const runtime = @import("runtime.zig");

// NOTE: allocator params are currently unused but kept for API consistency.
// All 13+ call sites pass ctx.allocator; removing it would be a large
// signature change with no behavioral benefit. Revisit if spawn() gains
// allocator-based features in future Zig versions.

pub fn runInherit(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
    _ = allocator;
    var child = try std.process.spawn(runtime.io(), .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(runtime.io());
    return switch (term) {
        .exited => |code| @as(u8, @intCast(code)),
        .signal => 128,
        .stopped => 129,
        .unknown => 130,
    };
}

pub fn runQuiet(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
    _ = allocator;
    var child = try std.process.spawn(runtime.io(), .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(runtime.io());
    return switch (term) {
        .exited => |code| @as(u8, @intCast(code)),
        .signal => 128,
        .stopped => 129,
        .unknown => 130,
    };
}

pub fn commandExists(allocator: std.mem.Allocator, command: []const u8) bool {
    // Use 'which' to check PATH lookup — works for all commands regardless
    // of whether they support --version
    const code = runQuiet(allocator, &.{ "which", command }) catch return false;
    return code == 0;
}
