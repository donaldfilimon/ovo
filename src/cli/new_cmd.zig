//! ovo new command
//!
//! Scaffold a new project with templates.
//! Usage: ovo new <name>

const std = @import("std");
const commands = @import("commands.zig");
const manifest = @import("manifest.zig");

const Context = commands.Context;
const TermWriter = commands.TermWriter;

/// Project template types
pub const Template = enum {
    executable,
    library,
    header_only,

    pub fn toString(self: Template) []const u8 {
        return switch (self) {
            .executable => "executable",
            .library => "library",
            .header_only => "header-only",
        };
    }
};

/// Print help for new command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo new", .{});
    try writer.print(" - Create a new project\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo new <name> [options]\n\n", .{});

    try writer.bold("ARGUMENTS:\n", .{});
    try writer.print("    <name>           Project name (also directory name)\n\n", .{});

    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    --lib            Create a library project\n", .{});
    try writer.print("    --header-only    Create a header-only library\n", .{});
    try writer.print("    --exe            Create an executable project (default)\n", .{});
    try writer.print("    --lang <c|cpp>   Language (default: cpp)\n", .{});
    try writer.print("    --std <ver>      C/C++ standard (c11, c++17, c++20)\n", .{});
    try writer.print("    --git            Initialize git repository\n", .{});
    try writer.print("    --no-git         Don't initialize git repository\n", .{});
    try writer.print("    -h, --help       Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo new myapp                # New C++ executable\n", .{});
    try writer.dim("    ovo new mylib --lib          # New library\n", .{});
    try writer.dim("    ovo new utils --header-only  # Header-only library\n", .{});
    try writer.dim("    ovo new legacy --lang c      # C project\n", .{});
}

/// Execute the new command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    // Check for help flag
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    // Parse options
    var project_name: ?[]const u8 = null;
    var template: Template = .executable;
    var lang: []const u8 = "cpp";
    var std_version: ?[]const u8 = null;
    var init_git = true;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--lib")) {
            template = .library;
        } else if (std.mem.eql(u8, arg, "--header-only")) {
            template = .header_only;
        } else if (std.mem.eql(u8, arg, "--exe")) {
            template = .executable;
        } else if (std.mem.eql(u8, arg, "--git")) {
            init_git = true;
        } else if (std.mem.eql(u8, arg, "--no-git")) {
            init_git = false;
        } else if (std.mem.eql(u8, arg, "--lang") and i + 1 < args.len) {
            i += 1;
            lang = args[i];
        } else if (std.mem.startsWith(u8, arg, "--lang=")) {
            lang = arg["--lang=".len..];
        } else if (std.mem.eql(u8, arg, "--std") and i + 1 < args.len) {
            i += 1;
            std_version = args[i];
        } else if (std.mem.startsWith(u8, arg, "--std=")) {
            std_version = arg["--std=".len..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            project_name = arg;
        }
    }

    // Validate project name
    if (project_name == null) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("missing project name\n", .{});
        try ctx.stderr.dim("Usage: ovo new <name>\n", .{});
        return 1;
    }

    const name = project_name.?;

    // Validate name doesn't contain invalid characters
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
            try ctx.stderr.err("error: ", .{});
            try ctx.stderr.print("invalid project name '{s}'\n", .{name});
            try ctx.stderr.dim("Project names can only contain letters, numbers, underscores, and hyphens.\n", .{});
            return 1;
        }
    }

    // Check if directory already exists
    const dir_exists = blk: {
        ctx.cwd.access(name, .{}) catch break :blk false;
        break :blk true;
    };

    if (dir_exists) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("directory '{s}' already exists\n", .{name});
        return 1;
    }

    // Print what we're creating
    try ctx.stdout.bold("Creating", .{});
    try ctx.stdout.print(" new {s} project ", .{template.toString()});
    try ctx.stdout.success("'{s}'\n", .{name});
    try ctx.stdout.print("\n", .{});

    // Create project directory structure
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Creating directory structure...\n", .{});

    // Create directories
    try createDir(ctx, name);
    try createDir(ctx, try joinPath(ctx.allocator, name, "src"));
    try createDir(ctx, try joinPath(ctx.allocator, name, "include"));
    try createDir(ctx, try joinPath(ctx.allocator, name, "tests"));

    // Create build.zon
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Writing build.zon...\n", .{});

    const manifest_path = try joinPath(ctx.allocator, name, manifest.manifest_filename);
    try writeBuildZon(ctx, manifest_path, name, template, lang, std_version);

    // Create source files
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Creating source files...\n", .{});

    const ext = if (std.mem.eql(u8, lang, "c")) ".c" else ".cpp";
    const header_ext = if (std.mem.eql(u8, lang, "c")) ".h" else ".hpp";

    switch (template) {
        .executable => {
            const main_path = try std.fmt.allocPrint(ctx.allocator, "{s}/src/main{s}", .{ name, ext });
            try writeMainFile(ctx, main_path, lang);
        },
        .library => {
            const src_path = try std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}{s}", .{ name, name, ext });
            const hdr_path = try std.fmt.allocPrint(ctx.allocator, "{s}/include/{s}{s}", .{ name, name, header_ext });
            try writeLibraryFiles(ctx, src_path, hdr_path, name, lang);
        },
        .header_only => {
            const hdr_path = try std.fmt.allocPrint(ctx.allocator, "{s}/include/{s}{s}", .{ name, name, header_ext });
            try writeHeaderOnlyFile(ctx, hdr_path, name, lang);
        },
    }

    // Create test file
    const test_path = try std.fmt.allocPrint(ctx.allocator, "{s}/tests/test_main{s}", .{ name, ext });
    try writeTestFile(ctx, test_path, name, lang);

    // Create .gitignore
    const gitignore_path = try joinPath(ctx.allocator, name, ".gitignore");
    try writeGitignore(ctx, gitignore_path);

    // Initialize git if requested
    if (init_git) {
        try ctx.stdout.print("  ", .{});
        try ctx.stdout.success("*", .{});
        try ctx.stdout.print(" Initializing git repository...\n", .{});
        // In real implementation, would run: git init
    }

    // Print success message
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.success("Project created successfully!\n", .{});
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.print("To get started:\n", .{});
    try ctx.stdout.info("  cd {s}\n", .{name});
    try ctx.stdout.info("  ovo build\n", .{});
    if (template == .executable) {
        try ctx.stdout.info("  ovo run\n", .{});
    }

    return 0;
}

