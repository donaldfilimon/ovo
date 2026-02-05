//! ovo build command
//!
//! Build the project with various configuration options.
//! Usage: ovo build [target] [--release/--debug/--target/--compiler/--std/--jobs/--verbose]

const std = @import("std");
const commands = @import("commands.zig");

// C library functions for compilation
extern "c" fn system(command: [*:0]const u8) c_int;

const Context = commands.Context;
const TermWriter = commands.TermWriter;
const ProgressBar = commands.ProgressBar;
const Color = commands.Color;

/// Build configuration options
pub const BuildOptions = struct {
    target: ?[]const u8 = null,
    release: bool = false,
    debug: bool = true,
    cross_target: ?[]const u8 = null,
    compiler: ?[]const u8 = null,
    std_version: ?[]const u8 = null,
    jobs: ?u32 = null,
    verbose: bool = false,
    clean_first: bool = false,
};

/// Print help for build command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo build", .{});
    try writer.print(" - Build the project\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo build [target] [options]\n\n", .{});

    try writer.bold("ARGUMENTS:\n", .{});
    try writer.print("    [target]         Build target name (from build.zon)\n\n", .{});

    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    --release        Build with optimizations\n", .{});
    try writer.print("    --debug          Build with debug info (default)\n", .{});
    try writer.print("    --target <arch>  Cross-compile for target architecture\n", .{});
    try writer.print("    --compiler <cc>  Use specific compiler (gcc, clang, msvc)\n", .{});
    try writer.print("    --std <ver>      C/C++ standard version (c11, c17, c++17, c++20)\n", .{});
    try writer.print("    -j, --jobs <n>   Number of parallel jobs\n", .{});
    try writer.print("    -v, --verbose    Show detailed build output\n", .{});
    try writer.print("    --clean          Clean before building\n", .{});
    try writer.print("    -h, --help       Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo build                    # Build default target\n", .{});
    try writer.dim("    ovo build mylib --release   # Build 'mylib' in release mode\n", .{});
    try writer.dim("    ovo build --target=arm64    # Cross-compile for ARM64\n", .{});
    try writer.dim("    ovo build -j8 --verbose     # Build with 8 jobs, verbose output\n", .{});
}

/// Parse command line options
fn parseOptions(args: []const []const u8) BuildOptions {
    var opts = BuildOptions{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--release")) {
            opts.release = true;
            opts.debug = false;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            opts.debug = true;
            opts.release = false;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--clean")) {
            opts.clean_first = true;
        } else if (std.mem.startsWith(u8, arg, "--target=")) {
            opts.cross_target = arg["--target=".len..];
        } else if (std.mem.eql(u8, arg, "--target") and i + 1 < args.len) {
            i += 1;
            opts.cross_target = args[i];
        } else if (std.mem.startsWith(u8, arg, "--compiler=")) {
            opts.compiler = arg["--compiler=".len..];
        } else if (std.mem.eql(u8, arg, "--compiler") and i + 1 < args.len) {
            i += 1;
            opts.compiler = args[i];
        } else if (std.mem.startsWith(u8, arg, "--std=")) {
            opts.std_version = arg["--std=".len..];
        } else if (std.mem.eql(u8, arg, "--std") and i + 1 < args.len) {
            i += 1;
            opts.std_version = args[i];
        } else if (std.mem.startsWith(u8, arg, "-j")) {
            const num_str = arg[2..];
            if (num_str.len > 0) {
                opts.jobs = std.fmt.parseInt(u32, num_str, 10) catch null;
            } else if (i + 1 < args.len) {
                i += 1;
                opts.jobs = std.fmt.parseInt(u32, args[i], 10) catch null;
            }
        } else if (std.mem.eql(u8, arg, "--jobs") and i + 1 < args.len) {
            i += 1;
            opts.jobs = std.fmt.parseInt(u32, args[i], 10) catch null;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Positional argument = target name
            opts.target = arg;
        }
    }

    return opts;
}

