//! Build profile definitions for optimization, debugging, and sanitizer configurations.
//!
//! This module provides the `Profile` type which encapsulates build configuration
//! settings including optimization levels, debug information, sanitizers, and
//! link-time optimization (LTO) settings.
//!
//! ## Predefined Profiles
//! - `debug`: Full debug information, no optimization, all sanitizers enabled
//! - `release`: Optimized for speed, stripped debug info, LTO enabled
//! - `release_safe`: Balanced optimization with safety checks
//! - `release_small`: Optimized for binary size
//!
//! ## Example
//! ```zig
//! const profile = Profile.debug;
//! const flags = try profile.compilerFlags(allocator, .gcc);
//! defer allocator.free(flags);
//! ```

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const platform_mod = @import("platform.zig");
const standard_mod = @import("standard.zig");
const Compiler = standard_mod.Compiler;

/// Optimization level for compilation.
pub const OptimizationLevel = enum {
    /// No optimization (fastest compilation).
    none,
    /// Basic optimizations that don't increase compile time significantly.
    debug,
    /// Standard optimization for release builds.
    release,
    /// Aggressive optimization for maximum performance.
    aggressive,
    /// Optimize for minimal binary size.
    size,
    /// Optimize for minimal binary size (more aggressive).
    size_aggressive,

    const Self = @This();

    /// Returns the compiler flag for this optimization level.
    pub fn compilerFlag(self: Self, compiler: Compiler) []const u8 {
        return switch (compiler) {
            .gcc, .clang => switch (self) {
                .none => "-O0",
                .debug => "-Og",
                .release => "-O2",
                .aggressive => "-O3",
                .size => "-Os",
                .size_aggressive => "-Oz",
            },
            .msvc => switch (self) {
                .none, .debug => "/Od",
                .release => "/O2",
                .aggressive => "/Ox",
                .size, .size_aggressive => "/O1",
            },
            .unknown => "-O0",
        };
    }

    /// Parses an optimization level from a string.
    pub fn parse(str: []const u8) ParseError!Self {
        if (std.mem.eql(u8, str, "none") or std.mem.eql(u8, str, "0")) return .none;
        if (std.mem.eql(u8, str, "debug") or std.mem.eql(u8, str, "g")) return .debug;
        if (std.mem.eql(u8, str, "release") or std.mem.eql(u8, str, "2")) return .release;
        if (std.mem.eql(u8, str, "aggressive") or std.mem.eql(u8, str, "3")) return .aggressive;
        if (std.mem.eql(u8, str, "size") or std.mem.eql(u8, str, "s")) return .size;
        if (std.mem.eql(u8, str, "size_aggressive") or std.mem.eql(u8, str, "z")) return .size_aggressive;
        return ParseError.InvalidOptimization;
    }
};

/// Debug information level.
pub const DebugInfo = enum {
    /// No debug information.
    none,
    /// Line tables only (minimal debug info for stack traces).
    line_tables,
    /// Full debug information (DWARF/PDB).
    full,

    const Self = @This();

    /// Returns compiler flags for this debug info level.
    /// May return multiple flags.
    pub fn compilerFlags(self: Self, compiler: Compiler) []const []const u8 {
        return switch (compiler) {
            .gcc, .clang => switch (self) {
                .none => &[_][]const u8{},
                .line_tables => &[_][]const u8{"-g1"},
                .full => &[_][]const u8{ "-g", "-fno-omit-frame-pointer" },
            },
            .msvc => switch (self) {
                .none => &[_][]const u8{},
                .line_tables => &[_][]const u8{"/Zi"},
                .full => &[_][]const u8{ "/Zi", "/DEBUG:FULL" },
            },
            .unknown => &[_][]const u8{},
        };
    }

    /// Parses a debug info level from a string.
    pub fn parse(str: []const u8) ParseError!Self {
        if (std.mem.eql(u8, str, "none") or std.mem.eql(u8, str, "false") or std.mem.eql(u8, str, "0")) return .none;
        if (std.mem.eql(u8, str, "line_tables") or std.mem.eql(u8, str, "lines") or std.mem.eql(u8, str, "1")) return .line_tables;
        if (std.mem.eql(u8, str, "full") or std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "2")) return .full;
        return ParseError.InvalidDebugInfo;
    }
};

