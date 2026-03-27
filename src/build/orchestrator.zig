const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/mod.zig");
const compiler = @import("../compiler/mod.zig");
const project_mod = @import("../core/project.zig");
const zon = @import("../zon/mod.zig");
const lockfile = @import("../package/lockfile.zig");

pub const BuildOptions = struct {
    target_name: ?[]const u8 = null,
    target_pattern: ?[]const u8 = null,
    optimize_override: ?[]const u8 = null,
    backend_override: ?[]const u8 = null,
    test_only: bool = false,
    force: bool = false,
    jobs: u32 = 0,
    quiet: bool = false,
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
    const build_start = nowNs();
    const project = try loadProject(allocator);
    try core.fs.ensureDir(project.defaults.output_dir);

    var artifacts: std.ArrayList(BuiltArtifact) = .empty;
    errdefer artifacts.deinit(allocator);

    const optimize = options.optimize_override orelse project.defaults.optimize;
    const backend = try normalizeBackendLabel(options.backend_override orelse project.defaults.backend);
    const jobs = options.jobs;
    const quiet = options.quiet;

    // Collect active (filtered) target indices
    var active_indices: std.ArrayList(usize) = .empty;
    defer active_indices.deinit(allocator);
    for (project.targets, 0..) |target, i| {
        if (options.target_name) |target_name| {
            if (!std.mem.eql(u8, target.name, target_name)) continue;
        }
        if (options.target_pattern) |pattern| {
            if (std.mem.indexOf(u8, target.name, pattern) == null) continue;
        }
        if (options.test_only and target.kind != .test_target and std.mem.indexOf(u8, target.name, "test") == null) continue;
        try active_indices.append(allocator, i);
    }

    if (active_indices.items.len == 0) {
        if (options.target_name != null) return error.TargetNotFound;
        if (options.test_only) return error.NoTestTargets;
        return error.NoTargets;
    }

    // Compute dependency waves for cross-target parallelism
    const waves = try computeTargetWaves(allocator, project.targets, active_indices.items);
    defer {
        for (waves) |wave| allocator.free(wave);
        allocator.free(waves);
    }

    const job_limit = if (jobs == 0) detectJobCount() else jobs;
    var total_compiled: usize = 0;

    for (waves) |wave| {
        if (wave.len == 1) {
            // Single target in wave — build directly (no threading overhead)
            const target_idx = wave[0];
            const target = project.targets[target_idx];
            const bt_result = try buildTarget(
                allocator,
                &project,
                target,
                optimize,
                backend,
                options.force,
                jobs,
            );
            if (!quiet) printTargetProgress(target.name, bt_result);
            total_compiled += bt_result.compile_timings.len;
            try artifacts.append(allocator, .{
                .name = target.name,
                .kind = target.kind,
                .path = bt_result.artifact_path,
            });
        } else {
            // Multiple independent targets — build in parallel
            // Shared GPA for target threads — deinited AFTER consuming results
            var target_gpa: std.heap.DebugAllocator(.{}) = .init;
            const target_gpa_alloc = target_gpa.allocator();

            const wave_results = try allocator.alloc(TargetBuildResult, wave.len);
            defer allocator.free(wave_results);
            for (wave_results) |*r| r.* = .{};

            var wave_job_args = try allocator.alloc(TargetBuildJobArgs, wave.len);
            defer allocator.free(wave_job_args);

            var wave_threads = try allocator.alloc(?std.Thread, wave.len);
            defer allocator.free(wave_threads);
            for (wave_threads) |*t| t.* = null;

            var active_count = std.atomic.Value(u32).init(0);
            // Divide job budget across targets in wave to avoid oversubscription
            const jobs_per_target = @max(1, job_limit / @as(u32, @intCast(wave.len)));

            for (wave, 0..) |target_idx, wi| {
                // Bounded concurrency via CAS loop
                while (true) {
                    const current = active_count.load(.acquire);
                    if (current >= @as(u32, @intCast(wave.len))) {
                        std.Thread.yield() catch {};
                        continue;
                    }
                    if (active_count.cmpxchgWeak(current, current + 1, .acq_rel, .acquire) == null) break;
                }

                wave_job_args[wi] = .{
                    .project = &project,
                    .target_idx = target_idx,
                    .optimize = optimize,
                    .backend = backend,
                    .force = options.force,
                    .jobs = jobs_per_target,
                    .result = &wave_results[wi],
                    .active_count = &active_count,
                    .shared_gpa = target_gpa_alloc,
                };
                wave_threads[wi] = std.Thread.spawn(.{}, targetBuildThread, .{&wave_job_args[wi]}) catch {
                    _ = active_count.fetchSub(1, .release);
                    wave_results[wi].err = error.SpawnFailed;
                    continue;
                };
            }

            // Join all threads in this wave
            for (wave_threads) |maybe_t| {
                if (maybe_t) |t| t.join();
            }

            // Collect results, then deinit shared GPA
            var first_err: ?anyerror = null;
            for (wave, 0..) |target_idx, wi| {
                const owned_artifact_path = wave_results[wi].artifact_path;
                if (wave_results[wi].err) |err| {
                    if (first_err == null) first_err = err;
                    if (owned_artifact_path.len > 0) {
                        target_gpa_alloc.free(owned_artifact_path);
                    }
                    continue;
                }
                const target = project.targets[target_idx];
                // Dupe artifact_path to the arena allocator so it survives GPA deinit
                const path_copy = allocator.dupe(u8, owned_artifact_path) catch {
                    if (first_err == null) first_err = error.OutOfMemory;
                    if (owned_artifact_path.len > 0) {
                        target_gpa_alloc.free(owned_artifact_path);
                    }
                    continue;
                };
                total_compiled += wave_results[wi].compiled_count;
                artifacts.append(allocator, .{
                    .name = target.name,
                    .kind = target.kind,
                    .path = path_copy,
                }) catch {
                    if (first_err == null) first_err = error.OutOfMemory;
                    if (owned_artifact_path.len > 0) {
                        target_gpa_alloc.free(owned_artifact_path);
                    }
                    continue;
                };

                if (owned_artifact_path.len > 0) {
                    target_gpa_alloc.free(owned_artifact_path);
                }
            }

            _ = target_gpa.deinit();
            if (first_err) |err| return err;
        }
    }

    try writeCompileCommands(allocator, project);

    // Print build summary
    if (!quiet and total_compiled > 0) {
        const total_ns = elapsedNs(build_start);
        if (total_ns > 0) {
            std.debug.print("Build complete: {d} file(s) compiled, {d} target(s), {d}.{d:0>2}s total\n", .{
                total_compiled,
                artifacts.items.len,
                total_ns / std.time.ns_per_s,
                (total_ns % std.time.ns_per_s) / (std.time.ns_per_s / 100),
            });
        }
    }

    return .{
        .project_name = project.name,
        .artifacts = try artifacts.toOwnedSlice(allocator),
    };
}

