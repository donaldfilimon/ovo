//! Build target model for executables, libraries, and other artifacts.
//!
//! This module defines the `Target` type which represents a build artifact
//! such as an executable, static library, shared library, or header-only library.
//! Targets include source files, include directories, compiler defines, flags,
//! and platform-specific configuration.
//!
//! ## Target Types
//! - **Executable**: Produces a runnable binary (.exe on Windows)
//! - **Static Library**: Produces a static archive (.a, .lib)
//! - **Shared Library**: Produces a dynamic/shared library (.so, .dll, .dylib)
//! - **Header Only**: No compilation, just provides headers to dependents
//! - **Object Library**: Produces object files for linking into other targets
//!
//! ## Example
//! ```zig
//! const target = Target{
//!     .name = "myapp",
//!     .kind = .executable,
//!     .sources = &.{"src/main.cpp", "src/app.cpp"},
//!     .include_dirs = &.{"include"},
//!     .defines = &.{.{ .name = "VERSION", .value = "\"1.0.0\"" }},
//! };
//! ```

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const platform_mod = @import("platform.zig");
const standard_mod = @import("standard.zig");
const profile_mod = @import("profile.zig");
const dependency_mod = @import("dependency.zig");

const Platform = platform_mod.Platform;
const Os = platform_mod.Os;
const Arch = platform_mod.Arch;
const CStandard = standard_mod.CStandard;
const CppStandard = standard_mod.CppStandard;
const LanguageStandard = standard_mod.LanguageStandard;

/// Type of build target/artifact.
pub const TargetKind = enum {
    /// Produces a runnable executable.
    executable,
    /// Produces a static library archive.
    static_library,
    /// Produces a shared/dynamic library.
    shared_library,
    /// Header-only library (no compilation).
    header_only,
    /// Object library (compiles to .o files, not archived).
    object_library,

    const Self = @This();

    /// Returns the default output extension for this target kind on the given OS.
    pub fn defaultExtension(self: Self, os: Os) []const u8 {
        return switch (self) {
            .executable => os.exeExtension(),
            .static_library => os.staticLibExtension(),
            .shared_library => os.sharedLibExtension(),
            .header_only => "",
            .object_library => if (os == .windows) ".obj" else ".o",
        };
    }

    /// Returns true if this target kind produces linkable output.
    pub fn isLinkable(self: Self) bool {
        return switch (self) {
            .static_library, .shared_library, .object_library => true,
            .executable, .header_only => false,
        };
    }

    /// Returns true if this target kind requires compilation.
    pub fn requiresCompilation(self: Self) bool {
        return switch (self) {
            .executable, .static_library, .shared_library, .object_library => true,
            .header_only => false,
        };
    }
};

/// Preprocessor definition.
pub const Define = struct {
    /// Macro name.
    name: []const u8,
    /// Optional value (null for flag-style defines like -DDEBUG).
    value: ?[]const u8 = null,

    const Self = @This();

    /// Creates a flag-style define (no value).
    pub fn flag(name: []const u8) Self {
        return .{ .name = name, .value = null };
    }

    /// Creates a define with a value.
    pub fn withValue(name: []const u8, val: []const u8) Self {
        return .{ .name = name, .value = val };
    }

    /// Returns the compiler flag for this define.
    pub fn toFlag(self: Self, buf: []u8, is_msvc: bool) []u8 {
        var writer = std.Io.Writer.fixed(buf);

        const prefix = if (is_msvc) "/D" else "-D";
        if (self.value) |val| {
            writer.print("{s}{s}={s}", .{ prefix, self.name, val }) catch {};
        } else {
            writer.print("{s}{s}", .{ prefix, self.name }) catch {};
        }

        return buf[0..writer.end];
    }
};

/// Include directory specification.
pub const IncludeDir = struct {
    /// Path to the include directory.
    path: []const u8,
    /// Whether this is a system include directory (-isystem vs -I).
    system: bool = false,
    /// Access level for dependents.
    access: Access = .public,

    pub const Access = enum {
        /// Available to this target and all dependents.
        public,
        /// Only available to this target.
        private,
        /// Only available to dependents, not this target.
        interface,
    };

    const Self = @This();

    /// Returns the compiler flag for this include directory.
    pub fn toFlag(self: Self, buf: []u8, is_msvc: bool) []u8 {
        var writer = std.Io.Writer.fixed(buf);

        if (is_msvc) {
            if (self.system) {
                writer.print("/external:I{s}", .{self.path}) catch {};
            } else {
                writer.print("/I{s}", .{self.path}) catch {};
            }
        } else {
            if (self.system) {
                writer.print("-isystem{s}", .{self.path}) catch {};
            } else {
                writer.print("-I{s}", .{self.path}) catch {};
            }
        }

        return buf[0..writer.end];
    }
};

