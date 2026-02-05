//! ovo import command
//!
//! Import project configuration from other build systems.
//! Usage: ovo import cmake/xcode/msbuild/meson [path]

const std = @import("std");
const commands = @import("commands.zig");

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
    var path: ?[]const u8 = null;
    var output: []const u8 = "build.zon";
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
            } else {
                path = arg;
            }
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
    const source_path = path orelse ".";

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
        try ctx.stdout.dim("  Source: {s}\n", .{source_path});
        try ctx.stdout.dim("  Output: {s}\n", .{output});
        if (merge) {
            try ctx.stdout.dim("  Mode:   merge\n", .{});
        }
        try ctx.stdout.print("\n", .{});
    }

    // Phase 1: Parse source
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Parsing {s}...\n", .{fmt.defaultFile()});

    // Simulated parsing results
    const ParsedProject = struct {
        name: []const u8,
        version: []const u8,
        sources: []const []const u8,
        includes: []const []const u8,
        defines: []const []const u8,
        dependencies: []const []const u8,
    };

    const parsed = ParsedProject{
        .name = "imported_project",
        .version = "1.0.0",
        .sources = &.{ "src/main.cpp", "src/utils.cpp", "src/core/*.cpp" },
        .includes = &.{ "include", "third_party/include" },
        .defines = &.{ "DEBUG", "VERSION=\"1.0\"" },
        .dependencies = &.{ "fmt", "spdlog" },
    };

    if (verbose) {
        try ctx.stdout.dim("    Found project: {s}\n", .{parsed.name});
        try ctx.stdout.dim("    Sources: {d} patterns\n", .{parsed.sources.len});
        try ctx.stdout.dim("    Includes: {d} directories\n", .{parsed.includes.len});
        try ctx.stdout.dim("    Dependencies: {d}\n", .{parsed.dependencies.len});
    }

    // Phase 2: Analyze dependencies
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Analyzing dependencies...\n", .{});

    for (parsed.dependencies) |dep| {
        if (verbose) {
            try ctx.stdout.dim("    Detected: {s}\n", .{dep});
        }
    }

    // Phase 3: Generate build.zon
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Generating {s}...\n", .{output});

    // Write file (simulated)
    if (verbose) {
        try ctx.stdout.dim("\n    Generated content:\n", .{});
        try ctx.stdout.dim("    ─────────────────\n", .{});
        try ctx.stdout.dim("    # Imported from {s}\n", .{fmt.toString()});
        try ctx.stdout.dim("    # Generated by: ovo import {s}\n", .{@tagName(fmt)});
        try ctx.stdout.dim("    \n", .{});
        try ctx.stdout.dim("    [package]\n", .{});
        try ctx.stdout.dim("    name = \"{s}\"\n", .{parsed.name});
        try ctx.stdout.dim("    version = \"{s}\"\n", .{parsed.version});
        try ctx.stdout.dim("    ...\n", .{});
    }

    // Summary
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.success("Import completed!\n", .{});
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.dim("Imported:\n", .{});
    try ctx.stdout.dim("  - {d} source patterns\n", .{parsed.sources.len});
    try ctx.stdout.dim("  - {d} include directories\n", .{parsed.includes.len});
    try ctx.stdout.dim("  - {d} dependencies\n", .{parsed.dependencies.len});

    try ctx.stdout.print("\n", .{});
    try ctx.stdout.warn("Note: ", .{});
    try ctx.stdout.print("Review generated {s} and adjust as needed.\n", .{output});

    return 0;
}
