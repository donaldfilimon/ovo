//! Ovo Compiler Abstraction Layer
//!
//! Provides a unified interface for C/C++ compilation across multiple
//! compiler backends (Zig CC, Clang, GCC, MSVC, Emscripten).
//!
//! Features:
//! - Support for C99-C23 and C++11-C++26 standards
//! - Seamless C++20/23/26 modules support with BMI management
//! - Cross-compilation support
//! - Automatic compiler detection and selection
//! - Compiler-specific flag translation
//!
//! Example usage:
//! ```zig
//! const compiler = @import("compiler");
//!
//! // Get default compiler (Zig CC)
//! var cc = try compiler.getDefaultCompiler(allocator);
//! defer cc.deinit();
//!
//! // Compile a file
//! const result = try cc.compile(allocator, .{
//!     .sources = &.{"main.cpp"},
//!     .output = "main.o",
//!     .cpp_standard = .cpp20,
//!     .optimization = .speed,
//! });
//!
//! // Or auto-select best compiler for requirements
//! var cc2 = try compiler.detection.autoSelectCompiler(allocator, .{
//!     .cpp_standard = .cpp23,
//!     .needs_modules = true,
//! });
//! ```

const std = @import("std");

// Re-export all submodules
pub const interface = @import("interface.zig");
pub const modules = @import("modules.zig");
pub const zig_cc = @import("zig_cc.zig");
pub const clang = @import("clang.zig");
pub const gcc = @import("gcc.zig");
pub const msvc = @import("msvc.zig");
pub const emscripten = @import("emscripten.zig");
pub const detection = @import("detection.zig");

// Re-export commonly used types from interface
pub const Compiler = interface.Compiler;
pub const CompilerKind = interface.CompilerKind;
pub const CompileOptions = interface.CompileOptions;
pub const CompileResult = interface.CompileResult;
pub const LinkOptions = interface.LinkOptions;
pub const LinkResult = interface.LinkResult;
pub const ModuleDepsResult = interface.ModuleDepsResult;
pub const Capabilities = interface.Capabilities;
pub const CStandard = interface.CStandard;
pub const CppStandard = interface.CppStandard;
pub const Language = interface.Language;
pub const OptLevel = interface.OptLevel;
pub const OutputKind = interface.OutputKind;
pub const Target = interface.Target;
pub const Architecture = interface.Architecture;
pub const OperatingSystem = interface.OperatingSystem;
pub const Diagnostic = interface.Diagnostic;
pub const DiagnosticLevel = interface.DiagnosticLevel;

// Module types
pub const ModuleGraph = modules.ModuleGraph;
pub const ModuleUnit = modules.ModuleUnit;
pub const ModuleDependency = modules.ModuleDependency;
pub const DependencyKind = modules.DependencyKind;
pub const BmiCache = modules.BmiCache;

// Compiler implementations
pub const ZigCC = zig_cc.ZigCC;
pub const Clang = clang.Clang;
pub const GCC = gcc.GCC;
pub const MSVC = msvc.MSVC;
pub const Emscripten = emscripten.Emscripten;

// Detection
pub const CompilerDetector = detection.CompilerDetector;
pub const CompilerRequirements = detection.CompilerRequirements;
pub const DetectedCompiler = detection.DetectedCompiler;

/// Get the default compiler (Zig CC - zero configuration)
pub fn getDefaultCompiler(allocator: std.mem.Allocator) !Compiler {
    return detection.getDefaultCompiler(allocator);
}

/// Auto-select the best compiler for given requirements
pub fn autoSelect(allocator: std.mem.Allocator, requirements: CompilerRequirements) !Compiler {
    return detection.autoSelectCompiler(allocator, requirements);
}

/// Create a compiler instance by kind
pub fn createCompiler(allocator: std.mem.Allocator, kind: CompilerKind) !Compiler {
    return switch (kind) {
        .zig_cc => blk: {
            const cc = try ZigCC.init(allocator);
            break :blk cc.compiler();
        },
        .clang => blk: {
            const cc = try Clang.init(allocator);
            break :blk cc.compiler();
        },
        .gcc => blk: {
            const cc = try GCC.init(allocator);
            break :blk cc.compiler();
        },
        .msvc => blk: {
            const cc = try MSVC.init(allocator);
            break :blk cc.compiler();
        },
        .emscripten => blk: {
            const cc = try Emscripten.init(allocator);
            break :blk cc.compiler();
        },
        .custom => return error.UnsupportedCompiler,
    };
}

/// Compile and link in one step (convenience function)
pub fn build(
    allocator: std.mem.Allocator,
    compiler_: Compiler,
    sources: []const []const u8,
    output: []const u8,
    options: struct {
        cpp_standard: CppStandard = .cpp20,
        c_standard: CStandard = .c17,
        optimization: OptLevel = .none,
        include_dirs: []const []const u8 = &.{},
        library_dirs: []const []const u8 = &.{},
        libraries: []const []const u8 = &.{},
        defines: []const []const u8 = &.{},
        debug_info: bool = true,
    },
) !CompileResult {
    // Compile sources
    const compile_result = try compiler_.compile(allocator, .{
        .sources = sources,
        .cpp_standard = options.cpp_standard,
        .c_standard = options.c_standard,
        .optimization = options.optimization,
        .include_dirs = options.include_dirs,
        .defines = options.defines,
        .debug_info = options.debug_info,
    });

    if (!compile_result.success) {
        return compile_result;
    }

    // If we got an object file, link it
    if (compile_result.output_path) |obj_path| {
        var link_result = try compiler_.link(allocator, .{
            .objects = &.{obj_path},
            .output = output,
            .library_dirs = options.library_dirs,
            .libraries = options.libraries,
        });

        // Merge results
        return .{
            .success = link_result.success,
            .output_path = if (link_result.success) try allocator.dupe(u8, output) else null,
            .diagnostics = compile_result.diagnostics,
            .stdout = compile_result.stdout,
            .stderr = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{
                compile_result.stderr,
                link_result.stderr,
            }),
            .exit_code = link_result.exit_code,
            .duration_ns = compile_result.duration_ns + link_result.duration_ns,
        };
    }

    return compile_result;
}

