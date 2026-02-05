//! Compiler Detection and Selection
//!
//! Auto-detects available compilers on the system and selects the best
//! compiler based on requirements (language standard, modules support,
//! cross-compilation, etc.)

const std = @import("std");
const Allocator = std.mem.Allocator;
const interface = @import("interface.zig");
const zig_cc = @import("zig_cc.zig");
const clang = @import("clang.zig");
const gcc = @import("gcc.zig");
const msvc = @import("msvc.zig");
const emscripten = @import("emscripten.zig");

const Compiler = interface.Compiler;
const CompilerKind = interface.CompilerKind;
const Capabilities = interface.Capabilities;
const CStandard = interface.CStandard;
const CppStandard = interface.CppStandard;
const Target = interface.Target;

/// Compiler detection result
pub const DetectedCompiler = struct {
    kind: CompilerKind,
    path: []const u8,
    capabilities: Capabilities,
    priority: u32,

    pub fn deinit(self: *DetectedCompiler, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.capabilities.version);
    }
};

/// Requirements for compiler selection
pub const CompilerRequirements = struct {
    /// Minimum C standard required
    c_standard: ?CStandard = null,
    /// Minimum C++ standard required
    cpp_standard: ?CppStandard = null,
    /// Need C++ modules support
    needs_modules: bool = false,
    /// Need cross-compilation support
    needs_cross_compile: bool = false,
    /// Specific target platform
    target: ?Target = null,
    /// Need LTO support
    needs_lto: bool = false,
    /// Need sanitizer support
    needs_sanitizers: bool = false,
    /// Prefer specific compiler
    preferred: ?CompilerKind = null,
    /// Exclude these compilers
    exclude: []const CompilerKind = &.{},
};

