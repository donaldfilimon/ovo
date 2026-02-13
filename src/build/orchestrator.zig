const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/mod.zig");
const project_mod = @import("../core/project.zig");
const zon = @import("../zon/mod.zig");

pub const BuildOptions = struct {
    target_name: ?[]const u8 = null,
    target_pattern: ?[]const u8 = null,
    optimize_override: ?[]const u8 = null,
    backend_override: ?[]const u8 = null,
    test_only: bool = false,
};

pub const BuiltArtifact = struct {
    name: []const u8,
    kind: project_mod.TargetType,
    path: []const u8,
};

pub const BuildResult = struct {
    project_name: []const u8,
    artifacts: []const BuiltArtifact,
};

pub fn loadProject(allocator: std.mem.Allocator) !project_mod.Project {
    const bytes = try core.fs.readFileAlloc(allocator, "build.zon");
    return zon.parser.parseBuildZon(allocator, bytes);
}

pub fn buildProject(allocator: std.mem.Allocator, options: BuildOptions) !BuildResult {
    const project = try loadProject(allocator);
    try core.fs.ensureDir(project.defaults.output_dir);

    var artifacts: std.ArrayList(BuiltArtifact) = .empty;
    errdefer artifacts.deinit(allocator);

    const optimize = options.optimize_override orelse project.defaults.optimize;
    const backend = options.backend_override orelse project.defaults.backend;

    var built_any = false;
    for (project.targets) |target| {
        if (options.target_name) |target_name| {
            if (!std.mem.eql(u8, target.name, target_name)) continue;
        }
        if (options.target_pattern) |pattern| {
            if (std.mem.indexOf(u8, target.name, pattern) == null) continue;
        }
        if (options.test_only and target.kind != .test_target and std.mem.indexOf(u8, target.name, "test") == null) continue;

        const artifact_path = try buildTarget(
            allocator,
            &project,
            target,
            optimize,
            backend,
        );
        try artifacts.append(allocator, .{
            .name = target.name,
            .kind = target.kind,
            .path = artifact_path,
        });
        built_any = true;
    }

    if (!built_any) {
        if (options.target_name != null) return error.TargetNotFound;
        if (options.test_only) return error.NoTestTargets;
        return error.NoTargets;
    }

    try writeCompileCommands(allocator, project);

    return .{
        .project_name = project.name,
        .artifacts = try artifacts.toOwnedSlice(allocator),
    };
}

pub fn findRunnableArtifact(result: BuildResult, requested_name: ?[]const u8) ?BuiltArtifact {
    if (requested_name) |name| {
        for (result.artifacts) |artifact| {
            if ((artifact.kind == .executable or artifact.kind == .test_target) and std.mem.eql(u8, artifact.name, name)) {
                return artifact;
            }
        }
        return null;
    }
    for (result.artifacts) |artifact| {
        if (artifact.kind == .executable or artifact.kind == .test_target) return artifact;
    }
    return null;
}

pub fn defaultRunnableTarget(project: project_mod.Project) ?project_mod.Target {
    for (project.targets) |target| {
        if (target.kind == .executable) return target;
    }
    for (project.targets) |target| {
        if (target.kind == .test_target) return target;
    }
    return null;
}

fn writeCompileCommands(allocator: std.mem.Allocator, project: project_mod.Project) !void {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "[\n");

    var first = true;
    for (project.targets) |target| {
        for (target.sources) |pattern| {
            const sources = resolveSourcePattern(allocator, pattern) catch continue;
            for (sources) |source| {
                if (!first) try out.appendSlice(allocator, ",\n");
                first = false;
                try out.print(
                    allocator,
                    "  {{\"directory\":\".\",\"file\":\"{s}\",\"command\":\"c++ {s} -c {s}\"}}",
                    .{ source, cppStandardFlag(project.defaults.cpp_standard), source },
                );
            }
        }
    }
    try out.appendSlice(allocator, "\n]\n");

    const path = try std.fmt.allocPrint(allocator, "{s}/compile_commands.json", .{project.defaults.output_dir});
    try core.fs.writeFile(path, out.items);
}