/// Sanitizer options for runtime error detection.
pub const Sanitizers = packed struct {
    /// AddressSanitizer: detects memory errors (buffer overflow, use-after-free).
    address: bool = false,
    /// ThreadSanitizer: detects data races.
    thread: bool = false,
    /// UndefinedBehaviorSanitizer: detects undefined behavior.
    undefined: bool = false,
    /// MemorySanitizer: detects uninitialized memory reads (Clang only).
    memory: bool = false,
    /// LeakSanitizer: detects memory leaks.
    leak: bool = false,

    const Self = @This();

    /// No sanitizers enabled.
    pub const none = Self{};

    /// All commonly used sanitizers enabled.
    pub const all = Self{
        .address = true,
        .thread = false, // Cannot be combined with address
        .undefined = true,
        .memory = false, // Cannot be combined with address
        .leak = true,
    };

    /// Address and undefined behavior sanitizers (common debug combo).
    pub const debug_default = Self{
        .address = true,
        .undefined = true,
        .leak = true,
    };

    /// Returns compiler flags for the enabled sanitizers.
    /// Caller owns the returned memory.
    pub fn compilerFlags(self: Self, allocator: Allocator, compiler: Compiler) Allocator.Error![]const []const u8 {
        var flags = std.ArrayList([]const u8).init(allocator);
        errdefer flags.deinit();

        switch (compiler) {
            .gcc, .clang => {
                if (self.address) try flags.append("-fsanitize=address");
                if (self.thread) try flags.append("-fsanitize=thread");
                if (self.undefined) try flags.append("-fsanitize=undefined");
                if (self.memory and compiler == .clang) try flags.append("-fsanitize=memory");
                if (self.leak) try flags.append("-fsanitize=leak");
            },
            .msvc => {
                if (self.address) try flags.append("/fsanitize=address");
                // MSVC has limited sanitizer support
            },
            .unknown => {},
        }

        return flags.toOwnedSlice();
    }

    /// Returns true if any sanitizer is enabled.
    pub fn anyEnabled(self: Self) bool {
        return self.address or self.thread or self.undefined or self.memory or self.leak;
    }

    /// Validates sanitizer combination (some sanitizers are mutually exclusive).
    pub fn validate(self: Self) ValidateError!void {
        // AddressSanitizer and ThreadSanitizer cannot be combined
        if (self.address and self.thread) {
            return ValidateError.IncompatibleSanitizers;
        }
        // AddressSanitizer and MemorySanitizer cannot be combined
        if (self.address and self.memory) {
            return ValidateError.IncompatibleSanitizers;
        }
        // ThreadSanitizer and MemorySanitizer cannot be combined
        if (self.thread and self.memory) {
            return ValidateError.IncompatibleSanitizers;
        }
    }
};

/// Link-Time Optimization (LTO) configuration.
pub const Lto = enum {
    /// No LTO.
    none,
    /// Thin LTO (faster compilation, good optimization).
    thin,
    /// Full LTO (slower compilation, maximum optimization).
    full,

    const Self = @This();

    /// Returns compiler flags for this LTO mode.
    pub fn compilerFlags(self: Self, compiler: Compiler) []const []const u8 {
        return switch (compiler) {
            .gcc => switch (self) {
                .none => &[_][]const u8{},
                .thin, .full => &[_][]const u8{"-flto"},
            },
            .clang => switch (self) {
                .none => &[_][]const u8{},
                .thin => &[_][]const u8{"-flto=thin"},
                .full => &[_][]const u8{"-flto=full"},
            },
            .msvc => switch (self) {
                .none => &[_][]const u8{},
                .thin, .full => &[_][]const u8{"/GL"},
            },
            .unknown => &[_][]const u8{},
        };
    }

    /// Returns linker flags for this LTO mode.
    pub fn linkerFlags(self: Self, compiler: Compiler) []const []const u8 {
        return switch (compiler) {
            .gcc => switch (self) {
                .none => &[_][]const u8{},
                .thin, .full => &[_][]const u8{"-flto"},
            },
            .clang => switch (self) {
                .none => &[_][]const u8{},
                .thin => &[_][]const u8{"-flto=thin"},
                .full => &[_][]const u8{"-flto=full"},
            },
            .msvc => switch (self) {
                .none => &[_][]const u8{},
                .thin, .full => &[_][]const u8{"/LTCG"},
            },
            .unknown => &[_][]const u8{},
        };
    }

    /// Parses an LTO mode from a string.
    pub fn parse(str: []const u8) ParseError!Self {
        if (std.mem.eql(u8, str, "none") or std.mem.eql(u8, str, "false") or std.mem.eql(u8, str, "off")) return .none;
        if (std.mem.eql(u8, str, "thin")) return .thin;
        if (std.mem.eql(u8, str, "full") or std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "on")) return .full;
        return ParseError.InvalidLto;
    }
};