/// Compiler detector and selector
pub const CompilerDetector = struct {
    allocator: Allocator,
    /// All detected compilers
    detected: std.ArrayList(DetectedCompiler),
    /// Cached compiler instances
    cached_compilers: std.AutoHashMap(CompilerKind, Compiler),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .detected = std.ArrayList(DetectedCompiler).init(allocator),
            .cached_compilers = std.AutoHashMap(CompilerKind, Compiler).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Free cached compilers
        var it = self.cached_compilers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.cached_compilers.deinit();

        // Free detected compiler info
        for (self.detected.items) |*d| {
            d.deinit(self.allocator);
        }
        self.detected.deinit();
    }

    /// Detect all available compilers
    pub fn detectAll(self: *Self) !void {
        self.detected.clearRetainingCapacity();

        // Try each compiler type in order of preference

        // 1. Zig CC (always available if ovo is installed)
        if (self.tryDetectZigCC()) |detected| {
            try self.detected.append(detected);
        }

        // 2. System Clang (best C++ modules support)
        if (self.tryDetectClang()) |detected| {
            try self.detected.append(detected);
        }

        // 3. GCC (widely available)
        if (self.tryDetectGCC()) |detected| {
            try self.detected.append(detected);
        }

        // 4. MSVC (Windows only)
        if (@import("builtin").os.tag == .windows) {
            if (self.tryDetectMSVC()) |detected| {
                try self.detected.append(detected);
            }
        }

        // 5. Emscripten (for WebAssembly)
        if (self.tryDetectEmscripten()) |detected| {
            try self.detected.append(detected);
        }

        // Sort by priority
        std.mem.sort(DetectedCompiler, self.detected.items, {}, struct {
            fn lessThan(_: void, a: DetectedCompiler, b: DetectedCompiler) bool {
                return a.priority > b.priority;
            }
        }.lessThan);
    }

    fn tryDetectZigCC(self: *Self) ?DetectedCompiler {
        const cc = zig_cc.ZigCC.init(self.allocator) catch return null;
        defer cc.deinit();

        if (!(cc.verify(self.allocator) catch false)) {
            return null;
        }

        const caps = cc.getCapabilities();
        return .{
            .kind = .zig_cc,
            .path = self.allocator.dupe(u8, cc.getPath()) catch return null,
            .capabilities = .{
                .cpp_modules = caps.cpp_modules,
                .header_units = caps.header_units,
                .module_dep_scan = caps.module_dep_scan,
                .lto = caps.lto,
                .pgo = caps.pgo,
                .sanitizers = caps.sanitizers,
                .cross_compile = caps.cross_compile,
                .max_c_standard = caps.max_c_standard,
                .max_cpp_standard = caps.max_cpp_standard,
                .version = self.allocator.dupe(u8, caps.version) catch return null,
                .vendor = caps.vendor,
            },
            .priority = 100, // High priority - zero config
        };
    }

    fn tryDetectClang(self: *Self) ?DetectedCompiler {
        const cc = clang.Clang.init(self.allocator) catch return null;
        defer cc.deinit();

        if (!(cc.verify(self.allocator) catch false)) {
            return null;
        }

        const caps = cc.getCapabilities();
        const priority: u32 = if (caps.cpp_modules) 95 else 80;

        return .{
            .kind = .clang,
            .path = self.allocator.dupe(u8, cc.getPath()) catch return null,
            .capabilities = .{
                .cpp_modules = caps.cpp_modules,
                .header_units = caps.header_units,
                .module_dep_scan = caps.module_dep_scan,
                .lto = caps.lto,
                .pgo = caps.pgo,
                .sanitizers = caps.sanitizers,
                .cross_compile = caps.cross_compile,
                .max_c_standard = caps.max_c_standard,
                .max_cpp_standard = caps.max_cpp_standard,
                .version = self.allocator.dupe(u8, caps.version) catch return null,
                .vendor = caps.vendor,
            },
            .priority = priority,
        };
    }

    fn tryDetectGCC(self: *Self) ?DetectedCompiler {
        const cc = gcc.GCC.init(self.allocator) catch return null;
        defer cc.deinit();

        if (!(cc.verify(self.allocator) catch false)) {
            return null;
        }

        const caps = cc.getCapabilities();
        const priority: u32 = if (caps.cpp_modules) 85 else 75;

        return .{
            .kind = .gcc,
            .path = self.allocator.dupe(u8, cc.getPath()) catch return null,
            .capabilities = .{
                .cpp_modules = caps.cpp_modules,
                .header_units = caps.header_units,
                .module_dep_scan = caps.module_dep_scan,
                .lto = caps.lto,
                .pgo = caps.pgo,
                .sanitizers = caps.sanitizers,
                .cross_compile = caps.cross_compile,
                .max_c_standard = caps.max_c_standard,
                .max_cpp_standard = caps.max_cpp_standard,
                .version = self.allocator.dupe(u8, caps.version) catch return null,
                .vendor = caps.vendor,
            },
            .priority = priority,
        };
    }

    fn tryDetectMSVC(self: *Self) ?DetectedCompiler {
        const cc = msvc.MSVC.init(self.allocator) catch return null;
        defer cc.deinit();

        if (!(cc.verify(self.allocator) catch false)) {
            return null;
        }

        const caps = cc.getCapabilities();
        const priority: u32 = if (caps.cpp_modules) 90 else 70;

        return .{
            .kind = .msvc,
            .path = self.allocator.dupe(u8, cc.getPath()) catch return null,
            .capabilities = .{
                .cpp_modules = caps.cpp_modules,
                .header_units = caps.header_units,
                .module_dep_scan = caps.module_dep_scan,
                .lto = caps.lto,
                .pgo = caps.pgo,
                .sanitizers = caps.sanitizers,
                .cross_compile = caps.cross_compile,
                .max_c_standard = caps.max_c_standard,
                .max_cpp_standard = caps.max_cpp_standard,
                .version = self.allocator.dupe(u8, caps.version) catch return null,
                .vendor = caps.vendor,
            },
            .priority = priority,
        };
    }

    fn tryDetectEmscripten(self: *Self) ?DetectedCompiler {
        const cc = emscripten.Emscripten.init(self.allocator) catch return null;
        defer cc.deinit();

        if (!(cc.verify(self.allocator) catch false)) {
            return null;
        }

        const caps = cc.getCapabilities();

        return .{
            .kind = .emscripten,
            .path = self.allocator.dupe(u8, cc.getPath()) catch return null,
            .capabilities = .{
                .cpp_modules = caps.cpp_modules,
                .header_units = caps.header_units,
                .module_dep_scan = caps.module_dep_scan,
                .lto = caps.lto,
                .pgo = caps.pgo,
                .sanitizers = caps.sanitizers,
                .cross_compile = caps.cross_compile,
                .max_c_standard = caps.max_c_standard,
                .max_cpp_standard = caps.max_cpp_standard,
                .version = self.allocator.dupe(u8, caps.version) catch return null,
                .vendor = caps.vendor,
            },
            .priority = 60, // Lower priority - specialized for WASM
        };
    }

    /// Select best compiler for given requirements
    pub fn select(self: *Self, requirements: CompilerRequirements) !?*const DetectedCompiler {
        if (self.detected.items.len == 0) {
            try self.detectAll();
        }

        var best: ?*const DetectedCompiler = null;
        var best_score: i32 = -1;

        for (self.detected.items) |*detected| {
            // Check exclusions
            var excluded = false;
            for (requirements.exclude) |ex| {
                if (detected.kind == ex) {
                    excluded = true;
                    break;
                }
            }
            if (excluded) continue;

            // Check hard requirements
            if (!meetsRequirements(detected.*, requirements)) continue;

            // Calculate score
            var score: i32 = @intCast(detected.priority);

            // Bonus for preferred compiler
            if (requirements.preferred) |pref| {
                if (detected.kind == pref) {
                    score += 50;
                }
            }

            // Bonus for modules support if needed
            if (requirements.needs_modules and detected.capabilities.cpp_modules) {
                score += 20;
            }

            // Bonus for matching target
            if (requirements.target) |target| {
                if (target.isWasm() and detected.kind == .emscripten) {
                    score += 30;
                } else if (target.os == .windows and detected.kind == .msvc) {
                    score += 20;
                }
            }

            if (score > best_score) {
                best_score = score;
                best = detected;
            }
        }

        return best;
    }

    /// Get a compiler instance by kind
    pub fn getCompiler(self: *Self, kind: CompilerKind) !Compiler {
        // Check cache
        if (self.cached_compilers.get(kind)) |compiler| {
            return compiler;
        }

        // Create new instance
        const compiler: Compiler = switch (kind) {
            .zig_cc => blk: {
                const cc = try zig_cc.ZigCC.init(self.allocator);
                break :blk cc.compiler();
            },
            .clang => blk: {
                const cc = try clang.Clang.init(self.allocator);
                break :blk cc.compiler();
            },
            .gcc => blk: {
                const cc = try gcc.GCC.init(self.allocator);
                break :blk cc.compiler();
            },
            .msvc => blk: {
                const cc = try msvc.MSVC.init(self.allocator);
                break :blk cc.compiler();
            },
            .emscripten => blk: {
                const cc = try emscripten.Emscripten.init(self.allocator);
                break :blk cc.compiler();
            },
            .custom => return error.UnsupportedCompiler,
        };

        try self.cached_compilers.put(kind, compiler);
        return compiler;
    }

    /// Get the default compiler (Zig CC)
    pub fn getDefault(self: *Self) !Compiler {
        return self.getCompiler(.zig_cc);
    }

    /// Get best compiler for requirements
    pub fn getBest(self: *Self, requirements: CompilerRequirements) !Compiler {
        const detected = try self.select(requirements) orelse return error.NoSuitableCompiler;
        return self.getCompiler(detected.kind);
    }

    /// List all detected compilers
    pub fn list(self: *Self) ![]const DetectedCompiler {
        if (self.detected.items.len == 0) {
            try self.detectAll();
        }
        return self.detected.items;
    }
};

