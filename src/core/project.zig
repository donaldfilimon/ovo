//! Project model with complete ZON configuration support.
//!
//! This module defines the `Project` type which represents a complete ovo
//! project configuration. It includes all settings typically found in a
//! build manifest: project metadata, targets, dependencies, profiles, features,
//! and more.
//!
//! ## Configuration Format
//! Projects are configured via ZON (Zig Object Notation) files, typically
//! named `ovo.zon` or `build.ovo.zon` in the project root.
//!
//! ## Example
//! ```zig
//! const project = Project{
//!     .name = "myapp",
//!     .version = .{ .major = 1, .minor = 0, .patch = 0 },
//!     .targets = &.{
//!         .{
//!             .name = "myapp",
//!             .kind = .executable,
//!             .sources = &.{"src/main.cpp"},
//!         },
//!     },
//!     .dependencies = &.{
//!         .{
//!             .name = "zlib",
//!             .source = .{ .vcpkg = .{ .name = "zlib" } },
//!         },
//!     },
//! };
//! ```

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

// Import core modules
const platform_mod = @import("platform.zig");
const standard_mod = @import("standard.zig");
const profile_mod = @import("profile.zig");
const dependency_mod = @import("dependency.zig");
const target_mod = @import("target.zig");
const workspace_mod = @import("workspace.zig");
const validation = @import("validation.zig");

// Re-export commonly used types
pub const Platform = platform_mod.Platform;
pub const Os = platform_mod.Os;
pub const Arch = platform_mod.Arch;
pub const CStandard = standard_mod.CStandard;
pub const CppStandard = standard_mod.CppStandard;
pub const Compiler = standard_mod.Compiler;
pub const Profile = profile_mod.Profile;
pub const Dependency = dependency_mod.Dependency;
pub const Target = target_mod.Target;
pub const TargetKind = target_mod.TargetKind;
pub const Workspace = workspace_mod.Workspace;

/// Semantic version with optional prerelease and build metadata.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    prerelease: ?[]const u8 = null,
    build_metadata: ?[]const u8 = null,

    const Self = @This();

    /// Creates a simple version without prerelease or build metadata.
    pub fn init(major: u32, minor: u32, patch: u32) Self {
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    /// Parses a semantic version string (e.g., "1.2.3", "1.0.0-alpha+build").
    pub fn parse(str: []const u8) ParseError!Self {
        var version = Self{ .major = 0, .minor = 0, .patch = 0 };

        // Find prerelease marker
        const prerelease_start = std.mem.indexOfScalar(u8, str, '-');
        const build_start = std.mem.indexOfScalar(u8, str, '+');

        // Determine where the version numbers end
        const version_end = prerelease_start orelse build_start orelse str.len;
        const version_str = str[0..version_end];

        // Parse major.minor.patch
        var parts = std.mem.splitScalar(u8, version_str, '.');
        const major_str = parts.next() orelse return ParseError.InvalidVersion;
        version.major = std.fmt.parseInt(u32, major_str, 10) catch return ParseError.InvalidVersion;

        if (parts.next()) |minor_str| {
            version.minor = std.fmt.parseInt(u32, minor_str, 10) catch return ParseError.InvalidVersion;
        }

        if (parts.next()) |patch_str| {
            version.patch = std.fmt.parseInt(u32, patch_str, 10) catch return ParseError.InvalidVersion;
        }

        // Parse prerelease
        if (prerelease_start) |start| {
            const end = build_start orelse str.len;
            if (start + 1 < end) {
                version.prerelease = str[start + 1 .. end];
            }
        }

        // Parse build metadata
        if (build_start) |start| {
            if (start + 1 < str.len) {
                version.build_metadata = str[start + 1 ..];
            }
        }

        return version;
    }

    /// Formats the version as a string.
    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });

        if (self.prerelease) |pre| {
            try writer.print("-{s}", .{pre});
        }

        if (self.build_metadata) |build| {
            try writer.print("+{s}", .{build});
        }
    }

    /// Writes the version to a buffer.
    pub fn toString(self: Self, buf: []u8) []u8 {
        var writer = std.Io.Writer.fixed(buf);
        self.format("", .{}, &writer) catch {};
        return buf[0..writer.end];
    }

    /// Compares two versions (ignoring build metadata per semver spec).
    pub fn compare(self: Self, other: Self) std.math.Order {
        if (self.major != other.major) {
            return std.math.order(self.major, other.major);
        }
        if (self.minor != other.minor) {
            return std.math.order(self.minor, other.minor);
        }
        if (self.patch != other.patch) {
            return std.math.order(self.patch, other.patch);
        }

        // Prerelease comparison (presence of prerelease is lower precedence)
        const self_has_pre = self.prerelease != null;
        const other_has_pre = other.prerelease != null;

        if (self_has_pre and !other_has_pre) return .lt;
        if (!self_has_pre and other_has_pre) return .gt;

        if (self.prerelease) |self_pre| {
            if (other.prerelease) |other_pre| {
                return std.mem.order(u8, self_pre, other_pre);
            }
        }

        return .eq;
    }

    /// Returns true if this version is compatible with the given constraint.
    pub fn isCompatibleWith(self: Self, constraint: Self) bool {
        // For semver, same major version with >= minor.patch is compatible
        if (self.major != constraint.major) return false;
        if (self.minor < constraint.minor) return false;
        if (self.minor == constraint.minor and self.patch < constraint.patch) return false;
        return true;
    }
};