fn printTargetProgress(target_name: []const u8, bt_result: BuildTargetResult) void {
    for (bt_result.compile_timings) |timing| {
        std.debug.print("Compiling {s} ... {d}.{d:0>2}s\n", .{
            timing.source,
            timing.elapsed_ns / std.time.ns_per_s,
            (timing.elapsed_ns % std.time.ns_per_s) / (std.time.ns_per_s / 100),
        });
    }
    if (bt_result.link_elapsed_ns > 0) {
        std.debug.print("Linking {s} ... {d}.{d:0>2}s\n", .{
            target_name,
            bt_result.link_elapsed_ns / std.time.ns_per_s,
            (bt_result.link_elapsed_ns % std.time.ns_per_s) / (std.time.ns_per_s / 100),
        });
    }
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

fn resolveDependencyIncludes(
    allocator: std.mem.Allocator,
    project: *const project_mod.Project,
    target_includes: []const []const u8,
) ![]const []const u8 {
    if (project.dependencies.len == 0) return target_includes;

    var merged: std.ArrayList([]const u8) = .empty;
    errdefer merged.deinit(allocator);

    // User-declared includes first (highest priority)
    for (target_includes) |inc| try merged.append(allocator, inc);

    // Scan fetched dependency cache dirs for include/ subdirs
    const lock = lockfileParseIfAvailable(allocator) catch null;
    for (project.dependencies) |dep| {
        const dep_dir = try resolveDependencyCacheDir(allocator, lock, dep);
        const include_path = try std.fmt.allocPrint(allocator, "{s}/include", .{dep_dir});
        if (core.fs.fileExists(include_path)) {
            try merged.append(allocator, include_path);
        }
        // Some C libraries put headers alongside sources
        const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{dep_dir});
        if (core.fs.fileExists(src_path)) {
            try merged.append(allocator, src_path);
        }
        // Also add the dep root itself (for flat-layout deps like stb)
        if (core.fs.fileExists(dep_dir)) {
            try merged.append(allocator, dep_dir);
        }
    }

    return try merged.toOwnedSlice(allocator);
}

fn lockfileParseIfAvailable(allocator: std.mem.Allocator) !?lockfile.LockFile {
    if (!core.fs.fileExists("ovo.lock.zon")) return null;
    const bytes = try core.fs.readFileAlloc(allocator, "ovo.lock.zon");
    return try lockfile.parseLockFile(allocator, bytes);
}

