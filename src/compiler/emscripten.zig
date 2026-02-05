//! Emscripten Compiler Backend
//!
//! Emscripten (emcc/em++) implementation for WebAssembly compilation.
//! Compiles C/C++ to WebAssembly for browser and Node.js environments.

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

/// Emscripten compiler implementation
pub const Emscripten = struct {
    allocator: Allocator,
    emcc_path: []const u8,
    emxx_path: []const u8,
    version: EmscriptenVersion,
    capabilities: Capabilities,
    /// Emscripten SDK root path
    emsdk_path: ?[]const u8,

    const Self = @This();

    pub const EmscriptenVersion = struct {
        major: u32,
        minor: u32,
        patch: u32,

        pub fn format(self: EmscriptenVersion, allocator: Allocator) ![]const u8 {
            return std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{
                self.major,
                self.minor,
                self.patch,
            });
        }

        /// Emscripten 3.1.0+ has good C++20 support
        pub fn supportsCpp20(self: EmscriptenVersion) bool {
            return self.major >= 3 and self.minor >= 1;
        }

        /// Emscripten 3.1.25+ has C++23 support
        pub fn supportsCpp23(self: EmscriptenVersion) bool {
            return self.major >= 3 and (self.minor > 1 or (self.minor == 1 and self.patch >= 25));
        }
    };

    /// Wasm output settings
    pub const WasmSettings = struct {
        /// Generate standalone WASM (no JS glue)
        standalone: bool = false,
        /// Target environment
        environment: Environment = .web,
        /// Enable WASM exceptions
        exceptions: bool = false,
        /// Enable SIMD
        simd: bool = false,
        /// Enable threads (requires SharedArrayBuffer)
        threads: bool = false,
        /// Initial memory size in bytes
        initial_memory: ?u32 = null,
        /// Maximum memory size in bytes
        max_memory: ?u32 = null,
        /// Allow memory growth
        allow_memory_growth: bool = true,
        /// Export all symbols
        export_all: bool = false,
        /// Exported functions (besides main)
        exported_functions: []const []const u8 = &.{},
        /// Exported runtime methods
        exported_runtime_methods: []const []const u8 = &.{},
        /// Enable asyncify for async/await
        asyncify: bool = false,
        /// Generate source maps
        source_maps: bool = false,
        /// Modularize output
        modularize: bool = false,
        /// Module name for modularized output
        module_name: ?[]const u8 = null,

        pub const Environment = enum {
            web,
            webview,
            worker,
            node,
            shell,

            pub fn toFlag(self: Environment) []const u8 {
                return switch (self) {
                    .web => "web",
                    .webview => "webview",
                    .worker => "worker",
                    .node => "node",
                    .shell => "shell",
                };
            }
        };
    };

    /// Initialize with auto-detected Emscripten
    pub fn init(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const paths = try findEmscripten(allocator);
        errdefer {
            allocator.free(paths.emcc_path);
            allocator.free(paths.emxx_path);
            if (paths.emsdk_path) |p| allocator.free(p);
        }

        const version = try detectVersion(allocator, paths.emcc_path);
        const version_str = try version.format(allocator);

        self.* = .{
            .allocator = allocator,
            .emcc_path = paths.emcc_path,
            .emxx_path = paths.emxx_path,
            .version = version,
            .emsdk_path = paths.emsdk_path,
            .capabilities = .{
                .cpp_modules = false, // Emscripten doesn't fully support C++20 modules yet
                .header_units = false,
                .module_dep_scan = false,
                .lto = true,
                .pgo = false,
                .sanitizers = true,
                .cross_compile = true, // It's always cross-compiling to WASM
                .max_c_standard = .c17,
                .max_cpp_standard = if (version.supportsCpp23()) .cpp23 else if (version.supportsCpp20()) .cpp20 else .cpp17,
                .version = version_str,
                .vendor = "Emscripten",
            },
        };

        return self;
    }

    /// Initialize with specific paths
    pub fn initWithPaths(allocator: Allocator, emcc_path: []const u8) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const owned_emcc = try allocator.dupe(u8, emcc_path);
        errdefer allocator.free(owned_emcc);

        // Derive em++ path from emcc
        const dir = std.fs.path.dirname(emcc_path) orelse ".";
        const owned_emxx = try std.fs.path.join(allocator, &.{ dir, "em++" });

        const version = try detectVersion(allocator, owned_emcc);
        const version_str = try version.format(allocator);

        self.* = .{
            .allocator = allocator,
            .emcc_path = owned_emcc,
            .emxx_path = owned_emxx,
            .version = version,
            .emsdk_path = null,
            .capabilities = .{
                .cpp_modules = false,
                .header_units = false,
                .module_dep_scan = false,
                .lto = true,
                .pgo = false,
                .sanitizers = true,
                .cross_compile = true,
                .max_c_standard = .c17,
                .max_cpp_standard = if (version.supportsCpp23()) .cpp23 else if (version.supportsCpp20()) .cpp20 else .cpp17,
                .version = version_str,
                .vendor = "Emscripten",
            },
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.emcc_path);
        self.allocator.free(self.emxx_path);
        if (self.emsdk_path) |p| self.allocator.free(p);
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

    /// Select compiler based on source language
    fn selectCompiler(self: *Self, sources: []const []const u8) []const u8 {
        for (sources) |src| {
            const ext = std.fs.path.extension(src);
            if (interface.Language.fromExtension(ext)) |lang| {
                switch (lang) {
                    .cpp, .objcpp => return self.emxx_path,
                    else => {},
                }
            }
        }
        return self.emcc_path;
    }

    /// Compile source files
    pub fn compile(self: *Self, allocator: Allocator, options: CompileOptions) !CompileResult {
        return self.compileWithWasm(allocator, options, .{});
    }

    /// Compile with WASM-specific settings
    pub fn compileWithWasm(self: *Self, allocator: Allocator, options: CompileOptions, wasm: WasmSettings) !CompileResult {
        const start_time = std.time.nanoTimestamp();

        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();

        // Select compiler
        try args.append(self.selectCompiler(options.sources));

        // Compilation only (no linking)
        if (options.output_kind == .object or options.output_kind == .assembly or
            options.output_kind == .preprocessed or options.output_kind == .bitcode)
        {
            try args.append("-c");
        }

        // Output type
        switch (options.output_kind) {
            .assembly => try args.append("-S"),
            .preprocessed => try args.append("-E"),
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
            if (wasm.source_maps) {
                try args.append("-gsource-map");
            }
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
        if (options.sanitize_undefined) {
            try args.append("-fsanitize=undefined");
        }

        // WASM-specific settings
        const env_flag = try std.fmt.allocPrint(allocator, "-sENVIRONMENT={s}", .{wasm.environment.toFlag()});
        try args.append(env_flag);

        if (wasm.exceptions) {
            try args.append("-fwasm-exceptions");
        }

        if (wasm.simd) {
            try args.append("-msimd128");
        }

        if (wasm.threads) {
            try args.append("-pthread");
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

        const diagnostics = try parseEmscriptenDiagnostics(allocator, result.stderr);

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

    /// Link object files to WASM
    pub fn link(self: *Self, allocator: Allocator, options: LinkOptions) !LinkResult {
        return self.linkWithWasm(allocator, options, .{});
    }

    /// Link with WASM-specific settings
    pub fn linkWithWasm(self: *Self, allocator: Allocator, options: LinkOptions, wasm: WasmSettings) !LinkResult {
        const start_time = std.time.nanoTimestamp();

        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();

        // Use em++ for linking (C++ runtime support)
        try args.append(self.emxx_path);

        // Output file
        try args.append("-o");
        try args.append(options.output);

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

        // LTO
        if (options.lto) {
            try args.append("-flto");
        }

        // WASM-specific linker settings
        const env_flag = try std.fmt.allocPrint(allocator, "-sENVIRONMENT={s}", .{wasm.environment.toFlag()});
        try args.append(env_flag);

        if (wasm.standalone) {
            try args.append("-sSTANDALONE_WASM=1");
        }

        if (wasm.initial_memory) |mem| {
            const mem_flag = try std.fmt.allocPrint(allocator, "-sINITIAL_MEMORY={d}", .{mem});
            try args.append(mem_flag);
        }

        if (wasm.max_memory) |mem| {
            const mem_flag = try std.fmt.allocPrint(allocator, "-sMAXIMUM_MEMORY={d}", .{mem});
            try args.append(mem_flag);
        }

        if (wasm.allow_memory_growth) {
            try args.append("-sALLOW_MEMORY_GROWTH=1");
        }

        if (wasm.export_all) {
            try args.append("-sEXPORT_ALL=1");
        }

        if (wasm.exported_functions.len > 0) {
            var exported = std.ArrayList(u8).init(allocator);
            try exported.appendSlice("-sEXPORTED_FUNCTIONS=[");
            for (wasm.exported_functions, 0..) |func, i| {
                if (i > 0) try exported.append(',');
                try exported.appendSlice("'_");
                try exported.appendSlice(func);
                try exported.append('\'');
            }
            try exported.append(']');
            try args.append(try exported.toOwnedSlice());
        }

        if (wasm.exported_runtime_methods.len > 0) {
            var exported = std.ArrayList(u8).init(allocator);
            try exported.appendSlice("-sEXPORTED_RUNTIME_METHODS=[");
            for (wasm.exported_runtime_methods, 0..) |method, i| {
                if (i > 0) try exported.append(',');
                try exported.append('\'');
                try exported.appendSlice(method);
                try exported.append('\'');
            }
            try exported.append(']');
            try args.append(try exported.toOwnedSlice());
        }

        if (wasm.asyncify) {
            try args.append("-sASYNCIFY=1");
        }

        if (wasm.modularize) {
            try args.append("-sMODULARIZE=1");
            if (wasm.module_name) |name| {
                const name_flag = try std.fmt.allocPrint(allocator, "-sEXPORT_NAME='{s}'", .{name});
                try args.append(name_flag);
            }
        }

        if (wasm.exceptions) {
            try args.append("-fwasm-exceptions");
        }

        if (wasm.threads) {
            try args.append("-pthread");
        }

        // Extra flags
        for (options.extra_flags) |flag| {
            try args.append(flag);
        }

        const result = try runProcess(allocator, args.items, options.cwd);

        const end_time = std.time.nanoTimestamp();
        const duration: u64 = @intCast(end_time - start_time);

        const diagnostics = try parseEmscriptenDiagnostics(allocator, result.stderr);

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

    /// Scan module dependencies (fallback to source scanning)
    pub fn scanModuleDeps(self: *Self, allocator: Allocator, source_path: []const u8, _: CompileOptions) !ModuleDepsResult {
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

    /// Compile module interface (limited support in Emscripten)
    pub fn compileModuleInterface(self: *Self, allocator: Allocator, source_path: []const u8, output_bmi: []const u8, options: CompileOptions) !CompileResult {
        // Emscripten doesn't fully support C++20 modules
        // Fall back to regular compilation with a warning
        var modified_options = options;
        modified_options.sources = &.{source_path};
        modified_options.output = output_bmi;

        var result = try self.compile(allocator, modified_options);

        // Add warning about limited module support
        const warning_diag = Diagnostic{
            .level = .warning,
            .file = try allocator.dupe(u8, source_path),
            .line = null,
            .column = null,
            .message = try allocator.dupe(u8, "C++20 modules have limited support in Emscripten"),
        };

        var new_diags = try allocator.alloc(Diagnostic, result.diagnostics.len + 1);
        new_diags[0] = warning_diag;
        @memcpy(new_diags[1..], result.diagnostics);
        allocator.free(result.diagnostics);
        result.diagnostics = new_diags;

        return result;
    }

    pub fn getCapabilities(self: *Self) Capabilities {
        return self.capabilities;
    }

    pub fn getKind(_: *Self) CompilerKind {
        return .emscripten;
    }

    pub fn getPath(self: *Self) []const u8 {
        return self.emcc_path;
    }

    pub fn verify(self: *Self, allocator: Allocator) !bool {
        const result = try runProcess(allocator, &.{ self.emcc_path, "--version" }, null);
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        return result.exit_code == 0;
    }

    const vtable = interface.compilerInterface(Self);
};

/// Find Emscripten installation
fn findEmscripten(allocator: Allocator) !struct {
    emcc_path: []const u8,
    emxx_path: []const u8,
    emsdk_path: ?[]const u8,
} {
    // Check EMSDK environment variable
    var emsdk_path: ?[]const u8 = null;
    if (std.posix.getenv("EMSDK")) |emsdk| {
        emsdk_path = try allocator.dupe(u8, emsdk);

        // Try to find emcc in EMSDK
        const emcc_candidates = [_][]const u8{
            "upstream/emscripten/emcc",
            "fastcomp/emscripten/emcc",
            "emscripten/emcc",
        };

        for (emcc_candidates) |candidate| {
            const emcc_path = try std.fs.path.join(allocator, &.{ emsdk, candidate });
            defer allocator.free(emcc_path);

            if (std.fs.cwd().access(emcc_path, .{})) |_| {
                const dir = std.fs.path.dirname(emcc_path) orelse ".";
                const emxx_path = try std.fs.path.join(allocator, &.{ dir, "em++" });

                return .{
                    .emcc_path = try allocator.dupe(u8, emcc_path),
                    .emxx_path = emxx_path,
                    .emsdk_path = emsdk_path,
                };
            } else |_| {}
        }
    }

    // Check PATH
    const names = [_][]const u8{"emcc"};

    if (std.posix.getenv("PATH")) |path_env| {
        const sep = if (@import("builtin").os.tag == .windows) ';' else ':';
        var paths = std.mem.splitScalar(u8, path_env, sep);
        while (paths.next()) |dir| {
            for (names) |name| {
                const full_path = try std.fs.path.join(allocator, &.{ dir, name });
                defer allocator.free(full_path);

                if (std.fs.cwd().access(full_path, .{})) |_| {
                    const emxx_path = try std.fs.path.join(allocator, &.{ dir, "em++" });

                    return .{
                        .emcc_path = try allocator.dupe(u8, full_path),
                        .emxx_path = emxx_path,
                        .emsdk_path = emsdk_path,
                    };
                } else |_| {}
            }
        }
    }

    if (emsdk_path) |p| allocator.free(p);
    return error.CompilerNotFound;
}

/// Detect Emscripten version
fn detectVersion(allocator: Allocator, emcc_path: []const u8) !Emscripten.EmscriptenVersion {
    const result = try runProcess(allocator, &.{ emcc_path, "--version" }, null);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // Format: "emcc (Emscripten gcc/clang-like replacement + linker emulating GNU ld) 3.1.25 ..."
    if (std.mem.indexOf(u8, result.stdout, ") ")) |idx| {
        const version_start = idx + ") ".len;
        const version_end = std.mem.indexOfAnyPos(u8, result.stdout, version_start, " \n(") orelse result.stdout.len;
        const version_str = result.stdout[version_start..version_end];

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

    return .{ .major = 0, .minor = 0, .patch = 0 };
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

/// Parse Emscripten diagnostic output
fn parseEmscriptenDiagnostics(allocator: Allocator, stderr: []const u8) ![]Diagnostic {
    var diagnostics = std.ArrayList(Diagnostic).init(allocator);
    errdefer diagnostics.deinit();

    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        if (parseEmscriptenDiagnosticLine(allocator, line)) |diag| {
            try diagnostics.append(diag);
        } else |_| {}
    }

    return diagnostics.toOwnedSlice();
}

/// Parse single Emscripten diagnostic line (Clang-style)
fn parseEmscriptenDiagnosticLine(allocator: Allocator, line: []const u8) !Diagnostic {
    // Emscripten uses Clang format: file:line:col: level: message
    var parts = std.mem.splitScalar(u8, line, ':');

    const file = parts.next() orelse return error.InvalidFormat;
    const line_str = parts.next() orelse return error.InvalidFormat;
    const col_str = parts.next() orelse return error.InvalidFormat;
    const rest = parts.rest();

    const trimmed = std.mem.trim(u8, rest, " ");
    const level_end = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidFormat;
    const level_str = std.mem.trim(u8, trimmed[0..level_end], " ");
    const message = std.mem.trim(u8, trimmed[level_end + 1 ..], " ");

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

test "Emscripten version parsing" {
    const testing = std.testing;

    const v3125 = Emscripten.EmscriptenVersion{ .major = 3, .minor = 1, .patch = 25 };
    const v310 = Emscripten.EmscriptenVersion{ .major = 3, .minor = 1, .patch = 0 };
    const v200 = Emscripten.EmscriptenVersion{ .major = 2, .minor = 0, .patch = 0 };

    try testing.expect(v3125.supportsCpp20());
    try testing.expect(v3125.supportsCpp23());
    try testing.expect(v310.supportsCpp20());
    try testing.expect(!v310.supportsCpp23());
    try testing.expect(!v200.supportsCpp20());
}

test "WasmSettings.Environment" {
    const testing = std.testing;

    try testing.expectEqualStrings("web", Emscripten.WasmSettings.Environment.web.toFlag());
    try testing.expectEqualStrings("node", Emscripten.WasmSettings.Environment.node.toFlag());
}
