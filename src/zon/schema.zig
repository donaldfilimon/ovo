//! Schema definitions and validation for build.zon files.
//!
//! This module defines all types used in the ovo package manager's build.zon format,
//! as well as validation functions for ensuring correctness.
const std = @import("std");

/// Error types for schema validation.
pub const ValidationError = error{
    MissingRequiredField,
    InvalidFieldType,
    InvalidEnumValue,
    InvalidVersion,
    InvalidGlobPattern,
    InvalidUrl,
    InvalidPath,
    DuplicateName,
    CircularDependency,
    IncompatibleOptions,
    EmptyArray,
    OutOfRange,
};

/// Semantic version following semver 2.0.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    prerelease: ?[]const u8 = null,
    build_metadata: ?[]const u8 = null,

    pub fn parse(allocator: std.mem.Allocator, str: []const u8) !Version {
        var version = Version{ .major = 0, .minor = 0, .patch = 0 };
        var remaining = str;

        // Handle build metadata first (+...)
        if (std.mem.indexOf(u8, remaining, "+")) |plus_idx| {
            version.build_metadata = try allocator.dupe(u8, remaining[plus_idx + 1 ..]);
            remaining = remaining[0..plus_idx];
        }

        // Handle prerelease (-...)
        if (std.mem.indexOf(u8, remaining, "-")) |dash_idx| {
            version.prerelease = try allocator.dupe(u8, remaining[dash_idx + 1 ..]);
            remaining = remaining[0..dash_idx];
        }

        // Parse major.minor.patch
        var parts = std.mem.splitScalar(u8, remaining, '.');
        version.major = std.fmt.parseInt(u32, parts.next() orelse return ValidationError.InvalidVersion, 10) catch
            return ValidationError.InvalidVersion;
        version.minor = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch
            return ValidationError.InvalidVersion;
        version.patch = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch
            return ValidationError.InvalidVersion;

        return version;
    }

    pub fn format(self: Version, writer: anytype) !void {
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
        if (self.prerelease) |pre| {
            try writer.print("-{s}", .{pre});
        }
        if (self.build_metadata) |meta| {
            try writer.print("+{s}", .{meta});
        }
    }

    pub fn deinit(self: *Version, allocator: std.mem.Allocator) void {
        if (self.prerelease) |pre| allocator.free(pre);
        if (self.build_metadata) |meta| allocator.free(meta);
        self.* = undefined;
    }
};

/// C++ standard versions.
pub const CppStandard = enum {
    cpp98,
    cpp03,
    cpp11,
    cpp14,
    cpp17,
    cpp20,
    cpp23,
    cpp26,

    pub fn toString(self: CppStandard) []const u8 {
        return switch (self) {
            .cpp98 => "c++98",
            .cpp03 => "c++03",
            .cpp11 => "c++11",
            .cpp14 => "c++14",
            .cpp17 => "c++17",
            .cpp20 => "c++20",
            .cpp23 => "c++23",
            .cpp26 => "c++26",
        };
    }

    pub fn fromString(str: []const u8) ?CppStandard {
        const map = std.StaticStringMap(CppStandard).initComptime(.{
            .{ "c++98", .cpp98 },
            .{ "cpp98", .cpp98 },
            .{ "98", .cpp98 },
            .{ "c++03", .cpp03 },
            .{ "cpp03", .cpp03 },
            .{ "03", .cpp03 },
            .{ "c++11", .cpp11 },
            .{ "cpp11", .cpp11 },
            .{ "11", .cpp11 },
            .{ "c++14", .cpp14 },
            .{ "cpp14", .cpp14 },
            .{ "14", .cpp14 },
            .{ "c++17", .cpp17 },
            .{ "cpp17", .cpp17 },
            .{ "17", .cpp17 },
            .{ "c++20", .cpp20 },
            .{ "cpp20", .cpp20 },
            .{ "20", .cpp20 },
            .{ "c++23", .cpp23 },
            .{ "cpp23", .cpp23 },
            .{ "23", .cpp23 },
            .{ "c++26", .cpp26 },
            .{ "cpp26", .cpp26 },
            .{ "26", .cpp26 },
        });
        return map.get(str);
    }
};

/// C standard versions.
pub const CStandard = enum {
    c89,
    c90,
    c99,
    c11,
    c17,
    c23,

    pub fn toString(self: CStandard) []const u8 {
        return switch (self) {
            .c89 => "c89",
            .c90 => "c90",
            .c99 => "c99",
            .c11 => "c11",
            .c17 => "c17",
            .c23 => "c23",
        };
    }

    pub fn fromString(str: []const u8) ?CStandard {
        const map = std.StaticStringMap(CStandard).initComptime(.{
            .{ "c89", .c89 },
            .{ "89", .c89 },
            .{ "c90", .c90 },
            .{ "90", .c90 },
            .{ "c99", .c99 },
            .{ "99", .c99 },
            .{ "c11", .c11 },
            .{ "11", .c11 },
            .{ "c17", .c17 },
            .{ "17", .c17 },
            .{ "c18", .c17 }, // C18 is an alias for C17
            .{ "c23", .c23 },
            .{ "23", .c23 },
        });
        return map.get(str);
    }
};