fn resolveDependencyCacheDir(
    allocator: std.mem.Allocator,
    lock: ?lockfile.LockFile,
    dep: project_mod.Dependency,
) ![]const u8 {
    if (lock) |l| {
        if (lockfile.findDependency(l, dep.name)) |locked| {
            if (locked.cache_key.len > 0) {
                const hashed = try std.fmt.allocPrint(allocator, ".ovo/cache/{s}", .{locked.cache_key});
                if (core.fs.fileExists(hashed)) {
                    return hashed;
                }
                allocator.free(hashed);
            }
        }
    }

    const legacy_key = try std.fmt.allocPrint(allocator, ".ovo/cache/{s}-{s}", .{ dep.name, dep.version });
    return legacy_key;
}

const BuildTargetResult = struct {
    artifact_path: []const u8,
    compile_timings: []const CompileTimingEntry,
    link_elapsed_ns: u64,
};

fn buildTarget(
    allocator: std.mem.Allocator,
    project: *const project_mod.Project,
    target: project_mod.Target,
    optimize: []const u8,
    backend: []const u8,
    force: bool,
    jobs: u32,
) !BuildTargetResult {
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
    const include_dirs = try resolveDependencyIncludes(allocator, project, target.include_dirs);

    var compile_timings: []const CompileTimingEntry = &.{};
    var link_elapsed_ns: u64 = 0;

    switch (target.kind) {
        .executable, .test_target => {
            const tr = try compileAndLinkExecutable(
                allocator,
                sources,
                include_dirs,
                target.link_libraries,
                optimize,
                project.defaults.cpp_standard,
                backend,
                output,
                project.defaults.output_dir,
                target.name,
                target.defines,
                target.cflags,
                force,
                jobs,
            );
            compile_timings = tr.compile_timings;
            link_elapsed_ns = tr.link_elapsed_ns;
        },
        .library_shared => {
            const tr = try compileSharedLibrary(
                allocator,
                sources,
                include_dirs,
                target.link_libraries,
                optimize,
                project.defaults.cpp_standard,
                backend,
                output,
                project.defaults.output_dir,
                target.name,
                target.defines,
                target.cflags,
                force,
                jobs,
            );
            compile_timings = tr.compile_timings;
            link_elapsed_ns = tr.link_elapsed_ns;
        },
        .library_static => {
            const tr = try compileStaticLibrary(
                allocator,
                sources,
                include_dirs,
                optimize,
                project.defaults.cpp_standard,
                backend,
                output,
                project.defaults.output_dir,
                target.name,
                target.defines,
                target.cflags,
                force,
                jobs,
            );
            compile_timings = tr.compile_timings;
            link_elapsed_ns = tr.link_elapsed_ns;
        },
    }

    return .{
        .artifact_path = output,
        .compile_timings = compile_timings,
        .link_elapsed_ns = link_elapsed_ns,
    };
}

const TargetBuildResult = struct {
    artifact_path: []const u8 = "",
    err: ?anyerror = null,
    compiled_count: usize = 0,
};

const TargetBuildJobArgs = struct {
    project: *const project_mod.Project,
    target_idx: usize,
    optimize: []const u8,
    backend: []const u8,
    force: bool,
    jobs: u32,
    result: *TargetBuildResult,
    active_count: *std.atomic.Value(u32),
    shared_gpa: std.mem.Allocator,
};

fn targetBuildThread(args: *TargetBuildJobArgs) void {
    defer _ = args.active_count.fetchSub(1, .release);

    // Per-thread arena backed by the shared GPA (DebugAllocator is thread-safe)
    var thread_arena = std.heap.ArenaAllocator.init(args.shared_gpa);
    defer thread_arena.deinit();
    const alloc = thread_arena.allocator();

    const target = args.project.targets[args.target_idx];
    const bt_result = buildTarget(
        alloc,
        args.project,
        target,
        args.optimize,
        args.backend,
        args.force,
        args.jobs,
    ) catch |err| {
        args.result.err = err;
        return;
    };

    args.result.compiled_count = bt_result.compile_timings.len;

    // Dupe artifact_path to shared GPA so it survives arena deinit
    args.result.artifact_path = args.shared_gpa.dupe(u8, bt_result.artifact_path) catch {
        args.result.err = error.OutOfMemory;
        return;
    };
}