fn buildTarget(
    allocator: std.mem.Allocator,
    project: *const project_mod.Project,
    target: project_mod.Target,
    optimize: []const u8,
    backend: []const u8,
) ![]const u8 {
    var resolved_sources_list: std.ArrayList([]const u8) = .empty;
    errdefer resolved_sources_list.deinit(allocator);

    for (target.sources) |source_pattern| {
        const expanded = try resolveSourcePattern(allocator, source_pattern);
        for (expanded) |resolved| {
            try resolved_sources_list.append(allocator, resolved);
        }
    }

    const sources = resolved_sources_list.items;
    if (sources.len == 0) return error.NoSources;

    const output = try artifactPath(allocator, project.defaults.output_dir, target);

    switch (target.kind) {
        .executable, .test_target => {
            try compileAndLinkExecutable(
                allocator,
                sources,
                target.include_dirs,
                target.link_libraries,
                optimize,
                project.defaults.cpp_standard,
                backend,
                output,
            );
        },
        .library_shared => {
            try compileSharedLibrary(
                allocator,
                sources,
                target.include_dirs,
                target.link_libraries,
                optimize,
                project.defaults.cpp_standard,
                backend,
                output,
            );
        },
        .library_static => {
            try compileStaticLibrary(
                allocator,
                sources,
                target.include_dirs,
                optimize,
                project.defaults.cpp_standard,
                backend,
                output,
                project.defaults.output_dir,
                target.name,
            );
        },
    }

    return output;
}

fn compileAndLinkExecutable(
    allocator: std.mem.Allocator,
    sources: []const []const u8,
    include_dirs: []const []const u8,
    link_libraries: []const []const u8,
    optimize: []const u8,
    standard: project_mod.CppStandard,
    backend: []const u8,
    output: []const u8,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try appendCompilerPrefix(allocator, &argv, backend);
    try appendCommonCompileFlags(allocator, &argv, optimize, standard, include_dirs, backend);
    for (sources) |source| try argv.append(allocator, source);
    if (std.mem.eql(u8, backend, "msvc")) {
        for (link_libraries) |lib| try argv.append(allocator, try std.fmt.allocPrint(allocator, "{s}.lib", .{lib}));
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "/Fe:{s}", .{output}));
    } else {
        for (link_libraries) |lib| try argv.append(allocator, try std.fmt.allocPrint(allocator, "-l{s}", .{lib}));
        try argv.append(allocator, "-o");
        try argv.append(allocator, output);
    }

    const code = try core.exec.runInherit(allocator, argv.items);
    if (code != 0) return error.CompileFailed;
}

fn compileSharedLibrary(
    allocator: std.mem.Allocator,
    sources: []const []const u8,
    include_dirs: []const []const u8,
    link_libraries: []const []const u8,
    optimize: []const u8,
    standard: project_mod.CppStandard,
    backend: []const u8,
    output: []const u8,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try appendCompilerPrefix(allocator, &argv, backend);
    if (std.mem.eql(u8, backend, "msvc")) {
        try argv.append(allocator, "/LD");
    } else {
        try argv.append(allocator, "-shared");
        try argv.append(allocator, "-fPIC");
    }
    try appendCommonCompileFlags(allocator, &argv, optimize, standard, include_dirs, backend);
    for (sources) |source| try argv.append(allocator, source);
    if (std.mem.eql(u8, backend, "msvc")) {
        for (link_libraries) |lib| try argv.append(allocator, try std.fmt.allocPrint(allocator, "{s}.lib", .{lib}));
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "/Fe:{s}", .{output}));
    } else {
        for (link_libraries) |lib| try argv.append(allocator, try std.fmt.allocPrint(allocator, "-l{s}", .{lib}));
        try argv.append(allocator, "-o");
        try argv.append(allocator, output);
    }

    const code = try core.exec.runInherit(allocator, argv.items);
    if (code != 0) return error.CompileFailed;
}