/// Complete build profile configuration.
pub const Profile = struct {
    /// Profile name (e.g., "debug", "release", or custom name).
    name: []const u8,
    /// Optimization level.
    optimization: OptimizationLevel,
    /// Debug information level.
    debug_info: DebugInfo,
    /// Enabled sanitizers.
    sanitizers: Sanitizers,
    /// Link-time optimization mode.
    lto: Lto,
    /// Strip symbols from binary.
    strip: bool,
    /// Enable position-independent code (required for shared libraries).
    pic: bool,
    /// Additional compiler flags.
    extra_cflags: []const []const u8,
    /// Additional C++ compiler flags.
    extra_cxxflags: []const []const u8,
    /// Additional linker flags.
    extra_ldflags: []const []const u8,
    /// Preprocessor definitions.
    defines: []const []const u8,

    const Self = @This();

    /// Predefined debug profile.
    pub const debug = Self{
        .name = "debug",
        .optimization = .debug,
        .debug_info = .full,
        .sanitizers = Sanitizers.debug_default,
        .lto = .none,
        .strip = false,
        .pic = false,
        .extra_cflags = &[_][]const u8{},
        .extra_cxxflags = &[_][]const u8{},
        .extra_ldflags = &[_][]const u8{},
        .defines = &[_][]const u8{"DEBUG"},
    };

    /// Predefined release profile (optimized for speed).
    pub const release = Self{
        .name = "release",
        .optimization = .release,
        .debug_info = .none,
        .sanitizers = Sanitizers.none,
        .lto = .full,
        .strip = true,
        .pic = false,
        .extra_cflags = &[_][]const u8{},
        .extra_cxxflags = &[_][]const u8{},
        .extra_ldflags = &[_][]const u8{},
        .defines = &[_][]const u8{"NDEBUG"},
    };

    /// Predefined release profile with safety checks.
    pub const release_safe = Self{
        .name = "release_safe",
        .optimization = .release,
        .debug_info = .line_tables,
        .sanitizers = Sanitizers.none,
        .lto = .thin,
        .strip = false,
        .pic = false,
        .extra_cflags = &[_][]const u8{},
        .extra_cxxflags = &[_][]const u8{},
        .extra_ldflags = &[_][]const u8{},
        .defines = &[_][]const u8{"NDEBUG"},
    };

    /// Predefined release profile optimized for size.
    pub const release_small = Self{
        .name = "release_small",
        .optimization = .size,
        .debug_info = .none,
        .sanitizers = Sanitizers.none,
        .lto = .full,
        .strip = true,
        .pic = false,
        .extra_cflags = &[_][]const u8{},
        .extra_cxxflags = &[_][]const u8{},
        .extra_ldflags = &[_][]const u8{},
        .defines = &[_][]const u8{"NDEBUG"},
    };

    /// Returns the predefined profile with the given name, or null if not found.
    pub fn fromName(name: []const u8) ?Self {
        if (std.mem.eql(u8, name, "debug")) return debug;
        if (std.mem.eql(u8, name, "release")) return release;
        if (std.mem.eql(u8, name, "release_safe") or std.mem.eql(u8, name, "releasesafe")) return release_safe;
        if (std.mem.eql(u8, name, "release_small") or std.mem.eql(u8, name, "releasesmall")) return release_small;
        return null;
    }

    /// Generates all compiler flags for this profile.
    /// Caller owns the returned memory.
    pub fn compilerFlags(self: Self, allocator: Allocator, compiler: Compiler) Allocator.Error![]const []const u8 {
        var flags = std.ArrayList([]const u8).init(allocator);
        errdefer flags.deinit();

        // Optimization
        try flags.append(self.optimization.compilerFlag(compiler));

        // Debug info
        for (self.debug_info.compilerFlags(compiler)) |flag| {
            try flags.append(flag);
        }

        // Sanitizers
        const san_flags = try self.sanitizers.compilerFlags(allocator, compiler);
        defer allocator.free(san_flags);
        for (san_flags) |flag| {
            try flags.append(flag);
        }

        // LTO
        for (self.lto.compilerFlags(compiler)) |flag| {
            try flags.append(flag);
        }

        // PIC
        if (self.pic) {
            switch (compiler) {
                .gcc, .clang => try flags.append("-fPIC"),
                .msvc => {}, // MSVC doesn't need explicit PIC flag
                .unknown => {},
            }
        }

        // Defines
        for (self.defines) |define| {
            switch (compiler) {
                .gcc, .clang => {
                    const flag = try std.fmt.allocPrint(allocator, "-D{s}", .{define});
                    try flags.append(flag);
                },
                .msvc => {
                    const flag = try std.fmt.allocPrint(allocator, "/D{s}", .{define});
                    try flags.append(flag);
                },
                .unknown => {},
            }
        }

        // Extra flags
        for (self.extra_cflags) |flag| {
            try flags.append(flag);
        }

        return flags.toOwnedSlice();
    }

    /// Generates linker flags for this profile.
    /// Caller owns the returned memory.
    pub fn linkerFlags(self: Self, allocator: Allocator, compiler: Compiler) Allocator.Error![]const []const u8 {
        var flags = std.ArrayList([]const u8).init(allocator);
        errdefer flags.deinit();

        // Strip
        if (self.strip) {
            switch (compiler) {
                .gcc, .clang => try flags.append("-s"),
                .msvc => {}, // MSVC strips by default in release
                .unknown => {},
            }
        }

        // LTO linker flags
        for (self.lto.linkerFlags(compiler)) |flag| {
            try flags.append(flag);
        }

        // Extra linker flags
        for (self.extra_ldflags) |flag| {
            try flags.append(flag);
        }

        return flags.toOwnedSlice();
    }

    /// Validates the profile configuration.
    pub fn validate(self: Self) ValidateError!void {
        try self.sanitizers.validate();
    }

    /// Creates a copy of this profile with a different name.
    pub fn withName(self: Self, name: []const u8) Self {
        var copy = self;
        copy.name = name;
        return copy;
    }
};