/// Feature flag definition.
pub const Feature = struct {
    /// Feature name (used as identifier).
    name: []const u8,
    /// Human-readable description.
    description: ?[]const u8 = null,
    /// Whether this feature is enabled by default.
    default: bool = false,
    /// Dependencies that are only included when this feature is enabled.
    dependencies: []const []const u8 = &.{},
    /// Defines that are added when this feature is enabled.
    defines: []const []const u8 = &.{},
    /// Additional sources compiled when this feature is enabled.
    sources: []const []const u8 = &.{},
    /// Features that this feature implies (automatically enables).
    implies: []const []const u8 = &.{},
    /// Features that this feature conflicts with.
    conflicts_with: []const []const u8 = &.{},

    const Self = @This();

    /// Validates the feature definition.
    pub fn validate(self: Self) ValidateError!void {
        if (self.name.len == 0) {
            return ValidateError.MissingName;
        }

        // Check for self-reference in implies
        for (self.implies) |implied| {
            if (std.mem.eql(u8, implied, self.name)) {
                return ValidateError.SelfReference;
            }
        }

        // Check for self-reference in conflicts
        for (self.conflicts_with) |conflict| {
            if (std.mem.eql(u8, conflict, self.name)) {
                return ValidateError.SelfReference;
            }
        }
    }
};

/// Project metadata.
pub const Metadata = struct {
    /// Project authors.
    authors: []const []const u8 = &.{},
    /// Project license (SPDX identifier).
    license: ?[]const u8 = null,
    /// Project homepage URL.
    homepage: ?[]const u8 = null,
    /// Project repository URL.
    repository: ?[]const u8 = null,
    /// Project documentation URL.
    documentation: ?[]const u8 = null,
    /// Short description.
    description: ?[]const u8 = null,
    /// Long description or readme content.
    readme: ?[]const u8 = null,
    /// Keywords for discoverability.
    keywords: []const []const u8 = &.{},
    /// Categories.
    categories: []const []const u8 = &.{},
};

/// Script hook definition.
pub const Script = struct {
    /// Script command to run.
    command: []const u8,
    /// Working directory (relative to project root).
    cwd: ?[]const u8 = null,
    /// Environment variables.
    env: []const EnvVar = &.{},
    /// Whether to stop the build on script failure.
    fail_on_error: bool = true,

    pub const EnvVar = struct {
        name: []const u8,
        value: []const u8,
    };
};

/// Build hooks for running scripts at various points.
pub const Hooks = struct {
    /// Run before any build steps.
    pre_build: []const Script = &.{},
    /// Run after successful build.
    post_build: []const Script = &.{},
    /// Run before tests.
    pre_test: []const Script = &.{},
    /// Run after tests.
    post_test: []const Script = &.{},
    /// Run before installation.
    pre_install: []const Script = &.{},
    /// Run after installation.
    post_install: []const Script = &.{},
};