/// Compiler toolchain selection.
pub const Compiler = enum {
    gcc,
    clang,
    msvc,
    zig_cc,
    auto,

    pub fn toString(self: Compiler) []const u8 {
        return switch (self) {
            .gcc => "gcc",
            .clang => "clang",
            .msvc => "msvc",
            .zig_cc => "zig",
            .auto => "auto",
        };
    }

    pub fn fromString(str: []const u8) ?Compiler {
        const map = std.StaticStringMap(Compiler).initComptime(.{
            .{ "gcc", .gcc },
            .{ "g++", .gcc },
            .{ "clang", .clang },
            .{ "clang++", .clang },
            .{ "msvc", .msvc },
            .{ "cl", .msvc },
            .{ "zig", .zig_cc },
            .{ "zig-cc", .zig_cc },
            .{ "auto", .auto },
        });
        return map.get(str);
    }
};

/// Optimization level.
pub const Optimization = enum {
    none,
    debug,
    release_safe,
    release_fast,
    release_small,

    pub fn toString(self: Optimization) []const u8 {
        return switch (self) {
            .none => "none",
            .debug => "debug",
            .release_safe => "release-safe",
            .release_fast => "release-fast",
            .release_small => "release-small",
        };
    }

    pub fn fromString(str: []const u8) ?Optimization {
        const map = std.StaticStringMap(Optimization).initComptime(.{
            .{ "none", .none },
            .{ "O0", .none },
            .{ "debug", .debug },
            .{ "Og", .debug },
            .{ "release-safe", .release_safe },
            .{ "release_safe", .release_safe },
            .{ "O2", .release_safe },
            .{ "release-fast", .release_fast },
            .{ "release_fast", .release_fast },
            .{ "O3", .release_fast },
            .{ "release-small", .release_small },
            .{ "release_small", .release_small },
            .{ "Os", .release_small },
            .{ "Oz", .release_small },
        });
        return map.get(str);
    }
};

/// Target type.
pub const TargetType = enum {
    executable,
    static_library,
    shared_library,
    header_only,
    object,

    pub fn toString(self: TargetType) []const u8 {
        return switch (self) {
            .executable => "executable",
            .static_library => "static_library",
            .shared_library => "shared_library",
            .header_only => "header_only",
            .object => "object",
        };
    }

    pub fn fromString(str: []const u8) ?TargetType {
        const map = std.StaticStringMap(TargetType).initComptime(.{
            .{ "executable", .executable },
            .{ "exe", .executable },
            .{ "binary", .executable },
            .{ "static_library", .static_library },
            .{ "static", .static_library },
            .{ "staticlib", .static_library },
            .{ "shared_library", .shared_library },
            .{ "shared", .shared_library },
            .{ "dynamic", .shared_library },
            .{ "dylib", .shared_library },
            .{ "header_only", .header_only },
            .{ "headers", .header_only },
            .{ "interface", .header_only },
            .{ "object", .object },
            .{ "obj", .object },
        });
        return map.get(str);
    }
};

/// Operating system targets.
pub const OsTag = enum {
    windows,
    linux,
    macos,
    freebsd,
    netbsd,
    openbsd,
    ios,
    android,
    wasi,
    freestanding,
    any,

    pub fn fromString(str: []const u8) ?OsTag {
        const map = std.StaticStringMap(OsTag).initComptime(.{
            .{ "windows", .windows },
            .{ "win32", .windows },
            .{ "linux", .linux },
            .{ "macos", .macos },
            .{ "darwin", .macos },
            .{ "osx", .macos },
            .{ "freebsd", .freebsd },
            .{ "netbsd", .netbsd },
            .{ "openbsd", .openbsd },
            .{ "ios", .ios },
            .{ "android", .android },
            .{ "wasi", .wasi },
            .{ "freestanding", .freestanding },
            .{ "any", .any },
            .{ "*", .any },
        });
        return map.get(str);
    }
};

