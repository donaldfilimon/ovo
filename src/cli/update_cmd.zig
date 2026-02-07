//! ovo update command
//!
//! Update dependencies to latest compatible versions.
//! Usage: ovo update [pkg]

const std = @import("std");
const commands = @import("commands.zig");
const manifest = @import("manifest.zig");

const Context = commands.Context;
const TermWriter = commands.TermWriter;

/// Print help for update command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo update", .{});
    try writer.print(" - Update dependencies to latest compatible versions\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo update [pkg] [options]\n\n", .{});

    try writer.bold("ARGUMENTS:\n", .{});
    try writer.print("    [pkg]           Optional: update specific package only\n\n", .{});

    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    --dry-run       Show what would be updated without changing\n", .{});
    try writer.print("    -h, --help       Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo update              # Update all dependencies\n", .{});
    try writer.dim("    ovo update fmt          # Update only fmt package\n", .{});
    try writer.dim("    ovo fetch --update      # Equivalent: fetch with update flag\n", .{});
}

/// Execute the update command
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

    try ctx.stdout.info("update", .{});
    try ctx.stdout.print(": Use 'ovo fetch --update' for now\n", .{});
    try ctx.stdout.dim("  Full update command coming soon.\n", .{});
    return 0;
}