fn computeTargetWaves(
    allocator: std.mem.Allocator,
    all_targets: []const project_mod.Target,
    active: []const usize,
) ![][]usize {
    // Build name → active position map
    var name_to_pos = std.StringHashMap(usize).init(allocator);
    defer name_to_pos.deinit();
    for (active, 0..) |target_idx, pos| {
        try name_to_pos.put(all_targets[target_idx].name, pos);
    }

    // Compute wave IDs via multi-pass relaxation
    var wave_ids = try allocator.alloc(usize, active.len);
    defer allocator.free(wave_ids);
    @memset(wave_ids, 0);

    var changed = true;
    while (changed) {
        changed = false;
        for (active, 0..) |target_idx, pos| {
            const target = all_targets[target_idx];
            for (target.link_libraries) |lib| {
                if (name_to_pos.get(lib)) |dep_pos| {
                    const needed = wave_ids[dep_pos] + 1;
                    if (needed > wave_ids[pos]) {
                        wave_ids[pos] = needed;
                        changed = true;
                    }
                }
            }
        }
    }

    // Find max wave
    var max_wave: usize = 0;
    for (wave_ids) |w| max_wave = @max(max_wave, w);

    // Count targets per wave
    var counts = try allocator.alloc(usize, max_wave + 1);
    defer allocator.free(counts);
    @memset(counts, 0);
    for (wave_ids) |w| counts[w] += 1;

    // Allocate wave slices
    var waves = try allocator.alloc([]usize, max_wave + 1);
    for (waves, 0..) |*w, wi| {
        w.* = try allocator.alloc(usize, counts[wi]);
    }

    // Fill wave slices with target indices (from all_targets, not active positions)
    @memset(counts, 0);
    for (active, 0..) |target_idx, pos| {
        const w = wave_ids[pos];
        waves[w][counts[w]] = target_idx;
        counts[w] += 1;
    }

    return waves;
}

fn sourceToObjectPath(
    allocator: std.mem.Allocator,
    obj_dir: []const u8,
    source: []const u8,
    is_msvc: bool,
) ![]const u8 {
    const mangled = try allocator.dupe(u8, source);
    defer allocator.free(mangled);
    for (mangled) |*c| {
        if (c.* == '/' or c.* == '\\' or c.* == ':' or c.* == '.') c.* = '_';
    }
    var trimmed = mangled;
    while (trimmed.len > 0 and trimmed[0] == '_') trimmed = trimmed[1..];
    const stem = if (trimmed.len > 0) trimmed else "source";
    const source_hash = std.hash.Wyhash.hash(0, source);
    const ext: []const u8 = if (is_msvc) ".obj" else ".o";
    return std.fmt.allocPrint(allocator, "{s}/{s}_{x}{s}", .{ obj_dir, stem, source_hash, ext });
}

fn removeStaleObjects(
    allocator: std.mem.Allocator,
    obj_dir: []const u8,
    expected_objects: []const []const u8,
    is_msvc: bool,
) bool {
    const obj_ext: []const u8 = if (is_msvc) ".obj" else ".o";
    var dir = std.Io.Dir.cwd().openDir(core.runtime.io(), obj_dir, .{ .iterate = true }) catch return false;
    defer dir.close(core.runtime.io());

    var removed_any = false;
    var it = dir.iterate();
    while (it.next(core.runtime.io()) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, obj_ext)) continue;

        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ obj_dir, entry.name }) catch continue;
        defer allocator.free(full_path);

        var is_expected = false;
        for (expected_objects) |expected| {
            if (std.mem.eql(u8, expected, full_path)) {
                is_expected = true;
                break;
            }
        }
        if (!is_expected) {
            core.fs.deleteFileIfExists(full_path) catch {};
            removed_any = true;
        }
    }
    return removed_any;
}

const CompileTimingEntry = struct {
    source: []const u8,
    elapsed_ns: u64,
};

const CompileResult = struct {
    objects: []const []const u8,
    any_dirty: bool,
    timings: []const CompileTimingEntry = &.{},
};

fn nowNs() ?u64 {
    const ts = std.Io.Clock.awake.now(core.runtime.io());
    const ns = ts.nanoseconds;
    if (ns <= 0) return null;
    return @intCast(ns);
}

fn elapsedNs(start: ?u64) u64 {
    const s = start orelse return 0;
    const end = nowNs() orelse return 0;
    if (end <= s) return 0;
    return end - s;
}

fn detectJobCount() u32 {
    const n = std.Thread.getCpuCount() catch return 4;
    return @intCast(@max(1, n));
}

const CompileJobResult = struct {
    failed: bool = false,
    stdout: ?[]u8 = null,
    stderr: ?[]u8 = null,
    elapsed_ns: u64 = 0,
};

const CompileJobArgs = struct {
    argv: []const []const u8,
    result: *CompileJobResult,
    active_count: *std.atomic.Value(u32),
    gpa: std.mem.Allocator,
};

