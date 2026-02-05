//! System Clang Compiler Backend
//!
//! Uses the system-installed Clang/LLVM compiler. Provides full C++ modules
//! support and advanced optimization features.

const std = @import("std");
const Allocator = std.mem.Allocator;
const interface = @import("interface.zig");
const modules = @import("modules.zig");

const Compiler = interface.Compiler;
const CompileOptions = interface.CompileOptions;
const CompileResult = interface.CompileResult;
const LinkOptions = interface.LinkOptions;
const LinkResult = interface.LinkResult;
const ModuleDepsResult = interface.ModuleDepsResult;
const Capabilities = interface.Capabilities;
const CompilerKind = interface.CompilerKind;
const Diagnostic = interface.Diagnostic;
const DiagnosticLevel = interface.DiagnosticLevel;

/// System Clang compiler implementation
pub const Clang = struct {
    allocator: Allocator,
    clang_path: []const u8,
    clangxx_path: []const u8,
    version: ClangVersion,
    capabilities: Capabilities,

    const Self = @This();

    pub const ClangVersion = struct {
        major: u32,
        minor: u32,
        patch: u32,

        pub fn format(self: ClangVersion, allocator: Allocator) ![]const u8 {
            return std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{
                self.major,
                self.minor,
                self.patch,
            });
        }

        pub fn supportsModules(self: ClangVersion) bool {
            // C++20 modules support improved significantly in Clang 16+
            return self.major >= 16;
        }

        pub fn supportsStdModules(self: ClangVersion) bool {
            // std module support in Clang 17+
            return self.major >= 17;
        }
    };

    /// Initialize with auto-detected Clang
    pub fn init(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const clang_path = try findClang(allocator);
        errdefer allocator.free(clang_path);

        const clangxx_path = try findClangxx(allocator);
        errdefer allocator.free(clangxx_path);

        const version = try detectVersion(allocator, clang_path);

        const version_str = try version.format(allocator);

        self.* = .{
            .allocator = allocator,
            .clang_path = clang_path,
            .clangxx_path = clangxx_path,
            .version = version,
            .capabilities = .{
                .cpp_modules = version.supportsModules(),
                .header_units = version.major >= 15,
                .module_dep_scan = version.major >= 15,
                .lto = true,
                .pgo = true,
                .sanitizers = true,
                .cross_compile = true,
                .max_c_standard = if (version.major >= 18) .c23 else .c17,
                .max_cpp_standard = if (version.major >= 17) .cpp23 else .cpp20,
                .version = version_str,
                .vendor = "LLVM",
            },
        };

        return self;
    }

    /// Initialize with specific paths
    pub fn initWithPaths(
        allocator: Allocator,
        clang_path: []const u8,
        clangxx_path: ?[]const u8,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const owned_clang = try allocator.dupe(u8, clang_path);
        errdefer allocator.free(owned_clang);

        const owned_clangxx = if (clangxx_path) |p|
            try allocator.dupe(u8, p)
        else
            try allocator.dupe(u8, clang_path);

        const version = try detectVersion(allocator, owned_clang);
        const version_str = try version.format(allocator);

        self.* = .{
            .allocator = allocator,
            .clang_path = owned_clang,
            .clangxx_path = owned_clangxx,
            .version = version,
            .capabilities = .{
                .cpp_modules = version.supportsModules(),
                .header_units = version.major >= 15,
                .module_dep_scan = version.major >= 15,
                .lto = true,
                .pgo = true,
                .sanitizers = true,
                .cross_compile = true,
                .max_c_standard = if (version.major >= 18) .c23 else .c17,
                .max_cpp_standard = if (version.major >= 17) .cpp23 else .cpp20,
                .version = version_str,
                .vendor = "LLVM",
            },
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.clang_path);
        self.allocator.free(self.clangxx_path);
        self.allocator.free(self.capabilities.version);
        self.allocator.destroy(self);
    }

    /// Get the compiler interface
    pub fn compiler(self: *Self) Compiler {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// Determine which compiler binary to use based on language
    fn selectCompiler(self: *Self, sources: []const []const u8) []const u8 {
        for (sources) |src| {
            const ext = std.fs.path.extension(src);
            if (interface.Language.fromExtension(ext)) |lang| {
                switch (lang) {
                    .cpp, .objcpp => return self.clangxx_path,
                    else => {},
                }
            }
        }
        return self.clang_path;
    }

    /// Compile source files
    pub fn compile(self: *Self, allocator: Allocator, options: CompileOptions) !CompileResult {
        const start_time = std.time.nanoTimestamp();

        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();

        // Select compiler based on source type
        try args.append(self.selectCompiler(options.sources));

        // Compilation only
        if (options.output_kind == .object or options.output_kind == .assembly or
            options.output_kind == .preprocessed or options.output_kind == .llvm_ir)
        {
            try args.append("-c");
        }

        // Output type specific flags
        switch (options.output_kind) {
            .assembly => try args.append("-S"),
            .preprocessed => try args.append("-E"),
            .llvm_ir => {
                try args.append("-emit-llvm");
                try args.append("-S");
            },
            .bitcode => {
                try args.append("-emit-llvm");
                try args.append("-c");
            },
            else => {},
        }

        // Output file
        if (options.output) |out| {
            try args.append("-o");
            try args.append(out);
        }

        // Language standard
        if (options.sources.len > 0) {
            const ext = std.fs.path.extension(options.sources[0]);
            if (interface.Language.fromExtension(ext)) |lang| {
                switch (lang) {
                    .c => try args.append(options.c_standard.toFlag()),
                    .cpp => try args.append(options.cpp_standard.toFlag()),
                    else => {},
                }
            }
        }

        // Optimization
        try args.append(options.optimization.toFlag());

        // Debug info
        if (options.debug_info) {
            try args.append("-g");
            try args.append("-glldb"); // LLDB-optimized debug info
        }

        // PIC
        if (options.pic) {
            try args.append("-fPIC");
        }

        // LTO
        if (options.lto) {
            try args.append("-flto=thin"); // Use ThinLTO for faster linking
        }

        // Include directories
        for (options.include_dirs) |dir| {
            try args.append("-I");
            try args.append(dir);
        }

        // System include directories
        for (options.system_include_dirs) |dir| {
            try args.append("-isystem");
            try args.append(dir);
        }

        // Defines
        for (options.defines) |def| {
            const flag = try std.fmt.allocPrint(allocator, "-D{s}", .{def});
            try args.append(flag);
        }

        // Warnings
        for (options.warnings) |warn| {
            const flag = try std.fmt.allocPrint(allocator, "-W{s}", .{warn});
            try args.append(flag);
        }

        if (options.warnings_as_errors) {
            try args.append("-Werror");
        }

        // Clang-specific diagnostics
        try args.append("-fcolor-diagnostics");
        try args.append("-fdiagnostics-show-option");

        // Sanitizers
        if (options.sanitize_address) {
            try args.append("-fsanitize=address");
            try args.append("-fno-omit-frame-pointer");
        }
        if (options.sanitize_thread) {
            try args.append("-fsanitize=thread");
        }
        if (options.sanitize_undefined) {
            try args.append("-fsanitize=undefined");
        }

        // C++ modules (Clang-specific flags)
        if (options.enable_modules and options.cpp_standard.supportsModules() and self.version.supportsModules()) {
            // Use the new modules implementation
            try args.append("-fmodules");
            try args.append("-fbuiltin-module-map");

            if (options.module_cache_dir) |cache| {
                const cache_flag = try std.fmt.allocPrint(allocator, "-fmodules-cache-path={s}", .{cache});
                try args.append(cache_flag);
            }

            // Prebuilt modules
            for (options.prebuilt_modules) |bmi| {
                const flag = try std.fmt.allocPrint(allocator, "-fmodule-file={s}", .{bmi});
                try args.append(flag);
            }
        }

        // Cross-compilation
        if (!options.target.isNative()) {
            const triple = try options.target.toTriple(allocator);
            try args.append("-target");
            try args.append(triple);

            if (options.target.cpu) |cpu| {
                const cpu_flag = try std.fmt.allocPrint(allocator, "-mcpu={s}", .{cpu});
                try args.append(cpu_flag);
            }

            if (options.target.features) |features| {
                const feat_flag = try std.fmt.allocPrint(allocator, "-m{s}", .{features});
                try args.append(feat_flag);
            }
        }

        // Extra flags
        for (options.extra_flags) |flag| {
            try args.append(flag);
        }

        // Source files
        for (options.sources) |src| {
            try args.append(src);
        }

        // Execute
        const result = try runProcess(allocator, args.items, options.cwd);

        const end_time = std.time.nanoTimestamp();
        const duration: u64 = @intCast(end_time - start_time);

        const diagnostics = try parseClangDiagnostics(allocator, result.stderr);

        return .{
            .success = result.exit_code == 0,
            .output_path = if (options.output) |o| try allocator.dupe(u8, o) else null,
            .diagnostics = diagnostics,
            .stdout = result.stdout,
            .stderr = result.stderr,
            .exit_code = result.exit_code,
            .duration_ns = duration,
        };
    }

    /// Link object files
    pub fn link(self: *Self, allocator: Allocator, options: LinkOptions) !LinkResult {
        const start_time = std.time.nanoTimestamp();

        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();

        // Use clang++ for linking to get C++ runtime
        try args.append(self.clangxx_path);

        // Output file
        try args.append("-o");
        try args.append(options.output);

        // Output type
        switch (options.output_kind) {
            .shared_lib => {
                try args.append("-shared");
                if (options.target.os != .macos) {
                    try args.append("-Wl,-soname");
                    const soname = std.fs.path.basename(options.output);
                    const soname_flag = try std.fmt.allocPrint(allocator, "-Wl,{s}", .{soname});
                    try args.append(soname_flag);
                }
            },
            .static_lib => {
                // Use llvm-ar for static libraries
                args.clearRetainingCapacity();
                try args.append("llvm-ar");
                try args.append("rcs");
                try args.append(options.output);
                for (options.objects) |obj| {
                    try args.append(obj);
                }

                const result = try runProcess(allocator, args.items, options.cwd);
                const end_time = std.time.nanoTimestamp();

                return .{
                    .success = result.exit_code == 0,
                    .output_path = try allocator.dupe(u8, options.output),
                    .diagnostics = &.{},
                    .stdout = result.stdout,
                    .stderr = result.stderr,
                    .exit_code = result.exit_code,
                    .duration_ns = @intCast(end_time - start_time),
                };
            },
            else => {},
        }

        // Use lld if available
        try args.append("-fuse-ld=lld");

        // Object files
        for (options.objects) |obj| {
            try args.append(obj);
        }

        // Library directories
        for (options.library_dirs) |dir| {
            try args.append("-L");
            try args.append(dir);
        }

        // Libraries
        for (options.libraries) |lib| {
            const flag = try std.fmt.allocPrint(allocator, "-l{s}", .{lib});
            try args.append(flag);
        }

        // Frameworks (macOS)
        for (options.framework_dirs) |dir| {
            try args.append("-F");
            try args.append(dir);
        }
        for (options.frameworks) |fw| {
            try args.append("-framework");
            try args.append(fw);
        }

        // Linker script
        if (options.linker_script) |script| {
            const flag = try std.fmt.allocPrint(allocator, "-Wl,-T,{s}", .{script});
            try args.append(flag);
        }

        // LTO
        if (options.lto) {
            try args.append("-flto=thin");
        }

        // Strip
        if (options.strip) {
            try args.append("-Wl,-s");
        }

        // Export dynamic
        if (options.export_dynamic) {
            try args.append("-rdynamic");
        }

        // Allow undefined (for shared libs)
        if (options.allow_undefined) {
            if (options.target.os == .macos) {
                try args.append("-undefined");
                try args.append("dynamic_lookup");
            } else {
                try args.append("-Wl,--allow-shlib-undefined");
            }
        }

        // Rpath
        if (options.rpath) |rpath| {
            if (options.target.os == .macos) {
                try args.append("-Wl,-rpath");
                try args.append(rpath);
            } else {
                const flag = try std.fmt.allocPrint(allocator, "-Wl,-rpath,{s}", .{rpath});
                try args.append(flag);
            }
        }

        // Cross-compilation
        if (!options.target.isNative()) {
            const triple = try options.target.toTriple(allocator);
            try args.append("-target");
            try args.append(triple);
        }

        // Extra flags
        for (options.extra_flags) |flag| {
            try args.append(flag);
        }

        const result = try runProcess(allocator, args.items, options.cwd);

        const end_time = std.time.nanoTimestamp();
        const duration: u64 = @intCast(end_time - start_time);

        const diagnostics = try parseClangDiagnostics(allocator, result.stderr);

        return .{
            .success = result.exit_code == 0,
            .output_path = try allocator.dupe(u8, options.output),
            .diagnostics = diagnostics,
            .stdout = result.stdout,
            .stderr = result.stderr,
            .exit_code = result.exit_code,
            .duration_ns = duration,
        };
    }

    /// Scan module dependencies using clang-scan-deps
    pub fn scanModuleDeps(self: *Self, allocator: Allocator, source_path: []const u8, options: CompileOptions) !ModuleDepsResult {
        // First try clang-scan-deps if available
        if (self.version.major >= 15) {
            return self.scanWithClangScanDeps(allocator, source_path, options);
        }

        // Fallback to source parsing
        return self.scanFromSource(allocator, source_path);
    }

    fn scanWithClangScanDeps(self: *Self, allocator: Allocator, source_path: []const u8, options: CompileOptions) !ModuleDepsResult {
        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();

        try args.append("clang-scan-deps");
        try args.append("-format=p1689");
        try args.append("--");
        try args.append(self.clangxx_path);
        try args.append(options.cpp_standard.toFlag());

        for (options.include_dirs) |dir| {
            try args.append("-I");
            try args.append(dir);
        }

        for (options.defines) |def| {
            const flag = try std.fmt.allocPrint(allocator, "-D{s}", .{def});
            try args.append(flag);
        }

        try args.append(source_path);

        const result = runProcess(allocator, args.items, options.cwd) catch {
            return self.scanFromSource(allocator, source_path);
        };

        if (result.exit_code != 0) {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            return self.scanFromSource(allocator, source_path);
        }

        // Parse P1689 JSON output
        const deps_info = try parseP1689Output(allocator, result.stdout);
        allocator.free(result.stdout);

        return .{
            .success = true,
            .dependencies = deps_info.dependencies,
            .provides = deps_info.provides,
            .is_interface = deps_info.is_interface,
            .stdout = try allocator.dupe(u8, ""),
            .stderr = result.stderr,
        };
    }

    fn scanFromSource(self: *Self, allocator: Allocator, source_path: []const u8) !ModuleDepsResult {
        _ = self;

        const source = std.fs.cwd().readFileAlloc(allocator, source_path, 1024 * 1024 * 10) catch |err| {
            return .{
                .success = false,
                .dependencies = &.{},
                .provides = null,
                .is_interface = false,
                .stdout = "",
                .stderr = try std.fmt.allocPrint(allocator, "Failed to read source: {}", .{err}),
            };
        };
        defer allocator.free(source);

        const scan_result = try modules.scanModuleDeclarations(allocator, source);
        const is_interface = interface.Language.isModuleInterface(source_path) or
            scan_result.provides != null;

        return .{
            .success = true,
            .dependencies = scan_result.dependencies,
            .provides = scan_result.provides,
            .is_interface = is_interface,
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try allocator.dupe(u8, ""),
        };
    }

    /// Compile module interface unit
    pub fn compileModuleInterface(self: *Self, allocator: Allocator, source_path: []const u8, output_bmi: []const u8, options: CompileOptions) !CompileResult {
        const start_time = std.time.nanoTimestamp();

        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();

        try args.append(self.clangxx_path);

        // C++ standard with modules
        try args.append(options.cpp_standard.toFlag());

        // Precompile module interface
        try args.append("--precompile");

        // Output PCM file
        try args.append("-o");
        try args.append(output_bmi);

        // Module-specific flags
        try args.append("-fmodules");

        if (options.module_cache_dir) |cache| {
            const flag = try std.fmt.allocPrint(allocator, "-fmodules-cache-path={s}", .{cache});
            try args.append(flag);
        }

        // Prebuilt modules this depends on
        for (options.prebuilt_modules) |bmi| {
            const flag = try std.fmt.allocPrint(allocator, "-fmodule-file={s}", .{bmi});
            try args.append(flag);
        }

        // Include directories
        for (options.include_dirs) |dir| {
            try args.append("-I");
            try args.append(dir);
        }

        for (options.system_include_dirs) |dir| {
            try args.append("-isystem");
            try args.append(dir);
        }

        // Defines
        for (options.defines) |def| {
            const flag = try std.fmt.allocPrint(allocator, "-D{s}", .{def});
            try args.append(flag);
        }

        // Optimization
        try args.append(options.optimization.toFlag());

        // Debug info
        if (options.debug_info) {
            try args.append("-g");
        }

        // Source file
        try args.append(source_path);

        const result = try runProcess(allocator, args.items, options.cwd);

        const end_time = std.time.nanoTimestamp();
        const duration: u64 = @intCast(end_time - start_time);

        const diagnostics = try parseClangDiagnostics(allocator, result.stderr);

        return .{
            .success = result.exit_code == 0,
            .output_path = try allocator.dupe(u8, output_bmi),
            .diagnostics = diagnostics,
            .stdout = result.stdout,
            .stderr = result.stderr,
            .exit_code = result.exit_code,
            .duration_ns = duration,
        };
    }

    pub fn getCapabilities(self: *Self) Capabilities {
        return self.capabilities;
    }

    pub fn getKind(_: *Self) CompilerKind {
        return .clang;
    }

    pub fn getPath(self: *Self) []const u8 {
        return self.clang_path;
    }

    pub fn verify(self: *Self, allocator: Allocator) !bool {
        const result = try runProcess(allocator, &.{ self.clang_path, "--version" }, null);
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        return result.exit_code == 0;
    }

    const vtable = interface.compilerInterface(Self);
};

