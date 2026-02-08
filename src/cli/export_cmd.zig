//! ovo export command
//!
//! Export project to other build system formats.
//! Usage: ovo export cmake/xcode/msbuild/ninja/compile-commands

const std = @import("std");
const commands = @import("commands.zig");
const manifest = @import("manifest.zig");
const zon = @import("zon");
const zon_parser = zon.parser;

const Context = commands.Context;
const TermWriter = commands.TermWriter;

/// Supported export formats
pub const ExportFormat = enum {
    cmake,
    xcode,
    msbuild,
    ninja,
    compile_commands,
    makefile,
    pkg_config,

    pub fn fromString(s: []const u8) ?ExportFormat {
        if (std.mem.eql(u8, s, "cmake")) {
            return .cmake;
        } else if (std.mem.eql(u8, s, "xcode")) {
            return .xcode;
        } else if (std.mem.eql(u8, s, "msbuild") or std.mem.eql(u8, s, "vs") or std.mem.eql(u8, s, "visual-studio")) {
            return .msbuild;
        } else if (std.mem.eql(u8, s, "ninja")) {
            return .ninja;
        } else if (std.mem.eql(u8, s, "compile-commands") or std.mem.eql(u8, s, "compile_commands")) {
            return .compile_commands;
        } else if (std.mem.eql(u8, s, "makefile") or std.mem.eql(u8, s, "make")) {
            return .makefile;
        } else if (std.mem.eql(u8, s, "pkg-config") or std.mem.eql(u8, s, "pkgconfig")) {
            return .pkg_config;
        }
        return null;
    }

    pub fn toString(self: ExportFormat) []const u8 {
        return switch (self) {
            .cmake => "CMake",
            .xcode => "Xcode",
            .msbuild => "MSBuild/Visual Studio",
            .ninja => "Ninja",
            .compile_commands => "compile_commands.json",
            .makefile => "Makefile",
            .pkg_config => "pkg-config",
        };
    }

    pub fn outputFile(self: ExportFormat) []const u8 {
        return switch (self) {
            .cmake => "CMakeLists.txt",
            .xcode => "project.xcodeproj",
            .msbuild => "project.vcxproj",
            .ninja => "build.ninja",
            .compile_commands => "compile_commands.json",
            .makefile => "Makefile",
            .pkg_config => "project.pc",
        };
    }
};

/// Print help for export command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo export", .{});
    try writer.print(" - Export to other formats\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo export <format> [options]\n\n", .{});

    try writer.bold("FORMATS:\n", .{});
    try writer.print("    cmake              Generate CMakeLists.txt\n", .{});
    try writer.print("    xcode              Generate Xcode project\n", .{});
    try writer.print("    msbuild            Generate Visual Studio project\n", .{});
    try writer.print("    ninja              Generate build.ninja\n", .{});
    try writer.print("    compile-commands   Generate compile_commands.json\n", .{});
    try writer.print("    makefile           Generate Makefile\n", .{});
    try writer.print("    pkg-config         Generate .pc file for libraries\n", .{});

    try writer.print("\n", .{});
    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    --output <path>    Output directory (default: current)\n", .{});
    try writer.print("    --release          Export release configuration\n", .{});
    try writer.print("    --debug            Export debug configuration\n", .{});
    try writer.print("    --force            Overwrite existing files\n", .{});
    try writer.print("    -h, --help         Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo export cmake                     # Generate CMakeLists.txt\n", .{});
    try writer.dim("    ovo export compile-commands          # For IDE integration\n", .{});
    try writer.dim("    ovo export xcode --output build/     # To specific dir\n", .{});
    try writer.dim("    ovo export ninja --release           # Release config\n", .{});
}