/// Library to link against.
pub const LinkLibrary = struct {
    /// Library name (without lib prefix or extension).
    name: []const u8,
    /// Optional explicit path to the library file.
    path: ?[]const u8 = null,
    /// Whether to link statically or dynamically.
    static: bool = false,
    /// Whether this is a framework (macOS/iOS).
    framework: bool = false,
    /// Access level for dependents.
    access: IncludeDir.Access = .public,

    const Self = @This();

    /// Returns the linker flag for this library.
    pub fn toFlag(self: Self, buf: []u8, os: Os, is_msvc: bool) []u8 {
        var writer = std.Io.Writer.fixed(buf);

        if (self.path) |p| {
            writer.writeAll(p) catch {};
        } else if (self.framework and os.isApple()) {
            writer.print("-framework {s}", .{self.name}) catch {};
        } else if (is_msvc) {
            writer.print("{s}.lib", .{self.name}) catch {};
        } else {
            writer.print("-l{s}", .{self.name}) catch {};
        }

        return buf[0..writer.end];
    }
};

/// Platform-specific configuration overlay.
pub const PlatformConfig = struct {
    /// Platform this configuration applies to.
    platform: PlatformMatcher,
    /// Additional sources for this platform.
    sources: []const []const u8 = &.{},
    /// Additional include directories for this platform.
    include_dirs: []const IncludeDir = &.{},
    /// Additional defines for this platform.
    defines: []const Define = &.{},
    /// Additional compiler flags for this platform.
    cflags: []const []const u8 = &.{},
    /// Additional C++ compiler flags for this platform.
    cxxflags: []const []const u8 = &.{},
    /// Additional linker flags for this platform.
    ldflags: []const []const u8 = &.{},
    /// Additional libraries for this platform.
    libraries: []const LinkLibrary = &.{},
    /// Additional frameworks for this platform (macOS/iOS).
    frameworks: []const []const u8 = &.{},

    /// Checks if this platform config applies to the given platform.
    pub fn appliesTo(self: PlatformConfig, target: Platform) bool {
        return self.platform.matches(target);
    }
};

/// Platform matching specification.
pub const PlatformMatcher = union(enum) {
    /// Matches any platform.
    any,
    /// Matches a specific OS.
    os: Os,
    /// Matches a specific architecture.
    arch: Arch,
    /// Matches a specific OS and architecture combination.
    os_arch: struct { os: Os, arch: Arch },
    /// Matches a complete platform specification.
    platform: Platform,
    /// Matches if any of the sub-matchers match (OR).
    any_of: []const PlatformMatcher,
    /// Matches if all of the sub-matchers match (AND).
    all_of: []const PlatformMatcher,
    /// Inverts the match result.
    not: *const PlatformMatcher,

    const Self = @This();

    /// Returns true if this matcher matches the given platform.
    pub fn matches(self: Self, target: Platform) bool {
        return switch (self) {
            .any => true,
            .os => |os| target.os == os,
            .arch => |arch| target.arch == arch,
            .os_arch => |oa| target.os == oa.os and target.arch == oa.arch,
            .platform => |p| target.arch == p.arch and target.os == p.os and target.abi == p.abi,
            .any_of => |matchers| {
                for (matchers) |m| {
                    if (m.matches(target)) return true;
                }
                return false;
            },
            .all_of => |matchers| {
                for (matchers) |m| {
                    if (!m.matches(target)) return false;
                }
                return true;
            },
            .not => |inner| !inner.matches(target),
        };
    }

    /// Convenience constructors.
    pub const windows = Self{ .os = .windows };
    pub const linux = Self{ .os = .linux };
    pub const macos = Self{ .os = .macos };
    pub const unix_like = Self{ .any_of = &[_]Self{ .{ .os = .linux }, .{ .os = .macos }, .{ .os = .freebsd } } };
    pub const x86_64 = Self{ .arch = .x86_64 };
    pub const aarch64 = Self{ .arch = .aarch64 };
};