/// CPU architecture targets.
pub const CpuArch = enum {
    x86,
    x86_64,
    arm,
    aarch64,
    riscv32,
    riscv64,
    wasm32,
    wasm64,
    any,

    pub fn fromString(str: []const u8) ?CpuArch {
        const map = std.StaticStringMap(CpuArch).initComptime(.{
            .{ "x86", .x86 },
            .{ "i386", .x86 },
            .{ "i686", .x86 },
            .{ "x86_64", .x86_64 },
            .{ "amd64", .x86_64 },
            .{ "x64", .x86_64 },
            .{ "arm", .arm },
            .{ "arm32", .arm },
            .{ "aarch64", .aarch64 },
            .{ "arm64", .aarch64 },
            .{ "riscv32", .riscv32 },
            .{ "riscv64", .riscv64 },
            .{ "wasm32", .wasm32 },
            .{ "wasm64", .wasm64 },
            .{ "any", .any },
            .{ "*", .any },
        });
        return map.get(str);
    }
};

/// Platform-specific configuration filter.
pub const PlatformFilter = struct {
    os: ?OsTag = null,
    arch: ?CpuArch = null,
    compiler: ?Compiler = null,

    pub fn matches(self: PlatformFilter, target_os: OsTag, target_arch: CpuArch, target_compiler: Compiler) bool {
        if (self.os) |os| {
            if (os != .any and os != target_os) return false;
        }
        if (self.arch) |arch| {
            if (arch != .any and arch != target_arch) return false;
        }
        if (self.compiler) |comp| {
            if (comp != .auto and comp != target_compiler) return false;
        }
        return true;
    }
};

/// Source file specification with optional platform filter.
pub const SourceSpec = struct {
    /// Glob pattern or path (e.g., "src/**/*.cpp", "main.c")
    pattern: []const u8,
    /// Platform filter for conditional inclusion.
    platform: ?PlatformFilter = null,
    /// Exclude patterns.
    exclude: ?[]const []const u8 = null,

    pub fn deinit(self: *SourceSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
        if (self.exclude) |excl| {
            for (excl) |e| allocator.free(e);
            allocator.free(excl);
        }
        self.* = undefined;
    }
};

/// Include directory specification.
pub const IncludeSpec = struct {
    path: []const u8,
    system: bool = false,
    platform: ?PlatformFilter = null,

    pub fn deinit(self: *IncludeSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

/// Preprocessor define.
pub const DefineSpec = struct {
    name: []const u8,
    value: ?[]const u8 = null,
    platform: ?PlatformFilter = null,

    pub fn deinit(self: *DefineSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.value) |v| allocator.free(v);
        self.* = undefined;
    }
};

/// Compiler/linker flag.
pub const FlagSpec = struct {
    flag: []const u8,
    platform: ?PlatformFilter = null,
    compile_only: bool = false,
    link_only: bool = false,

    pub fn deinit(self: *FlagSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.flag);
        self.* = undefined;
    }
};

/// Dependency source type.
pub const DependencySource = union(enum) {
    /// Git repository dependency.
    git: struct {
        url: []const u8,
        tag: ?[]const u8 = null,
        branch: ?[]const u8 = null,
        commit: ?[]const u8 = null,
    },
    /// URL to archive (tar.gz, zip).
    url: struct {
        location: []const u8,
        hash: ?[]const u8 = null,
    },
    /// Local path dependency.
    path: []const u8,
    /// vcpkg package.
    vcpkg: struct {
        name: []const u8,
        version: ?[]const u8 = null,
        features: ?[]const []const u8 = null,
    },
    /// Conan package.
    conan: struct {
        name: []const u8,
        version: []const u8,
        options: ?[]const []const u8 = null,
    },
    /// System library (pkg-config, cmake find).
    system: struct {
        name: []const u8,
        /// Fallback if system library not found.
        fallback: ?*Dependency = null,
    },

    pub fn deinit(self: *DependencySource, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .git => |*g| {
                allocator.free(g.url);
                if (g.tag) |t| allocator.free(t);
                if (g.branch) |b| allocator.free(b);
                if (g.commit) |c| allocator.free(c);
            },
            .url => |*u| {
                allocator.free(u.location);
                if (u.hash) |h| allocator.free(h);
            },
            .path => |p| allocator.free(p),
            .vcpkg => |*v| {
                allocator.free(v.name);
                if (v.version) |ver| allocator.free(ver);
                if (v.features) |feats| {
                    for (feats) |f| allocator.free(f);
                    allocator.free(feats);
                }
            },
            .conan => |*c| {
                allocator.free(c.name);
                allocator.free(c.version);
                if (c.options) |opts| {
                    for (opts) |o| allocator.free(o);
                    allocator.free(opts);
                }
            },
            .system => |*s| {
                allocator.free(s.name);
                if (s.fallback) |fb| {
                    fb.deinit(allocator);
                    allocator.destroy(fb);
                }
            },
        }
        self.* = undefined;
    }
};

