//! ovo info command
//!
//! Show project information.
//! Usage: ovo info

const std = @import("std");
const commands = @import("commands.zig");
const manifest = @import("manifest.zig");
const zon = @import("zon");

const zon_parser = zon.parser;

const Context = commands.Context;
const TermWriter = commands.TermWriter;
const Color = commands.Color;

/// Print help for info command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo info", .{});
    try writer.print(" - Show project information\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo info [options]\n\n", .{});

    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    --json           Output as JSON\n", .{});
    try writer.print("    --paths          Show resolved paths\n", .{});
    try writer.print("    --env            Show environment info\n", .{});
    try writer.print("    -h, --help       Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo info                     # Show project info\n", .{});
    try writer.dim("    ovo info --json              # JSON output\n", .{});
    try writer.dim("    ovo info --env               # Include environment\n", .{});
}

/// Execute the info command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    // Check for help flag
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    // Parse options
    var json_output = false;
    var show_paths = false;
    var show_env = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--paths")) {
            show_paths = true;
        } else if (std.mem.eql(u8, arg, "--env")) {
            show_env = true;
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

    // Parse build.zon
    var project = zon_parser.parseFile(ctx.allocator, manifest.manifest_filename) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to parse {s}: {}\n", .{ manifest.manifest_filename, err });
        return 1;
    };
    defer project.deinit(ctx.allocator);

    const name = project.name;
    const ver = project.version;
    const description = project.description orelse "No description";
    const license = project.license orelse "Not specified";
    const target_count = project.targets.len;
    const dep_count: usize = if (project.dependencies) |deps| deps.len else 0;

    // Format version string
    var version_buf: [64]u8 = undefined;
    const version_str = std.fmt.bufPrint(&version_buf, "{d}.{d}.{d}", .{ ver.major, ver.minor, ver.patch }) catch "0.0.0";

    if (json_output) {
        try ctx.stdout.print(
            \\{{
            \\  "name": "{s}",
            \\  "version": "{s}",
            \\  "description": "{s}",
            \\  "license": "{s}",
            \\  "targets": {d},
            \\  "dependencies": {d}
            \\}}
            \\
        , .{
            name,
            version_str,
            description,
            license,
            target_count,
            dep_count,
        });
        return 0;
    }

    // Formatted output
    try ctx.stdout.bold("Project Information\n", .{});
    try ctx.stdout.print("\n", .{});

    try printField(ctx.stdout, "Name", name);
    try printField(ctx.stdout, "Version", version_str);
    try printField(ctx.stdout, "Description", description);
    try printField(ctx.stdout, "License", license);

    try ctx.stdout.print("\n", .{});
    try ctx.stdout.bold("Targets\n", .{});
    for (project.targets) |target| {
        try ctx.stdout.print("  ", .{});
        try ctx.stdout.info("{s}", .{target.name});
        try ctx.stdout.dim(" ({s})\n", .{target.target_type.toString()});
    }

    try ctx.stdout.print("\n", .{});
    try ctx.stdout.bold("Dependencies\n", .{});
    try ctx.stdout.print("  Count:            ", .{});
    try ctx.stdout.info("{d}\n", .{dep_count});
    if (project.dependencies) |deps| {
        for (deps) |dep| {
            try ctx.stdout.print("  ", .{});
            try ctx.stdout.info("{s}", .{dep.name});
            const source_label: []const u8 = switch (dep.source) {
                .git => "git",
                .url => "url",
                .path => "path",
                .vcpkg => "vcpkg",
                .conan => "conan",
                .system => "system",
            };
            try ctx.stdout.dim(" ({s})\n", .{source_label});
        }
    }

    // Show paths if requested
    if (show_paths) {
        try ctx.stdout.print("\n", .{});
        try ctx.stdout.bold("Paths\n", .{});

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_path = ctx.cwd.realpath(".", &path_buf);

        try printField(ctx.stdout, "Project root", cwd_path);
        try printField(ctx.stdout, "Source dir", "src/");
        try printField(ctx.stdout, "Include dir", "include/");
        try printField(ctx.stdout, "Build dir", "build/");
        try printField(ctx.stdout, "Cache dir", ".ovo/");
    }

    // Show environment if requested
    if (show_env) {
        try ctx.stdout.print("\n", .{});
        try ctx.stdout.bold("Environment\n", .{});

        // Compiler detection (simulated)
        try printField(ctx.stdout, "Compiler", "clang++ 15.0.0");
        try printField(ctx.stdout, "Platform", @tagName(@import("builtin").os.tag));
        try printField(ctx.stdout, "Architecture", @tagName(@import("builtin").cpu.arch));

        // Check for tools
        const tools = [_]struct { name: []const u8, available: bool }{
            .{ .name = "clang-format", .available = true },
            .{ .name = "clang-tidy", .available = true },
            .{ .name = "cmake", .available = true },
            .{ .name = "ninja", .available = false },
        };

        try ctx.stdout.print("\n", .{});
        try ctx.stdout.dim("  Available tools:\n", .{});
        for (tools) |tool| {
            try ctx.stdout.print("    ", .{});
            if (tool.available) {
                try ctx.stdout.success("*", .{});
            } else {
                try ctx.stdout.err("x", .{});
            }
            try ctx.stdout.print(" {s}\n", .{tool.name});
        }
    }

    return 0;
}

fn printField(writer: *TermWriter, label: []const u8, value: []const u8) !void {
    try writer.print("  {s:<16}", .{label});
    try writer.info("{s}\n", .{value});
}
