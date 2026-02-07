//! ovo deps command
//!
//! Show dependency tree.
//! Usage: ovo deps [--why <pkg>]

const std = @import("std");
const commands = @import("commands.zig");
const manifest = @import("manifest.zig");
const zon_parser = @import("zon").parser;

const Context = commands.Context;
const TermWriter = commands.TermWriter;
const Color = commands.Color;

/// Print help for deps command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo deps", .{});
    try writer.print(" - Show dependency tree\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo deps [options]\n\n", .{});

    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    --why <pkg>      Show why a package is included\n", .{});
    try writer.print("    --depth <n>      Maximum tree depth (default: unlimited)\n", .{});
    try writer.print("    --flat           Show flat list instead of tree\n", .{});
    try writer.print("    --dev            Include dev dependencies\n", .{});
    try writer.print("    --duplicates     Show duplicate packages\n", .{});
    try writer.print("    --json           Output as JSON\n", .{});
    try writer.print("    -h, --help       Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo deps                     # Show dependency tree\n", .{});
    try writer.dim("    ovo deps --why spdlog        # Why is spdlog needed?\n", .{});
    try writer.dim("    ovo deps --flat              # Flat list\n", .{});
    try writer.dim("    ovo deps --depth 2           # Limit depth\n", .{});
}

/// Dependency node for tree display
const DepNode = struct {
    name: []const u8,
    version: []const u8,
    source: []const u8,
    is_dev: bool,
    children: []const DepNode,
};

/// Execute the deps command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    // Check for help flag
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    // Parse options
    var why_pkg: ?[]const u8 = null;
    var max_depth: ?u32 = null;
    var flat = false;
    var include_dev = false;
    var show_duplicates = false;
    var json_output = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--why") and i + 1 < args.len) {
            i += 1;
            why_pkg = args[i];
        } else if (std.mem.startsWith(u8, arg, "--why=")) {
            why_pkg = arg["--why=".len..];
        } else if (std.mem.eql(u8, arg, "--depth") and i + 1 < args.len) {
            i += 1;
            max_depth = std.fmt.parseInt(u32, args[i], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--flat")) {
            flat = true;
        } else if (std.mem.eql(u8, arg, "--dev")) {
            include_dev = true;
        } else if (std.mem.eql(u8, arg, "--duplicates")) {
            show_duplicates = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        }
    }

    // Parse build.zon
    var project = zon_parser.parseFile(ctx.allocator, manifest.manifest_filename) catch |err| {
        try ctx.stderr.err("error: ", .{});
        switch (err) {
            error.FileNotFound => try ctx.stderr.print("no " ++ manifest.manifest_filename ++ " found in current directory\n", .{}),
            else => try ctx.stderr.print("failed to parse " ++ manifest.manifest_filename ++ ": {}\n", .{err}),
        }
        return 1;
    };
    defer project.deinit(ctx.allocator);

    // Format project version string
    const version_str = try std.fmt.allocPrint(ctx.allocator, "{d}.{d}.{d}", .{
        project.version.major,
        project.version.minor,
        project.version.patch,
    });
    defer ctx.allocator.free(version_str);

    // Build DepNode array from parsed dependencies
    var nodes_list: std.ArrayListUnmanaged(DepNode) = .empty;
    defer nodes_list.deinit(ctx.allocator);

    if (project.dependencies) |deps| {
        for (deps) |dep| {
            const source_str: []const u8 = switch (dep.source) {
                .git => "git",
                .url => "url",
                .path => "path",
                .vcpkg => "vcpkg",
                .conan => "conan",
                .system => "system",
            };
            try nodes_list.append(ctx.allocator, .{
                .name = dep.name,
                .version = "latest",
                .source = source_str,
                .is_dev = false,
                .children = &.{},
            });
        }
    }

    const root_deps = nodes_list.items;

    // Handle --why query
    if (why_pkg) |pkg| {
        return showWhyPackage(ctx, pkg, root_deps, project.name);
    }

    // JSON output
    if (json_output) {
        try ctx.stdout.print("[\n", .{});
        for (root_deps, 0..) |dep, idx| {
            if (!include_dev and dep.is_dev) continue;
            try printDepJson(ctx, &dep, 1);
            if (idx < root_deps.len - 1) {
                try ctx.stdout.print(",\n", .{});
            }
        }
        try ctx.stdout.print("\n]\n", .{});
        return 0;
    }

    // Header
    try ctx.stdout.bold("Dependency Tree\n\n", .{});

    // Flat list
    if (flat) {
        return showFlatList(ctx, root_deps, include_dev);
    }

    // Tree view
    try ctx.stdout.success("{s}", .{project.name});
    try ctx.stdout.dim(" v{s}\n", .{version_str});

    var total_deps: u32 = 0;
    var dev_deps: u32 = 0;

    for (root_deps, 0..) |dep, idx| {
        if (!include_dev and dep.is_dev) continue;

        const is_last = blk: {
            var remaining: usize = 0;
            for (root_deps[idx + 1 ..]) |d| {
                if (include_dev or !d.is_dev) remaining += 1;
            }
            break :blk remaining == 0;
        };

        try printDepTree(ctx, &dep, "", is_last, max_depth, 0, include_dev);

        total_deps += 1;
        if (dep.is_dev) dev_deps += 1;
        total_deps += countChildren(&dep);
    }

    // Summary
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.dim("{d} dependencies", .{total_deps - dev_deps});
    if (include_dev and dev_deps > 0) {
        try ctx.stdout.dim(" + {d} dev", .{dev_deps});
    }
    try ctx.stdout.print("\n", .{});

    // Show duplicates if requested
    if (show_duplicates) {
        try ctx.stdout.print("\n", .{});
        try ctx.stdout.bold("Duplicates:\n", .{});
        try ctx.stdout.dim("  (no transitive dependencies resolved yet)\n", .{});
    }

    return 0;
}