/// Dependency specification.
pub const Dependency = struct {
    name: []const u8,
    source: DependencySource,
    /// Optional: only include if feature is enabled.
    feature: ?[]const u8 = null,
    /// Build options.
    build_options: ?[]const []const u8 = null,
    /// Components to use (for multi-component libraries).
    components: ?[]const []const u8 = null,
    /// Link as static or shared.
    link_static: ?bool = null,

    pub fn deinit(self: *Dependency, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.source.deinit(allocator);
        if (self.feature) |f| allocator.free(f);
        if (self.build_options) |opts| {
            for (opts) |o| allocator.free(o);
            allocator.free(opts);
        }
        if (self.components) |comps| {
            for (comps) |c| allocator.free(c);
            allocator.free(comps);
        }
        self.* = undefined;
    }
};

/// Build target specification.
pub const Target = struct {
    name: []const u8,
    target_type: TargetType,
    sources: []SourceSpec,
    includes: ?[]IncludeSpec = null,
    defines: ?[]DefineSpec = null,
    flags: ?[]FlagSpec = null,
    link_libraries: ?[]const []const u8 = null,
    dependencies: ?[]const []const u8 = null,
    cpp_standard: ?CppStandard = null,
    c_standard: ?CStandard = null,
    optimization: ?Optimization = null,
    /// Output name override.
    output_name: ?[]const u8 = null,
    /// Installation directory.
    install_dir: ?[]const u8 = null,
    /// Platform filter for entire target.
    platform: ?PlatformFilter = null,
    /// Features required for this target.
    required_features: ?[]const []const u8 = null,

    pub fn deinit(self: *Target, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.sources) |*s| s.deinit(allocator);
        allocator.free(self.sources);
        if (self.includes) |incs| {
            for (incs) |*i| i.deinit(allocator);
            allocator.free(incs);
        }
        if (self.defines) |defs| {
            for (defs) |*d| d.deinit(allocator);
            allocator.free(defs);
        }
        if (self.flags) |flgs| {
            for (flgs) |*f| f.deinit(allocator);
            allocator.free(flgs);
        }
        if (self.link_libraries) |libs| {
            for (libs) |l| allocator.free(l);
            allocator.free(libs);
        }
        if (self.dependencies) |deps| {
            for (deps) |d| allocator.free(d);
            allocator.free(deps);
        }
        if (self.output_name) |n| allocator.free(n);
        if (self.install_dir) |d| allocator.free(d);
        if (self.required_features) |feats| {
            for (feats) |f| allocator.free(f);
            allocator.free(feats);
        }
        self.* = undefined;
    }
};

/// Test specification.
pub const TestSpec = struct {
    name: []const u8,
    sources: []SourceSpec,
    dependencies: ?[]const []const u8 = null,
    /// Test framework (gtest, catch2, doctest, etc.).
    framework: ?[]const u8 = null,
    /// Test arguments.
    args: ?[]const []const u8 = null,
    /// Environment variables.
    env: ?[]const []const u8 = null,
    /// Working directory.
    working_dir: ?[]const u8 = null,
    /// Timeout in seconds.
    timeout: ?u32 = null,

    pub fn deinit(self: *TestSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.sources) |*s| s.deinit(allocator);
        allocator.free(self.sources);
        if (self.dependencies) |deps| {
            for (deps) |d| allocator.free(d);
            allocator.free(deps);
        }
        if (self.framework) |f| allocator.free(f);
        if (self.args) |a| {
            for (a) |arg| allocator.free(arg);
            allocator.free(a);
        }
        if (self.env) |e| {
            for (e) |ev| allocator.free(ev);
            allocator.free(e);
        }
        if (self.working_dir) |w| allocator.free(w);
        self.* = undefined;
    }
};

/// Benchmark specification.
pub const BenchmarkSpec = struct {
    name: []const u8,
    sources: []SourceSpec,
    dependencies: ?[]const []const u8 = null,
    /// Benchmark framework (google-benchmark, catch2, etc.).
    framework: ?[]const u8 = null,
    /// Iterations.
    iterations: ?u32 = null,
    /// Warmup iterations.
    warmup: ?u32 = null,

    pub fn deinit(self: *BenchmarkSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.sources) |*s| s.deinit(allocator);
        allocator.free(self.sources);
        if (self.dependencies) |deps| {
            for (deps) |d| allocator.free(d);
            allocator.free(deps);
        }
        if (self.framework) |f| allocator.free(f);
        self.* = undefined;
    }
};

/// Example specification.
pub const ExampleSpec = struct {
    name: []const u8,
    sources: []SourceSpec,
    dependencies: ?[]const []const u8 = null,
    description: ?[]const u8 = null,

    pub fn deinit(self: *ExampleSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.sources) |*s| s.deinit(allocator);
        allocator.free(self.sources);
        if (self.dependencies) |deps| {
            for (deps) |d| allocator.free(d);
            allocator.free(deps);
        }
        if (self.description) |d| allocator.free(d);
        self.* = undefined;
    }
};

