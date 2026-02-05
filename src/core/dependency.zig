//! Dependency model supporting multiple source types.
//!
//! This module defines the `Dependency` type which represents external dependencies
//! in a project. Dependencies can be sourced from various locations:
//!
//! - **Git**: Clone from a Git repository with optional branch/tag/commit
//! - **URL**: Download from an HTTP/HTTPS URL (tarball, zip)
//! - **Path**: Local filesystem path (for development or vendored deps)
//! - **Vcpkg**: Microsoft's vcpkg package manager
//! - **Conan**: JFrog's Conan package manager
//! - **System**: System-installed libraries (pkg-config, etc.)
//!
//! ## Example
//! ```zig
//! const dep = Dependency{
//!     .name = "zlib",
//!     .source = .{ .vcpkg = .{ .name = "zlib", .features = &.{"static"} } },
//!     .version = "1.2.13",
//! };
//! ```

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const platform_mod = @import("platform.zig");
const Platform = platform_mod.Platform;

/// Git repository source specification.
pub const GitSource = struct {
    /// Repository URL (HTTPS or SSH).
    url: []const u8,
    /// Branch name (mutually exclusive with tag and commit).
    branch: ?[]const u8 = null,
    /// Tag name (mutually exclusive with branch and commit).
    tag: ?[]const u8 = null,
    /// Specific commit hash (mutually exclusive with branch and tag).
    commit: ?[]const u8 = null,
    /// Subdirectory within the repository to use as root.
    subdir: ?[]const u8 = null,
    /// Whether to perform a shallow clone (depth=1).
    shallow: bool = true,
    /// Whether to recursively clone submodules.
    submodules: bool = false,

    const Self = @This();

    /// Returns the ref specification for checkout (branch, tag, or commit).
    pub fn refSpec(self: Self) ?[]const u8 {
        if (self.commit) |c| return c;
        if (self.tag) |t| return t;
        if (self.branch) |b| return b;
        return null;
    }

    /// Validates the git source configuration.
    pub fn validate(self: Self) ValidateError!void {
        // URL is required
        if (self.url.len == 0) {
            return ValidateError.MissingUrl;
        }

        // At most one of branch, tag, commit should be specified
        var ref_count: u8 = 0;
        if (self.branch != null) ref_count += 1;
        if (self.tag != null) ref_count += 1;
        if (self.commit != null) ref_count += 1;
        if (ref_count > 1) {
            return ValidateError.ConflictingRefs;
        }

        // Shallow clone not compatible with full commit history
        if (self.shallow and self.commit != null and self.commit.?.len == 40) {
            // Full SHA requires fetching the commit, which may fail with shallow clone
            // This is a warning, not an error
        }
    }
};

/// URL download source specification.
pub const UrlSource = struct {
    /// Download URL.
    url: []const u8,
    /// Expected hash of the downloaded content (SHA256).
    hash: ?[]const u8 = null,
    /// Subdirectory within the archive to use as root.
    subdir: ?[]const u8 = null,
    /// Archive type (auto-detected from URL if not specified).
    archive_type: ?ArchiveType = null,

    pub const ArchiveType = enum {
        tar_gz,
        tar_xz,
        tar_bz2,
        zip,
        raw, // Not an archive, just a file
    };

    const Self = @This();

    /// Auto-detects the archive type from the URL.
    pub fn detectArchiveType(self: Self) ArchiveType {
        if (self.archive_type) |at| return at;

        const url_lower = blk: {
            var buf: [256]u8 = undefined;
            const len = @min(self.url.len, buf.len);
            for (self.url[self.url.len - len ..], 0..) |c, i| {
                buf[i] = std.ascii.toLower(c);
            }
            break :blk buf[0..len];
        };

        if (std.mem.endsWith(u8, url_lower, ".tar.gz") or std.mem.endsWith(u8, url_lower, ".tgz")) return .tar_gz;
        if (std.mem.endsWith(u8, url_lower, ".tar.xz") or std.mem.endsWith(u8, url_lower, ".txz")) return .tar_xz;
        if (std.mem.endsWith(u8, url_lower, ".tar.bz2") or std.mem.endsWith(u8, url_lower, ".tbz2")) return .tar_bz2;
        if (std.mem.endsWith(u8, url_lower, ".zip")) return .zip;
        return .raw;
    }

    /// Validates the URL source configuration.
    pub fn validate(self: Self) ValidateError!void {
        if (self.url.len == 0) {
            return ValidateError.MissingUrl;
        }
    }
};

/// Local filesystem path source specification.
pub const PathSource = struct {
    /// Filesystem path (absolute or relative to project root).
    path: []const u8,
    /// Whether to copy the files or reference them in-place.
    copy: bool = false,

    const Self = @This();

    /// Validates the path source configuration.
    pub fn validate(self: Self) ValidateError!void {
        if (self.path.len == 0) {
            return ValidateError.MissingPath;
        }
    }
};