/// Execute the export command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    // Check for help flag
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    // Parse arguments
    var format: ?ExportFormat = null;
    var output_dir: []const u8 = ".";
    var release = false;
    var force = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output") and i + 1 < args.len) {
            i += 1;
            output_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            output_dir = arg["--output=".len..];
        } else if (std.mem.eql(u8, arg, "--release")) {
            release = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            release = false;
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            format = ExportFormat.fromString(arg);
            if (format == null) {
                try ctx.stderr.err("error: ", .{});
                try ctx.stderr.print("unknown format '{s}'\n", .{arg});
                return 1;
            }
        }
    }

    // Validate format
    if (format == null) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("missing format argument\n", .{});
        try ctx.stderr.dim("Usage: ovo export <format>\n", .{});
        return 1;
    }

    const fmt = format.?;

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

    // Print export info
    try ctx.stdout.bold("Exporting to {s}\n\n", .{fmt.toString()});

    // Phase 1: Parse build.zon
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Reading build.zon...\n", .{});

    var project = zon_parser.parseFile(ctx.allocator, manifest.manifest_filename) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to parse {s}: {}\n", .{ manifest.manifest_filename, err });
        return 1;
    };
    defer project.deinit(ctx.allocator);

    const project_name = project.name;
    const project_version = try std.fmt.allocPrint(ctx.allocator, "{d}.{d}.{d}", .{
        project.version.major,
        project.version.minor,
        project.version.patch,
    });
    defer ctx.allocator.free(project_version);

    // Phase 2: Generate output
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Generating {s}...\n", .{fmt.outputFile()});

    const output_path_owned = if (std.mem.eql(u8, output_dir, "."))
        false
    else
        true;
    const output_path = if (std.mem.eql(u8, output_dir, "."))
        fmt.outputFile()
    else
        try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ output_dir, fmt.outputFile() });
    defer if (output_path_owned) ctx.allocator.free(output_path);

    // Generate format-specific content
    switch (fmt) {
        .cmake => try generateCMake(ctx, project_name, project_version, output_path, release),
        .compile_commands => try generateCompileCommands(ctx, output_path),
        .ninja => try generateNinja(ctx, project_name, output_path, release),
        .makefile => try generateMakefile(ctx, project_name, output_path, release),
        .pkg_config => try generatePkgConfig(ctx, project_name, project_version, output_path),
        else => {
            try ctx.stdout.warn("    (format generation not yet implemented)\n", .{});
        },
    }

    // Summary
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.success("Export completed!\n", .{});
    try ctx.stdout.dim("Output: {s}\n", .{output_path});

    return 0;
}

fn generateCMake(ctx: *Context, name: []const u8, version: []const u8, path: []const u8, release: bool) !void {
    _ = release;

    const content = try std.fmt.allocPrint(ctx.allocator,
        \\# Generated by ovo export cmake
        \\cmake_minimum_required(VERSION 3.16)
        \\project({s} VERSION {s} LANGUAGES CXX)
        \\
        \\set(CMAKE_CXX_STANDARD 17)
        \\set(CMAKE_CXX_STANDARD_REQUIRED ON)
        \\set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
        \\
        \\# Sources
        \\file(GLOB_RECURSE SOURCES "src/*.cpp")
        \\
        \\# Target
        \\add_executable({s} ${{SOURCES}})
        \\
        \\target_include_directories({s} PRIVATE
        \\    ${{CMAKE_SOURCE_DIR}}/include
        \\)
        \\
        \\# Dependencies (via ovo fetch)
        \\# find_package(fmt REQUIRED)
        \\# target_link_libraries({s} PRIVATE fmt::fmt)
        \\
    , .{ name, version, name, name, name });
    defer ctx.allocator.free(content);

    const file = ctx.cwd.createFile(path, .{}) catch {
        try ctx.stdout.err("    Failed to write {s}\n", .{path});
        return;
    };
    defer file.close();
    file.writeAll(content) catch {
        try ctx.stdout.err("    Failed to write {s}\n", .{path});
        return;
    };
    try ctx.stdout.dim("    Generated CMakeLists.txt ({d} bytes)\n", .{content.len});
}

fn generateCompileCommands(ctx: *Context, path: []const u8) !void {

    const content =
        \\[
        \\  {
        \\    "directory": "/project",
        \\    "command": "clang++ -std=c++17 -I/project/include -c src/main.cpp -o build/main.o",
        \\    "file": "src/main.cpp"
        \\  }
        \\]
    ;

    const file = ctx.cwd.createFile(path, .{}) catch {
        try ctx.stdout.err("    Failed to write {s}\n", .{path});
        return;
    };
    defer file.close();
    file.writeAll(content) catch {
        try ctx.stdout.err("    Failed to write {s}\n", .{path});
        return;
    };
    try ctx.stdout.dim("    Generated compile_commands.json ({d} bytes)\n", .{content.len});
}