/// Script hook type.
pub const HookType = enum {
    pre_build,
    post_build,
    pre_test,
    post_test,
    pre_install,
    post_install,
    clean,

    pub fn fromString(str: []const u8) ?HookType {
        const map = std.StaticStringMap(HookType).initComptime(.{
            .{ "pre_build", .pre_build },
            .{ "pre-build", .pre_build },
            .{ "post_build", .post_build },
            .{ "post-build", .post_build },
            .{ "pre_test", .pre_test },
            .{ "pre-test", .pre_test },
            .{ "post_test", .post_test },
            .{ "post-test", .post_test },
            .{ "pre_install", .pre_install },
            .{ "pre-install", .pre_install },
            .{ "post_install", .post_install },
            .{ "post-install", .post_install },
            .{ "clean", .clean },
        });
        return map.get(str);
    }
};

/// Script specification.
pub const ScriptSpec = struct {
    name: []const u8,
    command: []const u8,
    args: ?[]const []const u8 = null,
    env: ?[]const []const u8 = null,
    working_dir: ?[]const u8 = null,
    hook: ?HookType = null,

    pub fn deinit(self: *ScriptSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.command);
        if (self.args) |a| {
            for (a) |arg| allocator.free(arg);
            allocator.free(a);
        }
        if (self.env) |e| {
            for (e) |ev| allocator.free(ev);
            allocator.free(e);
        }
        if (self.working_dir) |w| allocator.free(w);
        self.* = undefined;
    }
};

/// Build profile.
pub const Profile = struct {
    name: []const u8,
    /// Inherits from another profile.
    inherits: ?[]const u8 = null,
    optimization: ?Optimization = null,
    cpp_standard: ?CppStandard = null,
    c_standard: ?CStandard = null,
    defines: ?[]DefineSpec = null,
    flags: ?[]FlagSpec = null,
    /// Sanitizers to enable.
    sanitizers: ?[]const []const u8 = null,
    /// Enable debug info.
    debug_info: ?bool = null,
    /// Enable LTO.
    lto: ?bool = null,
    /// Enable PIC.
    pic: ?bool = null,

    pub fn deinit(self: *Profile, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.inherits) |i| allocator.free(i);
        if (self.defines) |defs| {
            for (defs) |*d| d.deinit(allocator);
            allocator.free(defs);
        }
        if (self.flags) |flgs| {
            for (flgs) |*f| f.deinit(allocator);
            allocator.free(flgs);
        }
        if (self.sanitizers) |sans| {
            for (sans) |s| allocator.free(s);
            allocator.free(sans);
        }
        self.* = undefined;
    }
};

/// Cross-compilation target.
pub const CrossTarget = struct {
    name: []const u8,
    os: OsTag,
    arch: CpuArch,
    /// Toolchain file or prefix.
    toolchain: ?[]const u8 = null,
    /// Sysroot path.
    sysroot: ?[]const u8 = null,
    /// Additional defines for cross-compilation.
    defines: ?[]DefineSpec = null,
    /// Additional flags for cross-compilation.
    flags: ?[]FlagSpec = null,

    pub fn deinit(self: *CrossTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.toolchain) |t| allocator.free(t);
        if (self.sysroot) |s| allocator.free(s);
        if (self.defines) |defs| {
            for (defs) |*d| d.deinit(allocator);
            allocator.free(defs);
        }
        if (self.flags) |flgs| {
            for (flgs) |*f| f.deinit(allocator);
            allocator.free(flgs);
        }
        self.* = undefined;
    }
};

/// Feature (optional dependency/functionality).
pub const Feature = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    /// Dependencies enabled by this feature.
    dependencies: ?[]const []const u8 = null,
    /// Defines enabled by this feature.
    defines: ?[]DefineSpec = null,
    /// Default state.
    default: bool = false,
    /// Implies other features.
    implies: ?[]const []const u8 = null,
    /// Conflicts with other features.
    conflicts: ?[]const []const u8 = null,

    pub fn deinit(self: *Feature, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.description) |d| allocator.free(d);
        if (self.dependencies) |deps| {
            for (deps) |d| allocator.free(d);
            allocator.free(deps);
        }
        if (self.defines) |defs| {
            for (defs) |*d| d.deinit(allocator);
            allocator.free(defs);
        }
        if (self.implies) |imp| {
            for (imp) |i| allocator.free(i);
            allocator.free(imp);
        }
        if (self.conflicts) |conf| {
            for (conf) |c| allocator.free(c);
            allocator.free(conf);
        }
        self.* = undefined;
    }
};

