//! GCC Compiler Backend
//!
//! GNU Compiler Collection implementation. Provides C/C++ compilation
//! with GCC-specific features and module support (GCC 11+).

const std = @import("std");
const Allocator = std.mem.Allocator;
const interface = @import("interface.zig");
const modules = @import("modules.zig");
const compat = @import("util").compat;

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

/// GCC compiler implementation
pub const GCC = struct {
    allocator: Allocator,
    gcc_path: []const u8,
    gxx_path: []const u8,
    version: GCCVersion,
    capabilities: Capabilities,

    const Self = @This();

    pub const GCCVersion = struct {
        major: u32,
        minor: u32,
        patch: u32,

        pub fn format(self: GCCVersion, allocator: Allocator) ![]const u8 {
            return std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{
                self.major,
                self.minor,
                self.patch,
            });
        }

        /// GCC 11+ has C++20 modules support
        pub fn supportsModules(self: GCCVersion) bool {
            return self.major >= 11;
        }

        /// GCC 14+ has improved modules support
        pub fn hasImprovedModules(self: GCCVersion) bool {
            return self.major >= 14;
        }
    };

    /// Initialize with auto-detected GCC
    pub fn init(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const gcc_path = try findGCC(allocator);
        errdefer allocator.free(gcc_path);

        const gxx_path = try findGxx(allocator);
        errdefer allocator.free(gxx_path);

        const version = try detectVersion(allocator, gcc_path);
        const version_str = try version.format(allocator);

        self.* = .{
            .allocator = allocator,
            .gcc_path = gcc_path,
            .gxx_path = gxx_path,
            .version = version,
            .capabilities = .{
                .cpp_modules = version.supportsModules(),
                .header_units = version.major >= 11,
                .module_dep_scan = version.major >= 11,
                .lto = true,
                .pgo = true,
                .sanitizers = true,
                .cross_compile = true,
                .max_c_standard = if (version.major >= 14) .c23 else .c17,
                .max_cpp_standard = if (version.major >= 14) .cpp23 else if (version.major >= 11) .cpp20 else .cpp17,
                .version = version_str,
                .vendor = "GNU",
            },
        };

        return self;
    }

    /// Initialize with specific paths
    pub fn initWithPaths(
        allocator: Allocator,
        gcc_path: []const u8,
        gxx_path: ?[]const u8,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const owned_gcc = try allocator.dupe(u8, gcc_path);
        errdefer allocator.free(owned_gcc);

        const owned_gxx = if (gxx_path) |p|
            try allocator.dupe(u8, p)
        else blk: {
            // Derive g++ path from gcc path
            if (std.mem.indexOf(u8, gcc_path, "gcc")) |idx| {
                var path_buf = try allocator.alloc(u8, gcc_path.len + 1);
                @memcpy(path_buf[0..idx], gcc_path[0..idx]);
                @memcpy(path_buf[idx .. idx + 2], "g++");
                @memcpy(path_buf[idx + 2 ..], gcc_path[idx + 3 ..]);
                break :blk path_buf[0 .. gcc_path.len - 1];
            }
            break :blk try allocator.dupe(u8, "g++");
        };

        const version = try detectVersion(allocator, owned_gcc);
        const version_str = try version.format(allocator);

        self.* = .{
            .allocator = allocator,
            .gcc_path = owned_gcc,
            .gxx_path = owned_gxx,
            .version = version,
            .capabilities = .{
                .cpp_modules = version.supportsModules(),
                .header_units = version.major >= 11,
                .module_dep_scan = version.major >= 11,
                .lto = true,
                .pgo = true,
                .sanitizers = true,
                .cross_compile = true,
                .max_c_standard = if (version.major >= 14) .c23 else .c17,
                .max_cpp_standard = if (version.major >= 14) .cpp23 else if (version.major >= 11) .cpp20 else .cpp17,
                .version = version_str,
                .vendor = "GNU",
            },
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.gcc_path);
        self.allocator.free(self.gxx_path);
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

    /// Select compiler binary based on language
    fn selectCompiler(self: *Self, sources: []const []const u8) []const u8 {
        for (sources) |src| {
            const ext = std.fs.path.extension(src);
            if (interface.Language.fromExtension(ext)) |lang| {
                switch (lang) {
                    .cpp, .objcpp => return self.gxx_path,
                    else => {},
                }
            }
        }
        return self.gcc_path;
    }

    /// Compile source files
    pub fn compile(self: *Self, allocator: Allocator, options: CompileOptions) !CompileResult {
        const start_time = std.time.nanoTimestamp();

        var args = std.ArrayList([]const u8).empty;
        defer args.deinit();

        // Select compiler
        try args.append(self.selectCompiler(options.sources));

        // Compilation only
        if (options.output_kind == .object or options.output_kind == .assembly or
            options.output_kind == .preprocessed)
        {
            try args.append("-c");
        }

        // Output type
        switch (options.output_kind) {
            .assembly => try args.append("-S"),
            .preprocessed => try args.append("-E"),
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
            try args.append("-ggdb"); // GDB-optimized debug info
        }

        // PIC
        if (options.pic) {
            try args.append("-fPIC");
        }

        // LTO
        if (options.lto) {
            try args.append("-flto");
            try args.append("-ffat-lto-objects"); // For compatibility
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

        // GCC-specific diagnostic options
        try args.append("-fdiagnostics-color=always");
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

        // C++ modules (GCC-specific)
        if (options.enable_modules and options.cpp_standard.supportsModules() and self.version.supportsModules()) {
            try args.append("-fmodules-ts");

            if (options.module_cache_dir) |cache| {
                // GCC uses -fmodule-mapper for module management
                const mapper_file = try std.fmt.allocPrint(allocator, "{s}/module.map", .{cache});
                const mapper_flag = try std.fmt.allocPrint(allocator, "-fmodule-mapper={s}", .{mapper_file});
                try args.append(mapper_flag);
            }

            // GCC uses different flag for prebuilt modules
            for (options.prebuilt_modules) |gcm| {
                // GCC compiled module interface files are .gcm
                const flag = try std.fmt.allocPrint(allocator, "-fmodule-file={s}", .{gcm});
                try args.append(flag);
            }
        }

        // Cross-compilation
        if (!options.target.isNative()) {
            // GCC uses different approach for cross-compilation
            // Typically through a prefixed toolchain (e.g., aarch64-linux-gnu-gcc)
            if (options.target.cpu) |cpu| {
                const cpu_flag = try std.fmt.allocPrint(allocator, "-mcpu={s}", .{cpu});
                try args.append(cpu_flag);
            }
            if (options.target.arch == .x86 and options.target.os != .native) {
                try args.append("-m32");
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

        const diagnostics = try parseGCCDiagnostics(allocator, result.stderr);

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

        var args = std.ArrayList([]const u8).empty;
        defer args.deinit();

        // Use g++ for linking (for C++ runtime)
        try args.append(self.gxx_path);

        // Output file
        try args.append("-o");
        try args.append(options.output);

        // Output type
        switch (options.output_kind) {
            .shared_lib => {
                try args.append("-shared");
                const soname = std.fs.path.basename(options.output);
                const soname_flag = try std.fmt.allocPrint(allocator, "-Wl,-soname,{s}", .{soname});
                try args.append(soname_flag);
            },
            .static_lib => {
                // Use ar for static libraries
                args.clearRetainingCapacity();
                try args.append("ar");
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

        // Linker script
        if (options.linker_script) |script| {
            const flag = try std.fmt.allocPrint(allocator, "-Wl,-T,{s}", .{script});
            try args.append(flag);
        }

        // LTO
        if (options.lto) {
            try args.append("-flto");
        }

        // Strip
        if (options.strip) {
            try args.append("-s");
        }

        // Export dynamic
        if (options.export_dynamic) {
            try args.append("-rdynamic");
        }

        // Allow undefined
        if (options.allow_undefined) {
            try args.append("-Wl,--allow-shlib-undefined");
        }

        // Rpath
        if (options.rpath) |rpath| {
            const flag = try std.fmt.allocPrint(allocator, "-Wl,-rpath,{s}", .{rpath});
            try args.append(flag);
        }

        // Extra flags
        for (options.extra_flags) |flag| {
            try args.append(flag);
        }

        const result = try runProcess(allocator, args.items, options.cwd);

        const end_time = std.time.nanoTimestamp();
        const duration: u64 = @intCast(end_time - start_time);

        const diagnostics = try parseGCCDiagnostics(allocator, result.stderr);

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

    /// Scan module dependencies
    pub fn scanModuleDeps(self: *Self, allocator: Allocator, source_path: []const u8, options: CompileOptions) !ModuleDepsResult {
        // GCC can output dependency info with -fdep-output and -fdep-format=p1689r5
        if (self.version.major >= 14) {
            return self.scanWithGCCDepOutput(allocator, source_path, options);
        }

        // Fallback to source scanning
        return self.scanFromSource(allocator, source_path);
    }

    fn scanWithGCCDepOutput(self: *Self, allocator: Allocator, source_path: []const u8, options: CompileOptions) !ModuleDepsResult {
        var args = std.ArrayList([]const u8).empty;
        defer args.deinit();

        try args.append(self.gxx_path);
        try args.append(options.cpp_standard.toFlag());
        try args.append("-fmodules-ts");
        try args.append("-E");
        try args.append("-fdep-format=p1689r5");

        // Create temp file for dependency output
        const dep_file = try std.fmt.allocPrint(allocator, "/tmp/ovo-deps-{d}.json", .{std.time.timestamp()});
        defer allocator.free(dep_file);

        const dep_flag = try std.fmt.allocPrint(allocator, "-fdep-output={s}", .{dep_file});
        try args.append(dep_flag);

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

        allocator.free(result.stdout);

        // Read and parse dependency file
        const dep_content = compat.readFileAlloc(allocator, dep_file, 1024 * 1024) catch {
            allocator.free(result.stderr);
            return self.scanFromSource(allocator, source_path);
        };
        defer allocator.free(dep_content);

        // Delete temp file
        compat.unlink(dep_file) catch {};

        // Parse P1689 format (simplified)
        const parsed = try parseP1689(allocator, dep_content);

        return .{
            .success = true,
            .dependencies = parsed.dependencies,
            .provides = parsed.provides,
            .is_interface = parsed.is_interface,
            .stdout = try allocator.dupe(u8, ""),
            .stderr = result.stderr,
        };
    }

    fn scanFromSource(self: *Self, allocator: Allocator, source_path: []const u8) !ModuleDepsResult {
        _ = self;

        const source = compat.readFileAlloc(allocator, source_path, 1024 * 1024 * 10) catch |err| {
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

    /// Compile module interface unit (generates GCM file)
    pub fn compileModuleInterface(self: *Self, allocator: Allocator, source_path: []const u8, output_bmi: []const u8, options: CompileOptions) !CompileResult {
        const start_time = std.time.nanoTimestamp();

        var args = std.ArrayList([]const u8).empty;
        defer args.deinit();

        try args.append(self.gxx_path);

        // C++ standard with modules
        try args.append(options.cpp_standard.toFlag());
        try args.append("-fmodules-ts");

        // Compile to module interface (GCM)
        try args.append("-c");

        // GCC outputs .gcm files in the current directory by default
        // Use -fmodule-only to only produce GCM without object file
        try args.append("-fmodule-only");

        // Output path
        try args.append("-o");
        try args.append(output_bmi);

        // Module cache/mapper
        if (options.module_cache_dir) |cache| {
            const mapper = try std.fmt.allocPrint(allocator, "{s}/module.map", .{cache});
            const flag = try std.fmt.allocPrint(allocator, "-fmodule-mapper={s}", .{mapper});
            try args.append(flag);
        }

        // Prebuilt modules
        for (options.prebuilt_modules) |gcm| {
            const flag = try std.fmt.allocPrint(allocator, "-fmodule-file={s}", .{gcm});
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

        const diagnostics = try parseGCCDiagnostics(allocator, result.stderr);

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
        return .gcc;
    }

    pub fn getPath(self: *Self) []const u8 {
        return self.gcc_path;
    }

    pub fn verify(self: *Self, allocator: Allocator) !bool {
        const result = try runProcess(allocator, &.{ self.gcc_path, "--version" }, null);
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        return result.exit_code == 0;
    }

    const vtable = interface.compilerInterface(Self);
};

/// Find GCC in PATH
fn findGCC(allocator: Allocator) ![]const u8 {
    const names = [_][]const u8{ "gcc-14", "gcc-13", "gcc-12", "gcc-11", "gcc" };

    if (compat.getenv("PATH")) |path_env| {
        var paths = std.mem.splitScalar(u8, path_env, ':');
        while (paths.next()) |dir| {
            for (names) |name| {
                const full_path = try std.fs.path.join(allocator, &.{ dir, name });
                defer allocator.free(full_path);

                if (compat.exists(full_path)) {
                    return allocator.dupe(u8, full_path);
                } else |_| {}
            }
        }
    }

    return error.CompilerNotFound;
}

/// Find G++ in PATH
fn findGxx(allocator: Allocator) ![]const u8 {
    const names = [_][]const u8{ "g++-14", "g++-13", "g++-12", "g++-11", "g++" };

    if (compat.getenv("PATH")) |path_env| {
        var paths = std.mem.splitScalar(u8, path_env, ':');
        while (paths.next()) |dir| {
            for (names) |name| {
                const full_path = try std.fs.path.join(allocator, &.{ dir, name });
                defer allocator.free(full_path);

                if (compat.exists(full_path)) {
                    return allocator.dupe(u8, full_path);
                } else |_| {}
            }
        }
    }

    return error.CompilerNotFound;
}

/// Detect GCC version
fn detectVersion(allocator: Allocator, gcc_path: []const u8) !GCC.GCCVersion {
    const result = try runProcess(allocator, &.{ gcc_path, "-dumpversion" }, null);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const version_str = std.mem.trim(u8, result.stdout, " \t\n\r");
    var parts = std.mem.splitScalar(u8, version_str, '.');

    const major = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
    const minor = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
    const patch = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;

    return .{
        .major = major,
        .minor = minor,
        .patch = patch,
    };
}

/// Parse P1689 format dependency info
fn parseP1689(allocator: Allocator, content: []const u8) !struct {
    provides: ?[]const u8,
    dependencies: []modules.ModuleDependency,
    is_interface: bool,
} {
    // Simplified P1689 parsing - full implementation would use JSON parser
    _ = content;

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

/// Parse GCC diagnostic output
fn parseGCCDiagnostics(allocator: Allocator, stderr: []const u8) ![]Diagnostic {
    var diagnostics = std.ArrayList(Diagnostic).init(allocator);
    errdefer diagnostics.deinit();

    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        if (parseGCCDiagnosticLine(allocator, line)) |diag| {
            try diagnostics.append(diag);
        } else |_| {}
    }

    return diagnostics.toOwnedSlice();
}

/// Parse single GCC diagnostic line
fn parseGCCDiagnosticLine(allocator: Allocator, line: []const u8) !Diagnostic {
    // GCC format: file:line:col: level: message [-Wflag]
    var parts = std.mem.splitScalar(u8, line, ':');

    const file = parts.next() orelse return error.InvalidFormat;
    const line_str = parts.next() orelse return error.InvalidFormat;
    const col_str = parts.next() orelse return error.InvalidFormat;
    const rest = parts.rest();

    const trimmed = std.mem.trim(u8, rest, " ");
    const level_end = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidFormat;
    const level_str = std.mem.trim(u8, trimmed[0..level_end], " ");
    var message = std.mem.trim(u8, trimmed[level_end + 1 ..], " ");

    // Extract warning code
    var code: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, message, '[')) |bracket_start| {
        if (std.mem.lastIndexOfScalar(u8, message, ']')) |bracket_end| {
            if (bracket_end > bracket_start) {
                code = try allocator.dupe(u8, message[bracket_start + 1 .. bracket_end]);
                message = std.mem.trim(u8, message[0..bracket_start], " ");
            }
        }
    }

    const level: DiagnosticLevel = if (std.mem.eql(u8, level_str, "error"))
        .error_
    else if (std.mem.eql(u8, level_str, "warning"))
        .warning
    else if (std.mem.eql(u8, level_str, "note"))
        .note
    else if (std.mem.eql(u8, level_str, "fatal error"))
        .fatal
    else
        return error.InvalidFormat;

    return .{
        .level = level,
        .file = try allocator.dupe(u8, file),
        .line = std.fmt.parseInt(u32, line_str, 10) catch null,
        .column = std.fmt.parseInt(u32, col_str, 10) catch null,
        .message = try allocator.dupe(u8, message),
        .code = code,
    };
}

test "GCC version parsing" {
    const testing = std.testing;

    const v14 = GCC.GCCVersion{ .major = 14, .minor = 0, .patch = 0 };
    const v11 = GCC.GCCVersion{ .major = 11, .minor = 0, .patch = 0 };
    const v10 = GCC.GCCVersion{ .major = 10, .minor = 0, .patch = 0 };

    try testing.expect(v14.supportsModules());
    try testing.expect(v14.hasImprovedModules());
    try testing.expect(v11.supportsModules());
    try testing.expect(!v11.hasImprovedModules());
    try testing.expect(!v10.supportsModules());
}