/// Vcpkg package manager source specification.
pub const VcpkgSource = struct {
    /// Package name in vcpkg.
    name: []const u8,
    /// Optional version constraint.
    version: ?[]const u8 = null,
    /// Vcpkg features to enable.
    features: []const []const u8 = &.{},
    /// Vcpkg triplet override (uses default triplet if null).
    triplet: ?[]const u8 = null,

    const Self = @This();

    /// Validates the vcpkg source configuration.
    pub fn validate(self: Self) ValidateError!void {
        if (self.name.len == 0) {
            return ValidateError.MissingPackageName;
        }
    }
};

/// Conan package manager source specification.
pub const ConanSource = struct {
    /// Package reference (name/version@user/channel).
    reference: []const u8,
    /// Conan options to pass.
    options: []const []const u8 = &.{},
    /// Conan settings override.
    settings: []const []const u8 = &.{},
    /// Additional remote URL.
    remote: ?[]const u8 = null,

    const Self = @This();

    /// Validates the conan source configuration.
    pub fn validate(self: Self) ValidateError!void {
        if (self.reference.len == 0) {
            return ValidateError.MissingPackageName;
        }
    }
};

/// System-installed library source specification.
pub const SystemSource = struct {
    /// pkg-config package name.
    pkg_config: ?[]const u8 = null,
    /// Library name for -l flag (without lib prefix).
    lib_name: ?[]const u8 = null,
    /// Include paths to search.
    include_paths: []const []const u8 = &.{},
    /// Library paths to search.
    lib_paths: []const []const u8 = &.{},
    /// Whether the library is required (error if not found) or optional.
    required: bool = true,

    const Self = @This();

    /// Validates the system source configuration.
    pub fn validate(self: Self) ValidateError!void {
        if (self.pkg_config == null and self.lib_name == null) {
            return ValidateError.MissingPackageName;
        }
    }

    /// Returns the identifier used for finding this library.
    pub fn identifier(self: Self) ?[]const u8 {
        return self.pkg_config orelse self.lib_name;
    }
};

/// Dependency source type union.
pub const Source = union(enum) {
    git: GitSource,
    url: UrlSource,
    path: PathSource,
    vcpkg: VcpkgSource,
    conan: ConanSource,
    system: SystemSource,

    const Self = @This();

    /// Validates the source configuration.
    pub fn validate(self: Self) ValidateError!void {
        return switch (self) {
            .git => |s| s.validate(),
            .url => |s| s.validate(),
            .path => |s| s.validate(),
            .vcpkg => |s| s.validate(),
            .conan => |s| s.validate(),
            .system => |s| s.validate(),
        };
    }

    /// Returns a human-readable description of the source type.
    pub fn typeName(self: Self) []const u8 {
        return switch (self) {
            .git => "git",
            .url => "url",
            .path => "path",
            .vcpkg => "vcpkg",
            .conan => "conan",
            .system => "system",
        };
    }
};

/// Version constraint specification.
pub const VersionConstraint = struct {
    /// Minimum version (inclusive), or null for no minimum.
    min: ?[]const u8 = null,
    /// Maximum version (exclusive), or null for no maximum.
    max: ?[]const u8 = null,
    /// Exact version match, or null for range matching.
    exact: ?[]const u8 = null,

    const Self = @This();

    /// Creates an exact version constraint.
    pub fn exactly(version: []const u8) Self {
        return .{ .exact = version };
    }

    /// Creates a minimum version constraint.
    pub fn atLeast(version: []const u8) Self {
        return .{ .min = version };
    }

    /// Creates a version range constraint.
    pub fn range(min_ver: []const u8, max_ver: []const u8) Self {
        return .{ .min = min_ver, .max = max_ver };
    }

    /// Validates the version constraint.
    pub fn validate(self: Self) ValidateError!void {
        // Cannot have both exact and range
        if (self.exact != null and (self.min != null or self.max != null)) {
            return ValidateError.ConflictingVersionConstraints;
        }
    }

    /// Returns a string representation of the constraint.
    pub fn toString(self: Self, buf: []u8) []u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        if (self.exact) |v| {
            writer.print("={s}", .{v}) catch {};
        } else if (self.min != null and self.max != null) {
            writer.print(">={s},<{s}", .{ self.min.?, self.max.? }) catch {};
        } else if (self.min) |v| {
            writer.print(">={s}", .{v}) catch {};
        } else if (self.max) |v| {
            writer.print("<{s}", .{v}) catch {};
        } else {
            writer.writeAll("*") catch {};
        }

        return fbs.getWritten();
    }
};