/// Source file specification with optional per-file settings.
pub const SourceFile = struct {
    /// Path to the source file.
    path: []const u8,
    /// Optional per-file compiler flags.
    flags: []const []const u8 = &.{},
    /// Optional per-file defines.
    defines: []const Define = &.{},
    /// Language override (auto-detected from extension if null).
    language: ?Language = null,

    pub const Language = enum {
        c,
        cpp,
        objc,
        objcpp,
        asm_att,
        asm_intel,
    };

    const Self = @This();

    /// Auto-detects the language from the file extension.
    pub fn detectLanguage(self: Self) Language {
        if (self.language) |l| return l;

        const ext = std.fs.path.extension(self.path);
        if (std.mem.eql(u8, ext, ".c")) return .c;
        if (std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".cc") or std.mem.eql(u8, ext, ".cxx")) return .cpp;
        if (std.mem.eql(u8, ext, ".m")) return .objc;
        if (std.mem.eql(u8, ext, ".mm")) return .objcpp;
        if (std.mem.eql(u8, ext, ".s") or std.mem.eql(u8, ext, ".S")) return .asm_att;
        if (std.mem.eql(u8, ext, ".asm")) return .asm_intel;
        return .cpp; // Default to C++
    }

    /// Creates a source file from just a path.
    pub fn fromPath(path: []const u8) Self {
        return .{ .path = path };
    }
};

/// Complete build target specification.
pub const Target = struct {
    /// Unique name for this target.
    name: []const u8,
    /// Type of target (executable, library, etc.).
    kind: TargetKind,
    /// Source files (simple string paths).
    sources: []const []const u8 = &.{},
    /// Source files with per-file configuration.
    source_files: []const SourceFile = &.{},
    /// Include directories.
    include_dirs: []const IncludeDir = &.{},
    /// Simple include directory paths (convenience, treated as public non-system).
    include_paths: []const []const u8 = &.{},
    /// Preprocessor defines.
    defines: []const Define = &.{},
    /// C language standard.
    c_standard: ?CStandard = null,
    /// C++ language standard.
    cpp_standard: ?CppStandard = null,
    /// Additional C compiler flags.
    cflags: []const []const u8 = &.{},
    /// Additional C++ compiler flags.
    cxxflags: []const []const u8 = &.{},
    /// Linker flags.
    ldflags: []const []const u8 = &.{},
    /// Libraries to link against.
    libraries: []const LinkLibrary = &.{},
    /// Simple library names to link (convenience).
    link_libraries: []const []const u8 = &.{},
    /// Frameworks to link (macOS/iOS).
    frameworks: []const []const u8 = &.{},
    /// Dependencies (names of other targets or external dependencies).
    dependencies: []const []const u8 = &.{},
    /// Platform-specific configuration overlays.
    platform_configs: []const PlatformConfig = &.{},
    /// Output filename override (auto-generated if null).
    output_name: ?[]const u8 = null,
    /// Output directory override.
    output_dir: ?[]const u8 = null,
    /// Whether to generate position-independent code.
    pic: ?bool = null,
    /// Visibility setting for symbols.
    visibility: Visibility = .default,
    /// Whether this target should be installed.
    install: bool = true,
    /// Install subdirectory override.
    install_dir: ?[]const u8 = null,
    /// Precompiled header file.
    pch: ?[]const u8 = null,
    /// Enable/disable exceptions (C++).
    exceptions: ?bool = null,
    /// Enable/disable RTTI (C++).
    rtti: ?bool = null,

    pub const Visibility = enum {
        default,
        hidden,
        protected,
    };

    const Self = @This();

    /// Returns all source file paths (combining sources and source_files).
    pub fn allSourcePaths(self: Self, allocator: Allocator) Allocator.Error![]const []const u8 {
        var paths = std.ArrayList([]const u8).init(allocator);
        errdefer paths.deinit();

        for (self.sources) |s| {
            try paths.append(s);
        }
        for (self.source_files) |sf| {
            try paths.append(sf.path);
        }

        return paths.toOwnedSlice();
    }

    /// Returns the output filename for this target.
    pub fn outputFilename(self: Self, _: Platform) []const u8 {
        if (self.output_name) |name| return name;

        // For libraries, we need to add prefix/suffix based on OS
        // For now, just return the name; the build system adds prefixes
        return self.name;
    }

    /// Returns all include directories for this target, including simple paths.
    pub fn allIncludeDirs(self: Self, allocator: Allocator) Allocator.Error![]IncludeDir {
        var dirs = std.ArrayList(IncludeDir).init(allocator);
        errdefer dirs.deinit();

        for (self.include_dirs) |d| {
            try dirs.append(d);
        }
        for (self.include_paths) |p| {
            try dirs.append(.{ .path = p });
        }

        return dirs.toOwnedSlice();
    }

    /// Merges platform-specific configuration into base configuration.
    pub fn mergedForPlatform(self: Self, platform: Platform, allocator: Allocator) Allocator.Error!MergedTarget {
        var merged = MergedTarget{
            .base = self,
            .sources = std.ArrayList([]const u8).init(allocator),
            .include_dirs = std.ArrayList(IncludeDir).init(allocator),
            .defines = std.ArrayList(Define).init(allocator),
            .cflags = std.ArrayList([]const u8).init(allocator),
            .cxxflags = std.ArrayList([]const u8).init(allocator),
            .ldflags = std.ArrayList([]const u8).init(allocator),
            .libraries = std.ArrayList(LinkLibrary).init(allocator),
            .frameworks = std.ArrayList([]const u8).init(allocator),
        };

        // Add base configuration
        for (self.sources) |s| try merged.sources.append(s);
        for (self.source_files) |sf| try merged.sources.append(sf.path);
        for (self.include_dirs) |d| try merged.include_dirs.append(d);
        for (self.include_paths) |p| try merged.include_dirs.append(.{ .path = p });
        for (self.defines) |d| try merged.defines.append(d);
        for (self.cflags) |f| try merged.cflags.append(f);
        for (self.cxxflags) |f| try merged.cxxflags.append(f);
        for (self.ldflags) |f| try merged.ldflags.append(f);
        for (self.libraries) |l| try merged.libraries.append(l);
        for (self.link_libraries) |name| try merged.libraries.append(.{ .name = name });
        for (self.frameworks) |f| try merged.frameworks.append(f);

        // Merge platform-specific configs
        for (self.platform_configs) |pc| {
            if (pc.appliesTo(platform)) {
                for (pc.sources) |s| try merged.sources.append(s);
                for (pc.include_dirs) |d| try merged.include_dirs.append(d);
                for (pc.defines) |d| try merged.defines.append(d);
                for (pc.cflags) |f| try merged.cflags.append(f);
                for (pc.cxxflags) |f| try merged.cxxflags.append(f);
                for (pc.ldflags) |f| try merged.ldflags.append(f);
                for (pc.libraries) |l| try merged.libraries.append(l);
                for (pc.frameworks) |f| try merged.frameworks.append(f);
            }
        }

        return merged;
    }

    /// Validates the target configuration.
    pub fn validate(self: Self) ValidateError!void {
        if (self.name.len == 0) {
            return ValidateError.MissingName;
        }

        // Targets that require compilation must have sources
        if (self.kind.requiresCompilation()) {
            if (self.sources.len == 0 and self.source_files.len == 0) {
                return ValidateError.NoSources;
            }
        }
    }
};

