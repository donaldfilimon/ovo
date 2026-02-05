//! Core build orchestration engine for the ovo package manager.
//! Coordinates target resolution, build graph construction, execution, and cache updates.
const std = @import("std");
const graph = @import("graph.zig");
const scheduler = @import("scheduler.zig");
const cache = @import("cache.zig");
const artifacts = @import("artifacts.zig");

/// Build profile configuration.
pub const BuildProfile = enum {
    debug,
    release,
    release_safe,
    release_small,
    custom,

    pub fn optimizationFlags(self: BuildProfile) []const []const u8 {
        return switch (self) {
            .debug => &.{ "-g", "-O0" },
            .release => &.{ "-O3", "-DNDEBUG" },
            .release_safe => &.{ "-O2", "-g" },
            .release_small => &.{ "-Os", "-DNDEBUG" },
            .custom => &.{},
        };
    }

    pub fn outputSubdir(self: BuildProfile) []const u8 {
        return switch (self) {
            .debug => "debug",
            .release => "release",
            .release_safe => "release-safe",
            .release_small => "release-small",
            .custom => "custom",
        };
    }
};

/// Cross-compilation target specification.
pub const CrossTarget = struct {
    /// Target architecture (e.g., x86_64, aarch64, wasm32)
    arch: []const u8,
    /// Target OS (e.g., linux, macos, windows, freestanding)
    os: []const u8,
    /// Target ABI (e.g., gnu, musl, msvc)
    abi: ?[]const u8,
    /// CPU features
    cpu_features: ?[]const u8,

    pub fn triple(self: CrossTarget, allocator: std.mem.Allocator) ![]const u8 {
        if (self.abi) |abi| {
            return std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ self.arch, self.os, abi });
        }
        return std.fmt.allocPrint(allocator, "{s}-{s}", .{ self.arch, self.os });
    }

    pub fn native() CrossTarget {
        return .{
            .arch = @tagName(std.Target.current.cpu.arch),
            .os = @tagName(std.Target.current.os.tag),
            .abi = null,
            .cpu_features = null,
        };
    }
};

/// Source file information.
pub const SourceFile = struct {
    path: []const u8,
    kind: SourceKind,
    /// For C++ modules: the module name
    module_name: ?[]const u8,
    /// Modules this source imports (for C++ modules)
    imports: []const []const u8,

    pub const SourceKind = enum {
        c,
        cpp,
        cpp_module_interface,
        cpp_module_impl,
        objc,
        objcpp,
        asm_att,
        asm_intel,
        header,

        pub fn fromExtension(ext: []const u8) ?SourceKind {
            const map = std.StaticStringMap(SourceKind).initComptime(.{
                .{ ".c", .c },
                .{ ".cpp", .cpp },
                .{ ".cxx", .cpp },
                .{ ".cc", .cpp },
                .{ ".cppm", .cpp_module_interface },
                .{ ".ixx", .cpp_module_interface },
                .{ ".mpp", .cpp_module_interface },
                .{ ".m", .objc },
                .{ ".mm", .objcpp },
                .{ ".s", .asm_att },
                .{ ".S", .asm_att },
                .{ ".asm", .asm_intel },
                .{ ".h", .header },
                .{ ".hpp", .header },
                .{ ".hxx", .header },
            });
            return map.get(ext);
        }

        pub fn isCppModule(self: SourceKind) bool {
            return self == .cpp_module_interface or self == .cpp_module_impl;
        }
    };
};

