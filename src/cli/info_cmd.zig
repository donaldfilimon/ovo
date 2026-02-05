//! ovo info command
//!
//! Show project information.
//! Usage: ovo info

const std = @import("std");
const commands = @import("commands.zig");

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
        ctx.cwd.access("build.zon", .{}) catch break :blk false;
        break :blk true;
    };

    if (!manifest_exists) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("no build.zon found in current directory\n", .{});
        return 1;
    }

    // Simulated project info (would parse build.zon in real implementation)
    const ProjectInfo = struct {
        name: []const u8,
        version: []const u8,
        description: []const u8,
        license: []const u8,
        build_type: []const u8,
        language: []const u8,
        standard: []const u8,
        dep_count: u32,
        dev_dep_count: u32,
    };

    const info = ProjectInfo{
        .name = "myproject",
        .version = "1.0.0",
        .description = "A sample C++ project",
        .license = "MIT",
        .build_type = "executable",
        .language = "cpp",
        .standard = "c++17",
        .dep_count = 3,
        .dev_dep_count = 1,
    };

    if (json_output) {
        // JSON output
        try ctx.stdout.print(
            \\{{
            \\  "name": "{s}",
            \\  "version": "{s}",
            \\  "description": "{s}",
            \\  "license": "{s}",
            \\  "build": {{
            \\    "type": "{s}",
            \\    "language": "{s}",
            \\    "standard": "{s}"
            \\  }},
            \\  "dependencies": {d},
            \\  "dev_dependencies": {d}
            \\}}
            \\
        , .{
            info.name,
            info.version,
            info.description,
            info.license,
            info.build_type,
            info.language,
            info.standard,
            info.dep_count,
            info.dev_dep_count,
        });
        return 0;
    }

    // Formatted output
    try ctx.stdout.bold("Project Information\n", .{});
    try ctx.stdout.print("\n", .{});

    // Basic info
    try printField(ctx.stdout, "Name", info.name);
    try printField(ctx.stdout, "Version", info.version);
    try printField(ctx.stdout, "Description", info.description);
    try printField(ctx.stdout, "License", info.license);

    try ctx.stdout.print("\n", .{});
    try ctx.stdout.bold("Build Configuration\n", .{});
    try printField(ctx.stdout, "Type", info.build_type);
    try printField(ctx.stdout, "Language", info.language);
    try printField(ctx.stdout, "Standard", info.standard);

    try ctx.stdout.print("\n", .{});
    try ctx.stdout.bold("Dependencies\n", .{});
    try ctx.stdout.print("  Dependencies:     ", .{});
    try ctx.stdout.info("{d}\n", .{info.dep_count});
    try ctx.stdout.print("  Dev dependencies: ", .{});
    try ctx.stdout.info("{d}\n", .{info.dev_dep_count});

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