/// Result of merging a Target with platform-specific configuration.
pub const MergedTarget = struct {
    base: Target,
    sources: std.ArrayList([]const u8),
    include_dirs: std.ArrayList(IncludeDir),
    defines: std.ArrayList(Define),
    cflags: std.ArrayList([]const u8),
    cxxflags: std.ArrayList([]const u8),
    ldflags: std.ArrayList([]const u8),
    libraries: std.ArrayList(LinkLibrary),
    frameworks: std.ArrayList([]const u8),

    const Self = @This();

    /// Frees all allocated memory.
    pub fn deinit(self: *Self) void {
        self.sources.deinit();
        self.include_dirs.deinit();
        self.defines.deinit();
        self.cflags.deinit();
        self.cxxflags.deinit();
        self.ldflags.deinit();
        self.libraries.deinit();
        self.frameworks.deinit();
    }
};

/// Errors that can occur during target validation.
pub const ValidateError = error{
    MissingName,
    NoSources,
    InvalidSourcePath,
};

// ============================================================================
// Tests
// ============================================================================

test "TargetKind.defaultExtension" {
    try testing.expectEqualStrings(".exe", TargetKind.executable.defaultExtension(.windows));
    try testing.expectEqualStrings("", TargetKind.executable.defaultExtension(.linux));
    try testing.expectEqualStrings(".a", TargetKind.static_library.defaultExtension(.linux));
    try testing.expectEqualStrings(".lib", TargetKind.static_library.defaultExtension(.windows));
    try testing.expectEqualStrings(".so", TargetKind.shared_library.defaultExtension(.linux));
    try testing.expectEqualStrings(".dylib", TargetKind.shared_library.defaultExtension(.macos));
}

test "Define.toFlag" {
    var buf: [64]u8 = undefined;

    const flag_define = Define.flag("DEBUG");
    const flag_result = flag_define.toFlag(&buf, false);
    try testing.expectEqualStrings("-DDEBUG", flag_result);

    const val_define = Define.withValue("VERSION", "\"1.0\"");
    const val_result = val_define.toFlag(&buf, false);
    try testing.expectEqualStrings("-DVERSION=\"1.0\"", val_result);

    const msvc_result = flag_define.toFlag(&buf, true);
    try testing.expectEqualStrings("/DDEBUG", msvc_result);
}