/// Package manager configuration.
pub const PackageManagerConfig = struct {
    /// vcpkg configuration.
    vcpkg: ?VcpkgConfig = null,
    /// Conan configuration.
    conan: ?ConanConfig = null,

    pub const VcpkgConfig = struct {
        /// Path to vcpkg root.
        root: ?[]const u8 = null,
        /// Triplet override.
        triplet: ?[]const u8 = null,
        /// Overlay ports paths.
        overlay_ports: []const []const u8 = &.{},
        /// Overlay triplets paths.
        overlay_triplets: []const []const u8 = &.{},
        /// Features to enable globally.
        features: []const []const u8 = &.{},
    };

    pub const ConanConfig = struct {
        /// Conan profile name.
        profile: ?[]const u8 = null,
        /// Remote URL.
        remote: ?[]const u8 = null,
        /// Build policy.
        build_policy: ?[]const u8 = null,
    };
};

/// Complete project configuration.
pub const Project = struct {
    /// Project name (identifier).
    name: []const u8,
    /// Project version.
    version: ?Version = null,
    /// Version string (alternative to structured version).
    version_string: ?[]const u8 = null,
    /// Project metadata.
    metadata: Metadata = .{},
    /// Minimum ovo version required.
    minimum_ovo_version: ?[]const u8 = null,
    /// Default C standard for all targets.
    c_standard: ?CStandard = null,
    /// Default C++ standard for all targets.
    cpp_standard: ?CppStandard = null,
    /// Build targets.
    targets: []const Target = &.{},
    /// External dependencies.
    dependencies: []const Dependency = &.{},
    /// Build profiles.
    profiles: []const Profile = &.{},
    /// Default profile name.
    default_profile: ?[]const u8 = null,
    /// Feature flags.
    features: []const Feature = &.{},
    /// Default enabled features.
    default_features: []const []const u8 = &.{},
    /// Build hooks.
    hooks: Hooks = .{},
    /// Package manager configuration.
    package_manager: PackageManagerConfig = .{},
    /// Output/build directory.
    output_dir: ?[]const u8 = null,
    /// Install prefix.
    install_prefix: ?[]const u8 = null,
    /// Source directory (default: "src").
    source_dir: ?[]const u8 = null,
    /// Include directory (default: "include").
    include_dir: ?[]const u8 = null,
    /// Test directory (default: "test" or "tests").
    test_dir: ?[]const u8 = null,
    /// Example directory.
    example_dir: ?[]const u8 = null,
    /// Benchmark directory.
    benchmark_dir: ?[]const u8 = null,
    /// Additional configuration files to include.
    includes: []const []const u8 = &.{},
    /// Workspace configuration (if this is a workspace root).
    workspace: ?Workspace = null,
    /// Custom variables for use in configuration.
    variables: []const Variable = &.{},

    pub const Variable = struct {
        name: []const u8,
        value: []const u8,
        description: ?[]const u8 = null,
    };

    const Self = @This();

    /// Returns the effective version string.
    pub fn effectiveVersion(self: Self) ?[]const u8 {
        if (self.version_string) |v| return v;
        if (self.version) |v| {
            var buf: [64]u8 = undefined;
            const str = v.toString(&buf);
            // Note: This returns a stack-allocated string, caller should copy
            return str;
        }
        return null;
    }

    /// Returns the effective C++ standard for a target.
    pub fn effectiveCppStandard(self: Self, tgt: Target) ?CppStandard {
        return tgt.cpp_standard orelse self.cpp_standard;
    }

    /// Returns the effective C standard for a target.
    pub fn effectiveCStandard(self: Self, tgt: Target) ?CStandard {
        return tgt.c_standard orelse self.c_standard;
    }

    /// Finds a target by name.
    pub fn findTarget(self: Self, name: []const u8) ?Target {
        for (self.targets) |t| {
            if (std.mem.eql(u8, t.name, name)) {
                return t;
            }
        }
        return null;
    }

    /// Finds a dependency by name.
    pub fn findDependency(self: Self, name: []const u8) ?Dependency {
        for (self.dependencies) |d| {
            if (std.mem.eql(u8, d.name, name)) {
                return d;
            }
        }
        return null;
    }

    /// Finds a feature by name.
    pub fn findFeature(self: Self, name: []const u8) ?Feature {
        for (self.features) |f| {
            if (std.mem.eql(u8, f.name, name)) {
                return f;
            }
        }
        return null;
    }

    /// Returns all executable targets.
    pub fn executableTargets(self: Self, allocator: Allocator) Allocator.Error![]const Target {
        var result = std.ArrayList(Target).init(allocator);
        errdefer result.deinit();

        for (self.targets) |t| {
            if (t.kind == .executable) {
                try result.append(t);
            }
        }

        return result.toOwnedSlice();
    }

    /// Returns all library targets.
    pub fn libraryTargets(self: Self, allocator: Allocator) Allocator.Error![]const Target {
        var result = std.ArrayList(Target).init(allocator);
        errdefer result.deinit();

        for (self.targets) |t| {
            if (t.kind == .static_library or t.kind == .shared_library or t.kind == .header_only) {
                try result.append(t);
            }
        }

        return result.toOwnedSlice();
    }

    /// Returns the effective profile by name.
    pub fn effectiveProfile(self: Self, name: ?[]const u8) ?Profile {
        const profile_name = name orelse self.default_profile orelse return Profile.fromName("debug");

        // Check custom profiles first
        for (self.profiles) |p| {
            if (std.mem.eql(u8, p.name, profile_name)) {
                return p;
            }
        }

        // Fall back to built-in profiles
        return Profile.fromName(profile_name);
    }

    /// Resolves all enabled features including implied features.
    pub fn resolveFeatures(self: Self, enabled: []const []const u8, allocator: Allocator) ![]const []const u8 {
        var resolved = std.StringHashMap(void).init(allocator);
        defer resolved.deinit();

        var queue = std.ArrayList([]const u8).init(allocator);
        defer queue.deinit();

        // Start with explicitly enabled features and defaults
        for (enabled) |f| {
            try queue.append(f);
        }
        for (self.default_features) |f| {
            try queue.append(f);
        }

        // Process queue, adding implied features
        while (queue.items.len > 0) {
            const feature_name = queue.pop();

            if (resolved.contains(feature_name)) continue;
            try resolved.put(feature_name, {});

            if (self.findFeature(feature_name)) |feature| {
                for (feature.implies) |implied| {
                    if (!resolved.contains(implied)) {
                        try queue.append(implied);
                    }
                }
            }
        }

        // Convert to slice
        var result = std.ArrayList([]const u8).init(allocator);
        errdefer result.deinit();

        var iter = resolved.keyIterator();
        while (iter.next()) |key| {
            try result.append(key.*);
        }

        return result.toOwnedSlice();
    }

    /// Checks for feature conflicts.
    pub fn checkFeatureConflicts(self: Self, enabled: []const []const u8) ?ConflictInfo {
        for (enabled) |feature_name| {
            if (self.findFeature(feature_name)) |feature| {
                for (feature.conflicts_with) |conflict| {
                    for (enabled) |other| {
                        if (std.mem.eql(u8, other, conflict)) {
                            return ConflictInfo{
                                .feature1 = feature_name,
                                .feature2 = conflict,
                            };
                        }
                    }
                }
            }
        }
        return null;
    }

    pub const ConflictInfo = struct {
        feature1: []const u8,
        feature2: []const u8,
    };

    /// Validates the project configuration.
    pub fn validate(self: Self) ValidateError!void {
        if (self.name.len == 0) {
            return ValidateError.MissingName;
        }

        // Validate targets
        for (self.targets) |t| {
            try t.validate();
        }

        // Validate dependencies
        for (self.dependencies) |d| {
            d.validate() catch |err| {
                _ = err;
                return ValidateError.InvalidDependency;
            };
        }

        // Validate features
        for (self.features) |f| {
            try f.validate();
        }

        // Check for duplicate target names
        if (validation.hasDuplicateName(Target, self.targets, targetName)) {
            return ValidateError.DuplicateTargetName;
        }

        // Check for duplicate dependency names
        if (validation.hasDuplicateName(Dependency, self.dependencies, dependencyName)) {
            return ValidateError.DuplicateDependencyName;
        }

        // Validate workspace if present
        if (self.workspace) |ws| {
            ws.validate() catch |err| {
                _ = err;
                return ValidateError.InvalidWorkspace;
            };
        }
    }

    /// Returns true if this project is a workspace root.
    pub fn isWorkspace(self: Self) bool {
        return self.workspace != null;
    }
};