/// Check if a detected compiler meets requirements
fn meetsRequirements(detected: DetectedCompiler, requirements: CompilerRequirements) bool {
    // Check C standard
    if (requirements.c_standard) |required| {
        if (@intFromEnum(detected.capabilities.max_c_standard) < @intFromEnum(required)) {
            return false;
        }
    }

    // Check C++ standard
    if (requirements.cpp_standard) |required| {
        if (@intFromEnum(detected.capabilities.max_cpp_standard) < @intFromEnum(required)) {
            return false;
        }
    }

    // Check modules support
    if (requirements.needs_modules and !detected.capabilities.cpp_modules) {
        return false;
    }

    // Check cross-compilation
    if (requirements.needs_cross_compile and !detected.capabilities.cross_compile) {
        return false;
    }

    // Check LTO
    if (requirements.needs_lto and !detected.capabilities.lto) {
        return false;
    }

    // Check sanitizers
    if (requirements.needs_sanitizers and !detected.capabilities.sanitizers) {
        return false;
    }

    // Check target platform
    if (requirements.target) |target| {
        if (target.isWasm()) {
            // Only Emscripten or Zig can target WASM
            if (detected.kind != .emscripten and detected.kind != .zig_cc) {
                return false;
            }
        }

        if (target.os == .windows and detected.kind != .msvc and detected.kind != .clang and detected.kind != .zig_cc) {
            return false;
        }
    }

    return true;
}