/// Dependency linking type.
pub const LinkType = enum {
    /// Link statically (.a, .lib).
    static,
    /// Link as shared library (.so, .dll, .dylib).
    shared,
    /// Header-only library (no linking required).
    header_only,
    /// Interface library (for transitive dependencies).
    interface,
};

/// Complete dependency specification.
pub const Dependency = struct {
    /// Unique name for this dependency within the project.
    name: []const u8,
    /// Dependency source specification.
    source: Source,
    /// Version string or constraint.
    version: ?[]const u8 = null,
    /// Detailed version constraint.
    version_constraint: ?VersionConstraint = null,
    /// How to link this dependency.
    link_type: LinkType = .static,
    /// Whether this dependency is optional.
    optional: bool = false,
    /// Features/components to enable.
    features: []const []const u8 = &.{},
    /// Platform conditions (only use on these platforms).
    platforms: []const Platform = &.{},
    /// Build-time dependency only (not linked into final binary).
    build_only: bool = false,
    /// Dependencies of this dependency (transitive).
    dependencies: []const []const u8 = &.{},
    /// CMake target name override.
    cmake_target: ?[]const u8 = null,
    /// pkg-config name override.
    pkg_config_name: ?[]const u8 = null,

    const Self = @This();

    /// Validates the dependency configuration.
    pub fn validate(self: Self) ValidateError!void {
        if (self.name.len == 0) {
            return ValidateError.MissingName;
        }

        try self.source.validate();

        if (self.version_constraint) |vc| {
            try vc.validate();
        }
    }

    /// Returns true if this dependency should be used on the given platform.
    pub fn appliesToPlatform(self: Self, target: Platform) bool {
        if (self.platforms.len == 0) {
            return true; // No platform restriction
        }

        for (self.platforms) |p| {
            if (p.arch == target.arch and p.os == target.os) {
                return true;
            }
        }
        return false;
    }

    /// Returns the effective CMake target name.
    pub fn cmakeTarget(self: Self) []const u8 {
        return self.cmake_target orelse self.name;
    }

    /// Returns the effective pkg-config name.
    pub fn pkgConfigName(self: Self) []const u8 {
        return self.pkg_config_name orelse self.name;
    }
};

/// Errors that can occur during dependency validation.
pub const ValidateError = error{
    MissingName,
    MissingUrl,
    MissingPath,
    MissingPackageName,
    ConflictingRefs,
    ConflictingVersionConstraints,
    InvalidHash,
};

// ============================================================================
// Builder Pattern for Ergonomic Dependency Creation
// ============================================================================