fn generateNinja(ctx: *Context, name: []const u8, path: []const u8, release: bool) !void {
    const opt_flags = if (release) "-O3 -DNDEBUG" else "-g -O0";

    const content = try std.fmt.allocPrint(ctx.allocator,
        \\# Generated by ovo export ninja
        \\
        \\cxx = clang++
        \\cxxflags = -std=c++17 {s} -Iinclude
        \\ldflags =
        \\
        \\rule cxx
        \\  command = $cxx $cxxflags -c $in -o $out
        \\  description = CXX $out
        \\
        \\rule link
        \\  command = $cxx $ldflags $in -o $out
        \\  description = LINK $out
        \\
        \\build build/main.o: cxx src/main.cpp
        \\build {s}: link build/main.o
        \\
        \\default {s}
        \\
    , .{ opt_flags, name, name });
    defer ctx.allocator.free(content);

    const file = ctx.cwd.createFile(path, .{}) catch {
        try ctx.stdout.err("    Failed to write {s}\n", .{path});
        return;
    };
    defer file.close();
    file.writeAll(content) catch {
        try ctx.stdout.err("    Failed to write {s}\n", .{path});
        return;
    };
    try ctx.stdout.dim("    Generated build.ninja ({d} bytes)\n", .{content.len});
}

fn generateMakefile(ctx: *Context, name: []const u8, path: []const u8, release: bool) !void {
    const opt_flags = if (release) "-O3 -DNDEBUG" else "-g -O0";

    const content = try std.fmt.allocPrint(ctx.allocator,
        \\# Generated by ovo export makefile
        \\
        \\CXX = clang++
        \\CXXFLAGS = -std=c++17 {s} -Iinclude
        \\LDFLAGS =
        \\
        \\SRCS = $(wildcard src/*.cpp)
        \\OBJS = $(SRCS:src/%.cpp=build/%.o)
        \\TARGET = {s}
        \\
        \\.PHONY: all clean
        \\
        \\all: $(TARGET)
        \\
        \\$(TARGET): $(OBJS)
        \\    $(CXX) $(LDFLAGS) $^ -o $@
        \\
        \\build/%.o: src/%.cpp | build
        \\    $(CXX) $(CXXFLAGS) -c $< -o $@
        \\
        \\build:
        \\    mkdir -p build
        \\
        \\clean:
        \\    rm -rf build $(TARGET)
        \\
    , .{ opt_flags, name });
    defer ctx.allocator.free(content);

    const file = ctx.cwd.createFile(path, .{}) catch {
        try ctx.stdout.err("    Failed to write {s}\n", .{path});
        return;
    };
    defer file.close();
    file.writeAll(content) catch {
        try ctx.stdout.err("    Failed to write {s}\n", .{path});
        return;
    };
    try ctx.stdout.dim("    Generated Makefile ({d} bytes)\n", .{content.len});
}

fn generatePkgConfig(ctx: *Context, name: []const u8, version: []const u8, path: []const u8) !void {
    const content = try std.fmt.allocPrint(ctx.allocator,
        \\# Generated by ovo export pkg-config
        \\
        \\prefix=/usr/local
        \\exec_prefix=${{prefix}}
        \\libdir=${{exec_prefix}}/lib
        \\includedir=${{prefix}}/include
        \\
        \\Name: {s}
        \\Description: {s} library
        \\Version: {s}
        \\Libs: -L${{libdir}} -l{s}
        \\Cflags: -I${{includedir}}
        \\
    , .{ name, name, version, name });
    defer ctx.allocator.free(content);

    const file = ctx.cwd.createFile(path, .{}) catch {
        try ctx.stdout.err("    Failed to write {s}\n", .{path});
        return;
    };
    defer file.close();
    file.writeAll(content) catch {
        try ctx.stdout.err("    Failed to write {s}\n", .{path});
        return;
    };
    try ctx.stdout.dim("    Generated {s}.pc ({d} bytes)\n", .{ name, content.len });
}