fn compileStaticLibrary(
    allocator: std.mem.Allocator,
    sources: []const []const u8,
    include_dirs: []const []const u8,
    optimize: []const u8,
    standard: project_mod.CppStandard,
    backend: []const u8,
    output: []const u8,
    output_dir: []const u8,
    target_name: []const u8,
) !void {
    const obj_dir = try std.fmt.allocPrint(allocator, "{s}/obj-{s}", .{ output_dir, target_name });
    try core.fs.ensureDir(obj_dir);

    var objects: std.ArrayList([]const u8) = .empty;
    defer objects.deinit(allocator);

    for (sources, 0..) |source, i| {
        const obj_ext = if (std.mem.eql(u8, backend, "msvc")) ".obj" else ".o";
        const obj = try std.fmt.allocPrint(allocator, "{s}/{d}{s}", .{ obj_dir, i, obj_ext });
        try objects.append(allocator, obj);

        var compile_argv: std.ArrayList([]const u8) = .empty;
        defer compile_argv.deinit(allocator);
        try appendCompilerPrefix(allocator, &compile_argv, backend);
        try appendCommonCompileFlags(allocator, &compile_argv, optimize, standard, include_dirs, backend);
        if (std.mem.eql(u8, backend, "msvc")) {
            try compile_argv.append(allocator, "/c");
        } else {
            try compile_argv.append(allocator, "-c");
        }
        try compile_argv.append(allocator, source);
        if (std.mem.eql(u8, backend, "msvc")) {
            try compile_argv.append(allocator, try std.fmt.allocPrint(allocator, "/Fo:{s}", .{obj}));
        } else {
            try compile_argv.append(allocator, "-o");
            try compile_argv.append(allocator, obj);
        }

        const compile_code = try core.exec.runInherit(allocator, compile_argv.items);
        if (compile_code != 0) return error.CompileFailed;
    }

    if (std.mem.eql(u8, backend, "msvc")) {
        var lib_argv: std.ArrayList([]const u8) = .empty;
        defer lib_argv.deinit(allocator);
        try lib_argv.append(allocator, "lib");
        try lib_argv.append(allocator, try std.fmt.allocPrint(allocator, "/OUT:{s}", .{output}));
        for (objects.items) |obj| try lib_argv.append(allocator, obj);

        const lib_code = try core.exec.runInherit(allocator, lib_argv.items);
        if (lib_code != 0) return error.ArchiveFailed;
    } else {
        var ar_argv: std.ArrayList([]const u8) = .empty;
        defer ar_argv.deinit(allocator);
        try ar_argv.append(allocator, "ar");
        try ar_argv.append(allocator, "rcs");
        try ar_argv.append(allocator, output);
        for (objects.items) |obj| try ar_argv.append(allocator, obj);

        const ar_code = try core.exec.runInherit(allocator, ar_argv.items);
        if (ar_code != 0) return error.ArchiveFailed;
    }
}

fn appendCompilerPrefix(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    backend: []const u8,
) !void {
    if (std.mem.eql(u8, backend, "zigcc")) {
        try argv.append(allocator, "zig");
        try argv.append(allocator, "c++");
        return;
    }
    if (std.mem.eql(u8, backend, "clang")) {
        try argv.append(allocator, "clang++");
        return;
    }
    if (std.mem.eql(u8, backend, "gcc")) {
        try argv.append(allocator, "g++");
        return;
    }
    if (std.mem.eql(u8, backend, "msvc")) {
        try argv.append(allocator, "cl");
        return;
    }
    return error.UnsupportedCompilerBackend;
}

fn appendCommonCompileFlags(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    optimize: []const u8,
    standard: project_mod.CppStandard,
    include_dirs: []const []const u8,
    backend: []const u8,
) !void {
    if (std.mem.eql(u8, backend, "msvc")) {
        try argv.append(allocator, cppStandardFlagMsvc(standard));
        try argv.append(allocator, try optimizeFlagMsvc(optimize));
        try argv.append(allocator, "/EHsc");
        try argv.append(allocator, "/W3");
        for (include_dirs) |include_dir| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "/I{s}", .{include_dir}));
        }
    } else {
        try argv.append(allocator, cppStandardFlag(standard));
        try argv.append(allocator, try optimizeFlag(optimize));
        try argv.append(allocator, "-Wall");
        try argv.append(allocator, "-Wextra");
        for (include_dirs) |include_dir| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-I{s}", .{include_dir}));
        }
    }
}

fn cppStandardFlag(standard: project_mod.CppStandard) []const u8 {
    return switch (standard) {
        .c89 => "-std=c89",
        .c99 => "-std=c99",
        .c11 => "-std=c11",
        .c17 => "-std=c17",
        .cpp11 => "-std=c++11",
        .cpp14 => "-std=c++14",
        .cpp17 => "-std=c++17",
        .cpp20 => "-std=c++20",
        .cpp23 => "-std=c++23",
    };
}

fn optimizeFlag(optimize: []const u8) ![]const u8 {
    if (std.mem.eql(u8, optimize, "Debug")) return "-O0";
    if (std.mem.eql(u8, optimize, "ReleaseSafe")) return "-O2";
    if (std.mem.eql(u8, optimize, "ReleaseFast")) return "-O3";
    if (std.mem.eql(u8, optimize, "ReleaseSmall")) return "-Os";
    if (std.mem.eql(u8, optimize, "debug")) return "-O0";
    if (std.mem.eql(u8, optimize, "release-safe")) return "-O2";
    if (std.mem.eql(u8, optimize, "release-fast")) return "-O3";
    if (std.mem.eql(u8, optimize, "release-small")) return "-Os";
    return error.UnsupportedOptimizeMode;
}