/// Module settings for C++20 modules.
pub const ModuleSettings = struct {
    /// Enable module support.
    enabled: bool = false,
    /// Module interface files.
    interfaces: ?[]SourceSpec = null,
    /// Module partition files.
    partitions: ?[]SourceSpec = null,
    /// Precompiled module cache directory.
    cache_dir: ?[]const u8 = null,

    pub fn deinit(self: *ModuleSettings, allocator: std.mem.Allocator) void {
        if (self.interfaces) |ifaces| {
            for (ifaces) |*i| i.deinit(allocator);
            allocator.free(ifaces);
        }
        if (self.partitions) |parts| {
            for (parts) |*p| p.deinit(allocator);
            allocator.free(parts);
        }
        if (self.cache_dir) |c| allocator.free(c);
        self.* = undefined;
    }
};

/// Default build settings.
pub const Defaults = struct {
    cpp_standard: ?CppStandard = null,
    c_standard: ?CStandard = null,
    compiler: ?Compiler = null,
    optimization: ?Optimization = null,
    /// Global include directories.
    includes: ?[]IncludeSpec = null,
    /// Global defines.
    defines: ?[]DefineSpec = null,
    /// Global flags.
    flags: ?[]FlagSpec = null,

    pub fn deinit(self: *Defaults, allocator: std.mem.Allocator) void {
        if (self.includes) |incs| {
            for (incs) |*i| i.deinit(allocator);
            allocator.free(incs);
        }
        if (self.defines) |defs| {
            for (defs) |*d| d.deinit(allocator);
            allocator.free(defs);
        }
        if (self.flags) |flgs| {
            for (flgs) |*f| f.deinit(allocator);
            allocator.free(flgs);
        }
        self.* = undefined;
    }
};

/// Root project model.
pub const Project = struct {
    /// Package name.
    name: []const u8,
    /// Package version.
    version: Version,
    /// Package description.
    description: ?[]const u8 = null,
    /// License identifier (SPDX).
    license: ?[]const u8 = null,
    /// Authors.
    authors: ?[]const []const u8 = null,
    /// Repository URL.
    repository: ?[]const u8 = null,
    /// Homepage URL.
    homepage: ?[]const u8 = null,
    /// Documentation URL.
    documentation: ?[]const u8 = null,
    /// Keywords.
    keywords: ?[]const []const u8 = null,
    /// Minimum ovo version required.
    min_ovo_version: ?[]const u8 = null,

    /// Build defaults.
    defaults: ?Defaults = null,

    /// Build targets.
    targets: []Target,

    /// Dependencies.
    dependencies: ?[]Dependency = null,

    /// Tests.
    tests: ?[]TestSpec = null,

    /// Benchmarks.
    benchmarks: ?[]BenchmarkSpec = null,

    /// Examples.
    examples: ?[]ExampleSpec = null,

    /// Scripts.
    scripts: ?[]ScriptSpec = null,

    /// Profiles.
    profiles: ?[]Profile = null,

    /// Cross-compilation targets.
    cross_targets: ?[]CrossTarget = null,

    /// Features.
    features: ?[]Feature = null,

    /// Module settings.
    modules: ?ModuleSettings = null,

    /// Workspace members (for workspace root).
    workspace_members: ?[]const []const u8 = null,

    pub fn deinit(self: *Project, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.version.deinit(allocator);
        if (self.description) |d| allocator.free(d);
        if (self.license) |l| allocator.free(l);
        if (self.authors) |auths| {
            for (auths) |a| allocator.free(a);
            allocator.free(auths);
        }
        if (self.repository) |r| allocator.free(r);
        if (self.homepage) |h| allocator.free(h);
        if (self.documentation) |d| allocator.free(d);
        if (self.keywords) |kws| {
            for (kws) |k| allocator.free(k);
            allocator.free(kws);
        }
        if (self.min_ovo_version) |m| allocator.free(m);
        if (self.defaults) |*d| d.deinit(allocator);
        for (self.targets) |*t| t.deinit(allocator);
        allocator.free(self.targets);
        if (self.dependencies) |deps| {
            for (deps) |*d| d.deinit(allocator);
            allocator.free(deps);
        }
        if (self.tests) |tsts| {
            for (tsts) |*t| t.deinit(allocator);
            allocator.free(tsts);
        }
        if (self.benchmarks) |bms| {
            for (bms) |*b| b.deinit(allocator);
            allocator.free(bms);
        }
        if (self.examples) |exs| {
            for (exs) |*e| e.deinit(allocator);
            allocator.free(exs);
        }
        if (self.scripts) |scrs| {
            for (scrs) |*s| s.deinit(allocator);
            allocator.free(scrs);
        }
        if (self.profiles) |profs| {
            for (profs) |*p| p.deinit(allocator);
            allocator.free(profs);
        }
        if (self.cross_targets) |cts| {
            for (cts) |*c| c.deinit(allocator);
            allocator.free(cts);
        }
        if (self.features) |feats| {
            for (feats) |*f| f.deinit(allocator);
            allocator.free(feats);
        }
        if (self.modules) |*m| m.deinit(allocator);
        if (self.workspace_members) |wms| {
            for (wms) |w| allocator.free(w);
            allocator.free(wms);
        }
        self.* = undefined;
    }
};