/// Errors that can occur when parsing profile options.
pub const ParseError = error{
    InvalidOptimization,
    InvalidDebugInfo,
    InvalidLto,
    InvalidProfile,
};

/// Errors that can occur when validating a profile.
pub const ValidateError = error{
    /// Two or more enabled sanitizers cannot be used together.
    IncompatibleSanitizers,
};

// ============================================================================
// Tests
// ============================================================================

test "OptimizationLevel.compilerFlag" {
    try testing.expectEqualStrings("-O0", OptimizationLevel.none.compilerFlag(.gcc));
    try testing.expectEqualStrings("-O2", OptimizationLevel.release.compilerFlag(.clang));
    try testing.expectEqualStrings("-O3", OptimizationLevel.aggressive.compilerFlag(.gcc));
    try testing.expectEqualStrings("-Os", OptimizationLevel.size.compilerFlag(.clang));

    try testing.expectEqualStrings("/O2", OptimizationLevel.release.compilerFlag(.msvc));
    try testing.expectEqualStrings("/O1", OptimizationLevel.size.compilerFlag(.msvc));
}

test "OptimizationLevel.parse" {
    try testing.expectEqual(OptimizationLevel.none, try OptimizationLevel.parse("none"));
    try testing.expectEqual(OptimizationLevel.none, try OptimizationLevel.parse("0"));
    try testing.expectEqual(OptimizationLevel.release, try OptimizationLevel.parse("release"));
    try testing.expectEqual(OptimizationLevel.release, try OptimizationLevel.parse("2"));
    try testing.expectEqual(OptimizationLevel.size, try OptimizationLevel.parse("s"));
    try testing.expectError(ParseError.InvalidOptimization, OptimizationLevel.parse("invalid"));
}

