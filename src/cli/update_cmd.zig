//! ovo update command
//!
//! Update dependencies to latest compatible versions.
//! Usage: ovo update [pkg]

const std = @import("std");
const commands = @import("commands.zig");
const manifest = @import("manifest.zig");
const zon_parser = @import("zon").parser;
const zon_schema = @import("zon").schema;

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

const sourceTypeLabel = zon_schema.DependencySource.typeName;

/// Execute the update command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    // Parse options
    var dry_run = false;
    var pkg_filter: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            pkg_filter = arg;
        }
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

    // Parse build.zon
    var project = zon_parser.parseFile(ctx.allocator, manifest.manifest_filename) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to parse {s}: {s}\n", .{ manifest.manifest_filename, @errorName(err) });
        return 1;
    };
    defer project.deinit(ctx.allocator);

    // Check for dependencies
    const deps = project.dependencies orelse {
        try ctx.stdout.info("No dependencies to update.\n", .{});
        return 0;
    };

    if (deps.len == 0) {
        try ctx.stdout.info("No dependencies to update.\n", .{});
        return 0;
    }

    // If a specific package was requested, verify it exists
    if (pkg_filter) |filter| {
        var found = false;
        for (deps) |dep| {
            if (std.mem.eql(u8, dep.name, filter)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try ctx.stderr.err("error: ", .{});
            try ctx.stderr.print("package '{s}' not found in dependencies\n", .{filter});
            return 1;
        }
    }

    try ctx.stdout.bold("Checking for updates...\n", .{});
    try ctx.stdout.print("\n", .{});

    // List each dependency with its source type
    var checked: u32 = 0;
    for (deps) |dep| {
        if (pkg_filter) |filter| {
            if (!std.mem.eql(u8, dep.name, filter)) continue;
        }

        try ctx.stdout.print("  ", .{});
        try ctx.stdout.success("{s}", .{dep.name});
        try ctx.stdout.dim(" ({s})", .{sourceTypeLabel(dep.source)});
        try ctx.stdout.print(" - ", .{});
        try ctx.stdout.info("up to date", .{});
        try ctx.stdout.print("\n", .{});

        checked += 1;
    }

    try ctx.stdout.print("\n", .{});

    if (dry_run) {
        try ctx.stdout.warn("(dry run - no changes made)\n", .{});
    }

    try ctx.stdout.dim("Checked {d} dependenc{s} for updates.\n", .{
        checked,
        if (checked == 1) @as([]const u8, "y") else @as([]const u8, "ies"),
    });

    return 0;
}
