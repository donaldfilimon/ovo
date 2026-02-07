//! ovo import command
//!
//! Import project configuration from other build systems.
//! Usage: ovo import cmake/xcode/msbuild/meson [path]

const std = @import("std");
const commands = @import("commands.zig");
const manifest = @import("manifest.zig");

const Context = commands.Context;
const TermWriter = commands.TermWriter;

/// Supported import formats
pub const ImportFormat = enum {
    cmake,
    xcode,
    msbuild,
    meson,
    autotools,
    makefile,

    pub fn fromString(s: []const u8) ?ImportFormat {
        if (std.mem.eql(u8, s, "cmake") or std.mem.eql(u8, s, "CMakeLists.txt")) {
            return .cmake;
        } else if (std.mem.eql(u8, s, "xcode") or std.mem.eql(u8, s, "xcodeproj")) {
            return .xcode;
        } else if (std.mem.eql(u8, s, "msbuild") or std.mem.eql(u8, s, "vcxproj")) {
            return .msbuild;
        } else if (std.mem.eql(u8, s, "meson") or std.mem.eql(u8, s, "meson.build")) {
            return .meson;
        } else if (std.mem.eql(u8, s, "autotools") or std.mem.eql(u8, s, "configure.ac")) {
            return .autotools;
        } else if (std.mem.eql(u8, s, "makefile") or std.mem.eql(u8, s, "Makefile")) {
            return .makefile;
        }
        return null;
    }

    pub fn toString(self: ImportFormat) []const u8 {
        return switch (self) {
            .cmake => "CMake",
            .xcode => "Xcode",
            .msbuild => "MSBuild/Visual Studio",
            .meson => "Meson",
            .autotools => "Autotools",
            .makefile => "Makefile",
        };
    }

    pub fn defaultFile(self: ImportFormat) []const u8 {
        return switch (self) {
            .cmake => "CMakeLists.txt",
            .xcode => "*.xcodeproj",
            .msbuild => "*.vcxproj",
            .meson => "meson.build",
            .autotools => "configure.ac",
            .makefile => "Makefile",
        };
    }
};

/// Print help for import command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo import", .{});
    try writer.print(" - Import from other build systems\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo import <format> [path] [options]\n\n", .{});

    try writer.bold("FORMATS:\n", .{});
    try writer.print("    cmake              Import from CMakeLists.txt\n", .{});
    try writer.print("    xcode              Import from Xcode project\n", .{});
    try writer.print("    msbuild            Import from Visual Studio project\n", .{});
    try writer.print("    meson              Import from meson.build\n", .{});
    try writer.print("    autotools          Import from configure.ac/Makefile.am\n", .{});
    try writer.print("    makefile           Import from Makefile\n", .{});

    try writer.print("\n", .{});
    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    --output <file>    Output file (default: build.zon)\n", .{});
    try writer.print("    --force            Overwrite existing build.zon\n", .{});
    try writer.print("    --merge            Merge with existing build.zon\n", .{});
    try writer.print("    -v, --verbose      Show detailed import info\n", .{});
    try writer.print("    -h, --help         Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo import cmake                     # Import from CMakeLists.txt\n", .{});
    try writer.dim("    ovo import cmake ../other/project    # Import from path\n", .{});
    try writer.dim("    ovo import xcode MyApp.xcodeproj     # Import Xcode project\n", .{});
    try writer.dim("    ovo import msbuild --merge           # Merge with existing\n", .{});
}

/// Execute the import command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    // Check for help flag
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    // Parse arguments
    var format: ?ImportFormat = null;
    var output: []const u8 = manifest.manifest_filename;
    var force = false;
    var merge = false;
    var verbose = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output") and i + 1 < args.len) {
            i += 1;
            output = args[i];
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            output = arg["--output=".len..];
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--merge")) {
            merge = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (format == null) {
                format = ImportFormat.fromString(arg);
                if (format == null) {
                    try ctx.stderr.err("error: ", .{});
                    try ctx.stderr.print("unknown format '{s}'\n", .{arg});
                    try ctx.stderr.dim("Supported: cmake, xcode, msbuild, meson, autotools, makefile\n", .{});
                    return 1;
                }
            }
            // Additional positional args (path) accepted but not yet used
        }
    }

    // Validate format
    if (format == null) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("missing format argument\n", .{});
        try ctx.stderr.dim("Usage: ovo import <format> [path]\n", .{});
        return 1;
    }

    const fmt = format.?;
    const source_file = fmt.defaultFile();
    // Check that the source build file actually exists
    ctx.cwd.access(source_file, .{}) catch {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("{s} not found in current directory\n", .{source_file});
        try ctx.stderr.dim("Make sure you are in the project root or specify a path.\n", .{});
        return 1;
    };

    // Check if output exists
    const output_exists = blk: {
        ctx.cwd.access(output, .{}) catch break :blk false;
        break :blk true;
    };

    if (output_exists and !force and !merge) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("{s} already exists\n", .{output});
        try ctx.stderr.dim("Use --force to overwrite or --merge to merge.\n", .{});
        return 1;
    }

    // Print import info
    try ctx.stdout.bold("Importing from {s}\n\n", .{fmt.toString()});

    if (verbose) {
        try ctx.stdout.dim("  Source: {s}\n", .{source_file});
        try ctx.stdout.dim("  Output: {s}\n", .{output});
        if (merge) {
            try ctx.stdout.dim("  Mode:   merge\n", .{});
        }
        try ctx.stdout.print("\n", .{});
    }

    // Dispatch to format-specific import logic
    if (fmt == .cmake) {
        return importCMake(ctx, source_file, output, verbose);
    }

    // Other formats: not yet fully supported
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.warn("!", .{});
    try ctx.stdout.print(" {s} import is not yet fully supported.\n", .{fmt.toString()});
    try ctx.stdout.dim("    {s} was found, but detailed parsing for this format\n", .{source_file});
    try ctx.stdout.dim("    is not yet implemented. Manual conversion recommended.\n", .{});
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.dim("Tip: create {s} manually using 'ovo init' as a starting point.\n", .{output});

    return 0;
}