fn targetName(target: Target) []const u8 {
    return target.name;
}

fn dependencyName(dep: Dependency) []const u8 {
    return dep.name;
}

/// Parse errors.
pub const ParseError = error{
    InvalidVersion,
    InvalidFormat,
    UnexpectedToken,
};

/// Validation errors.
pub const ValidateError = error{
    MissingName,
    InvalidDependency,
    InvalidTarget,
    InvalidWorkspace,
    DuplicateTargetName,
    DuplicateDependencyName,
    DuplicateFeatureName,
    SelfReference,
    CircularDependency,
};

// ============================================================================
// Tests
// ============================================================================

test "Version.parse" {
    const v1 = try Version.parse("1.2.3");
    try testing.expectEqual(@as(u32, 1), v1.major);
    try testing.expectEqual(@as(u32, 2), v1.minor);
    try testing.expectEqual(@as(u32, 3), v1.patch);
    try testing.expect(v1.prerelease == null);
    try testing.expect(v1.build_metadata == null);

    const v2 = try Version.parse("2.0.0-alpha");
    try testing.expectEqual(@as(u32, 2), v2.major);
    try testing.expectEqualStrings("alpha", v2.prerelease.?);

    const v3 = try Version.parse("1.0.0-beta+build123");
    try testing.expectEqualStrings("beta", v3.prerelease.?);
    try testing.expectEqualStrings("build123", v3.build_metadata.?);

    const v4 = try Version.parse("3.0.0+build");
    try testing.expect(v4.prerelease == null);
    try testing.expectEqualStrings("build", v4.build_metadata.?);
}

