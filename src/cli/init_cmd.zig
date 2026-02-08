//! ovo init command
//!
//! Initialize an ovo project in the current directory.
//! Usage: ovo init

const std = @import("std");
const commands = @import("commands.zig");
const manifest = @import("manifest.zig");

const Context = commands.Context;
const TermWriter = commands.TermWriter;

/// Print help for init command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo init", .{});
    try writer.print(" - Initialize project in current directory\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo init [options]\n\n", .{});

    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    --name <name>    Project name (default: directory name)\n", .{});
    try writer.print("    --lib            Initialize as a library\n", .{});
    try writer.print("    --exe            Initialize as an executable (default)\n", .{});
    try writer.print("    --lang <c|cpp>   Language (default: auto-detect or cpp)\n", .{});
    try writer.print("    --force          Overwrite existing build.zon\n", .{});
    try writer.print("    -h, --help       Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo init                     # Initialize in current directory\n", .{});
    try writer.dim("    ovo init --name myproject    # With specific name\n", .{});
    try writer.dim("    ovo init --lib --lang c      # C library project\n", .{});
}

/// Execute the init command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    // Check for help flag
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    // Parse options
    var project_name: ?[]const u8 = null;
    var is_library = false;
    var lang: ?[]const u8 = null;
    var force = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--lib")) {
            is_library = true;
        } else if (std.mem.eql(u8, arg, "--exe")) {
            is_library = false;
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--name") and i + 1 < args.len) {
            i += 1;
            project_name = args[i];
        } else if (std.mem.startsWith(u8, arg, "--name=")) {
            project_name = arg["--name=".len..];
        } else if (std.mem.eql(u8, arg, "--lang") and i + 1 < args.len) {
            i += 1;
            lang = args[i];
        } else if (std.mem.startsWith(u8, arg, "--lang=")) {
            lang = arg["--lang=".len..];
        }
    }

    // Check if build.zon already exists
    const manifest_exists = blk: {
        ctx.cwd.access(manifest.manifest_filename, .{}) catch break :blk false;
        break :blk true;
    };

    if (manifest_exists and !force) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("{s} already exists in this directory\n", .{manifest.manifest_filename});
        try ctx.stderr.dim("Use --force to overwrite.\n", .{});
        return 1;
    }

    // Get project name from directory if not specified
    const name = project_name orelse blk: {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_path = ctx.cwd.realpath(".", &path_buf);
        break :blk std.fs.path.basename(cwd_path);
    };

    // Auto-detect language if not specified
    var scan = scanSources(ctx) catch ScanResult{
        .source_count = 0,
        .header_count = 0,
        .has_c = false,
        .has_cpp = false,
    };
    const detected_lang = lang orelse inferLanguage(&scan);

    try ctx.stdout.bold("Initializing", .{});
    try ctx.stdout.print(" ovo project in current directory\n\n", .{});

    // Scan existing files
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Scanning existing files...\n", .{});

    if (scan.source_count > 0 or scan.header_count > 0) {
        try ctx.stdout.dim("    Found {d} source files, {d} headers\n", .{ scan.source_count, scan.header_count });
    }

    // Create build.zon
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Creating build.zon...\n", .{});

    try writeBuildZon(ctx, name, is_library, detected_lang);

    // Create directories if they don't exist
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Creating directory structure...\n", .{});

    const dirs = [_][]const u8{ "src", "include", "tests", "build" };
    for (dirs) |dir| {
        ctx.cwd.makeDir(dir) catch |e| {
            if (e != error.PathAlreadyExists) {
                try ctx.stderr.warn("warning: ", .{});
                try ctx.stderr.print("failed to create {s}/\n", .{dir});
            }
        };
    }

    // Create .gitignore if it doesn't exist
    const gitignore_exists = blk: {
        ctx.cwd.access(".gitignore", .{}) catch break :blk false;
        break :blk true;
    };

    if (!gitignore_exists) {
        try ctx.stdout.print("  ", .{});
        try ctx.stdout.success("*", .{});
        try ctx.stdout.print(" Creating .gitignore...\n", .{});
        try writeGitignore(ctx);
    }

    // Print success
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.success("Project initialized successfully!\n", .{});
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.dim("Project: {s}\n", .{name});
    try ctx.stdout.dim("Type:    {s}\n", .{if (is_library) "library" else "executable"});
    try ctx.stdout.dim("Lang:    {s}\n", .{detected_lang});
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.print("Next steps:\n", .{});
    try ctx.stdout.info("  ovo add <package>   ", .{});
    try ctx.stdout.dim("# Add dependencies\n", .{});
    try ctx.stdout.info("  ovo build           ", .{});
    try ctx.stdout.dim("# Build the project\n", .{});

    return 0;
}

