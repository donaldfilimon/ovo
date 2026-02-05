//! Compiler Interface - Abstract trait for C/C++ compiler backends
//!
//! This module defines the core compiler abstraction that all backend
//! implementations must conform to. Supports C99-C23 and C++11-C++26 standards.

const std = @import("std");
const Allocator = std.mem.Allocator;
const modules = @import("modules.zig");

/// C language standard versions
pub const CStandard = enum {
    c89,
    c99,
    c11,
    c17,
    c23,

    pub fn toFlag(self: CStandard) []const u8 {
        return switch (self) {
            .c89 => "-std=c89",
            .c99 => "-std=c99",
            .c11 => "-std=c11",
            .c17 => "-std=c17",
            .c23 => "-std=c23",
        };
    }

    pub fn toMsvcFlag(self: CStandard) []const u8 {
        return switch (self) {
            .c89, .c99, .c11 => "/std:c11",
            .c17 => "/std:c17",
            .c23 => "/std:clatest",
        };
    }
};

/// C++ language standard versions
pub const CppStandard = enum {
    cpp11,
    cpp14,
    cpp17,
    cpp20,
    cpp23,
    cpp26,

    pub fn toFlag(self: CppStandard) []const u8 {
        return switch (self) {
            .cpp11 => "-std=c++11",
            .cpp14 => "-std=c++14",
            .cpp17 => "-std=c++17",
            .cpp20 => "-std=c++20",
            .cpp23 => "-std=c++23",
            .cpp26 => "-std=c++26",
        };
    }

    pub fn toMsvcFlag(self: CppStandard) []const u8 {
        return switch (self) {
            .cpp11, .cpp14 => "/std:c++14",
            .cpp17 => "/std:c++17",
            .cpp20 => "/std:c++20",
            .cpp23 => "/std:c++latest",
            .cpp26 => "/std:c++latest",
        };
    }

    pub fn supportsModules(self: CppStandard) bool {
        return switch (self) {
            .cpp20, .cpp23, .cpp26 => true,
            else => false,
        };
    }
};

/// Language being compiled
pub const Language = enum {
    c,
    cpp,
    objc,
    objcpp,
    asm_,

    pub fn fromExtension(ext: []const u8) ?Language {
        const map = std.StaticStringMap(Language).initComptime(.{
            .{ ".c", .c },
            .{ ".h", .c },
            .{ ".cpp", .cpp },
            .{ ".cxx", .cpp },
            .{ ".cc", .cpp },
            .{ ".C", .cpp },
            .{ ".hpp", .cpp },
            .{ ".hxx", .cpp },
            .{ ".hh", .cpp },
            .{ ".H", .cpp },
            .{ ".cppm", .cpp }, // C++ module interface
            .{ ".ixx", .cpp }, // MSVC module interface
            .{ ".mpp", .cpp }, // Module partition
            .{ ".m", .objc },
            .{ ".mm", .objcpp },
            .{ ".s", .asm_ },
            .{ ".S", .asm_ },
            .{ ".asm", .asm_ },
        });
        return map.get(ext);
    }

    pub fn isModuleInterface(path: []const u8) bool {
        const ext = std.fs.path.extension(path);
        return std.mem.eql(u8, ext, ".cppm") or
            std.mem.eql(u8, ext, ".ixx") or
            std.mem.eql(u8, ext, ".mpp");
    }
};

/// Optimization level
pub const OptLevel = enum {
    none, // -O0
    debug, // -Og
    size, // -Os
    size_aggressive, // -Oz
    speed, // -O2
    aggressive, // -O3
    fast_math, // -Ofast (GCC/Clang)

    pub fn toFlag(self: OptLevel) []const u8 {
        return switch (self) {
            .none => "-O0",
            .debug => "-Og",
            .size => "-Os",
            .size_aggressive => "-Oz",
            .speed => "-O2",
            .aggressive => "-O3",
            .fast_math => "-Ofast",
        };
    }

    pub fn toMsvcFlag(self: OptLevel) []const u8 {
        return switch (self) {
            .none, .debug => "/Od",
            .size, .size_aggressive => "/O1",
            .speed, .aggressive, .fast_math => "/O2",
        };
    }
};