/// Build target definition.
pub const BuildTarget = struct {
    name: []const u8,
    kind: artifacts.ArtifactKind,
    sources: []const SourceFile,
    include_paths: []const []const u8,
    library_paths: []const []const u8,
    libraries: []const []const u8,
    defines: []const []const u8,
    compiler_flags: []const []const u8,
    linker_flags: []const []const u8,
    dependencies: []const []const u8,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, kind: artifacts.ArtifactKind) !BuildTarget {
        return .{
            .name = try allocator.dupe(u8, name),
            .kind = kind,
            .sources = &.{},
            .include_paths = &.{},
            .library_paths = &.{},
            .libraries = &.{},
            .defines = &.{},
            .compiler_flags = &.{},
            .linker_flags = &.{},
            .dependencies = &.{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BuildTarget) void {
        self.allocator.free(self.name);
        // Note: Other slices are assumed to be owned by the caller
        self.* = undefined;
    }
};

/// Build engine configuration.
pub const EngineConfig = struct {
    /// Build profile
    profile: BuildProfile = .debug,
    /// Cross-compilation target (null for native)
    cross_target: ?CrossTarget = null,
    /// Maximum parallel jobs
    max_jobs: u32 = 0,
    /// Output directory
    output_dir: []const u8 = "build",
    /// Cache directory
    cache_dir: []const u8 = ".ovo-cache",
    /// Verbose output
    verbose: bool = false,
    /// Keep going on errors
    keep_going: bool = false,
    /// Dry run
    dry_run: bool = false,
    /// Force rebuild (ignore cache)
    force_rebuild: bool = false,
    /// C compiler
    cc: []const u8 = "cc",
    /// C++ compiler
    cxx: []const u8 = "c++",
    /// Linker
    ld: []const u8 = "c++",
    /// Archiver
    ar: []const u8 = "ar",
};

/// Build result summary.
pub const BuildResult = struct {
    success: bool,
    targets_built: u64,
    targets_cached: u64,
    targets_failed: u64,
    total_time_ns: u64,
    artifacts: []const u64,
    error_messages: []const []const u8,

    pub fn deinit(self: *BuildResult, allocator: std.mem.Allocator) void {
        if (self.artifacts.len > 0) allocator.free(self.artifacts);
        for (self.error_messages) |msg| allocator.free(msg);
        if (self.error_messages.len > 0) allocator.free(self.error_messages);
        self.* = undefined;
    }
};

/// The core build orchestration engine.
pub const BuildEngine = struct {
    config: EngineConfig,
    build_cache: cache.BuildCache,
    build_graph: graph.BuildGraph,
    artifact_registry: artifacts.ArtifactRegistry,
    targets: std.StringHashMap(BuildTarget),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: EngineConfig) !BuildEngine {
        const target_os = if (config.cross_target) |ct|
            parseOsTag(ct.os)
        else
            std.Target.current.os.tag;

        const profile_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{
            config.output_dir,
            config.profile.outputSubdir(),
        });
        defer allocator.free(profile_dir);

        return .{
            .config = config,
            .build_cache = try cache.BuildCache.init(allocator, config.cache_dir),
            .build_graph = graph.BuildGraph.init(allocator),
            .artifact_registry = try artifacts.ArtifactRegistry.init(allocator, profile_dir, target_os),
            .targets = std.StringHashMap(BuildTarget).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BuildEngine) void {
        self.build_cache.deinit();
        self.build_graph.deinit();
        self.artifact_registry.deinit();

        var it = self.targets.valueIterator();
        while (it.next()) |target| {
            var t = target.*;
            t.deinit();
        }
        self.targets.deinit();

        self.* = undefined;
    }

    /// Add a build target.
    pub fn addTarget(self: *BuildEngine, target: BuildTarget) !void {
        const key = try self.allocator.dupe(u8, target.name);
        try self.targets.put(key, target);
    }

    /// Resolve and build specified targets.
    pub fn build(self: *BuildEngine, target_names: []const []const u8) !BuildResult {
        const start_time = std.time.nanoTimestamp();
        var built_artifacts = std.ArrayList(u64).init(self.allocator);
        defer built_artifacts.deinit();
        var error_messages = std.ArrayList([]const u8).init(self.allocator);
        defer error_messages.deinit();

        // Ensure output directories exist
        try self.artifact_registry.ensureDirectories();

        // Resolve targets
        var targets_to_build = std.ArrayList(*BuildTarget).init(self.allocator);
        defer targets_to_build.deinit();

        if (target_names.len == 0) {
            // Build all targets
            var it = self.targets.valueIterator();
            while (it.next()) |target| {
                try targets_to_build.append(target);
            }
        } else {
            for (target_names) |name| {
                if (self.targets.getPtr(name)) |target| {
                    try targets_to_build.append(target);
                } else {
                    try error_messages.append(
                        try std.fmt.allocPrint(self.allocator, "Unknown target: {s}", .{name}),
                    );
                }
            }
        }

        if (error_messages.items.len > 0) {
            return .{
                .success = false,
                .targets_built = 0,
                .targets_cached = 0,
                .targets_failed = @intCast(error_messages.items.len),
                .total_time_ns = @intCast(std.time.nanoTimestamp() - start_time),
                .artifacts = &.{},
                .error_messages = try error_messages.toOwnedSlice(),
            };
        }

        // Build the dependency graph
        for (targets_to_build.items) |target| {
            try self.buildTargetGraph(target);
        }

        // Check for cycles
        if (self.build_graph.hasCycle()) {
            try error_messages.append(
                try self.allocator.dupe(u8, "Circular dependency detected in build graph"),
            );
            return .{
                .success = false,
                .targets_built = 0,
                .targets_cached = 0,
                .targets_failed = 1,
                .total_time_ns = @intCast(std.time.nanoTimestamp() - start_time),
                .artifacts = &.{},
                .error_messages = try error_messages.toOwnedSlice(),
            };
        }

        // Apply cache - mark nodes as skipped if their inputs haven't changed
        var cached_count: u64 = 0;
        if (!self.config.force_rebuild) {
            cached_count = try self.applyCaching();
        }

        // Execute the build
        var exec = try scheduler.Scheduler.init(
            self.allocator,
            &self.build_graph,
            .{
                .max_jobs = self.config.max_jobs,
                .keep_going = self.config.keep_going,
                .verbose = self.config.verbose,
                .dry_run = self.config.dry_run,
                .progress_callback = if (self.config.verbose) scheduler.defaultProgressCallback else null,
            },
        );
        defer exec.deinit();

        const stats = try exec.execute();

        // Update cache with successful builds
        try self.updateCacheFromResults();

        // Save cache manifest
        self.build_cache.saveManifest() catch |err| {
            if (self.config.verbose) {
                std.debug.print("Warning: Failed to save cache manifest: {}\n", .{err});
            }
        };

        // Collect error messages from failed nodes
        var graph_it = self.build_graph.nodes.valueIterator();
        while (graph_it.next()) |node| {
            if (node.state == .failed) {
                if (node.error_msg) |msg| {
                    try error_messages.append(
                        try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ node.name, msg }),
                    );
                }
            }
        }

        // Collect built artifacts
        var art_it = self.artifact_registry.artifacts.valueIterator();
        while (art_it.next()) |artifact| {
            if (artifact.is_valid) {
                try built_artifacts.append(artifact.id);
            }
        }

        const total_time = std.time.nanoTimestamp() - start_time;

        return .{
            .success = stats.failed_tasks == 0,
            .targets_built = stats.completed_tasks,
            .targets_cached = cached_count,
            .targets_failed = stats.failed_tasks,
            .total_time_ns = @intCast(total_time),
            .artifacts = try built_artifacts.toOwnedSlice(),
            .error_messages = try error_messages.toOwnedSlice(),
        };
    }

    fn buildTargetGraph(self: *BuildEngine, target: *BuildTarget) !void {
        var builder = graph.GraphBuilder.init(self.allocator, &self.build_graph);

        var object_nodes = std.ArrayList(u64).init(self.allocator);
        defer object_nodes.deinit();
        var object_files = std.ArrayList([]const u8).init(self.allocator);
        defer object_files.deinit();

        // First pass: add module interface units (they must be compiled first)
        for (target.sources) |source| {
            if (source.kind == .cpp_module_interface) {
                const obj_path = try self.objectPath(source.path);
                const bmi_path = try self.bmiPath(source.module_name orelse source.path);

                const compiler_args = try self.buildCompilerArgs(target, source, obj_path, bmi_path);
                defer self.allocator.free(compiler_args);

                const node_id = try builder.addModuleCompileNode(
                    source.module_name orelse source.path,
                    source.path,
                    bmi_path,
                    obj_path,
                    compiler_args,
                );

                try object_nodes.append(node_id);
                try object_files.append(obj_path);
            }
        }

        // Second pass: add regular source files
        for (target.sources) |source| {
            if (source.kind != .cpp_module_interface and source.kind != .header) {
                const obj_path = try self.objectPath(source.path);
                const compiler_args = try self.buildCompilerArgs(target, source, obj_path, null);
                defer self.allocator.free(compiler_args);

                const node_id = try builder.addCompileNode(
                    source.path,
                    obj_path,
                    compiler_args,
                );

                // Resolve module dependencies
                if (source.imports.len > 0) {
                    try self.build_graph.resolveModuleDependencies(node_id, source.imports);
                }

                try object_nodes.append(node_id);
                try object_files.append(obj_path);
            }
        }

        // Add link node
        if (object_nodes.items.len > 0 and target.kind != .object) {
            const output_path = try self.artifactPath(target.name, target.kind);
            const linker_args = try self.buildLinkerArgs(target, object_files.items, output_path);
            defer self.allocator.free(linker_args);

            const link_id = try builder.addLinkNode(
                target.name,
                output_path,
                object_files.items,
                linker_args,
            );

            // Link depends on all object files
            for (object_nodes.items) |obj_node| {
                try self.build_graph.addEdge(link_id, obj_node);
            }

            // Register artifact
            const artifact_id = try self.artifact_registry.register(
                target.name,
                target.kind,
                if (self.config.cross_target) |ct| try ct.triple(self.allocator) else null,
            );

            var node = self.build_graph.getMut(link_id).?;
            node.artifact_id = artifact_id;
        }
    }

    fn buildCompilerArgs(
        self: *BuildEngine,
        target: *BuildTarget,
        source: SourceFile,
        obj_path: []const u8,
        bmi_path: ?[]const u8,
    ) ![]const []const u8 {
        var args = std.ArrayList([]const u8).init(self.allocator);
        errdefer args.deinit();

        // Compiler
        const compiler = if (source.kind == .c) self.config.cc else self.config.cxx;
        try args.append(compiler);

        // Compile only
        try args.append("-c");

        // Output
        try args.append("-o");
        try args.append(obj_path);

        // Source
        try args.append(source.path);

        // Profile flags
        for (self.config.profile.optimizationFlags()) |flag| {
            try args.append(flag);
        }

        // Module-specific flags
        if (source.kind.isCppModule()) {
            try args.append("-fmodules");
            try args.append("-fmodule-output");
            if (bmi_path) |bmi| {
                const bmi_flag = try std.fmt.allocPrint(self.allocator, "-fmodule-output={s}", .{bmi});
                try args.append(bmi_flag);
            }
        }

        // Include paths
        for (target.include_paths) |path| {
            const flag = try std.fmt.allocPrint(self.allocator, "-I{s}", .{path});
            try args.append(flag);
        }

        // Defines
        for (target.defines) |define| {
            const flag = try std.fmt.allocPrint(self.allocator, "-D{s}", .{define});
            try args.append(flag);
        }

        // Custom compiler flags
        for (target.compiler_flags) |flag| {
            try args.append(flag);
        }

        // Cross-compilation
        if (self.config.cross_target) |ct| {
            const triple = try ct.triple(self.allocator);
            const target_flag = try std.fmt.allocPrint(self.allocator, "--target={s}", .{triple});
            try args.append(target_flag);
        }

        return args.toOwnedSlice();
    }

    fn buildLinkerArgs(
        self: *BuildEngine,
        target: *BuildTarget,
        object_files: []const []const u8,
        output_path: []const u8,
    ) ![]const []const u8 {
        var args = std.ArrayList([]const u8).init(self.allocator);
        errdefer args.deinit();

        // Linker
        try args.append(self.config.ld);

        // Output type
        switch (target.kind) {
            .shared_library => try args.append("-shared"),
            .static_library => {
                // Use archiver instead
                args.clearRetainingCapacity();
                try args.append(self.config.ar);
                try args.append("rcs");
            },
            else => {},
        }

        // Output
        try args.append("-o");
        try args.append(output_path);

        // Object files
        for (object_files) |obj| {
            try args.append(obj);
        }

        // Library paths
        for (target.library_paths) |path| {
            const flag = try std.fmt.allocPrint(self.allocator, "-L{s}", .{path});
            try args.append(flag);
        }

        // Libraries
        for (target.libraries) |lib| {
            const flag = try std.fmt.allocPrint(self.allocator, "-l{s}", .{lib});
            try args.append(flag);
        }

        // Custom linker flags
        for (target.linker_flags) |flag| {
            try args.append(flag);
        }

        // Cross-compilation
        if (self.config.cross_target) |ct| {
            const triple = try ct.triple(self.allocator);
            const target_flag = try std.fmt.allocPrint(self.allocator, "--target={s}", .{triple});
            try args.append(target_flag);
        }

        return args.toOwnedSlice();
    }

    fn objectPath(self: *BuildEngine, source_path: []const u8) ![]const u8 {
        const basename = std.fs.path.stem(source_path);
        return std.fmt.allocPrint(self.allocator, "{s}/{s}/obj/{s}.o", .{
            self.config.output_dir,
            self.config.profile.outputSubdir(),
            basename,
        });
    }

    fn bmiPath(self: *BuildEngine, module_name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}/obj/{s}.pcm", .{
            self.config.output_dir,
            self.config.profile.outputSubdir(),
            module_name,
        });
    }

    fn artifactPath(self: *BuildEngine, name: []const u8, kind: artifacts.ArtifactKind) ![]const u8 {
        const target_os = if (self.config.cross_target) |ct|
            parseOsTag(ct.os)
        else
            std.Target.current.os.tag;

        const ext = kind.extension(target_os);
        const subdir = switch (kind) {
            .executable => "bin",
            .static_library, .shared_library => "lib",
            else => "obj",
        };

        return std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}/{s}{s}", .{
            self.config.output_dir,
            self.config.profile.outputSubdir(),
            subdir,
            name,
            ext,
        });
    }

    fn applyCaching(self: *BuildEngine) !u64 {
        var cached_count: u64 = 0;

        var it = self.build_graph.nodes.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr;

            if (node.kind != .compile and node.kind != .compile_module) {
                continue;
            }

            if (node.inputs.len == 0) continue;

            // Check if cached
            const result = self.build_cache.checkDirty(
                node.inputs[0],
                node.command_args,
                &.{}, // TODO: dependencies
            ) catch continue;

            switch (result) {
                .clean => {
                    self.build_graph.markSkipped(entry.key_ptr.*);
                    cached_count += 1;
                },
                .dirty => {},
            }
        }

        return cached_count;
    }

    fn updateCacheFromResults(self: *BuildEngine) !void {
        var it = self.build_graph.nodes.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr;

            if (node.state != .completed) continue;
            if (node.kind != .compile and node.kind != .compile_module) continue;
            if (node.inputs.len == 0 or node.outputs.len == 0) continue;

            const source_hash = self.build_cache.hashFile(node.inputs[0]) catch continue;
            const flags_hash = cache.BuildCache.hashStrings(node.command_args);

            const key = cache.CacheKey.compute(source_hash, flags_hash, 0);

            // Get output size
            const stat = std.fs.cwd().statFile(node.outputs[0]) catch continue;

            try self.build_cache.store(key, node.outputs[0], stat.size, node.inputs);
        }
    }

    /// Clean all build outputs.
    pub fn clean(self: *BuildEngine) !void {
        try self.artifact_registry.clean();
        self.build_cache.clear();

        // Remove output directory
        std.fs.cwd().deleteTree(self.config.output_dir) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// Get build statistics.
    pub fn getStats(self: *const BuildEngine) BuildStats {
        const state = self.build_graph.countByState();
        const cache_stats = self.build_cache.getStats();

        return .{
            .total_nodes = self.build_graph.total_nodes,
            .completed = state.completed,
            .failed = state.failed,
            .skipped = state.skipped,
            .cache_hits = cache_stats.hits,
            .cache_misses = cache_stats.misses,
            .cache_hit_rate = self.build_cache.getHitRate(),
        };
    }

    pub const BuildStats = struct {
        total_nodes: u64,
        completed: u64,
        failed: u64,
        skipped: u64,
        cache_hits: u64,
        cache_misses: u64,
        cache_hit_rate: f64,
    };
};

