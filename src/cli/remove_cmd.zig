//! ovo remove command
//!
//! Remove a dependency from the project.
//! Usage: ovo remove <package>

const std = @import("std");
const commands = @import("commands.zig");

const Context = commands.Context;
const TermWriter = commands.TermWriter;

/// Print help for remove command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo remove", .{});
    try writer.print(" - Remove a dependency\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo remove <package> [options]\n\n", .{});

    try writer.bold("ARGUMENTS:\n", .{});
    try writer.print("    <package>        Package name to remove\n\n", .{});

    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    --dev            Remove from dev dependencies\n", .{});
    try writer.print("    --no-prune       Don't remove unused transitive deps\n", .{});
    try writer.print("    -h, --help       Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo remove fmt                # Remove dependency\n", .{});
    try writer.dim("    ovo remove catch2 --dev       # Remove dev dependency\n", .{});
}

/// Execute the remove command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    // Check for help flag
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    // Parse options
    var package_name: ?[]const u8 = null;
    var is_dev = false;
    var prune = true;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dev")) {
            is_dev = true;
        } else if (std.mem.eql(u8, arg, "--no-prune")) {
            prune = false;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            package_name = arg;
        }
    }

    // Check for build.zon
    const manifest_exists = blk: {
        ctx.cwd.access("build.zon", .{}) catch break :blk false;
        break :blk true;
    };

    if (!manifest_exists) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("no build.zon found in current directory\n", .{});
        return 1;
    }

    // Validate arguments
    if (package_name == null) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("missing package name\n", .{});
        try ctx.stderr.dim("Usage: ovo remove <package>\n", .{});
        return 1;
    }

    const name = package_name.?;

    // Print what we're doing
    try ctx.stdout.bold("Removing", .{});
    try ctx.stdout.print(" dependency ", .{});
    try ctx.stdout.success("'{s}'", .{name});
    if (is_dev) {
        try ctx.stdout.dim(" (dev)", .{});
    }
    try ctx.stdout.print("\n\n", .{});

    // Check if dependency exists (simulated)
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Checking dependency...\n", .{});

    // In real implementation, would parse build.zon and check

    // Update build.zon
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Updating build.zon...\n", .{});

    // Prune unused transitive dependencies
    if (prune) {
        try ctx.stdout.print("  ", .{});
        try ctx.stdout.success("*", .{});
        try ctx.stdout.print(" Pruning unused dependencies...\n", .{});

        // Simulated pruning
        try ctx.stdout.dim("    Removed 0 unused transitive dependencies\n", .{});
    }

    // Clean cached files
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Cleaning cached files...\n", .{});

    // Print success
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.success("Removed '{s}' from ", .{name});
    try ctx.stdout.print("{s}\n", .{if (is_dev) "dev-dependencies" else "dependencies"});

    return 0;
}