/// Target architecture for cross-compilation
pub const Architecture = enum {
    x86,
    x86_64,
    arm,
    aarch64,
    riscv32,
    riscv64,
    wasm32,
    wasm64,
    mips,
    mips64,
    powerpc,
    powerpc64,
    native,

    pub fn toTripleArch(self: Architecture) []const u8 {
        return switch (self) {
            .x86 => "i686",
            .x86_64 => "x86_64",
            .arm => "arm",
            .aarch64 => "aarch64",
            .riscv32 => "riscv32",
            .riscv64 => "riscv64",
            .wasm32 => "wasm32",
            .wasm64 => "wasm64",
            .mips => "mips",
            .mips64 => "mips64",
            .powerpc => "powerpc",
            .powerpc64 => "powerpc64",
            .native => "native",
        };
    }
};

/// Target operating system
pub const OperatingSystem = enum {
    linux,
    windows,
    macos,
    freebsd,
    netbsd,
    openbsd,
    ios,
    android,
    wasi,
    freestanding,
    native,

    pub fn toTripleOs(self: OperatingSystem) []const u8 {
        return switch (self) {
            .linux => "linux",
            .windows => "windows",
            .macos => "darwin",
            .freebsd => "freebsd",
            .netbsd => "netbsd",
            .openbsd => "openbsd",
            .ios => "ios",
            .android => "android",
            .wasi => "wasi",
            .freestanding => "unknown",
            .native => "native",
        };
    }
};

/// Cross-compilation target specification
pub const Target = struct {
    arch: Architecture = .native,
    os: OperatingSystem = .native,
    abi: ?[]const u8 = null,
    cpu: ?[]const u8 = null,
    features: ?[]const u8 = null,

    pub fn toTriple(self: Target, allocator: Allocator) ![]const u8 {
        const arch_str = self.arch.toTripleArch();
        const os_str = self.os.toTripleOs();
        const abi_str = self.abi orelse "gnu";

        return std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{
            arch_str,
            os_str,
            abi_str,
        });
    }

    pub fn isNative(self: Target) bool {
        return self.arch == .native and self.os == .native;
    }

    pub fn isWasm(self: Target) bool {
        return self.arch == .wasm32 or self.arch == .wasm64;
    }
};

/// Output type from compilation
pub const OutputKind = enum {
    object, // .o / .obj
    static_lib, // .a / .lib
    shared_lib, // .so / .dll / .dylib
    executable,
    assembly, // .s
    preprocessed, // -E
    llvm_ir, // -emit-llvm
    bitcode, // .bc
    module_interface, // BMI/CMI (C++20 modules)
};

/// Diagnostic severity levels
pub const DiagnosticLevel = enum {
    note,
    warning,
    error_,
    fatal,
};

/// Compiler diagnostic message
pub const Diagnostic = struct {
    level: DiagnosticLevel,
    file: ?[]const u8,
    line: ?u32,
    column: ?u32,
    message: []const u8,
    code: ?[]const u8 = null, // e.g., -Wunused-variable

    pub fn format(self: Diagnostic, allocator: Allocator) ![]const u8 {
        var parts = std.ArrayList(u8).init(allocator);
        const writer = parts.writer();

        if (self.file) |f| {
            try writer.print("{s}", .{f});
            if (self.line) |l| {
                try writer.print(":{d}", .{l});
                if (self.column) |c| {
                    try writer.print(":{d}", .{c});
                }
            }
            try writer.writeAll(": ");
        }

        const level_str = switch (self.level) {
            .note => "note",
            .warning => "warning",
            .error_ => "error",
            .fatal => "fatal error",
        };
        try writer.print("{s}: {s}", .{ level_str, self.message });

        if (self.code) |c| {
            try writer.print(" [{s}]", .{c});
        }

        return parts.toOwnedSlice();
    }
};

