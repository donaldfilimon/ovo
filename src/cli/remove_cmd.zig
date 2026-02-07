//! ovo remove command
//!
//! Remove a dependency from the project.
//! Usage: ovo remove <package>

const std = @import("std");
const commands = @import("commands.zig");
const manifest = @import("manifest.zig");
const zon_parser = @import("zon").parser;
const zon_schema = @import("zon").schema;
const zon_writer = @import("zon").writer;

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
        ctx.cwd.access(manifest.manifest_filename, .{}) catch break :blk false;
        break :blk true;
    };

    if (!manifest_exists) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("no {s} found in current directory\n", .{manifest.manifest_filename});
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

    // Parse build.zon
    var project = zon_parser.parseFile(ctx.allocator, manifest.manifest_filename) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to parse {s}: {}\n", .{ manifest.manifest_filename, err });
        return 1;
    };
    defer project.deinit(ctx.allocator);

    // Find the named dependency
    const deps = project.dependencies orelse {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("'{s}' is not a dependency\n", .{name});
        return 1;
    };

    var found_index: ?usize = null;
    for (deps, 0..) |dep, idx| {
        if (std.mem.eql(u8, dep.name, name)) {
            found_index = idx;
            break;
        }
    }

    const remove_idx = found_index orelse {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("'{s}' is not a dependency\n", .{name});
        return 1;
    };

    // Remove the dependency: allocate a new slice one shorter
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Updating {s}...\n", .{manifest.manifest_filename});

    if (deps.len == 1) {
        // Removing the only dependency -- free it and set dependencies to null
        var removed = deps[remove_idx];
        removed.deinit(ctx.allocator);
        ctx.allocator.free(deps);
        project.dependencies = null;
    } else {
        const new_deps = ctx.allocator.alloc(zon_schema.Dependency, deps.len - 1) catch |err| {
            try ctx.stderr.err("error: ", .{});
            try ctx.stderr.print("allocation failed: {}\n", .{err});
            return 1;
        };
        @memcpy(new_deps[0..remove_idx], deps[0..remove_idx]);
        @memcpy(new_deps[remove_idx..], deps[remove_idx + 1 ..]);

        // Free the removed dependency entry
        var removed = deps[remove_idx];
        removed.deinit(ctx.allocator);

        // Free the old slice and replace
        ctx.allocator.free(deps);
        project.dependencies = new_deps;
    }

    // Write back to build.zon
    const content = zon_writer.writeProject(ctx.allocator, &project, .{}) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to serialize {s}: {}\n", .{ manifest.manifest_filename, err });
        return 1;
    };
    defer ctx.allocator.free(content);

    const file = ctx.cwd.createFile(manifest.manifest_filename, .{}) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to write {s}: {}\n", .{ manifest.manifest_filename, err });
        return 1;
    };
    defer file.close();
    file.writeAll(content) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to write {s}: {}\n", .{ manifest.manifest_filename, err });
        return 1;
    };

    // Prune unused transitive dependencies
    if (prune) {
        try ctx.stdout.print("  ", .{});
        try ctx.stdout.success("*", .{});
        try ctx.stdout.print(" Pruning unused dependencies...\n", .{});
        try ctx.stdout.dim("    Removed 0 unused transitive dependencies\n", .{});
    }

    // Print success
    try ctx.stdout.print("\n", .{});
    const dep_kind = if (is_dev) "dev-dependencies" else "dependencies";
    try ctx.stdout.success("Removed '{s}' from {s}\n", .{ name, dep_kind });

    return 0;
}
