//! ovo doctor command
//!
//! Diagnose environment and project configuration issues.
//! Usage: ovo doctor

const std = @import("std");
const builtin = @import("builtin");
const commands = @import("commands.zig");
const manifest = @import("manifest.zig");

const Context = commands.Context;
const TermWriter = commands.TermWriter;

/// Print help for doctor command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo doctor", .{});
    try writer.print(" - Diagnose environment and project issues\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo doctor [options]\n\n", .{});

    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    -h, --help    Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo doctor    # Run diagnostics\n", .{});
}

fn inPath(allocator: std.mem.Allocator, name: []const u8) bool {
    var key_buf: [8]u8 = undefined;
    @memcpy(key_buf[0..4], "PATH");
    key_buf[4] = 0;
    const path_env = std.c.getenv(@ptrCast(&key_buf)) orelse return false;
    const path_str = std.mem.span(path_env);
    var iter = std.mem.splitScalar(u8, path_str, if (builtin.os.tag == .windows) ';' else ':');
    while (iter.next()) |dir| {
        const full = std.fs.path.join(allocator, &.{ dir, name }) catch continue;
        defer allocator.free(full);
        var path_buf: [4096]u8 = undefined;
        if (full.len >= path_buf.len) continue;
        @memcpy(path_buf[0..full.len], full);
        path_buf[full.len] = 0;
        if (std.c.access(@ptrCast(&path_buf), std.c.F_OK) == 0) return true;
    }
    return false;
}

/// Execute the doctor command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    try ctx.stdout.bold("OVO Doctor\n", .{});
    try ctx.stdout.print("\n", .{});

    var ok: u32 = 0;
    var warn: u32 = 0;

    // Check Zig version
    try ctx.stdout.print("  Zig: ", .{});
    try ctx.stdout.success("{s}\n", .{builtin.zig_version_string});
    ok += 1;

    // Check build.zon
    try ctx.stdout.print("  ", .{});
    const manifest_exists = blk: {
        ctx.cwd.access(manifest.manifest_filename, .{}) catch break :blk false;
        break :blk true;
    };
    if (manifest_exists) {
        try ctx.stdout.success("*", .{});
        try ctx.stdout.print(" {s}: found\n", .{manifest.manifest_filename});
        ok += 1;
    } else {
        try ctx.stdout.warn("!", .{});
        try ctx.stdout.print(" {s}: not found (run 'ovo init')\n", .{manifest.manifest_filename});
        warn += 1;
    }

    // Check compilers in PATH
    try ctx.stdout.print("  ", .{});
    const has_clang = inPath(ctx.allocator, if (builtin.os.tag == .windows) "clang.exe" else "clang");
    const has_gcc = inPath(ctx.allocator, if (builtin.os.tag == .windows) "gcc.exe" else "gcc");
    if (has_clang or has_gcc) {
        try ctx.stdout.success("*", .{});
        try ctx.stdout.print(" Compilers: ", .{});
        if (has_clang) try ctx.stdout.print("clang ", .{});
        if (has_gcc) try ctx.stdout.print("gcc ", .{});
        try ctx.stdout.print("\n", .{});
        ok += 1;
    } else {
        try ctx.stdout.warn("!", .{});
        try ctx.stdout.print(" No clang/gcc in PATH (Zig CC may still work)\n", .{});
        warn += 1;
    }

    try ctx.stdout.print("\n", .{});
    try ctx.stdout.success("Diagnostics complete", .{});
    try ctx.stdout.print(" ({d} ok, {d} warnings)\n", .{ ok, warn });
    return 0;
}