test "DebugInfo.compilerFlags" {
    const none_flags = DebugInfo.none.compilerFlags(.gcc);
    try testing.expectEqual(@as(usize, 0), none_flags.len);

    const full_flags = DebugInfo.full.compilerFlags(.gcc);
    try testing.expectEqual(@as(usize, 2), full_flags.len);
    try testing.expectEqualStrings("-g", full_flags[0]);
}

test "Sanitizers.validate" {
    // Valid combinations
    try Sanitizers.none.validate();
    try Sanitizers.debug_default.validate();

    // Invalid combinations
    const addr_thread = Sanitizers{ .address = true, .thread = true };
    try testing.expectError(ValidateError.IncompatibleSanitizers, addr_thread.validate());

    const addr_memory = Sanitizers{ .address = true, .memory = true };
    try testing.expectError(ValidateError.IncompatibleSanitizers, addr_memory.validate());
}

test "Sanitizers.compilerFlags" {
    const allocator = testing.allocator;

    const flags = try Sanitizers.debug_default.compilerFlags(allocator, .gcc);
    defer allocator.free(flags);

    try testing.expectEqual(@as(usize, 3), flags.len);

    var has_address = false;
    var has_undefined = false;
    for (flags) |flag| {
        if (std.mem.eql(u8, flag, "-fsanitize=address")) has_address = true;
        if (std.mem.eql(u8, flag, "-fsanitize=undefined")) has_undefined = true;
    }
    try testing.expect(has_address);
    try testing.expect(has_undefined);
}

test "Lto.compilerFlags" {
    const thin_flags = Lto.thin.compilerFlags(.clang);
    try testing.expectEqual(@as(usize, 1), thin_flags.len);
    try testing.expectEqualStrings("-flto=thin", thin_flags[0]);

    const full_flags = Lto.full.compilerFlags(.gcc);
    try testing.expectEqual(@as(usize, 1), full_flags.len);
    try testing.expectEqualStrings("-flto", full_flags[0]);
}

test "Profile.fromName" {
    const debug_profile = Profile.fromName("debug").?;
    try testing.expectEqualStrings("debug", debug_profile.name);
    try testing.expectEqual(OptimizationLevel.debug, debug_profile.optimization);
    try testing.expectEqual(DebugInfo.full, debug_profile.debug_info);

    const release_profile = Profile.fromName("release").?;
    try testing.expectEqualStrings("release", release_profile.name);
    try testing.expectEqual(OptimizationLevel.release, release_profile.optimization);
    try testing.expect(release_profile.strip);

    try testing.expect(Profile.fromName("nonexistent") == null);
}

test "Profile.validate" {
    // Built-in profiles should be valid
    try Profile.debug.validate();
    try Profile.release.validate();
    try Profile.release_safe.validate();
    try Profile.release_small.validate();
}

test "Profile.compilerFlags" {
    const allocator = testing.allocator;

    const flags = try Profile.release.compilerFlags(allocator, .gcc);
    defer {
        for (flags) |flag| {
            // Free allocated define flags
            if (flag.len > 2 and flag[0] == '-' and flag[1] == 'D') {
                allocator.free(flag);
            }
        }
        allocator.free(flags);
    }

    // Should contain at least optimization flag
    try testing.expect(flags.len >= 1);

    var has_opt = false;
    for (flags) |flag| {
        if (std.mem.eql(u8, flag, "-O2")) has_opt = true;
    }
    try testing.expect(has_opt);
}