/// Builder for creating Dependency instances with a fluent API.
pub const DependencyBuilder = struct {
    dep: Dependency,

    const Self = @This();

    /// Creates a new builder with the given name.
    pub fn init(name: []const u8) Self {
        return .{
            .dep = .{
                .name = name,
                .source = .{ .system = .{} },
            },
        };
    }

    /// Sets the source to a Git repository.
    pub fn git(self: *Self, git_url: []const u8) *Self {
        self.dep.source = .{ .git = .{ .url = git_url } };
        return self;
    }

    /// Sets the Git branch.
    pub fn branch(self: *Self, b: []const u8) *Self {
        if (self.dep.source == .git) {
            self.dep.source.git.branch = b;
        }
        return self;
    }

    /// Sets the Git tag.
    pub fn tag(self: *Self, t: []const u8) *Self {
        if (self.dep.source == .git) {
            self.dep.source.git.tag = t;
        }
        return self;
    }

    /// Sets the source to a URL.
    pub fn url(self: *Self, u: []const u8) *Self {
        self.dep.source = .{ .url = .{ .url = u } };
        return self;
    }

    /// Sets the URL hash.
    pub fn hash(self: *Self, h: []const u8) *Self {
        if (self.dep.source == .url) {
            self.dep.source.url.hash = h;
        }
        return self;
    }

    /// Sets the source to a local path.
    pub fn path(self: *Self, p: []const u8) *Self {
        self.dep.source = .{ .path = .{ .path = p } };
        return self;
    }

    /// Sets the source to vcpkg.
    pub fn vcpkg(self: *Self, name: []const u8) *Self {
        self.dep.source = .{ .vcpkg = .{ .name = name } };
        return self;
    }

    /// Sets the source to conan.
    pub fn conan(self: *Self, reference: []const u8) *Self {
        self.dep.source = .{ .conan = .{ .reference = reference } };
        return self;
    }

    /// Sets the source to a system library.
    pub fn system(self: *Self, pkg_config: []const u8) *Self {
        self.dep.source = .{ .system = .{ .pkg_config = pkg_config } };
        return self;
    }

    /// Sets the version.
    pub fn version(self: *Self, v: []const u8) *Self {
        self.dep.version = v;
        return self;
    }

    /// Sets the link type.
    pub fn linkType(self: *Self, lt: LinkType) *Self {
        self.dep.link_type = lt;
        return self;
    }

    /// Marks the dependency as optional.
    pub fn optional(self: *Self) *Self {
        self.dep.optional = true;
        return self;
    }

    /// Sets the features.
    pub fn features(self: *Self, f: []const []const u8) *Self {
        self.dep.features = f;
        return self;
    }

    /// Builds and returns the final Dependency.
    pub fn build(self: Self) Dependency {
        return self.dep;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "GitSource.validate" {
    // Valid sources
    const valid = GitSource{ .url = "https://github.com/user/repo.git" };
    try valid.validate();

    const with_branch = GitSource{ .url = "https://github.com/user/repo.git", .branch = "main" };
    try with_branch.validate();

    // Invalid: missing URL
    const no_url = GitSource{ .url = "" };
    try testing.expectError(ValidateError.MissingUrl, no_url.validate());

    // Invalid: conflicting refs
    const conflict = GitSource{ .url = "https://github.com/user/repo.git", .branch = "main", .tag = "v1.0" };
    try testing.expectError(ValidateError.ConflictingRefs, conflict.validate());
}

test "UrlSource.detectArchiveType" {
    const tar_gz = UrlSource{ .url = "https://example.com/file.tar.gz" };
    try testing.expectEqual(UrlSource.ArchiveType.tar_gz, tar_gz.detectArchiveType());

    const zip = UrlSource{ .url = "https://example.com/file.ZIP" };
    try testing.expectEqual(UrlSource.ArchiveType.zip, zip.detectArchiveType());

    const raw = UrlSource{ .url = "https://example.com/file.h" };
    try testing.expectEqual(UrlSource.ArchiveType.raw, raw.detectArchiveType());
}

test "VersionConstraint" {
    const exact = VersionConstraint.exactly("1.2.3");
    try exact.validate();
    try testing.expectEqualStrings("1.2.3", exact.exact.?);

    const range = VersionConstraint.range("1.0.0", "2.0.0");
    try range.validate();
    try testing.expectEqualStrings("1.0.0", range.min.?);
    try testing.expectEqualStrings("2.0.0", range.max.?);

    // Invalid: both exact and range
    const invalid = VersionConstraint{ .exact = "1.0.0", .min = "0.5.0" };
    try testing.expectError(ValidateError.ConflictingVersionConstraints, invalid.validate());
}

test "Dependency.validate" {
    // Valid dependency
    const valid = Dependency{
        .name = "zlib",
        .source = .{ .vcpkg = .{ .name = "zlib" } },
        .version = "1.2.13",
    };
    try valid.validate();

    // Invalid: missing name
    const no_name = Dependency{
        .name = "",
        .source = .{ .vcpkg = .{ .name = "zlib" } },
    };
    try testing.expectError(ValidateError.MissingName, no_name.validate());

    // Invalid: missing source info
    const no_pkg = Dependency{
        .name = "test",
        .source = .{ .vcpkg = .{ .name = "" } },
    };
    try testing.expectError(ValidateError.MissingPackageName, no_pkg.validate());
}

test "Dependency.appliesToPlatform" {
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

    // No platform restriction
    const universal = Dependency{
        .name = "universal",
        .source = .{ .system = .{ .pkg_config = "test" } },
    };
    try testing.expect(universal.appliesToPlatform(linux_x86_64));
    try testing.expect(universal.appliesToPlatform(windows_x86_64));

    // Linux only
    const linux_only = Dependency{
        .name = "linux_only",
        .source = .{ .system = .{ .pkg_config = "test" } },
        .platforms = &[_]Platform{linux_x86_64},
    };
    try testing.expect(linux_only.appliesToPlatform(linux_x86_64));
    try testing.expect(!linux_only.appliesToPlatform(windows_x86_64));
}

test "DependencyBuilder" {
    var builder = DependencyBuilder.init("mylib");
    const dep = builder
        .git("https://github.com/user/mylib.git")
        .tag("v1.0.0")
        .version("1.0.0")
        .linkType(.shared)
        .build();

    try testing.expectEqualStrings("mylib", dep.name);
    try testing.expectEqual(Source.git, @as(@TypeOf(dep.source), dep.source));
    try testing.expectEqualStrings("https://github.com/user/mylib.git", dep.source.git.url);
    try testing.expectEqualStrings("v1.0.0", dep.source.git.tag.?);
    try testing.expectEqual(LinkType.shared, dep.link_type);
}

test "Source.typeName" {
    const git_source = Source{ .git = .{ .url = "test" } };
    try testing.expectEqualStrings("git", git_source.typeName());

    const system_source = Source{ .system = .{ .pkg_config = "test" } };
    try testing.expectEqualStrings("system", system_source.typeName());
}