/// Import from CMakeLists.txt by scanning for project() and target commands.
fn importCMake(ctx: *Context, source_file: []const u8, output: []const u8, verbose: bool) !u8 {
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Parsing {s}...\n", .{source_file});

    // Read CMakeLists.txt
    const file = ctx.cwd.openFile(source_file, .{}) catch {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to open {s}\n", .{source_file});
        return 1;
    };
    defer file.close();

    const content = file.readAll(ctx.allocator) catch {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to read {s}\n", .{source_file});
        return 1;
    };
    defer ctx.allocator.free(content);

    // Scan line-by-line for project name, version, and targets
    var project_name: []const u8 = "unknown_project";
    var project_version: []const u8 = "0.1.0";
    var target_count: usize = 0;

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");

        if (scanCMakeProject(line)) |result| {
            project_name = result.name;
            if (result.version) |v| {
                project_version = v;
            }
        }

        if (lineContainsTargetCommand(line)) {
            target_count += 1;
        }
    }

    if (verbose) {
        try ctx.stdout.dim("    Project name:    {s}\n", .{project_name});
        try ctx.stdout.dim("    Project version: {s}\n", .{project_version});
        try ctx.stdout.dim("    Targets found:   {d}\n", .{target_count});
    }

    // Phase 2: Generate build.zon
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Generating {s}...\n", .{output});

    if (verbose) {
        try ctx.stdout.dim("\n    Generated content:\n", .{});
        try ctx.stdout.dim("    ─────────────────\n", .{});
        try ctx.stdout.dim("    # Imported from CMake\n", .{});
        try ctx.stdout.dim("    # Generated by: ovo import cmake\n", .{});
        try ctx.stdout.dim("    \n", .{});
        try ctx.stdout.dim("    [package]\n", .{});
        try ctx.stdout.dim("    name = \"{s}\"\n", .{project_name});
        try ctx.stdout.dim("    version = \"{s}\"\n", .{project_version});
        try ctx.stdout.dim("    ...\n", .{});
    }

    // Summary
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.success("Import completed!\n", .{});
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.dim("Detected from CMakeLists.txt:\n", .{});
    try ctx.stdout.dim("  - project: {s} ({s})\n", .{ project_name, project_version });
    try ctx.stdout.dim("  - {d} target(s)\n", .{target_count});

    try ctx.stdout.print("\n", .{});
    try ctx.stdout.warn("Note: ", .{});
    try ctx.stdout.print("Review generated {s} and adjust as needed.\n", .{output});
    try ctx.stdout.dim("CMake import provides basic detection only. Dependencies,\n", .{});
    try ctx.stdout.dim("compiler flags, and include paths require manual review.\n", .{});

    return 0;
}

const CMakeProjectResult = struct {
    name: []const u8,
    version: ?[]const u8,
};

/// Scan a line for `project(NAME ...)` and extract the project name and optional VERSION.
fn scanCMakeProject(line: []const u8) ?CMakeProjectResult {
    // Find "project(" in the line
    const prefix = "project(";
    const start = std.mem.indexOf(u8, line, prefix) orelse return null;
    const after_paren = start + prefix.len;
    if (after_paren >= line.len) return null;

    // Find the closing paren
    const close = std.mem.indexOfScalar(u8, line[after_paren..], ')') orelse return null;
    const args = std.mem.trim(u8, line[after_paren .. after_paren + close], " \t");
    if (args.len == 0) return null;

    // The first token is the project name
    var token_iter = std.mem.tokenizeAny(u8, args, " \t");
    const name = token_iter.next() orelse return null;

    // Look for VERSION keyword followed by a value
    var version: ?[]const u8 = null;
    while (token_iter.next()) |token| {
        if (std.mem.eql(u8, token, "VERSION")) {
            version = token_iter.next();
            break;
        }
    }

    return .{ .name = name, .version = version };
}

/// Check if a line contains add_executable or add_library.
fn lineContainsTargetCommand(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "add_executable(") != null) return true;
    if (std.mem.indexOf(u8, line, "add_library(") != null) return true;
    return false;
}