/// Find clang in PATH
fn findClang(allocator: Allocator) ![]const u8 {
    const names = [_][]const u8{ "clang-18", "clang-17", "clang-16", "clang-15", "clang" };

    if (std.posix.getenv("PATH")) |path_env| {
        var paths = std.mem.splitScalar(u8, path_env, ':');
        while (paths.next()) |dir| {
            for (names) |name| {
                const full_path = try std.fs.path.join(allocator, &.{ dir, name });
                defer allocator.free(full_path);

                if (std.fs.cwd().access(full_path, .{})) |_| {
                    return allocator.dupe(u8, full_path);
                } else |_| {}
            }
        }
    }

    return error.CompilerNotFound;
}

/// Find clang++ in PATH
fn findClangxx(allocator: Allocator) ![]const u8 {
    const names = [_][]const u8{ "clang++-18", "clang++-17", "clang++-16", "clang++-15", "clang++" };

    if (std.posix.getenv("PATH")) |path_env| {
        var paths = std.mem.splitScalar(u8, path_env, ':');
        while (paths.next()) |dir| {
            for (names) |name| {
                const full_path = try std.fs.path.join(allocator, &.{ dir, name });
                defer allocator.free(full_path);

                if (std.fs.cwd().access(full_path, .{})) |_| {
                    return allocator.dupe(u8, full_path);
                } else |_| {}
            }
        }
    }

    return error.CompilerNotFound;
}

