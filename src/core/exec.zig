const std = @import("std");
const runtime = @import("runtime.zig");

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
    const code = runQuiet(allocator, &.{ command, "--version" }) catch return false;
    return code == 0;
}