/// Validation context for collecting errors.
pub const ValidationContext = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList([]const u8),
    warnings: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) ValidationContext {
        return .{
            .allocator = allocator,
            .errors = std.ArrayList([]const u8).init(allocator),
            .warnings = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ValidationContext) void {
        for (self.errors.items) |e| self.allocator.free(e);
        self.errors.deinit();
        for (self.warnings.items) |w| self.allocator.free(w);
        self.warnings.deinit();
    }

    pub fn addError(self: *ValidationContext, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.errors.append(msg);
    }

    pub fn addWarning(self: *ValidationContext, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.warnings.append(msg);
    }

    pub fn hasErrors(self: *const ValidationContext) bool {
        return self.errors.items.len > 0;
    }
};

/// Validate a Project for correctness.
pub fn validateProject(project: *const Project, ctx: *ValidationContext) !void {
    // Validate name
    if (project.name.len == 0) {
        try ctx.addError("Project name cannot be empty", .{});
    } else if (!isValidIdentifier(project.name)) {
        try ctx.addError("Project name '{s}' is not a valid identifier", .{project.name});
    }

    // Validate targets
    if (project.targets.len == 0) {
        try ctx.addError("Project must have at least one target", .{});
    }

    var target_names = std.StringHashMap(void).init(ctx.allocator);
    defer target_names.deinit();

    for (project.targets) |*target| {
        try validateTarget(target, ctx, &target_names);
    }

    // Validate dependencies
    if (project.dependencies) |deps| {
        var dep_names = std.StringHashMap(void).init(ctx.allocator);
        defer dep_names.deinit();

        for (deps) |*dep| {
            try validateDependency(dep, ctx, &dep_names);
        }
    }

    // Validate features
    if (project.features) |features| {
        var feature_names = std.StringHashMap(void).init(ctx.allocator);
        defer feature_names.deinit();

        for (features) |*feature| {
            try validateFeature(feature, ctx, &feature_names);
        }
    }

    // Validate profiles
    if (project.profiles) |profiles| {
        var profile_names = std.StringHashMap(void).init(ctx.allocator);
        defer profile_names.deinit();

        for (profiles) |*profile| {
            if (profile.name.len == 0) {
                try ctx.addError("Profile name cannot be empty", .{});
            } else if (profile_names.contains(profile.name)) {
                try ctx.addError("Duplicate profile name: '{s}'", .{profile.name});
            } else {
                try profile_names.put(profile.name, {});
            }
        }
    }
}

fn validateTarget(target: *const Target, ctx: *ValidationContext, names: *std.StringHashMap(void)) !void {
    if (target.name.len == 0) {
        try ctx.addError("Target name cannot be empty", .{});
    } else if (names.contains(target.name)) {
        try ctx.addError("Duplicate target name: '{s}'", .{target.name});
    } else {
        try names.put(target.name, {});
    }

    if (target.sources.len == 0 and target.target_type != .header_only) {
        try ctx.addError("Target '{s}' must have at least one source file (unless header-only)", .{target.name});
    }

    for (target.sources) |source| {
        if (source.pattern.len == 0) {
            try ctx.addError("Target '{s}' has empty source pattern", .{target.name});
        }
    }
}

fn validateDependency(dep: *const Dependency, ctx: *ValidationContext, names: *std.StringHashMap(void)) !void {
    if (dep.name.len == 0) {
        try ctx.addError("Dependency name cannot be empty", .{});
    } else if (names.contains(dep.name)) {
        try ctx.addError("Duplicate dependency name: '{s}'", .{dep.name});
    } else {
        try names.put(dep.name, {});
    }

    switch (dep.source) {
        .git => |git| {
            if (git.url.len == 0) {
                try ctx.addError("Dependency '{s}' has empty git URL", .{dep.name});
            }
            if (git.tag == null and git.branch == null and git.commit == null) {
                try ctx.addWarning("Dependency '{s}' has no version specifier (tag, branch, or commit)", .{dep.name});
            }
        },
        .url => |url| {
            if (url.location.len == 0) {
                try ctx.addError("Dependency '{s}' has empty URL", .{dep.name});
            }
        },
        .path => |path| {
            if (path.len == 0) {
                try ctx.addError("Dependency '{s}' has empty path", .{dep.name});
            }
        },
        .vcpkg => |vcpkg| {
            if (vcpkg.name.len == 0) {
                try ctx.addError("Dependency '{s}' has empty vcpkg package name", .{dep.name});
            }
        },
        .conan => |conan| {
            if (conan.name.len == 0) {
                try ctx.addError("Dependency '{s}' has empty conan package name", .{dep.name});
            }
            if (conan.version.len == 0) {
                try ctx.addError("Dependency '{s}' has empty conan version", .{dep.name});
            }
        },
        .system => |sys| {
            if (sys.name.len == 0) {
                try ctx.addError("Dependency '{s}' has empty system library name", .{dep.name});
            }
        },
    }
}