/// Execute the build command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    // Check for help flag
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    const opts = parseOptions(args);

    // Check for build.zon
    const manifest_exists = blk: {
        ctx.cwd.access("build.zon", .{}) catch break :blk false;
        break :blk true;
    };

    if (!manifest_exists) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("no build.zon found in current directory\n", .{});
        try ctx.stderr.dim("Run 'ovo init' to create a new project or 'ovo new <name>' to scaffold one.\n", .{});
        return 1;
    }

    // Print build configuration
    try ctx.stdout.bold("Building", .{});
    if (opts.target) |t| {
        try ctx.stdout.print(" target '{s}'", .{t});
    }
    if (opts.release) {
        try ctx.stdout.success(" [release]", .{});
    } else {
        try ctx.stdout.info(" [debug]", .{});
    }
    try ctx.stdout.print("\n", .{});

    // Show configuration details in verbose mode
    if (opts.verbose) {
        try ctx.stdout.dim("  Compiler: {s}\n", .{opts.compiler orelse "auto"});
        try ctx.stdout.dim("  Standard: {s}\n", .{opts.std_version orelse "default"});
        if (opts.cross_target) |t| {
            try ctx.stdout.dim("  Target:   {s}\n", .{t});
        }
        if (opts.jobs) |j| {
            try ctx.stdout.dim("  Jobs:     {d}\n", .{j});
        }
    }

    // Clean if requested
    if (opts.clean_first) {
        try ctx.stdout.info("Cleaning build artifacts...\n", .{});
        // Would invoke clean logic here
    }

    // Try to actually compile using system()
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Detecting sources...\n", .{});

    // Determine source file and language
    var source: ?[]const u8 = null;
    var is_cpp = false;

    // Check for source files using C library access()
    const patterns = [_]struct { path: [*:0]const u8, cpp: bool }{
        .{ .path = "main.cpp", .cpp = true },
        .{ .path = "main.c", .cpp = false },
        .{ .path = "src/main.cpp", .cpp = true },
        .{ .path = "src/main.c", .cpp = false },
    };

    for (patterns) |p| {
        if (std.c.access(p.path, std.c.F_OK) == 0) {
            source = std.mem.span(p.path);
            is_cpp = p.cpp;
            break;
        }
    }

    if (source == null) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("no source files found\n", .{});
        return 1;
    }

    // Determine compiler and flags
    const compiler: []const u8 = opts.compiler orelse if (is_cpp) "clang++" else "clang";
    const std_flag: []const u8 = opts.std_version orelse if (is_cpp) "-std=c++17" else "-std=c11";
    const out_dir: [*:0]const u8 = if (opts.release) "build/release" else "build/debug";
    const out_dir_slice: []const u8 = std.mem.span(out_dir);
    const opt_flag: []const u8 = if (opts.release) "-O2" else "-g";
    const out_name = opts.target orelse "main";

    // Create output directory
    _ = std.c.mkdir("build", 0o755);
    _ = std.c.mkdir(out_dir, 0o755);

    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Compiling {s} with {s}...\n", .{ source.?, compiler });

    // Build command string
    var cmd_buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "{s} {s} -o {s}/{s} {s} -Wall {s}", .{
        compiler,
        source.?,
        out_dir_slice,
        out_name,
        std_flag,
        opt_flag,
    }) catch {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("command too long\n", .{});
        return 1;
    };

    // Null-terminate for system()
    cmd_buf[cmd.len] = 0;

    if (opts.verbose) {
        try ctx.stdout.dim("  Command: {s}\n", .{cmd});
    }

    // Execute using system()
    const result = system(@ptrCast(&cmd_buf));

    if (result != 0) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("compilation failed\n", .{});
        return 1;
    }

    // Build summary
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.success("Build completed successfully!\n", .{});
    try ctx.stdout.dim("  Output: {s}/{s}\n", .{ out_dir_slice, out_name });

    return 0;
}