const ScanResult = struct {
    source_count: u32,
    header_count: u32,
    has_c: bool,
    has_cpp: bool,
};

fn inferLanguage(scan: *const ScanResult) []const u8 {
    if (scan.has_cpp) return "cpp";
    if (scan.has_c) return "c";
    return "cpp";
}

fn scanSources(_: *Context) !ScanResult {
    var result = ScanResult{ .source_count = 0, .header_count = 0, .has_c = false, .has_cpp = false };

    // Check common source file locations using C library
    const common_paths = [_][]const u8{
        "main.c",
        "main.cpp",
        "src/main.c",
        "src/main.cpp",
        "lib.c",
        "lib.cpp",
        "src/lib.c",
        "src/lib.cpp",
    };

    const c_paths = [_][]const u8{ "main.c", "src/main.c", "lib.c", "src/lib.c" };
    const cpp_paths = [_][]const u8{ "main.cpp", "src/main.cpp", "lib.cpp", "src/lib.cpp", "main.cc", "src/main.cc" };
    const header_paths = [_][]const u8{ "include", "src", "." };

    // Check for C files
    for (c_paths) |path| {
        if (fileExistsC(path)) {
            result.has_c = true;
            result.source_count += 1;
        }
    }

    // Check for C++ files
    for (cpp_paths) |path| {
        if (fileExistsC(path)) {
            result.has_cpp = true;
            result.source_count += 1;
        }
    }

    // Check for headers in common locations
    for (header_paths) |path| {
        if (fileExistsC(path)) {
            result.header_count += 1;
        }
    }

    _ = common_paths;
    return result;
}

const fileExistsC = commands.fileExistsC;

fn isCSource(ext: []const u8) bool {
    return std.mem.eql(u8, ext, ".c");
}

fn isCppSource(ext: []const u8) bool {
    return std.mem.eql(u8, ext, ".cpp") or
        std.mem.eql(u8, ext, ".cc") or
        std.mem.eql(u8, ext, ".cxx") or
        std.mem.eql(u8, ext, ".cppm") or
        std.mem.eql(u8, ext, ".ixx") or
        std.mem.eql(u8, ext, ".mpp");
}

fn isHeader(ext: []const u8) bool {
    return std.mem.eql(u8, ext, ".h") or
        std.mem.eql(u8, ext, ".hpp") or
        std.mem.eql(u8, ext, ".hxx");
}

fn writeBuildZon(ctx: *Context, name: []const u8, is_library: bool, lang: []const u8) !void {
    const kind = if (is_library)
        if (std.mem.eql(u8, lang, "c")) manifest.TemplateKind.c_lib else manifest.TemplateKind.cpp_lib
    else if (std.mem.eql(u8, lang, "c"))
        manifest.TemplateKind.c_exe
    else
        manifest.TemplateKind.cpp_exe;

    const template_dir = try manifest.getTemplateDir(ctx.allocator);
    defer ctx.allocator.free(template_dir);
    const template_rel = manifest.getBuildZonTemplatePath(kind, lang);
    const template_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ template_dir, template_rel });
    defer ctx.allocator.free(template_path);

    const content = readTemplateFile(ctx, template_path) catch |err| blk: {
        if (err == error.FileNotFound) {
            break :blk try manifest.renderTemplate(ctx.allocator, kind, name);
        }
        return err;
    };
    defer ctx.allocator.free(content);

    const to_write = if (std.mem.indexOf(u8, content, "{{PROJECT_NAME}}") != null)
        try manifest.substituteInContent(ctx.allocator, content, name)
    else
        content;
    defer if (to_write.ptr != content.ptr) ctx.allocator.free(to_write);

    const file = try ctx.cwd.createFile(manifest.manifest_filename, .{ .truncate = true });
    defer file.close();
    try file.writeAll(to_write);
}

fn readTemplateFile(ctx: *Context, template_path: []const u8) ![]u8 {
    var file = ctx.cwd.openFile(template_path, .{}) catch return error.FileNotFound;
    defer file.close();
    return file.readAll(ctx.allocator);
}

fn writeGitignore(ctx: *Context) !void {
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

    const file = try ctx.cwd.createFile(".gitignore", .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}