fn printDepTree(
    ctx: *Context,
    dep: *const DepNode,
    prefix: []const u8,
    is_last: bool,
    max_depth: ?u32,
    depth: u32,
    include_dev: bool,
) !void {
    // Check depth limit
    if (max_depth) |max| {
        if (depth >= max) return;
    }

    // Print connector
    try ctx.stdout.print("{s}", .{prefix});
    if (is_last) {
        try ctx.stdout.dim("+-", .{});
    } else {
        try ctx.stdout.dim("|-", .{});
    }

    // Print package info
    try ctx.stdout.success(" {s}", .{dep.name});
    try ctx.stdout.dim(" v{s}", .{dep.version});

    if (dep.is_dev) {
        try ctx.stdout.warn(" (dev)", .{});
    }

    if (!std.mem.eql(u8, dep.source, "registry")) {
        try ctx.stdout.dim(" [{s}]", .{dep.source});
    }

    try ctx.stdout.print("\n", .{});

    // Print children
    const new_prefix = if (is_last)
        try std.fmt.allocPrint(ctx.allocator, "{s}  ", .{prefix})
    else
        try std.fmt.allocPrint(ctx.allocator, "{s}| ", .{prefix});
    defer ctx.allocator.free(new_prefix);

    for (dep.children, 0..) |child, idx| {
        if (!include_dev and child.is_dev) continue;
        const child_is_last = idx == dep.children.len - 1;
        try printDepTree(ctx, &child, new_prefix, child_is_last, max_depth, depth + 1, include_dev);
    }
}

fn printDepJson(ctx: *Context, dep: *const DepNode, indent: u32) !void {
    const spaces = "                    "[0 .. indent * 2];

    try ctx.stdout.print("{s}{{\n", .{spaces});
    try ctx.stdout.print("{s}  \"name\": \"{s}\",\n", .{ spaces, dep.name });
    try ctx.stdout.print("{s}  \"version\": \"{s}\",\n", .{ spaces, dep.version });
    try ctx.stdout.print("{s}  \"source\": \"{s}\",\n", .{ spaces, dep.source });
    try ctx.stdout.print("{s}  \"dev\": {s}", .{ spaces, if (dep.is_dev) "true" else "false" });

    if (dep.children.len > 0) {
        try ctx.stdout.print(",\n{s}  \"dependencies\": [\n", .{spaces});
        for (dep.children, 0..) |child, idx| {
            try printDepJson(ctx, &child, indent + 2);
            if (idx < dep.children.len - 1) {
                try ctx.stdout.print(",\n", .{});
            }
        }
        try ctx.stdout.print("\n{s}  ]\n", .{spaces});
    } else {
        try ctx.stdout.print("\n", .{});
    }

    try ctx.stdout.print("{s}}}", .{spaces});
}

const FlatDep = struct { name: []const u8, version: []const u8, dev: bool };

fn showFlatList(ctx: *Context, deps: []const DepNode, include_dev: bool) !u8 {
    var all_deps: std.ArrayListUnmanaged(FlatDep) = .empty;
    defer all_deps.deinit(ctx.allocator);

    // Collect all dependencies
    for (deps) |dep| {
        if (!include_dev and dep.is_dev) continue;
        try all_deps.append(ctx.allocator, .{ .name = dep.name, .version = dep.version, .dev = dep.is_dev });
        try collectChildren(ctx.allocator, &dep, &all_deps, include_dev);
    }

    // Print sorted list
    for (all_deps.items) |dep| {
        try ctx.stdout.success("{s}", .{dep.name});
        try ctx.stdout.dim(" v{s}", .{dep.version});
        if (dep.dev) {
            try ctx.stdout.warn(" (dev)", .{});
        }
        try ctx.stdout.print("\n", .{});
    }

    try ctx.stdout.print("\n", .{});
    try ctx.stdout.dim("{d} total packages\n", .{all_deps.items.len});

    return 0;
}

fn collectChildren(
    allocator: std.mem.Allocator,
    dep: *const DepNode,
    list: *std.ArrayListUnmanaged(FlatDep),
    include_dev: bool,
) !void {
    for (dep.children) |child| {
        if (!include_dev and child.is_dev) continue;
        try list.append(allocator, .{ .name = child.name, .version = child.version, .dev = child.is_dev });
        try collectChildren(allocator, &child, list, include_dev);
    }
}

fn showWhyPackage(ctx: *Context, pkg: []const u8, deps: []const DepNode, project_name: []const u8) !u8 {
    try ctx.stdout.bold("Why is '{s}' included?\n\n", .{pkg});

    var found = false;
    for (deps) |dep| {
        if (std.mem.eql(u8, dep.name, pkg)) {
            found = true;
            try ctx.stdout.print("  {s}\n", .{project_name});
            try ctx.stdout.dim("    |\n", .{});
            try ctx.stdout.print("    +- ", .{});
            try ctx.stdout.success("{s}", .{dep.name});
            try ctx.stdout.dim(" v{s} (direct dependency)", .{dep.version});
            if (dep.is_dev) {
                try ctx.stdout.warn(" (dev)", .{});
            }
            try ctx.stdout.print("\n", .{});
            break;
        }
    }

    if (!found) {
        try ctx.stdout.warn("Package '{s}' not found in dependency tree.\n", .{pkg});
        return 1;
    }

    return 0;
}

fn countChildren(dep: *const DepNode) u32 {
    var count: u32 = 0;
    for (dep.children) |child| {
        count += 1;
        count += countChildren(&child);
    }
    return count;
}