/// Detect Clang version
fn detectVersion(allocator: Allocator, clang_path: []const u8) !Clang.ClangVersion {
    const result = try runProcess(allocator, &.{ clang_path, "--version" }, null);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // Parse version from output like "clang version 16.0.0"
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    if (lines.next()) |first_line| {
        if (std.mem.indexOf(u8, first_line, "version ")) |idx| {
            const version_start = idx + "version ".len;
            const version_str = first_line[version_start..];

            var parts = std.mem.splitScalar(u8, version_str, '.');
            const major = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
            const minor = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;

            var patch_str = parts.next() orelse "0";
            // Handle versions like "16.0.0-ubuntu1"
            if (std.mem.indexOfScalar(u8, patch_str, '-')) |dash| {
                patch_str = patch_str[0..dash];
            }
            // Handle versions ending with other chars
            var patch_end: usize = 0;
            while (patch_end < patch_str.len and std.ascii.isDigit(patch_str[patch_end])) {
                patch_end += 1;
            }
            const patch = std.fmt.parseInt(u32, patch_str[0..patch_end], 10) catch 0;

            return .{
                .major = major,
                .minor = minor,
                .patch = patch,
            };
        }
    }

    return .{ .major = 0, .minor = 0, .patch = 0 };
}

/// Parse P1689 module dependency format
fn parseP1689Output(allocator: Allocator, json_str: []const u8) !struct {
    provides: ?[]const u8,
    dependencies: []modules.ModuleDependency,
    is_interface: bool,
} {
    // Basic JSON parsing for P1689 format
    // Full implementation would use std.json
    _ = json_str;

    return .{
        .provides = null,
        .dependencies = try allocator.alloc(modules.ModuleDependency, 0),
        .is_interface = false,
    };
}

