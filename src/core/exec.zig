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

pub const CaptureResult = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,
};

pub fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) !CaptureResult {
    const result = try std.process.run(allocator, runtime.io(), .{ .argv = argv });
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        .signal => 128,
        .stopped => 129,
        .unknown => 130,
    };
    return .{
        .code = code,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

pub fn commandExists(allocator: std.mem.Allocator, command: []const u8) bool {
    // Use 'which' to check PATH lookup — works for all commands regardless
    // of whether they support --version
    const code = runQuiet(allocator, &.{ "which", command }) catch return false;
    return code == 0;
}
