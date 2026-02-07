//! ovo build command
//!
//! Build the project with various configuration options.
//! Usage: ovo build [target] [--release/--debug/--target/--compiler/--std/--jobs/--verbose]

const std = @import("std");
const commands = @import("commands.zig");

// Module imports
const zon = @import("zon");
const build_mod = @import("build");
const util = @import("util");

const zon_parser = zon.parser;
const schema = zon.schema;
const engine = build_mod.engine;
const artifacts = build_mod.artifacts;
const glob = util.glob;

const Context = commands.Context;
const TermWriter = commands.TermWriter;
const ProgressBar = commands.ProgressBar;

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

/// Convert schema TargetType to engine ArtifactKind
fn toArtifactKind(target_type: schema.TargetType) artifacts.ArtifactKind {
    return switch (target_type) {
        .executable => .executable,
        .static_library => .static_library,
        .shared_library => .shared_library,
        .object => .object,
        .header_only => .object, // Header-only doesn't produce artifacts
    };
}

/// Resolve source files from glob patterns
fn resolveSourceFiles(
    allocator: std.mem.Allocator,
    sources: []const schema.SourceSpec,
) ![]engine.SourceFile {
    var result: std.ArrayList(engine.SourceFile) = .{};
    errdefer result.deinit(allocator);

    for (sources) |source_spec| {
        // Check if it's a glob pattern or literal path
        if (glob.isGlobPattern(source_spec.pattern)) {
            // Walk directory and match patterns
            const matched = try walkAndMatch(allocator, source_spec.pattern);
            defer allocator.free(matched);

            for (matched) |path| {
                const ext = std.fs.path.extension(path);
                const kind = engine.SourceFile.SourceKind.fromExtension(ext) orelse continue;
                if (kind == .header) continue; // Skip headers in source list

                try result.append(allocator, .{
                    .path = try allocator.dupe(u8, path),
                    .kind = kind,
                    .module_name = null,
                    .imports = &.{},
                });
            }
        } else {
            // Literal path
            const ext = std.fs.path.extension(source_spec.pattern);
            const kind = engine.SourceFile.SourceKind.fromExtension(ext) orelse continue;
            if (kind == .header) continue;

            try result.append(allocator, .{
                .path = try allocator.dupe(u8, source_spec.pattern),
                .kind = kind,
                .module_name = null,
                .imports = &.{},
            });
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Walk directory tree and find files matching pattern
fn walkAndMatch(
    allocator: std.mem.Allocator,
    pattern: []const u8,
) ![][]const u8 {
    var results: std.ArrayList([]const u8) = .{};
    errdefer {
        for (results.items) |item| allocator.free(item);
        results.deinit(allocator);
    }

    // For now, just return the literal pattern if not a complex glob
    // Full directory walking requires std.fs APIs which changed in 0.16
    // A proper implementation should use the C library or Zig's new Io APIs

    // If the pattern contains **, try common source directories
    if (std.mem.indexOf(u8, pattern, "**") != null) {
        // Extract the file extension pattern (e.g., "*.cpp" from "**/*.cpp")
        const ext_start = std.mem.lastIndexOfScalar(u8, pattern, '*') orelse 0;
        const ext_pattern = pattern[ext_start..];

        // Check common source file locations
        const common_paths = [_][]const u8{
            "src/main.c",
            "src/main.cpp",
            "src/lib.c",
            "src/lib.cpp",
            "main.c",
            "main.cpp",
            "lib.c",
            "lib.cpp",
        };

        for (common_paths) |path| {
            // Check if file matches extension pattern
            if (glob.match(ext_pattern, std.fs.path.basename(path))) {
                // Check if file exists using C library
                if (fileExists(path)) {
                    try results.append(allocator, try allocator.dupe(u8, path));
                }
            }
        }
    } else {
        // Literal path - just check if it exists
        if (fileExists(pattern)) {
            try results.append(allocator, try allocator.dupe(u8, pattern));
        }
    }

    return results.toOwnedSlice(allocator);
}

fn fileExists(path: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return false;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    return std.c.access(@ptrCast(&path_buf), std.c.F_OK) == 0;
}


/// Convert project target to build engine target
fn convertTarget(
    allocator: std.mem.Allocator,
    project_target: *const schema.Target,
    project: *const schema.Project,
) !engine.BuildTarget {
    var build_target = try engine.BuildTarget.init(
        allocator,
        project_target.name,
        toArtifactKind(project_target.target_type),
    );
    errdefer build_target.deinit();

    // Resolve source files
    const sources = try resolveSourceFiles(allocator, project_target.sources);
    build_target.sources = sources;

    // Include paths
    var includes: std.ArrayList([]const u8) = .{};
    if (project_target.includes) |incs| {
        for (incs) |inc| {
            try includes.append(allocator, inc.path);
        }
    }
    // Add default include directories if they exist
    if (fileExists("include")) {
        try includes.append(allocator, "include");
    }
    build_target.include_paths = try includes.toOwnedSlice(allocator);

    // Defines
    var defines: std.ArrayList([]const u8) = .{};
    if (project_target.defines) |defs| {
        for (defs) |def| {
            if (def.value) |val| {
                const define_str = try std.fmt.allocPrint(allocator, "{s}={s}", .{ def.name, val });
                try defines.append(allocator, define_str);
            } else {
                try defines.append(allocator, try allocator.dupe(u8, def.name));
            }
        }
    }
    build_target.defines = try defines.toOwnedSlice(allocator);

    // Compiler flags
    var flags: std.ArrayList([]const u8) = .{};

    // Add C/C++ standard flag
    const cpp_std = project_target.cpp_standard orelse
        (if (project.defaults) |d| d.cpp_standard else null);
    const c_std = project_target.c_standard orelse
        (if (project.defaults) |d| d.c_standard else null);

    if (cpp_std) |std_ver| {
        const flag = try std.fmt.allocPrint(allocator, "-std={s}", .{std_ver.toString()});
        try flags.append(allocator, flag);
    } else if (c_std) |std_ver| {
        const flag = try std.fmt.allocPrint(allocator, "-std={s}", .{std_ver.toString()});
        try flags.append(allocator, flag);
    }

    // Add target-specific flags
    if (project_target.flags) |target_flags| {
        for (target_flags) |f| {
            if (!f.link_only) {
                try flags.append(allocator, f.flag);
            }
        }
    }

    build_target.compiler_flags = try flags.toOwnedSlice(allocator);

    // Link libraries
    if (project_target.link_libraries) |libs| {
        build_target.libraries = libs;
    }

    return build_target;
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

    // Parse build.zon
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Parsing build.zon...\n", .{});

    var project = zon_parser.parseFile(ctx.allocator, "build.zon") catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to parse build.zon: {}\n", .{err});
        return 1;
    };
    defer project.deinit(ctx.allocator);

    // Print build configuration
    try ctx.stdout.bold("Building", .{});
    try ctx.stdout.print(" project '{s}' v{d}.{d}.{d}", .{
        project.name,
        project.version.major,
        project.version.minor,
        project.version.patch,
    });
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
        try ctx.stdout.dim("  Targets:  {d}\n", .{project.targets.len});
    }

    // Configure build engine
    const profile: engine.BuildProfile = if (opts.release) .release else .debug;

    var cross_target: ?engine.CrossTarget = null;
    if (opts.cross_target) |ct| {
        // Parse cross target string (e.g., "aarch64-linux-gnu")
        var parts = std.mem.splitScalar(u8, ct, '-');
        const arch = parts.next() orelse ct;
        const os = parts.next() orelse "linux";
        const abi = parts.next();

        cross_target = .{
            .arch = arch,
            .os = os,
            .abi = abi,
            .cpu_features = null,
        };
    }

    // Determine compiler
    const cc: []const u8 = opts.compiler orelse "cc";
    const cxx: []const u8 = if (opts.compiler) |c|
        if (std.mem.eql(u8, c, "gcc")) "g++" else if (std.mem.eql(u8, c, "clang")) "clang++" else "c++"
    else
        "c++";

    var build_engine = try engine.BuildEngine.init(ctx.allocator, .{
        .profile = profile,
        .cross_target = cross_target,
        .max_jobs = opts.jobs orelse 0,
        .output_dir = "build",
        .cache_dir = ".ovo-cache",
        .verbose = opts.verbose,
        .cc = cc,
        .cxx = cxx,
    });
    defer build_engine.deinit();

    // Clean if requested
    if (opts.clean_first) {
        try ctx.stdout.info("Cleaning build artifacts...\n", .{});
        try build_engine.clean();
    }

    // Convert project targets to build engine targets
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Resolving targets...\n", .{});

    var targets_to_build: std.ArrayList([]const u8) = .{};
    defer targets_to_build.deinit(ctx.allocator);

    for (project.targets) |*target| {
        // Skip if specific target requested and this isn't it
        if (opts.target) |requested| {
            if (!std.mem.eql(u8, target.name, requested)) continue;
        }

        // Skip header-only targets
        if (target.target_type == .header_only) continue;

        const build_target = convertTarget(ctx.allocator, target, &project) catch |err| {
            try ctx.stderr.warn("warning: ", .{});
            try ctx.stderr.print("failed to configure target '{s}': {}\n", .{ target.name, err });
            continue;
        };

        try build_engine.addTarget(build_target);
        try targets_to_build.append(ctx.allocator, target.name);

        if (opts.verbose) {
            try ctx.stdout.dim("    + {s} ({s})\n", .{
                target.name,
                @tagName(target.target_type),
            });
        }
    }

    if (targets_to_build.items.len == 0) {
        if (opts.target) |requested| {
            try ctx.stderr.err("error: ", .{});
            try ctx.stderr.print("target '{s}' not found in build.zon\n", .{requested});
            return 1;
        }
        try ctx.stderr.warn("warning: ", .{});
        try ctx.stderr.print("no buildable targets found\n", .{});
        return 0;
    }

    // Execute build
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Compiling {d} target(s)...\n", .{targets_to_build.items.len});

    const result = try build_engine.build(targets_to_build.items);

    // Print results
    try ctx.stdout.print("\n", .{});

    if (result.success) {
        try ctx.stdout.success("Build completed successfully!\n", .{});
        try ctx.stdout.dim("  Built:  {d} target(s)\n", .{result.targets_built});
        try ctx.stdout.dim("  Cached: {d} target(s)\n", .{result.targets_cached});

        const time_ms = result.total_time_ns / 1_000_000;
        try ctx.stdout.dim("  Time:   {d}ms\n", .{time_ms});
    } else {
        try ctx.stderr.err("Build failed!\n", .{});
        try ctx.stderr.print("  Built:  {d} target(s)\n", .{result.targets_built});
        try ctx.stderr.print("  Failed: {d} target(s)\n", .{result.targets_failed});

        for (result.error_messages) |msg| {
            try ctx.stderr.print("  - {s}\n", .{msg});
        }

        return 1;
    }

    return 0;
}