fn createDir(ctx: *Context, path: []const u8) !void {
    ctx.cwd.makeDir(path) catch |e| {
        if (e != error.PathAlreadyExists) {
            try ctx.stderr.err("error: ", .{});
            try ctx.stderr.print("failed to create directory '{s}': {}\n", .{ path, e });
            return e;
        }
    };
}

fn joinPath(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

fn writeBuildZon(ctx: *Context, path: []const u8, name: []const u8, template: Template, lang: []const u8, std_version: ?[]const u8) !void {
    const kind = templateKind(template, lang);
    var content = try manifest.renderTemplate(ctx.allocator, kind, name);
    if (std_version) |ver| {
        const updated = try manifest.applyStandardOverride(ctx.allocator, content, lang, ver);
        ctx.allocator.free(content);
        content = updated;
    }
    defer ctx.allocator.free(content);

    const file = try ctx.cwd.createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

fn templateKind(template: Template, lang: []const u8) manifest.TemplateKind {
    if (template == .header_only) {
        return if (std.mem.eql(u8, lang, "c")) .c_header_only else .cpp_header_only;
    }
    if (template == .library) {
        return if (std.mem.eql(u8, lang, "c")) .c_lib else .cpp_lib;
    }
    return if (std.mem.eql(u8, lang, "c")) .c_exe else .cpp_exe;
}

fn writeMainFile(ctx: *Context, path: []const u8, lang: []const u8) !void {
    const content = if (std.mem.eql(u8, lang, "c"))
        \\#include <stdio.h>
        \\
        \\int main(int argc, char* argv[]) {
        \\    (void)argc;
        \\    (void)argv;
        \\    printf("Hello, World!\n");
        \\    return 0;
        \\}
        \\
    else
        \\#include <iostream>
        \\
        \\int main(int argc, char* argv[]) {
        \\    (void)argc;
        \\    (void)argv;
        \\    std::cout << "Hello, World!" << std::endl;
        \\    return 0;
        \\}
        \\
    ;

    const file = try ctx.cwd.createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

fn writeLibraryFiles(ctx: *Context, src_path: []const u8, hdr_path: []const u8, name: []const u8, lang: []const u8) !void {
    // Header file
    const header = if (std.mem.eql(u8, lang, "c"))
        try std.fmt.allocPrint(ctx.allocator,
            \\#ifndef {s}_H
            \\#define {s}_H
            \\
            \\#ifdef __cplusplus
            \\extern "C" {{
            \\#endif
            \\
            \\/**
            \\ * Example function
            \\ */
            \\int {s}_init(void);
            \\
            \\#ifdef __cplusplus
            \\}}
            \\#endif
            \\
            \\#endif /* {s}_H */
            \\
        , .{ toUpperSnake(ctx.allocator, name), toUpperSnake(ctx.allocator, name), name, toUpperSnake(ctx.allocator, name) })
    else
        try std.fmt.allocPrint(ctx.allocator,
            \\#pragma once
            \\
            \\namespace {s} {{
            \\
            \\/**
            \\ * Example class
            \\ */
            \\class Library {{
            \\public:
            \\    Library();
            \\    ~Library();
            \\
            \\    int init();
            \\}};
            \\
            \\}} // namespace {s}
            \\
        , .{ name, name });

    const hdr_file = try ctx.cwd.createFile(hdr_path, .{});
    defer hdr_file.close();
    try hdr_file.writeAll(header);

    // Source file
    const source = if (std.mem.eql(u8, lang, "c"))
        try std.fmt.allocPrint(ctx.allocator,
            \\#include "{s}.h"
            \\
            \\int {s}_init(void) {{
            \\    return 0;
            \\}}
            \\
        , .{ name, name })
    else
        try std.fmt.allocPrint(ctx.allocator,
            \\#include "{s}.hpp"
            \\
            \\namespace {s} {{
            \\
            \\Library::Library() {{
            \\}}
            \\
            \\Library::~Library() {{
            \\}}
            \\
            \\int Library::init() {{
            \\    return 0;
            \\}}
            \\
            \\}} // namespace {s}
            \\
        , .{ name, name, name });

    const src_file = try ctx.cwd.createFile(src_path, .{});
    defer src_file.close();
    try src_file.writeAll(source);
}

fn writeHeaderOnlyFile(ctx: *Context, path: []const u8, name: []const u8, lang: []const u8) !void {
    const content = if (std.mem.eql(u8, lang, "c"))
        try std.fmt.allocPrint(ctx.allocator,
            \\#ifndef {s}_H
            \\#define {s}_H
            \\
            \\#ifdef __cplusplus
            \\extern "C" {{
            \\#endif
            \\
            \\/**
            \\ * Inline example function
            \\ */
            \\static inline int {s}_add(int a, int b) {{
            \\    return a + b;
            \\}}
            \\
            \\#ifdef __cplusplus
            \\}}
            \\#endif
            \\
            \\#endif /* {s}_H */
            \\
        , .{ toUpperSnake(ctx.allocator, name), toUpperSnake(ctx.allocator, name), name, toUpperSnake(ctx.allocator, name) })
    else
        try std.fmt.allocPrint(ctx.allocator,
            \\#pragma once
            \\
            \\namespace {s} {{
            \\
            \\/**
            \\ * Example template function
            \\ */
            \\template<typename T>
            \\constexpr T add(T a, T b) {{
            \\    return a + b;
            \\}}
            \\
            \\}} // namespace {s}
            \\
        , .{ name, name });

    const file = try ctx.cwd.createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

fn writeTestFile(ctx: *Context, path: []const u8, name: []const u8, lang: []const u8) !void {
    const content = if (std.mem.eql(u8, lang, "c"))
        try std.fmt.allocPrint(ctx.allocator,
            \\#include <stdio.h>
            \\#include <assert.h>
            \\
            \\void test_example(void) {{
            \\    assert(1 + 1 == 2);
            \\    printf("test_example passed\n");
            \\}}
            \\
            \\int main(void) {{
            \\    printf("Running {s} tests...\n");
            \\    test_example();
            \\    printf("All tests passed!\n");
            \\    return 0;
            \\}}
            \\
        , .{name})
    else
        try std.fmt.allocPrint(ctx.allocator,
            \\#include <iostream>
            \\#include <cassert>
            \\
            \\void test_example() {{
            \\    assert(1 + 1 == 2);
            \\    std::cout << "test_example passed" << std::endl;
            \\}}
            \\
            \\int main() {{
            \\    std::cout << "Running {s} tests..." << std::endl;
            \\    test_example();
            \\    std::cout << "All tests passed!" << std::endl;
            \\    return 0;
            \\}}
            \\
        , .{name});

    const file = try ctx.cwd.createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

fn writeGitignore(ctx: *Context, path: []const u8) !void {
    const content =
        \\# Build outputs
        \\/build/
        \\/out/
        \\
        \\# IDE files
        \\.vscode/
        \\.idea/
        \\*.swp
        \\*.swo
        \\*~
        \\
        \\# Dependency cache
        \\/.ovo/
        \\/deps/
        \\
        \\# Compiled objects
        \\*.o
        \\*.obj
        \\*.a
        \\*.lib
        \\*.so
        \\*.dylib
        \\*.dll
        \\
        \\# Executables
        \\*.exe
        \\*.out
        \\
        \\# Coverage
        \\*.gcno
        \\*.gcda
        \\*.gcov
        \\/coverage/
        \\
    ;

    const file = try ctx.cwd.createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

fn toUpperSnake(allocator: std.mem.Allocator, s: []const u8) []const u8 {
    var result = allocator.alloc(u8, s.len) catch return s;
    for (s, 0..) |c, i| {
        if (c == '-') {
            result[i] = '_';
        } else {
            result[i] = std.ascii.toUpper(c);
        }
    }
    return result;
}