/// Quick helper to get default compiler
pub fn getDefaultCompiler(allocator: Allocator) !Compiler {
    const cc = try zig_cc.ZigCC.init(allocator);
    return cc.compiler();
}

/// Quick helper to detect and select best compiler
pub fn autoSelectCompiler(allocator: Allocator, requirements: CompilerRequirements) !Compiler {
    var detector = CompilerDetector.init(allocator);
    defer detector.deinit();

    return detector.getBest(requirements);
}

test "CompilerDetector basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var detector = CompilerDetector.init(allocator);
    defer detector.deinit();

    // Try to detect compilers (may not find any in test environment)
    detector.detectAll() catch {};

    // If we found any compilers, verify they have valid properties
    for (detector.detected.items) |d| {
        try testing.expect(d.path.len > 0);
        try testing.expect(d.priority > 0);
    }
}

test "meetsRequirements" {
    const testing = std.testing;

    const detected = DetectedCompiler{
        .kind = .clang,
        .path = "/usr/bin/clang",
        .capabilities = .{
            .cpp_modules = true,
            .header_units = true,
            .module_dep_scan = true,
            .lto = true,
            .pgo = true,
            .sanitizers = true,
            .cross_compile = true,
            .max_c_standard = .c23,
            .max_cpp_standard = .cpp23,
            .version = "17.0.0",
            .vendor = "LLVM",
        },
        .priority = 95,
    };

    // Should meet basic requirements
    try testing.expect(meetsRequirements(detected, .{}));

    // Should meet C++20 requirement
    try testing.expect(meetsRequirements(detected, .{ .cpp_standard = .cpp20 }));

    // Should meet modules requirement
    try testing.expect(meetsRequirements(detected, .{ .needs_modules = true }));

    // Test with lower capability compiler
    const limited = DetectedCompiler{
        .kind = .gcc,
        .path = "/usr/bin/gcc",
        .capabilities = .{
            .cpp_modules = false,
            .header_units = false,
            .module_dep_scan = false,
            .lto = true,
            .pgo = true,
            .sanitizers = true,
            .cross_compile = true,
            .max_c_standard = .c17,
            .max_cpp_standard = .cpp17,
            .version = "10.0.0",
            .vendor = "GNU",
        },
        .priority = 75,
    };

    // Should not meet C++20 requirement
    try testing.expect(!meetsRequirements(limited, .{ .cpp_standard = .cpp20 }));

    // Should not meet modules requirement
    try testing.expect(!meetsRequirements(limited, .{ .needs_modules = true }));
}