/// Build with C++ modules support
pub fn buildWithModules(
    allocator: std.mem.Allocator,
    compiler_: Compiler,
    sources: []const []const u8,
    output: []const u8,
    module_cache_dir: []const u8,
) !CompileResult {
    var graph = ModuleGraph.init(allocator, module_cache_dir);
    defer graph.deinit();

    // Scan all sources for module dependencies
    for (sources) |src| {
        const scan_result = try compiler_.scanModuleDeps(allocator, src, .{
            .sources = &.{src},
        });
        defer {
            for (scan_result.dependencies) |*d| {
                allocator.free(d.name);
                if (d.source_path) |p| allocator.free(p);
            }
            allocator.free(scan_result.dependencies);
            if (scan_result.provides) |p| allocator.free(p);
            allocator.free(scan_result.stdout);
            allocator.free(scan_result.stderr);
        }

        _ = try graph.addUnit(.{
            .source_path = try allocator.dupe(u8, src),
            .provides = if (scan_result.provides) |p| try allocator.dupe(u8, p) else null,
            .is_interface = scan_result.is_interface,
            .is_partition = false,
            .dependencies = try allocator.dupe(modules.ModuleDependency, scan_result.dependencies),
        });
    }

    // Build dependency graph
    try graph.buildGraph();

    // Get compilation order
    const order = try graph.topologicalSort();
    defer allocator.free(order);

    // Compile in order
    var objects = std.ArrayList([]const u8).init(allocator);
    defer {
        for (objects.items) |o| allocator.free(o);
        objects.deinit();
    }

    var prebuilt_modules = std.ArrayList([]const u8).init(allocator);
    defer prebuilt_modules.deinit();

    for (order) |unit| {
        if (unit.is_interface) {
            // Compile module interface first
            const bmi_path = try graph.getBmiPath(unit.provides orelse "unknown");
            const ifc_result = try compiler_.compileModuleInterface(
                allocator,
                unit.source_path,
                bmi_path,
                .{
                    .sources = &.{unit.source_path},
                    .prebuilt_modules = prebuilt_modules.items,
                    .module_cache_dir = module_cache_dir,
                },
            );

            if (!ifc_result.success) {
                return ifc_result;
            }

            try prebuilt_modules.append(bmi_path);
        }

        // Compile to object
        const obj_path = try std.fmt.allocPrint(allocator, "{s}.o", .{
            std.fs.path.stem(unit.source_path),
        });

        const compile_result = try compiler_.compile(allocator, .{
            .sources = &.{unit.source_path},
            .output = obj_path,
            .prebuilt_modules = prebuilt_modules.items,
            .module_cache_dir = module_cache_dir,
        });

        if (!compile_result.success) {
            return compile_result;
        }

        try objects.append(obj_path);
    }

    // Link all objects
    const link_result = try compiler_.link(allocator, .{
        .objects = objects.items,
        .output = output,
    });

    return .{
        .success = link_result.success,
        .output_path = if (link_result.success) try allocator.dupe(u8, output) else null,
        .diagnostics = link_result.diagnostics,
        .stdout = link_result.stdout,
        .stderr = link_result.stderr,
        .exit_code = link_result.exit_code,
        .duration_ns = link_result.duration_ns,
    };
}

test {
    // Reference all submodules for testing
    std.testing.refAllDecls(@This());
}

test "compiler module imports" {
    // Verify all submodules can be imported
    _ = interface;
    _ = modules;
    _ = zig_cc;
    _ = clang;
    _ = gcc;
    _ = msvc;
    _ = emscripten;
    _ = detection;
}

test "CppStandard.supportsModules" {
    const testing = std.testing;

    try testing.expect(CppStandard.cpp20.supportsModules());
    try testing.expect(CppStandard.cpp23.supportsModules());
    try testing.expect(CppStandard.cpp26.supportsModules());
    try testing.expect(!CppStandard.cpp17.supportsModules());
    try testing.expect(!CppStandard.cpp14.supportsModules());
}

test "Language detection" {
    const testing = std.testing;

    try testing.expectEqual(Language.c, Language.fromExtension(".c").?);
    try testing.expectEqual(Language.cpp, Language.fromExtension(".cpp").?);
    try testing.expectEqual(Language.cpp, Language.fromExtension(".cppm").?);
    try testing.expect(Language.isModuleInterface("foo.cppm"));
    try testing.expect(Language.isModuleInterface("bar.ixx"));
    try testing.expect(!Language.isModuleInterface("baz.cpp"));
}