fn parseOsTag(os_str: []const u8) std.Target.Os.Tag {
    const map = std.StaticStringMap(std.Target.Os.Tag).initComptime(.{
        .{ "linux", .linux },
        .{ "macos", .macos },
        .{ "windows", .windows },
        .{ "freebsd", .freebsd },
        .{ "freestanding", .freestanding },
    });
    return map.get(os_str) orelse .linux;
}

// Tests
test "build profile optimization flags" {
    const debug_flags = BuildProfile.debug.optimizationFlags();
    try std.testing.expect(debug_flags.len == 2);

    const release_flags = BuildProfile.release.optimizationFlags();
    try std.testing.expect(release_flags.len == 2);
}

test "cross target triple generation" {
    const allocator = std.testing.allocator;

    const target = CrossTarget{
        .arch = "aarch64",
        .os = "linux",
        .abi = "gnu",
        .cpu_features = null,
    };

    const triple = try target.triple(allocator);
    defer allocator.free(triple);

    try std.testing.expectEqualStrings("aarch64-linux-gnu", triple);
}

test "source kind from extension" {
    try std.testing.expect(SourceFile.SourceKind.fromExtension(".c") == .c);
    try std.testing.expect(SourceFile.SourceKind.fromExtension(".cpp") == .cpp);
    try std.testing.expect(SourceFile.SourceKind.fromExtension(".cppm") == .cpp_module_interface);
    try std.testing.expect(SourceFile.SourceKind.fromExtension(".h") == .header);
    try std.testing.expect(SourceFile.SourceKind.fromExtension(".unknown") == null);
}

test "engine initialization" {
    const allocator = std.testing.allocator;

    var engine = try BuildEngine.init(allocator, .{
        .profile = .debug,
        .output_dir = "/tmp/ovo-test-build",
        .cache_dir = "/tmp/ovo-test-cache",
    });
    defer engine.deinit();

    const stats = engine.getStats();
    try std.testing.expect(stats.total_nodes == 0);
}

test "artifact path generation" {
    const allocator = std.testing.allocator;

    var engine = try BuildEngine.init(allocator, .{
        .profile = .release,
        .output_dir = "build",
    });
    defer engine.deinit();

    const path = try engine.artifactPath("myapp", .executable);
    defer allocator.free(path);

    try std.testing.expect(std.mem.indexOf(u8, path, "release") != null);
    try std.testing.expect(std.mem.indexOf(u8, path, "bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, path, "myapp") != null);
}
