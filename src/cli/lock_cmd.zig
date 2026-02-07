//! ovo lock command
//!
//! Generate or update the lock file from build.zon.
//! Usage: ovo lock

const std = @import("std");
const commands = @import("commands.zig");
const manifest = @import("manifest.zig");

const Context = commands.Context;
const TermWriter = commands.TermWriter;

/// Print help for lock command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo lock", .{});
    try writer.print(" - Generate lock file from build.zon\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo lock [options]\n\n", .{});

    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    -h, --help    Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo lock       # Generate ovo.lock from dependencies\n", .{});
    try writer.dim("    ovo fetch      # Fetch also generates/updates lock file\n", .{});
}

/// Execute the lock command
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

    try ctx.stdout.info("Lock", .{});
    try ctx.stdout.print(" file written to {s}\n", .{manifest.lock_filename});
    try ctx.stdout.dim("  Run 'ovo fetch' to resolve and lock dependencies.\n", .{});
    return 0;
}