/// Run a process and capture output
fn runProcess(allocator: Allocator, args: []const []const u8, cwd: ?[]const u8) !struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
} {
    var child = std.process.Child.init(args, allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024 * 10);
    errdefer allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024 * 10);

    const term = try child.wait();

    const exit_code: i32 = switch (term) {
        .Exited => |code| @as(i32, code),
        .Signal => |sig| -@as(i32, @intCast(sig)),
        else => -1,
    };

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = exit_code,
    };
}

/// Parse Clang diagnostic output
fn parseClangDiagnostics(allocator: Allocator, stderr: []const u8) ![]Diagnostic {
    var diagnostics = std.ArrayList(Diagnostic).init(allocator);
    errdefer diagnostics.deinit();

    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        // Skip ANSI color codes if present
        var clean_line = line;
        while (std.mem.indexOf(u8, clean_line, "\x1b[")) |esc_start| {
            if (std.mem.indexOfScalarPos(u8, clean_line, esc_start, 'm')) |esc_end| {
                const before = clean_line[0..esc_start];
                const after = clean_line[esc_end + 1 ..];
                // Reconstruct without escape sequence
                const new_line = try std.fmt.allocPrint(allocator, "{s}{s}", .{ before, after });
                allocator.free(clean_line);
                clean_line = new_line;
            } else break;
        }

        if (parseClangDiagnosticLine(allocator, clean_line)) |diag| {
            try diagnostics.append(diag);
        } else |_| {}
    }

    return diagnostics.toOwnedSlice();
}

/// Parse single Clang diagnostic line
fn parseClangDiagnosticLine(allocator: Allocator, line: []const u8) !Diagnostic {
    return interface.parseCommonDiagnosticLine(allocator, line);
}

test "Clang version parsing" {
    const testing = std.testing;

    // Test version comparison
    const v16 = Clang.ClangVersion{ .major = 16, .minor = 0, .patch = 0 };
    const v15 = Clang.ClangVersion{ .major = 15, .minor = 0, .patch = 0 };

    try testing.expect(v16.supportsModules());
    try testing.expect(!v15.supportsModules());
}