test "IncludeDir.toFlag" {
    var buf: [128]u8 = undefined;

    const normal = IncludeDir{ .path = "/usr/include" };
    const normal_result = normal.toFlag(&buf, false);
    try testing.expectEqualStrings("-I/usr/include", normal_result);

    const system = IncludeDir{ .path = "/usr/include", .system = true };
    const system_result = system.toFlag(&buf, false);
    try testing.expectEqualStrings("-isystem/usr/include", system_result);
}

test "PlatformMatcher.matches" {
    const linux_x86_64 = Platform{
        .arch = .x86_64,
        .vendor = .unknown,
        .os = .linux,
        .abi = .gnu,
    };

    const windows_x86_64 = Platform{
        .arch = .x86_64,
        .vendor = .pc,
        .os = .windows,
        .abi = .msvc,
    };

    try testing.expect(PlatformMatcher.linux.matches(linux_x86_64));
    try testing.expect(!PlatformMatcher.linux.matches(windows_x86_64));
    try testing.expect(PlatformMatcher.windows.matches(windows_x86_64));
    try testing.expect(PlatformMatcher.x86_64.matches(linux_x86_64));
    try testing.expect(PlatformMatcher.x86_64.matches(windows_x86_64));
    try testing.expect(PlatformMatcher.unix_like.matches(linux_x86_64));
    try testing.expect(!PlatformMatcher.unix_like.matches(windows_x86_64));
}

test "SourceFile.detectLanguage" {
    const cpp = SourceFile{ .path = "src/main.cpp" };
    try testing.expectEqual(SourceFile.Language.cpp, cpp.detectLanguage());

    const c = SourceFile{ .path = "src/lib.c" };
    try testing.expectEqual(SourceFile.Language.c, c.detectLanguage());

    const objc = SourceFile{ .path = "src/app.m" };
    try testing.expectEqual(SourceFile.Language.objc, objc.detectLanguage());

    const override = SourceFile{ .path = "src/main.cpp", .language = .c };
    try testing.expectEqual(SourceFile.Language.c, override.detectLanguage());
}

test "Target.validate" {
    // Valid executable
    const valid_exe = Target{
        .name = "myapp",
        .kind = .executable,
        .sources = &[_][]const u8{"src/main.cpp"},
    };
    try valid_exe.validate();

    // Valid header-only (no sources required)
    const header_only = Target{
        .name = "myheaders",
        .kind = .header_only,
    };
    try header_only.validate();

    // Invalid: missing name
    const no_name = Target{
        .name = "",
        .kind = .executable,
        .sources = &[_][]const u8{"src/main.cpp"},
    };
    try testing.expectError(ValidateError.MissingName, no_name.validate());

    // Invalid: executable without sources
    const no_sources = Target{
        .name = "myapp",
        .kind = .executable,
    };
    try testing.expectError(ValidateError.NoSources, no_sources.validate());
}

test "Target.mergedForPlatform" {
    const allocator = testing.allocator;

    const target = Target{
        .name = "myapp",
        .kind = .executable,
        .sources = &[_][]const u8{"src/main.cpp"},
        .defines = &[_]Define{Define.flag("COMMON")},
        .platform_configs = &[_]PlatformConfig{
            .{
                .platform = PlatformMatcher.windows,
                .sources = &[_][]const u8{"src/win32.cpp"},
                .defines = &[_]Define{Define.flag("WIN32")},
            },
            .{
                .platform = PlatformMatcher.linux,
                .sources = &[_][]const u8{"src/linux.cpp"},
                .defines = &[_]Define{Define.flag("LINUX")},
            },
        },
    };

    // Test Linux merge
    const linux_platform = Platform{
        .arch = .x86_64,
        .vendor = .unknown,
        .os = .linux,
        .abi = .gnu,
    };

    var merged_linux = try target.mergedForPlatform(linux_platform, allocator);
    defer merged_linux.deinit();

    try testing.expectEqual(@as(usize, 2), merged_linux.sources.items.len);
    try testing.expectEqual(@as(usize, 2), merged_linux.defines.items.len);

    // Test Windows merge
    const windows_platform = Platform{
        .arch = .x86_64,
        .vendor = .pc,
        .os = .windows,
        .abi = .msvc,
    };

    var merged_windows = try target.mergedForPlatform(windows_platform, allocator);
    defer merged_windows.deinit();

    try testing.expectEqual(@as(usize, 2), merged_windows.sources.items.len);

    var has_win32 = false;
    for (merged_windows.defines.items) |d| {
        if (std.mem.eql(u8, d.name, "WIN32")) has_win32 = true;
    }
    try testing.expect(has_win32);
}
