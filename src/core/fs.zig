const std = @import("std");
const runtime = @import("runtime.zig");

pub fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(runtime.io(), path, .{}) catch return false;
    return true;
}

pub fn ensureDir(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(runtime.io(), path);
}

pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    const parent = std.fs.path.dirname(path);
    if (parent) |dir| {
        if (dir.len > 0) try ensureDir(dir);
    }
    try std.Io.Dir.cwd().writeFile(runtime.io(), .{
        .sub_path = path,
        .data = bytes,
        .flags = .{ .truncate = true },
    });
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        runtime.io(),
        path,
        allocator,
        .limited(32 * 1024 * 1024),
    );
}

pub fn removeTreeIfExists(path: []const u8) !void {
    std.Io.Dir.cwd().deleteTree(runtime.io(), path) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
}

pub fn deleteFileIfExists(path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(runtime.io(), path) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
}

pub fn copyFile(source_path: []const u8, destination_path: []const u8) !void {
    try std.Io.Dir.copyFileAbsolute(source_path, destination_path, runtime.io(), .{});
}

pub fn currentPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    return std.process.currentPathAlloc(runtime.io(), allocator);
}
