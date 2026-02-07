//! ovo doc command
//!
//! Generate documentation for the project.
//! Usage: ovo doc

const std = @import("std");
const builtin = @import("builtin");
const commands = @import("commands.zig");
const manifest = @import("manifest.zig");

const Context = commands.Context;
const TermWriter = commands.TermWriter;

/// Print help for doc command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo doc", .{});
    try writer.print(" - Generate documentation\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo doc [options]\n\n", .{});

    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    --open            Open documentation in browser after generation\n", .{});
    try writer.print("    -o, --output <dir> Output directory (default: docs/)\n", .{});
    try writer.print("    --format <fmt>     Format: doxygen, clang-doc (default: auto)\n", .{});
    try writer.print("    -h, --help         Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo doc                 # Generate docs to docs/\n", .{});
    try writer.dim("    ovo doc --open           # Generate and open in browser\n", .{});
    try writer.dim("    ovo doc -o html/         # Output to html/\n", .{});
}

/// Search PATH for an executable by name.
fn findInPath(name: []const u8) bool {
    var key_buf: [8]u8 = undefined;
    const key = "PATH";
    @memcpy(key_buf[0..key.len], key);
    key_buf[key.len] = 0;

    const path_env_ptr = std.c.getenv(@ptrCast(&key_buf)) orelse return false;
    const path_env = std.mem.span(path_env_ptr);

    var iter = std.mem.splitScalar(u8, path_env, if (builtin.os.tag == .windows) ';' else ':');
    while (iter.next()) |dir| {
        var check_buf: [4096]u8 = undefined;
        if (dir.len + 1 + name.len >= check_buf.len) continue;
        @memcpy(check_buf[0..dir.len], dir);
        check_buf[dir.len] = '/';
        @memcpy(check_buf[dir.len + 1 ..][0..name.len], name);
        check_buf[dir.len + 1 + name.len] = 0;
        if (std.c.access(@ptrCast(&check_buf), std.c.F_OK) == 0) return true;
    }
    return false;
}

/// Execute the doc command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    const manifest_exists = blk: {
        ctx.cwd.access(manifest.manifest_filename, .{}) catch break :blk false;
        break :blk true;
    };

    if (!manifest_exists) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("no {s} found in current directory\n", .{manifest.manifest_filename});
        return 1;
    }

    if (findInPath("doxygen")) {
        try ctx.stdout.success("Found doxygen", .{});
        try ctx.stdout.print(" in PATH.\n", .{});
        try ctx.stdout.dim("  Run 'doxygen -g' to generate a Doxyfile, then 'doxygen' to build docs.\n", .{});
        return 0;
    }

    if (findInPath("clang-doc")) {
        try ctx.stdout.success("Found clang-doc", .{});
        try ctx.stdout.print(" in PATH.\n", .{});
        try ctx.stdout.dim("  Run 'clang-doc --format=html src/' to generate documentation.\n", .{});
        return 0;
    }

    try ctx.stderr.warn("No documentation generator found.\n", .{});
    try ctx.stderr.print("  Install one of the following to use 'ovo doc':\n", .{});
    try ctx.stderr.print("    - doxygen   (https://www.doxygen.nl)\n", .{});
    try ctx.stderr.print("    - clang-doc (part of LLVM/Clang tools)\n", .{});
    return 1;
}