fn compileJobThread(args: *CompileJobArgs) void {
    defer _ = args.active_count.fetchSub(1, .release);

    const start = nowNs();
    const cap = core.exec.runCapture(args.gpa, args.argv) catch {
        args.result.failed = true;
        return;
    };
    args.result.elapsed_ns = elapsedNs(start);
    args.result.stdout = cap.stdout;
    args.result.stderr = cap.stderr;
    args.result.failed = cap.code != 0;
}

fn compileSources(
    allocator: std.mem.Allocator,
    sources: []const []const u8,
    include_dirs: []const []const u8,
    optimize: []const u8,
    standard: project_mod.CppStandard,
    backend: []const u8,
    obj_dir: []const u8,
    defines: []const []const u8,
    cflags: []const []const u8,
    force: bool,
    jobs: u32,
) !CompileResult {
    try core.fs.ensureDir(obj_dir);
    const is_msvc = std.mem.eql(u8, backend, "msvc");
    const job_limit = if (jobs == 0) detectJobCount() else jobs;

    // Phase 1: Pre-compute all object paths, dirty flags, and compile commands
    var objects: std.ArrayList([]const u8) = .empty;
    errdefer objects.deinit(allocator);
    var any_dirty = false;

    var dirty_indices: std.ArrayList(usize) = .empty;
    defer dirty_indices.deinit(allocator);
    var all_argvs: std.ArrayList([]const []const u8) = .empty;
    defer all_argvs.deinit(allocator);

    for (sources, 0..) |source, i| {
        const obj = try sourceToObjectPath(allocator, obj_dir, source, is_msvc);
        try objects.append(allocator, obj);

        const dirty = blk: {
            if (force) break :blk true;
            const src_mtime = core.fs.fileMtimeNs(source) catch break :blk true;
            const obj_mtime = core.fs.fileMtimeNs(obj) catch break :blk true;
            break :blk src_mtime > obj_mtime;
        };

        if (!dirty) continue;
        any_dirty = true;

        var compile_argv: std.ArrayList([]const u8) = .empty;
        try appendCompilerPrefix(allocator, &compile_argv, backend);
        try appendCommonCompileFlags(allocator, &compile_argv, optimize, standard, include_dirs, backend, defines, cflags);
        if (is_msvc) {
            try compile_argv.append(allocator, "/c");
            try compile_argv.append(allocator, source);
            try compile_argv.append(allocator, try std.fmt.allocPrint(allocator, "/Fo:{s}", .{obj}));
        } else {
            try compile_argv.append(allocator, "-c");
            try compile_argv.append(allocator, source);
            try compile_argv.append(allocator, "-o");
            try compile_argv.append(allocator, obj);
        }
        try dirty_indices.append(allocator, i);
        try all_argvs.append(allocator, try compile_argv.toOwnedSlice(allocator));
    }

    // Remove stale .o/.obj files from previous builds (sources removed from build.zon)
    const stale_removed = removeStaleObjects(allocator, obj_dir, objects.items, is_msvc);
    if (stale_removed) any_dirty = true;

    const dirty_count = dirty_indices.items.len;
    if (dirty_count == 0 and !stale_removed) {
        return .{
            .objects = try objects.toOwnedSlice(allocator),
            .any_dirty = false,
        };
    }

    // Serial path: 1 job or 1 dirty source — skip threading overhead
    if (job_limit == 1 or dirty_count == 1) {
        var timings: std.ArrayList(CompileTimingEntry) = .empty;
        var failed_count: usize = 0;
        for (all_argvs.items, 0..) |argv, di| {
            const start = nowNs();
            const code = core.exec.runInherit(argv) catch {
                failed_count += 1;
                continue;
            };
            const elapsed_ns = elapsedNs(start);
            const source_idx = dirty_indices.items[di];
            try timings.append(allocator, .{ .source = sources[source_idx], .elapsed_ns = elapsed_ns });
            if (code != 0) failed_count += 1;
        }
        if (failed_count > 0) return error.CompileFailed;
        return .{
            .objects = try objects.toOwnedSlice(allocator),
            .any_dirty = true,
            .timings = try timings.toOwnedSlice(allocator),
        };
    }

    // Phase 2: Parallel dispatch with bounded concurrency
    // Shared GPA for captured output — deinited AFTER consuming results
    var capture_gpa: std.heap.DebugAllocator(.{}) = .init;
    const capture_alloc = capture_gpa.allocator();

    var results = try allocator.alloc(CompileJobResult, dirty_count);
    defer allocator.free(results);
    for (results) |*r| r.* = .{};

    var job_args_store = try allocator.alloc(CompileJobArgs, dirty_count);
    defer allocator.free(job_args_store);

    var threads = try allocator.alloc(?std.Thread, dirty_count);
    defer allocator.free(threads);
    for (threads) |*t| t.* = null;

    var active_count = std.atomic.Value(u32).init(0);

    for (all_argvs.items, 0..) |argv, di| {
        // Bounded concurrency via CAS loop — prevents exceeding job_limit
        while (true) {
            const current = active_count.load(.acquire);
            if (current >= job_limit) {
                std.Thread.yield() catch {};
                continue;
            }
            if (active_count.cmpxchgWeak(current, current + 1, .acq_rel, .acquire) == null) break;
        }

        job_args_store[di] = .{
            .argv = argv,
            .result = &results[di],
            .active_count = &active_count,
            .gpa = capture_alloc,
        };
        threads[di] = std.Thread.spawn(.{}, compileJobThread, .{&job_args_store[di]}) catch {
            _ = active_count.fetchSub(1, .release);
            results[di].failed = true;
            continue;
        };
    }

    // Phase 3: Join all threads
    for (threads) |maybe_thread| {
        if (maybe_thread) |thread| thread.join();
    }

    // Phase 4: Print captured output atomically, collect timings, count failures
    var failed_count: usize = 0;
    var timings: std.ArrayList(CompileTimingEntry) = .empty;
    for (results, 0..) |result, di| {
        const source_idx = dirty_indices.items[di];
        if (result.stderr) |s| {
            if (s.len > 0) {
                std.debug.print("--- {s} ---\n{s}", .{ sources[source_idx], s });
            }
        }
        if (result.stdout) |s| {
            if (s.len > 0) std.debug.print("{s}", .{s});
        }
        timings.append(allocator, .{
            .source = sources[source_idx],
            .elapsed_ns = result.elapsed_ns,
        }) catch {};
        if (result.failed) failed_count += 1;
    }

    // Free captured output and deinit shared GPA
    for (results) |result| {
        if (result.stdout) |s| capture_alloc.free(s);
        if (result.stderr) |s| capture_alloc.free(s);
    }
    _ = capture_gpa.deinit();

    if (failed_count > 0) {
        std.debug.print("error: {d} of {d} compilation(s) failed\n", .{ failed_count, dirty_count });
        return error.CompileFailed;
    }

    return .{
        .objects = try objects.toOwnedSlice(allocator),
        .any_dirty = true,
        .timings = timings.toOwnedSlice(allocator) catch &.{},
    };
}