fn cppStandardFlagMsvc(standard: project_mod.CppStandard) []const u8 {
    return switch (standard) {
        .c89, .c99, .c11, .c17, .cpp11, .cpp14, .cpp17 => "/std:c++17",
        .cpp20 => "/std:c++20",
        .cpp23 => "/std:c++latest",
    };
}

fn optimizeFlagMsvc(optimize: []const u8) ![]const u8 {
    if (std.mem.eql(u8, optimize, "Debug") or std.mem.eql(u8, optimize, "debug")) return "/Od";
    if (std.mem.eql(u8, optimize, "ReleaseSafe") or std.mem.eql(u8, optimize, "release-safe")) return "/O2";
    if (std.mem.eql(u8, optimize, "ReleaseFast") or std.mem.eql(u8, optimize, "release-fast")) return "/Ox";
    if (std.mem.eql(u8, optimize, "ReleaseSmall") or std.mem.eql(u8, optimize, "release-small")) return "/O1";
    return error.UnsupportedOptimizeMode;
}

fn artifactPath(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    target: project_mod.Target,
) ![]const u8 {
    return switch (target.kind) {
        .executable, .test_target => blk: {
            const ext = if (builtin.os.tag == .windows) ".exe" else "";
            break :blk try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ output_dir, target.name, ext });
        },
        .library_static => blk: {
            if (builtin.os.tag == .windows) {
                break :blk try std.fmt.allocPrint(allocator, "{s}/{s}.lib", .{ output_dir, target.name });
            }
            break :blk try std.fmt.allocPrint(allocator, "{s}/lib{s}.a", .{ output_dir, target.name });
        },
        .library_shared => blk: {
            const ext = switch (builtin.os.tag) {
                .windows => ".dll",
                .macos => ".dylib",
                else => ".so",
            };
            break :blk try std.fmt.allocPrint(allocator, "{s}/lib{s}{s}", .{ output_dir, target.name, ext });
        },
    };
}

pub fn resolveSourcePattern(allocator: std.mem.Allocator, pattern: []const u8) ![]const []const u8 {
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) {
        const single = try allocator.alloc([]const u8, 1);
        single[0] = pattern;
        return single;
    }

    const wildcard_index = std.mem.indexOfScalar(u8, pattern, '*').?;
    var base_dir = trimTrailingSlashes(pattern[0..wildcard_index]);
    if (base_dir.len == 0) base_dir = ".";
    const recursive = std.mem.indexOf(u8, pattern, "**") != null;
    const ext = std.fs.path.extension(pattern);

    var files: std.ArrayList([]const u8) = .empty;
    errdefer files.deinit(allocator);

    if (recursive) {
        var dir = try std.Io.Dir.cwd().openDir(core.runtime.io(), base_dir, .{ .iterate = true });
        defer dir.close(core.runtime.io());

        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(core.runtime.io())) |entry| {
            if (entry.kind != .file) continue;
            if (ext.len > 0 and !std.mem.eql(u8, std.fs.path.extension(entry.path), ext)) continue;
            try files.append(allocator, try resolvePatternPath(allocator, base_dir, entry.path));
        }
    } else {
        var dir = try std.Io.Dir.cwd().openDir(core.runtime.io(), base_dir, .{ .iterate = true });
        defer dir.close(core.runtime.io());

        var it = dir.iterate();
        while (try it.next(core.runtime.io())) |entry| {
            if (entry.kind != .file) continue;
            if (ext.len > 0 and !std.mem.eql(u8, std.fs.path.extension(entry.name), ext)) continue;
            try files.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, entry.name }));
        }
    }

    if (files.items.len == 0) return error.NoSources;
    return try files.toOwnedSlice(allocator);
}

fn resolvePatternPath(allocator: std.mem.Allocator, base_dir: []const u8, entry_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(entry_path)) return try allocator.dupe(u8, entry_path);
    if (hasBasePrefix(entry_path, base_dir)) return try allocator.dupe(u8, entry_path);
    return try std.fs.path.join(allocator, &.{ base_dir, entry_path });
}

fn hasBasePrefix(path: []const u8, base_dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, base_dir)) return false;
    if (path.len == base_dir.len) return true;
    return base_dir.len < path.len and isPathSeparator(path[base_dir.len]);
}

fn isPathSeparator(char: u8) bool {
    return char == '/' or char == '\\';
}

fn trimTrailingSlashes(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') : (end -= 1) {}
    return value[0..end];
}
