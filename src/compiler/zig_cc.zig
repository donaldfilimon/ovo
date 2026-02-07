//! Zig CC Compiler Backend
//!
//! Uses Zig's bundled Clang compiler. This is the default, zero-configuration
//! compiler that works out of the box with any Zig installation.

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

/// Zig CC compiler implementation
pub const ZigCC = struct {
    allocator: Allocator,
    zig_path: []const u8,
    capabilities: Capabilities,

    const Self = @This();

    /// Initialize ZigCC with auto-detected Zig path
    pub fn init(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Find zig executable
        const zig_path = try findZigPath(allocator);

        self.* = .{
            .allocator = allocator,
            .zig_path = zig_path,
            .capabilities = .{
                .cpp_modules = true,
                .header_units = true,
                .module_dep_scan = true,
                .lto = true,
                .pgo = false, // Zig cc doesn't expose PGO directly
                .sanitizers = true,
                .cross_compile = true,
                .max_c_standard = .c23,
                .max_cpp_standard = .cpp23,
                .version = "zig-cc",
                .vendor = "Zig",
            },
        };

        return self;
    }

    /// Initialize with custom Zig path
    pub fn initWithPath(allocator: Allocator, zig_path: []const u8) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .zig_path = try allocator.dupe(u8, zig_path),
            .capabilities = .{
                .cpp_modules = true,
                .header_units = true,
                .module_dep_scan = true,
                .lto = true,
                .pgo = false,
                .sanitizers = true,
                .cross_compile = true,
                .max_c_standard = .c23,
                .max_cpp_standard = .cpp23,
                .version = "zig-cc",
                .vendor = "Zig",
            },
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.zig_path);
        self.allocator.destroy(self);
    }

    /// Get the compiler interface
    pub fn compiler(self: *Self) Compiler {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// Compile source files
    pub fn compile(self: *Self, allocator: Allocator, options: CompileOptions) !CompileResult {
        const start_time = std.time.nanoTimestamp();

        var args = std.ArrayList([]const u8).empty;
        defer args.deinit();

        // Base command
        try args.append(self.zig_path);
        try args.append("cc");

        // Compilation only (no linking)
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

        // Language standard (detect from first source)
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
        }

        // PIC
        if (options.pic) {
            try args.append("-fPIC");
        }

        // LTO
        if (options.lto) {
            try args.append("-flto");
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

        // Sanitizers
        if (options.sanitize_address) {
            try args.append("-fsanitize=address");
        }
        if (options.sanitize_thread) {
            try args.append("-fsanitize=thread");
        }
        if (options.sanitize_undefined) {
            try args.append("-fsanitize=undefined");
        }

        // C++ modules support
        if (options.enable_modules and options.cpp_standard.supportsModules()) {
            try args.append("-fmodules");
            if (options.module_cache_dir) |cache| {
                const cache_flag = try std.fmt.allocPrint(allocator, "-fmodules-cache-path={s}", .{cache});
                try args.append(cache_flag);
            }
            // Add prebuilt module paths
            for (options.prebuilt_modules) |bmi| {
                const mod_flag = try std.fmt.allocPrint(allocator, "-fmodule-file={s}", .{bmi});
                try args.append(mod_flag);
            }
        }

        // Cross-compilation target
        if (!options.target.isNative()) {
            const triple = try options.target.toTriple(allocator);
            const target_flag = try std.fmt.allocPrint(allocator, "-target={s}", .{triple});
            try args.append(target_flag);

            if (options.target.cpu) |cpu| {
                const cpu_flag = try std.fmt.allocPrint(allocator, "-mcpu={s}", .{cpu});
                try args.append(cpu_flag);
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

        // Parse diagnostics from stderr
        const diagnostics = try parseDiagnostics(allocator, result.stderr);

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

        try args.append(self.zig_path);
        try args.append("cc");

        // Output file
        try args.append("-o");
        try args.append(options.output);

        // Output type
        switch (options.output_kind) {
            .shared_lib => try args.append("-shared"),
            .static_lib => {
                // Use ar for static libraries
                args.clearRetainingCapacity();
                try args.append(self.zig_path);
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
            const flag = try std.fmt.allocPrint(allocator, "-T{s}", .{script});
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

        // Cross-compilation
        if (!options.target.isNative()) {
            const triple = try options.target.toTriple(allocator);
            const target_flag = try std.fmt.allocPrint(allocator, "-target={s}", .{triple});
            try args.append(target_flag);
        }

        // Extra flags
        for (options.extra_flags) |flag| {
            try args.append(flag);
        }

        const result = try runProcess(allocator, args.items, options.cwd);

        const end_time = std.time.nanoTimestamp();
        const duration: u64 = @intCast(end_time - start_time);

        const diagnostics = try parseDiagnostics(allocator, result.stderr);

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
        // Read source file and scan for module declarations
        const source = std.fs.cwd().readFileAlloc(allocator, source_path, 1024 * 1024 * 10) catch |err| {
            return .{
                .success = false,
                .dependencies = &.{},
                .provides = null,
                .is_interface = false,
                .stdout = "",
                .stderr = try std.fmt.allocPrint(allocator, "Failed to read source file: {}", .{err}),
            };
        };
        defer allocator.free(source);

        const scan_result = try modules.scanModuleDeclarations(allocator, source);

        // Also try clang's dependency scanning if available
        var args = std.ArrayList([]const u8).empty;
        defer args.deinit();

        try args.append(self.zig_path);
        try args.append("cc");
        try args.append("-E");
        try args.append("-fdirectives-only");

        // Add standard
        if (options.cpp_standard.supportsModules()) {
            try args.append(options.cpp_standard.toFlag());
            try args.append("-fmodules");
        }

        // Include dirs
        for (options.include_dirs) |dir| {
            try args.append("-I");
            try args.append(dir);
        }

        try args.append(source_path);

        const proc_result = try runProcess(allocator, args.items, options.cwd);
        defer allocator.free(proc_result.stdout);

        const is_interface = interface.Language.isModuleInterface(source_path) or
            scan_result.provides != null;

        return .{
            .success = true,
            .dependencies = scan_result.dependencies,
            .provides = scan_result.provides,
            .is_interface = is_interface,
            .stdout = try allocator.dupe(u8, ""),
            .stderr = proc_result.stderr,
        };
    }

    /// Compile module interface unit
    pub fn compileModuleInterface(self: *Self, allocator: Allocator, source_path: []const u8, output_bmi: []const u8, options: CompileOptions) !CompileResult {
        const start_time = std.time.nanoTimestamp();

        var args = std.ArrayList([]const u8).empty;
        defer args.deinit();

        try args.append(self.zig_path);
        try args.append("cc");

        // Precompile module
        try args.append("--precompile");

        // C++ standard with modules
        try args.append(options.cpp_standard.toFlag());
        try args.append("-fmodules");

        // Output BMI
        try args.append("-o");
        try args.append(output_bmi);

        // Module cache
        if (options.module_cache_dir) |cache| {
            const flag = try std.fmt.allocPrint(allocator, "-fmodules-cache-path={s}", .{cache});
            try args.append(flag);
        }

        // Prebuilt modules
        for (options.prebuilt_modules) |bmi| {
            const flag = try std.fmt.allocPrint(allocator, "-fmodule-file={s}", .{bmi});
            try args.append(flag);
        }

        // Include dirs
        for (options.include_dirs) |dir| {
            try args.append("-I");
            try args.append(dir);
        }

        // System includes
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

        // Source
        try args.append(source_path);

        const result = try runProcess(allocator, args.items, options.cwd);

        const end_time = std.time.nanoTimestamp();
        const duration: u64 = @intCast(end_time - start_time);

        const diagnostics = try parseDiagnostics(allocator, result.stderr);

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
        return .zig_cc;
    }

    pub fn getPath(self: *Self) []const u8 {
        return self.zig_path;
    }

    pub fn verify(self: *Self, allocator: Allocator) !bool {
        const result = try runProcess(allocator, &.{ self.zig_path, "cc", "--version" }, null);
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        return result.exit_code == 0;
    }

    // Vtable for interface
    const vtable = interface.compilerInterface(Self);
};

/// Find Zig executable path
fn findZigPath(allocator: Allocator) ![]const u8 {
    // Check ZIG_PATH environment variable
    if (std.posix.getenv("ZIG_PATH")) |path| {
        return allocator.dupe(u8, path);
    }

    // Check PATH
    if (std.posix.getenv("PATH")) |path_env| {
        var paths = std.mem.splitScalar(u8, path_env, ':');
        while (paths.next()) |dir| {
            const zig_path = try std.fs.path.join(allocator, &.{ dir, "zig" });
            defer allocator.free(zig_path);

            if (std.fs.cwd().access(zig_path, .{})) |_| {
                return allocator.dupe(u8, zig_path);
            } else |_| {}
        }
    }

    // Default to "zig" and hope it's in PATH
    return allocator.dupe(u8, "zig");
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

/// Parse diagnostic messages from stderr
fn parseDiagnostics(allocator: Allocator, stderr: []const u8) ![]Diagnostic {
    var diagnostics = std.ArrayList(Diagnostic).init(allocator);
    errdefer diagnostics.deinit();

    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        if (parseDiagnosticLine(allocator, line)) |diag| {
            try diagnostics.append(diag);
        } else |_| {}
    }

    return diagnostics.toOwnedSlice();
}

/// Parse a single diagnostic line
fn parseDiagnosticLine(allocator: Allocator, line: []const u8) !Diagnostic {
    // Format: file:line:col: level: message
    var parts = std.mem.splitScalar(u8, line, ':');

    const file = parts.next() orelse return error.InvalidFormat;
    const line_str = parts.next() orelse return error.InvalidFormat;
    const col_str = parts.next() orelse return error.InvalidFormat;
    const rest = parts.rest();

    const trimmed_rest = std.mem.trim(u8, rest, " ");
    const level_end = std.mem.indexOfScalar(u8, trimmed_rest, ':') orelse return error.InvalidFormat;
    const level_str = trimmed_rest[0..level_end];
    const message = std.mem.trim(u8, trimmed_rest[level_end + 1 ..], " ");

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
    };
}

test "ZigCC initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const compiler = ZigCC.init(allocator) catch |err| {
        // Skip test if zig not available
        if (err == error.FileNotFound) return;
        return err;
    };
    defer compiler.deinit();

    try testing.expectEqual(CompilerKind.zig_cc, compiler.getKind());
    try testing.expect(compiler.capabilities.cpp_modules);
    try testing.expect(compiler.capabilities.cross_compile);
}
