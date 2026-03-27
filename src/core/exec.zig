const std = @import("std");
const runtime = @import("runtime.zig");

pub fn runInherit(argv: []const []const u8) !u8 {
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

pub fn runQuiet(argv: []const []const u8) !u8 {
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

pub fn commandExists(command: []const u8) bool {
    const code = runQuiet(&.{ "which", command }) catch return false;
    return code == 0;
}