test "Version.compare" {
    const v100 = Version.init(1, 0, 0);
    const v110 = Version.init(1, 1, 0);
    const v111 = Version.init(1, 1, 1);
    const v200 = Version.init(2, 0, 0);

    try testing.expectEqual(std.math.Order.lt, v100.compare(v110));
    try testing.expectEqual(std.math.Order.lt, v110.compare(v111));
    try testing.expectEqual(std.math.Order.lt, v111.compare(v200));
    try testing.expectEqual(std.math.Order.gt, v200.compare(v100));
    try testing.expectEqual(std.math.Order.eq, v100.compare(v100));

    // Prerelease versions are lower than release
    const v100_alpha = Version{ .major = 1, .minor = 0, .patch = 0, .prerelease = "alpha" };
    try testing.expectEqual(std.math.Order.lt, v100_alpha.compare(v100));
}

test "Version.toString" {
    var buf: [64]u8 = undefined;

    const v1 = Version.init(1, 2, 3);
    try testing.expectEqualStrings("1.2.3", v1.toString(&buf));

    const v2 = Version{ .major = 2, .minor = 0, .patch = 0, .prerelease = "beta" };
    try testing.expectEqualStrings("2.0.0-beta", v2.toString(&buf));
}

test "Feature.validate" {
    const valid = Feature{ .name = "ssl" };
    try valid.validate();

    const no_name = Feature{ .name = "" };
    try testing.expectError(ValidateError.MissingName, no_name.validate());

    const self_implies = Feature{ .name = "test", .implies = &[_][]const u8{"test"} };
    try testing.expectError(ValidateError.SelfReference, self_implies.validate());
}