const TimedBuildResult = struct {
    compile_timings: []const CompileTimingEntry,
    link_elapsed_ns: u64,
};

fn compileAndLinkExecutable(
    allocator: std.mem.Allocator,
    sources: []const []const u8,
    include_dirs: []const []const u8,
    link_libraries: []const []const u8,
    optimize: []const u8,
    standard: project_mod.CppStandard,
    backend: []const u8,
    output: []const u8,
    output_dir: []const u8,
    target_name: []const u8,
    defines: []const []const u8,
    cflags: []const []const u8,
    force: bool,
    jobs: u32,
) !TimedBuildResult {
    const obj_dir = try std.fmt.allocPrint(allocator, "{s}/obj-{s}", .{ output_dir, target_name });
    const result = try compileSources(allocator, sources, include_dirs, optimize, standard, backend, obj_dir, defines, cflags, force, jobs);

    const needs_link = result.any_dirty or !core.fs.fileExists(output);
    if (!needs_link) return .{ .compile_timings = result.timings, .link_elapsed_ns = 0 };

    const is_msvc = std.mem.eql(u8, backend, "msvc");
    const is_macos = builtin.os.tag == .macos;
    var argv: std.ArrayList([]const u8) = .empty;
    try appendCompilerPrefix(allocator, &argv, backend);
    for (result.objects) |obj| try argv.append(allocator, obj);
    if (is_msvc) {
        for (link_libraries) |lib| try argv.append(allocator, try std.fmt.allocPrint(allocator, "{s}.lib", .{lib}));
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "/Fe:{s}", .{output}));
    } else {
        for (link_libraries) |lib| try argv.append(allocator, try std.fmt.allocPrint(allocator, "-l{s}", .{lib}));
        if (is_macos) try appendMacosLinkerFlags(allocator, &argv, output);
        try argv.append(allocator, "-o");
        try argv.append(allocator, output);
    }

    const link_start = nowNs();
    const code = try core.exec.runInherit(argv.items);
    const link_elapsed = elapsedNs(link_start);
    if (code != 0) return error.CompileFailed;
    return .{ .compile_timings = result.timings, .link_elapsed_ns = link_elapsed };
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
    output_dir: []const u8,
    target_name: []const u8,
    defines: []const []const u8,
    cflags: []const []const u8,
    force: bool,
    jobs: u32,
) !TimedBuildResult {
    const is_msvc = std.mem.eql(u8, backend, "msvc");
    const obj_dir = try std.fmt.allocPrint(allocator, "{s}/obj-{s}", .{ output_dir, target_name });

    // For shared libraries, add -fPIC to compile flags (non-MSVC)
    const compile_cflags: []const []const u8 = if (!is_msvc) blk: {
        const extended = try allocator.alloc([]const u8, cflags.len + 1);
        extended[0] = "-fPIC";
        @memcpy(extended[1 .. cflags.len + 1], cflags);
        break :blk extended;
    } else cflags;
    defer if (!is_msvc) allocator.free(compile_cflags);

    const result = try compileSources(allocator, sources, include_dirs, optimize, standard, backend, obj_dir, defines, compile_cflags, force, jobs);

    const needs_link = result.any_dirty or !core.fs.fileExists(output);
    if (!needs_link) return .{ .compile_timings = result.timings, .link_elapsed_ns = 0 };

    var argv: std.ArrayList([]const u8) = .empty;
    try appendCompilerPrefix(allocator, &argv, backend);
    if (is_msvc) {
        try argv.append(allocator, "/LD");
    } else {
        try argv.append(allocator, "-shared");
    }
    for (result.objects) |obj| try argv.append(allocator, obj);
    if (is_msvc) {
        for (link_libraries) |lib| try argv.append(allocator, try std.fmt.allocPrint(allocator, "{s}.lib", .{lib}));
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "/Fe:{s}", .{output}));
    } else {
        for (link_libraries) |lib| try argv.append(allocator, try std.fmt.allocPrint(allocator, "-l{s}", .{lib}));
        if (builtin.os.tag == .macos) {
            try argv.append(allocator, "-Wl,-install_name,@rpath/{s}");
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Wl,-id,@rpath/{s}", .{std.fs.path.basename(output)}));
        }
        try argv.append(allocator, "-o");
        try argv.append(allocator, output);
    }

    const link_start = nowNs();
    const code = try core.exec.runInherit(argv.items);
    const link_elapsed = elapsedNs(link_start);
    if (code != 0) return error.CompileFailed;
    return .{ .compile_timings = result.timings, .link_elapsed_ns = link_elapsed };
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
    defines: []const []const u8,
    cflags: []const []const u8,
    force: bool,
    jobs: u32,
) !TimedBuildResult {
    const obj_dir = try std.fmt.allocPrint(allocator, "{s}/obj-{s}", .{ output_dir, target_name });
    const result = try compileSources(allocator, sources, include_dirs, optimize, standard, backend, obj_dir, defines, cflags, force, jobs);

    const needs_archive = result.any_dirty or !core.fs.fileExists(output);
    if (!needs_archive) return .{ .compile_timings = result.timings, .link_elapsed_ns = 0 };

    const link_start = nowNs();

    if (std.mem.eql(u8, backend, "msvc")) {
        var lib_argv: std.ArrayList([]const u8) = .empty;
        try lib_argv.append(allocator, "lib");
        try lib_argv.append(allocator, try std.fmt.allocPrint(allocator, "/OUT:{s}", .{output}));
        for (result.objects) |obj| try lib_argv.append(allocator, obj);

        const lib_code = try core.exec.runInherit(lib_argv.items);
        if (lib_code != 0) return error.ArchiveFailed;
    } else {
        var ar_argv: std.ArrayList([]const u8) = .empty;
        try ar_argv.append(allocator, "ar");
        try ar_argv.append(allocator, "rcs");
        try ar_argv.append(allocator, output);
        for (result.objects) |obj| try ar_argv.append(allocator, obj);

        const ar_code = try core.exec.runInherit(ar_argv.items);
        if (ar_code != 0) return error.ArchiveFailed;
    }

    const link_elapsed = elapsedNs(link_start);
    return .{ .compile_timings = result.timings, .link_elapsed_ns = link_elapsed };
}