/// Compilation result
pub const CompileResult = struct {
    success: bool,
    output_path: ?[]const u8,
    diagnostics: []Diagnostic,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
    duration_ns: u64,

    pub fn deinit(self: *CompileResult, allocator: Allocator) void {
        if (self.output_path) |p| allocator.free(p);
        for (self.diagnostics) |*d| {
            if (d.file) |f| allocator.free(f);
            allocator.free(d.message);
            if (d.code) |c| allocator.free(c);
        }
        allocator.free(self.diagnostics);
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Link result
pub const LinkResult = struct {
    success: bool,
    output_path: ?[]const u8,
    diagnostics: []Diagnostic,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
    duration_ns: u64,

    pub fn deinit(self: *LinkResult, allocator: Allocator) void {
        if (self.output_path) |p| allocator.free(p);
        for (self.diagnostics) |*d| {
            if (d.file) |f| allocator.free(f);
            allocator.free(d.message);
            if (d.code) |c| allocator.free(c);
        }
        allocator.free(self.diagnostics);
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Module dependency scan result
pub const ModuleDepsResult = struct {
    success: bool,
    dependencies: []modules.ModuleDependency,
    provides: ?[]const u8, // Module name this file provides
    is_interface: bool,
    stdout: []const u8,
    stderr: []const u8,

    pub fn deinit(self: *ModuleDepsResult, allocator: Allocator) void {
        for (self.dependencies) |*d| {
            allocator.free(d.name);
            if (d.source_path) |p| allocator.free(p);
        }
        allocator.free(self.dependencies);
        if (self.provides) |p| allocator.free(p);
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Compilation options
pub const CompileOptions = struct {
    /// Source files to compile
    sources: []const []const u8,
    /// Output file path (optional, auto-generated if null)
    output: ?[]const u8 = null,
    /// Output kind
    output_kind: OutputKind = .object,
    /// C standard (for C files)
    c_standard: CStandard = .c17,
    /// C++ standard (for C++ files)
    cpp_standard: CppStandard = .cpp20,
    /// Optimization level
    optimization: OptLevel = .none,
    /// Include directories
    include_dirs: []const []const u8 = &.{},
    /// System include directories
    system_include_dirs: []const []const u8 = &.{},
    /// Preprocessor definitions
    defines: []const []const u8 = &.{},
    /// Warning flags
    warnings: []const []const u8 = &.{},
    /// Additional compiler flags
    extra_flags: []const []const u8 = &.{},
    /// Target for cross-compilation
    target: Target = .{},
    /// Enable debug info
    debug_info: bool = true,
    /// Position independent code
    pic: bool = false,
    /// Enable link-time optimization
    lto: bool = false,
    /// Enable C++ modules
    enable_modules: bool = true,
    /// Module cache directory
    module_cache_dir: ?[]const u8 = null,
    /// Precompiled module paths (BMI/CMI files)
    prebuilt_modules: []const []const u8 = &.{},
    /// Thread sanitizer
    sanitize_thread: bool = false,
    /// Address sanitizer
    sanitize_address: bool = false,
    /// Undefined behavior sanitizer
    sanitize_undefined: bool = false,
    /// Treat warnings as errors
    warnings_as_errors: bool = false,
    /// Verbose output
    verbose: bool = false,
    /// Working directory
    cwd: ?[]const u8 = null,
    /// Environment variables
    env: ?std.process.EnvMap = null,
};

/// Link options
pub const LinkOptions = struct {
    /// Object files to link
    objects: []const []const u8,
    /// Output file path
    output: []const u8,
    /// Output kind
    output_kind: OutputKind = .executable,
    /// Library directories
    library_dirs: []const []const u8 = &.{},
    /// Libraries to link
    libraries: []const []const u8 = &.{},
    /// Framework directories (macOS)
    framework_dirs: []const []const u8 = &.{},
    /// Frameworks to link (macOS)
    frameworks: []const []const u8 = &.{},
    /// Linker script
    linker_script: ?[]const u8 = null,
    /// Additional linker flags
    extra_flags: []const []const u8 = &.{},
    /// Target for cross-compilation
    target: Target = .{},
    /// Enable link-time optimization
    lto: bool = false,
    /// Strip symbols
    strip: bool = false,
    /// Export dynamic symbols
    export_dynamic: bool = false,
    /// Allow undefined symbols
    allow_undefined: bool = false,
    /// Runtime library path
    rpath: ?[]const u8 = null,
    /// Verbose output
    verbose: bool = false,
    /// Working directory
    cwd: ?[]const u8 = null,
};

/// Compiler capability flags
pub const Capabilities = struct {
    /// Supports C++ modules
    cpp_modules: bool = false,
    /// Supports header units
    header_units: bool = false,
    /// Supports module dependency scanning
    module_dep_scan: bool = false,
    /// Supports link-time optimization
    lto: bool = false,
    /// Supports profile-guided optimization
    pgo: bool = false,
    /// Supports sanitizers
    sanitizers: bool = false,
    /// Supports cross-compilation
    cross_compile: bool = false,
    /// Maximum supported C standard
    max_c_standard: CStandard = .c17,
    /// Maximum supported C++ standard
    max_cpp_standard: CppStandard = .cpp20,
    /// Compiler version string
    version: []const u8 = "unknown",
    /// Compiler vendor
    vendor: []const u8 = "unknown",
};

/// Compiler backend identifier
pub const CompilerKind = enum {
    zig_cc, // Zig's bundled Clang (default)
    clang, // System Clang
    gcc, // GCC
    msvc, // Microsoft Visual C++
    emscripten, // Emscripten for WebAssembly
    custom, // Custom compiler

    pub fn name(self: CompilerKind) []const u8 {
        return switch (self) {
            .zig_cc => "zig cc",
            .clang => "clang",
            .gcc => "gcc",
            .msvc => "cl.exe",
            .emscripten => "emcc",
            .custom => "custom",
        };
    }
};

/// The compiler interface - all compiler backends implement this
pub const Compiler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Compile source files to object/output
        compile: *const fn (ptr: *anyopaque, allocator: Allocator, options: CompileOptions) anyerror!CompileResult,
        /// Link object files
        link: *const fn (ptr: *anyopaque, allocator: Allocator, options: LinkOptions) anyerror!LinkResult,
        /// Scan module dependencies from source file
        scanModuleDeps: *const fn (ptr: *anyopaque, allocator: Allocator, source_path: []const u8, options: CompileOptions) anyerror!ModuleDepsResult,
        /// Compile module interface unit (generates BMI)
        compileModuleInterface: *const fn (ptr: *anyopaque, allocator: Allocator, source_path: []const u8, output_bmi: []const u8, options: CompileOptions) anyerror!CompileResult,
        /// Get compiler capabilities
        getCapabilities: *const fn (ptr: *anyopaque) Capabilities,
        /// Get compiler kind
        getKind: *const fn (ptr: *anyopaque) CompilerKind,
        /// Get compiler executable path
        getPath: *const fn (ptr: *anyopaque) []const u8,
        /// Verify compiler is available and working
        verify: *const fn (ptr: *anyopaque, allocator: Allocator) anyerror!bool,
        /// Clean up resources
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// Compile source files
    pub fn compile(self: Compiler, allocator: Allocator, options: CompileOptions) !CompileResult {
        return self.vtable.compile(self.ptr, allocator, options);
    }

    /// Link object files
    pub fn link(self: Compiler, allocator: Allocator, options: LinkOptions) !LinkResult {
        return self.vtable.link(self.ptr, allocator, options);
    }

    /// Scan module dependencies from a source file
    pub fn scanModuleDeps(self: Compiler, allocator: Allocator, source_path: []const u8, options: CompileOptions) !ModuleDepsResult {
        return self.vtable.scanModuleDeps(self.ptr, allocator, source_path, options);
    }

    /// Compile a module interface unit, generating a Binary Module Interface (BMI)
    pub fn compileModuleInterface(self: Compiler, allocator: Allocator, source_path: []const u8, output_bmi: []const u8, options: CompileOptions) !CompileResult {
        return self.vtable.compileModuleInterface(self.ptr, allocator, source_path, output_bmi, options);
    }

    /// Get compiler capabilities
    pub fn getCapabilities(self: Compiler) Capabilities {
        return self.vtable.getCapabilities(self.ptr);
    }

    /// Get compiler kind
    pub fn getKind(self: Compiler) CompilerKind {
        return self.vtable.getKind(self.ptr);
    }

    /// Get compiler executable path
    pub fn getPath(self: Compiler) []const u8 {
        return self.vtable.getPath(self.ptr);
    }

    /// Verify compiler availability
    pub fn verify(self: Compiler, allocator: Allocator) !bool {
        return self.vtable.verify(self.ptr, allocator);
    }

    /// Deinitialize compiler resources
    pub fn deinit(self: Compiler) void {
        return self.vtable.deinit(self.ptr);
    }
};

/// Helper to create a Compiler interface from an implementation
pub fn compilerInterface(comptime T: type) Compiler.VTable {
    return .{
        .compile = struct {
            fn call(ptr: *anyopaque, allocator: Allocator, options: CompileOptions) anyerror!CompileResult {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.compile(allocator, options);
            }
        }.call,
        .link = struct {
            fn call(ptr: *anyopaque, allocator: Allocator, options: LinkOptions) anyerror!LinkResult {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.link(allocator, options);
            }
        }.call,
        .scanModuleDeps = struct {
            fn call(ptr: *anyopaque, allocator: Allocator, source_path: []const u8, options: CompileOptions) anyerror!ModuleDepsResult {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.scanModuleDeps(allocator, source_path, options);
            }
        }.call,
        .compileModuleInterface = struct {
            fn call(ptr: *anyopaque, allocator: Allocator, source_path: []const u8, output_bmi: []const u8, options: CompileOptions) anyerror!CompileResult {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.compileModuleInterface(allocator, source_path, output_bmi, options);
            }
        }.call,
        .getCapabilities = struct {
            fn call(ptr: *anyopaque) Capabilities {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.getCapabilities();
            }
        }.call,
        .getKind = struct {
            fn call(ptr: *anyopaque) CompilerKind {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.getKind();
            }
        }.call,
        .getPath = struct {
            fn call(ptr: *anyopaque) []const u8 {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.getPath();
            }
        }.call,
        .verify = struct {
            fn call(ptr: *anyopaque, allocator: Allocator) anyerror!bool {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.verify(allocator);
            }
        }.call,
        .deinit = struct {
            fn call(ptr: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(ptr));
                self.deinit();
            }
        }.call,
    };
}

test "Language.fromExtension" {
    const testing = std.testing;

    try testing.expectEqual(Language.c, Language.fromExtension(".c").?);
    try testing.expectEqual(Language.cpp, Language.fromExtension(".cpp").?);
    try testing.expectEqual(Language.cpp, Language.fromExtension(".cppm").?);
    try testing.expect(Language.fromExtension(".unknown") == null);
}

test "Language.isModuleInterface" {
    const testing = std.testing;

    try testing.expect(Language.isModuleInterface("foo.cppm"));
    try testing.expect(Language.isModuleInterface("bar.ixx"));
    try testing.expect(Language.isModuleInterface("baz.mpp"));
    try testing.expect(!Language.isModuleInterface("regular.cpp"));
}

test "Target.toTriple" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const target = Target{
        .arch = .x86_64,
        .os = .linux,
        .abi = "gnu",
    };

    const triple = try target.toTriple(allocator);
    defer allocator.free(triple);

    try testing.expectEqualStrings("x86_64-linux-gnu", triple);
}