fn validateFeature(feature: *const Feature, ctx: *ValidationContext, names: *std.StringHashMap(void)) !void {
    if (feature.name.len == 0) {
        try ctx.addError("Feature name cannot be empty", .{});
    } else if (names.contains(feature.name)) {
        try ctx.addError("Duplicate feature name: '{s}'", .{feature.name});
    } else {
        try names.put(feature.name, {});
    }

    // Check for self-reference in implies
    if (feature.implies) |implies| {
        for (implies) |imp| {
            if (std.mem.eql(u8, imp, feature.name)) {
                try ctx.addError("Feature '{s}' cannot imply itself", .{feature.name});
            }
        }
    }

    // Check for self-reference in conflicts
    if (feature.conflicts) |conflicts| {
        for (conflicts) |conf| {
            if (std.mem.eql(u8, conf, feature.name)) {
                try ctx.addError("Feature '{s}' cannot conflict with itself", .{feature.name});
            }
        }
    }
}

/// Check if a string is a valid identifier.
fn isValidIdentifier(str: []const u8) bool {
    if (str.len == 0) return false;

    const first = str[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;

    for (str[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }

    return true;
}

/// Validate a glob pattern for basic correctness.
pub fn isValidGlobPattern(pattern: []const u8) bool {
    if (pattern.len == 0) return false;

    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        // Check for invalid sequences
        if (c == '*' and i + 1 < pattern.len and pattern[i + 1] == '*') {
            // ** is valid for recursive glob
            if (i + 2 < pattern.len and pattern[i + 2] != '/') {
                // ** must be followed by / or end of string
                if (i + 2 < pattern.len) return false;
            }
            i += 1; // Skip second *
        }
    }

    return true;
}

test "version parsing" {
    const allocator = std.testing.allocator;

    var v1 = try Version.parse(allocator, "1.2.3");
    defer v1.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 1), v1.major);
    try std.testing.expectEqual(@as(u32, 2), v1.minor);
    try std.testing.expectEqual(@as(u32, 3), v1.patch);

    var v2 = try Version.parse(allocator, "2.0.0-beta.1+build.123");
    defer v2.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 2), v2.major);
    try std.testing.expectEqualStrings("beta.1", v2.prerelease.?);
    try std.testing.expectEqualStrings("build.123", v2.build_metadata.?);
}

test "enum from string" {
    try std.testing.expectEqual(CppStandard.cpp17, CppStandard.fromString("c++17").?);
    try std.testing.expectEqual(CppStandard.cpp20, CppStandard.fromString("20").?);
    try std.testing.expectEqual(Compiler.clang, Compiler.fromString("clang++").?);
    try std.testing.expectEqual(Optimization.release_fast, Optimization.fromString("O3").?);
}

test "validation context" {
    const allocator = std.testing.allocator;
    var ctx = ValidationContext.init(allocator);
    defer ctx.deinit();

    try ctx.addError("Test error: {s}", .{"something"});
    try ctx.addWarning("Test warning: {d}", .{42});

    try std.testing.expect(ctx.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), ctx.errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.warnings.items.len);
}

test "valid identifier" {
    try std.testing.expect(isValidIdentifier("my_project"));
    try std.testing.expect(isValidIdentifier("MyProject123"));
    try std.testing.expect(isValidIdentifier("_private"));
    try std.testing.expect(isValidIdentifier("my-project"));
    try std.testing.expect(!isValidIdentifier(""));
    try std.testing.expect(!isValidIdentifier("123abc"));
    try std.testing.expect(!isValidIdentifier("my project"));
}

test "valid glob pattern" {
    try std.testing.expect(isValidGlobPattern("*.cpp"));
    try std.testing.expect(isValidGlobPattern("src/**/*.cpp"));
    try std.testing.expect(isValidGlobPattern("main.c"));
    try std.testing.expect(!isValidGlobPattern(""));
}