fn normalizeBackendLabel(value: []const u8) ![]const u8 {
    return compiler.backend.validateLabel(value) catch return error.UnsupportedCompilerBackend;
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

fn appendMacosLinkerFlags(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    output: []const u8,
) !void {
    try argv.append(allocator, "-Wl,-e,_main");
    try argv.append(allocator, "-Wl,-rpath,@executable_path/../lib");
    const basename = std.fs.path.basename(output);
    try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Wl,-install_name,@rpath/{s}", .{basename}));
}

fn appendCommonCompileFlags(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    optimize: []const u8,
    standard: project_mod.CppStandard,
    include_dirs: []const []const u8,
    backend: []const u8,
    defines: []const []const u8,
    cflags: []const []const u8,
) !void {
    if (std.mem.eql(u8, backend, "msvc")) {
        try argv.append(allocator, cppStandardFlagMsvc(standard));
        try argv.append(allocator, try optimizeFlagMsvc(optimize));
        try argv.append(allocator, "/EHsc");
        try argv.append(allocator, "/W3");
        for (include_dirs) |include_dir| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "/I{s}", .{include_dir}));
        }
        for (defines) |define| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "/D{s}", .{define}));
        }
    } else {
        try argv.append(allocator, cppStandardFlag(standard));
        try argv.append(allocator, try optimizeFlag(optimize));
        try argv.append(allocator, "-Wall");
        try argv.append(allocator, "-Wextra");
        for (include_dirs) |include_dir| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-I{s}", .{include_dir}));
        }
        for (defines) |define| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-D{s}", .{define}));
        }
    }
    for (cflags) |flag| {
        try argv.append(allocator, flag);
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

test "normalizeBackendLabel canonicalizes aliases and casing" {
    try std.testing.expectEqualStrings("clang", try normalizeBackendLabel("Clang++"));
    try std.testing.expectEqualStrings("gcc", try normalizeBackendLabel("G++"));
    try std.testing.expectEqualStrings("msvc", try normalizeBackendLabel("cl"));
    try std.testing.expectEqualStrings("zigcc", try normalizeBackendLabel("zig-cc"));
    try std.testing.expectError(error.UnsupportedCompilerBackend, normalizeBackendLabel("wat"));
}

test "detectJobCount returns at least 1" {
    const count = detectJobCount();
    try std.testing.expect(count >= 1);
}

test "computeTargetWaves orders dependencies correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Target "app" links "mylib"; "mylib" has no deps
    const targets = &[_]project_mod.Target{
        .{ .name = "mylib", .kind = .library_static },
        .{ .name = "app", .kind = .executable, .link_libraries = &.{"mylib"} },
    };
    const active = &[_]usize{ 0, 1 };

    const waves = try computeTargetWaves(alloc, targets, active);

    // Wave 0 should contain "mylib" (index 0), wave 1 should contain "app" (index 1)
    try std.testing.expectEqual(@as(usize, 2), waves.len);
    try std.testing.expectEqual(@as(usize, 1), waves[0].len);
    try std.testing.expectEqual(@as(usize, 0), waves[0][0]);
    try std.testing.expectEqual(@as(usize, 1), waves[1].len);
    try std.testing.expectEqual(@as(usize, 1), waves[1][0]);
}