test "Project.findTarget" {
    const project = Project{
        .name = "test-project",
        .targets = &[_]Target{
            .{ .name = "myapp", .kind = .executable, .sources = &.{"main.cpp"} },
            .{ .name = "mylib", .kind = .static_library, .sources = &.{"lib.cpp"} },
        },
    };

    const app = project.findTarget("myapp");
    try testing.expect(app != null);
    try testing.expectEqual(TargetKind.executable, app.?.kind);

    const lib = project.findTarget("mylib");
    try testing.expect(lib != null);
    try testing.expectEqual(TargetKind.static_library, lib.?.kind);

    const none = project.findTarget("nonexistent");
    try testing.expect(none == null);
}

test "Project.resolveFeatures" {
    const allocator = testing.allocator;

    const project = Project{
        .name = "test-project",
        .features = &[_]Feature{
            .{ .name = "ssl", .implies = &[_][]const u8{"crypto"} },
            .{ .name = "crypto" },
            .{ .name = "json" },
        },
        .default_features = &[_][]const u8{"json"},
    };

    const enabled = try project.resolveFeatures(&[_][]const u8{"ssl"}, allocator);
    defer allocator.free(enabled);

    try testing.expectEqual(@as(usize, 3), enabled.len);

    var has_ssl = false;
    var has_crypto = false;
    var has_json = false;
    for (enabled) |f| {
        if (std.mem.eql(u8, f, "ssl")) has_ssl = true;
        if (std.mem.eql(u8, f, "crypto")) has_crypto = true;
        if (std.mem.eql(u8, f, "json")) has_json = true;
    }
    try testing.expect(has_ssl);
    try testing.expect(has_crypto);
    try testing.expect(has_json);
}

test "Project.checkFeatureConflicts" {
    const project = Project{
        .name = "test-project",
        .features = &[_]Feature{
            .{ .name = "openssl", .conflicts_with = &[_][]const u8{"boringssl"} },
            .{ .name = "boringssl", .conflicts_with = &[_][]const u8{"openssl"} },
            .{ .name = "json" },
        },
    };

    // No conflict
    const no_conflict = project.checkFeatureConflicts(&[_][]const u8{ "openssl", "json" });
    try testing.expect(no_conflict == null);

    // Conflict
    const conflict = project.checkFeatureConflicts(&[_][]const u8{ "openssl", "boringssl" });
    try testing.expect(conflict != null);
}

test "Project.validate" {
    // Valid project
    const valid = Project{
        .name = "test-project",
        .version = Version.init(1, 0, 0),
        .targets = &[_]Target{
            .{ .name = "myapp", .kind = .executable, .sources = &.{"main.cpp"} },
        },
    };
    try valid.validate();

    // Invalid: missing name
    const no_name = Project{ .name = "" };
    try testing.expectError(ValidateError.MissingName, no_name.validate());

    // Invalid: duplicate targets
    const dup_targets = Project{
        .name = "test",
        .targets = &[_]Target{
            .{ .name = "app", .kind = .executable, .sources = &.{"a.cpp"} },
            .{ .name = "app", .kind = .executable, .sources = &.{"b.cpp"} },
        },
    };
    try testing.expectError(ValidateError.DuplicateTargetName, dup_targets.validate());
}

test "Project.effectiveProfile" {
    const project = Project{
        .name = "test",
        .default_profile = "release",
    };

    const default = project.effectiveProfile(null);
    try testing.expect(default != null);
    try testing.expectEqualStrings("release", default.?.name);

    const explicit = project.effectiveProfile("debug");
    try testing.expect(explicit != null);
    try testing.expectEqualStrings("debug", explicit.?.name);
}

test "Project.executableTargets" {
    const allocator = testing.allocator;

    const project = Project{
        .name = "test",
        .targets = &[_]Target{
            .{ .name = "app1", .kind = .executable, .sources = &.{"a.cpp"} },
            .{ .name = "lib1", .kind = .static_library, .sources = &.{"b.cpp"} },
            .{ .name = "app2", .kind = .executable, .sources = &.{"c.cpp"} },
            .{ .name = "headers", .kind = .header_only },
        },
    };

    const exes = try project.executableTargets(allocator);
    defer allocator.free(exes);

    try testing.expectEqual(@as(usize, 2), exes.len);
    try testing.expectEqualStrings("app1", exes[0].name);
    try testing.expectEqualStrings("app2", exes[1].name);
}