test "computeTargetWaves puts independent targets in same wave" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = &[_]project_mod.Target{
        .{ .name = "a", .kind = .executable },
        .{ .name = "b", .kind = .executable },
        .{ .name = "c", .kind = .executable },
    };
    const active = &[_]usize{ 0, 1, 2 };

    const waves = try computeTargetWaves(alloc, targets, active);

    // All independent → single wave
    try std.testing.expectEqual(@as(usize, 1), waves.len);
    try std.testing.expectEqual(@as(usize, 3), waves[0].len);
}

test "sourceToObjectPath produces stable path-derived names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = try sourceToObjectPath(alloc, ".ovo/build/obj-app", "src/util/helper.cpp", false);
    const expected = try std.fmt.allocPrint(
        alloc,
        ".ovo/build/obj-app/src_util_helper_cpp_{x}.o",
        .{std.hash.Wyhash.hash(0, "src/util/helper.cpp")},
    );
    try std.testing.expectEqualStrings(expected, path);

    const msvc = try sourceToObjectPath(alloc, ".ovo/build/obj-app", "src/main.cpp", true);
    const expected_msvc = try std.fmt.allocPrint(
        alloc,
        ".ovo/build/obj-app/src_main_cpp_{x}.obj",
        .{std.hash.Wyhash.hash(0, "src/main.cpp")},
    );
    try std.testing.expectEqualStrings(expected_msvc, msvc);

    const dotslash = try sourceToObjectPath(alloc, "obj", "./src/a.cpp", false);
    const expected_dotslash = try std.fmt.allocPrint(
        alloc,
        "obj/src_a_cpp_{x}.o",
        .{std.hash.Wyhash.hash(0, "./src/a.cpp")},
    );
    try std.testing.expectEqualStrings(expected_dotslash, dotslash);
}

test "sourceToObjectPath disambiguates colliding sanitized stems" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const nested = try sourceToObjectPath(alloc, "obj", "src/util/helper.cpp", false);
    const flat = try sourceToObjectPath(alloc, "obj", "src/util_helper.cpp", false);

    try std.testing.expect(!std.mem.eql(u8, nested, flat));
    try std.testing.expect(std.mem.indexOf(u8, nested, "src_util_helper_cpp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, flat, "src_util_helper_cpp_") != null);
}
