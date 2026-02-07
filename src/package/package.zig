//! Ovo Package Manager
//!
//! A decentralized package manager for Zig with support for multiple sources:
//! - Git repositories (default)
//! - Archives (tar.gz, zip)
//! - Local paths
//! - vcpkg packages (C/C++ ecosystem)
//! - Conan packages (C/C++ ecosystem)
//! - System libraries (pkg-config)
//! - Future: central registry
//!
//! Features:
//! - Decentralized by default (git URLs, paths)
//! - vcpkg/Conan integration for C++ ecosystem
//! - Lockfile for reproducible builds (ovo.lock)
//! - Fallback support (system lib not found -> fetch it)
//! - Transitive dependency resolution
//! - Cycle detection and version conflict resolution

const std = @import("std");
const Allocator = std.mem.Allocator;

// Core modules
pub const integrity = @import("integrity.zig");
pub const lockfile = @import("lockfile.zig");
pub const registry = @import("registry.zig");
pub const resolver = @import("resolver.zig");
pub const fetcher = @import("fetcher.zig");

// Source modules
pub const sources = struct {
    pub const git = @import("sources/git.zig");
    pub const archive = @import("sources/archive.zig");
    pub const path = @import("sources/path.zig");
    pub const vcpkg = @import("sources/vcpkg.zig");
    pub const conan = @import("sources/conan.zig");
    pub const system = @import("sources/system.zig");
};

// Re-exports for convenience
pub const Lockfile = lockfile.Lockfile;
pub const LockedPackage = lockfile.LockedPackage;
pub const Resolver = resolver.Resolver;
pub const Dependency = resolver.Dependency;
pub const ResolvedPackage = resolver.ResolvedPackage;
pub const ResolutionResult = resolver.ResolutionResult;
pub const Fetcher = fetcher.Fetcher;
pub const FetchResult = fetcher.FetchResult;
pub const Hash = integrity.Hash;
pub const HashString = integrity.HashString;

/// Package manager configuration.
pub const Config = struct {
    /// Cache directory for downloaded packages.
    cache_dir: []const u8 = ".ovo/cache",

    /// Whether to use the lockfile.
    use_lockfile: bool = true,

    /// Lockfile path.
    lockfile_path: []const u8 = "ovo.lock",

    /// Offline mode (no network requests).
    offline: bool = false,

    /// Registry URL (for future use).
    registry_url: ?[]const u8 = null,

    /// vcpkg root directory.
    vcpkg_root: ?[]const u8 = null,

    /// Maximum parallel downloads.
    max_parallel: u32 = 4,

    /// Download timeout in milliseconds.
    timeout_ms: u32 = 300000,
};

/// High-level package manager.
pub const PackageManager = struct {
    allocator: Allocator,
    config: Config,
    lock: ?Lockfile,
    resolver_instance: ?Resolver,
    fetcher_instance: ?Fetcher,

    pub fn init(allocator: Allocator, config: Config) !PackageManager {
        var pm = PackageManager{
            .allocator = allocator,
            .config = config,
            .lock = null,
            .resolver_instance = null,
            .fetcher_instance = null,
        };

        // Try to load existing lockfile
        if (config.use_lockfile) {
            pm.lock = Lockfile.tryLoad(allocator, config.lockfile_path) catch null;
        }

        return pm;
    }

    pub fn deinit(self: *PackageManager) void {
        if (self.lock) |*l| l.deinit();
        if (self.resolver_instance) |*r| r.deinit();
        if (self.fetcher_instance) |*f| f.deinit();
    }

    /// Resolve all dependencies from a list of dependency specifications.
    pub fn resolve(self: *PackageManager, dependencies: []const Dependency) !ResolutionResult {
        const lock_ptr: ?*Lockfile = if (self.lock) |*l| l else null;

        self.resolver_instance = Resolver.init(
            self.allocator,
            .{
                .use_lockfile = self.config.use_lockfile,
                .offline = self.config.offline,
            },
            lock_ptr,
        );

        return self.resolver_instance.?.resolve(dependencies);
    }

    /// Fetch a resolved package.
    pub fn fetch(self: *PackageManager, pkg: ResolvedPackage) !FetchResult {
        if (self.fetcher_instance == null) {
            self.fetcher_instance = try Fetcher.init(
                self.allocator,
                .{ .cache_dir = self.config.cache_dir },
                .{
                    .offline = self.config.offline,
                    .timeout_ms = self.config.timeout_ms,
                },
            );
        }

        return self.fetcher_instance.?.fetch(pkg);
    }

    /// Install all dependencies (resolve + fetch).
    pub fn install(self: *PackageManager, dependencies: []const Dependency) !InstallResult {
        // Resolve
        var resolution = try self.resolve(dependencies);
        errdefer resolution.deinit();

        // Get install order
        const order = try resolution.getInstallOrder();
        defer self.allocator.free(order);

        // Fetch each package
        var fetched = std.ArrayList(FetchedPackage).init(self.allocator);
        errdefer {
            for (fetched.items) |*f| f.deinit(self.allocator);
            fetched.deinit();
        }

        for (order) |name| {
            if (resolution.packages.get(name)) |pkg| {
                const result = try self.fetch(pkg);
                try fetched.append(.{
                    .name = try self.allocator.dupe(u8, name),
                    .path = result.path,
                    .hash = result.content_hash,
                });
            }
        }

        // Update lockfile
        if (self.config.use_lockfile) {
            var new_lock = try resolution.toLockfile();
            try new_lock.save(self.config.lockfile_path);

            if (self.lock) |*l| l.deinit();
            self.lock = new_lock;
        }

        return InstallResult{
            .packages = try fetched.toOwnedSlice(),
            .resolution = resolution,
        };
    }

    pub const InstallResult = struct {
        packages: []FetchedPackage,
        resolution: ResolutionResult,

        pub fn deinit(self_result: *InstallResult, allocator: Allocator) void {
            for (self_result.packages) |*p| p.deinit(allocator);
            allocator.free(self_result.packages);
            self_result.resolution.deinit();
        }
    };

    pub const FetchedPackage = struct {
        name: []const u8,
        path: []const u8,
        hash: []const u8,

        pub fn deinit(self_pkg: *FetchedPackage, allocator: Allocator) void {
            allocator.free(self_pkg.name);
            allocator.free(self_pkg.path);
            allocator.free(self_pkg.hash);
        }
    };

    /// Update dependencies (re-resolve with latest versions).
    pub fn update(self: *PackageManager, dependencies: []const Dependency) !ResolutionResult {
        // Temporarily disable lockfile to get fresh resolution
        const old_use_lockfile = self.config.use_lockfile;
        self.config.use_lockfile = false;
        defer self.config.use_lockfile = old_use_lockfile;

        return self.resolve(dependencies);
    }

    /// Clean the cache.
    pub fn clean(self: *PackageManager) !void {
        if (self.fetcher_instance) |*f| {
            try f.cleanCache();
        }
    }

    /// Verify installed packages against lockfile.
    pub fn verify(self: *PackageManager) !VerifyResult {
        var result = VerifyResult{
            .valid = true,
            .mismatches = std.ArrayList([]const u8).init(self.allocator),
            .missing = std.ArrayList([]const u8).init(self.allocator),
        };

        if (self.lock) |lock| {
            var iter = lock.packages.iterator();
            while (iter.next()) |entry| {
                const pkg = entry.value_ptr.*;

                // Check if package exists at expected location
                if (pkg.integrity_hash) |expected_hash| {
                    const actual_hash = integrity.hashDirectory(self.allocator, pkg.source_url) catch {
                        const name = self.allocator.dupe(u8, pkg.name) catch continue;
                        result.missing.append(name) catch continue;
                        result.valid = false;
                        continue;
                    };

                    const actual_hash_str = integrity.hashToString(actual_hash);
                    if (!std.mem.eql(u8, &actual_hash_str, expected_hash)) {
                        const name = self.allocator.dupe(u8, pkg.name) catch continue;
                        result.mismatches.append(name) catch continue;
                        result.valid = false;
                    }
                }
            }
        }

        return result;
    }

    pub const VerifyResult = struct {
        valid: bool,
        mismatches: std.ArrayList([]const u8),
        missing: std.ArrayList([]const u8),

        pub fn deinit(self_result: *VerifyResult, allocator: Allocator) void {
            for (self_result.mismatches.items) |m| allocator.free(m);
            self_result.mismatches.deinit();
            for (self_result.missing.items) |m| allocator.free(m);
            self_result.missing.deinit();
        }
    };
};

/// Parse a dependency string.
/// Formats supported:
/// - "name" (registry)
/// - "name@version" (registry with version)
/// - "git:url" or "git:url#ref"
/// - "path:./local/path"
/// - "vcpkg:name" or "vcpkg:name[features]"
/// - "conan:name/version"
/// - "system:libname"
pub fn parseDependencyString(allocator: Allocator, spec: []const u8) !Dependency {
    if (std.mem.startsWith(u8, spec, "git:")) {
        const rest = spec[4..];
        var url = rest;
        var ref: ?[]const u8 = null;

        if (std.mem.indexOf(u8, rest, "#")) |hash_pos| {
            url = rest[0..hash_pos];
            ref = rest[hash_pos + 1 ..];
        }

        // Extract name from URL
        const name = extractNameFromGitUrl(url);

        return Dependency{
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, ref orelse "HEAD"),
            .source = .{
                .git = .{
                    .url = try allocator.dupe(u8, url),
                    .ref = if (ref) |r| try allocator.dupe(u8, r) else null,
                },
            },
        };
    }

    if (std.mem.startsWith(u8, spec, "path:")) {
        const path = spec[5..];
        const name = std.fs.path.basename(path);

        return Dependency{
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, "local"),
            .source = .{
                .path = .{
                    .path = try allocator.dupe(u8, path),
                },
            },
        };
    }

    if (std.mem.startsWith(u8, spec, "vcpkg:")) {
        const rest = spec[6..];
        var name = rest;
        var features: std.ArrayList([]const u8) = .empty;

        if (std.mem.indexOf(u8, rest, "[")) |bracket_pos| {
            name = rest[0..bracket_pos];
            if (std.mem.indexOf(u8, rest, "]")) |end_bracket| {
                const features_str = rest[bracket_pos + 1 .. end_bracket];
                var feat_iter = std.mem.splitScalar(u8, features_str, ',');
                while (feat_iter.next()) |feat| {
                    try features.append(allocator, try allocator.dupe(u8, feat));
                }
            }
        }

        return Dependency{
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, "*"),
            .source = .{
                .vcpkg = .{
                    .name = try allocator.dupe(u8, name),
                    .features = try features.toOwnedSlice(allocator),
                },
            },
        };
    }

    if (std.mem.startsWith(u8, spec, "conan:")) {
        const reference = spec[6..];
        var name = reference;

        if (std.mem.indexOf(u8, reference, "/")) |slash_pos| {
            name = reference[0..slash_pos];
        }

        return Dependency{
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, "*"),
            .source = .{
                .conan = .{
                    .reference = try allocator.dupe(u8, reference),
                },
            },
        };
    }

    if (std.mem.startsWith(u8, spec, "system:")) {
        const name = spec[7..];

        return Dependency{
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, "*"),
            .source = .{
                .system = .{
                    .pkg_config_name = try allocator.dupe(u8, name),
                },
            },
        };
    }

    // Default: registry package
    var name = spec;
    var version: []const u8 = "*";

    if (std.mem.indexOf(u8, spec, "@")) |at_pos| {
        name = spec[0..at_pos];
        version = spec[at_pos + 1 ..];
    }

    return Dependency{
        .name = try allocator.dupe(u8, name),
        .version = try allocator.dupe(u8, version),
        .source = .{
            .registry_pkg = .{},
        },
    };
}

fn extractNameFromGitUrl(url: []const u8) []const u8 {
    // Extract repo name from URL like https://github.com/owner/repo.git
    var name = url;

    // Remove .git suffix
    if (std.mem.endsWith(u8, name, ".git")) {
        name = name[0 .. name.len - 4];
    }

    // Get last path component
    if (std.mem.lastIndexOf(u8, name, "/")) |pos| {
        name = name[pos + 1 ..];
    }

    return name;
}

// Tests
test "parse git dependency" {
    const allocator = std.testing.allocator;

    var dep = try parseDependencyString(allocator, "git:https://github.com/test/repo.git#v1.0.0");
    defer dep.deinit(allocator);

    try std.testing.expectEqualStrings("repo", dep.name);
    try std.testing.expectEqualStrings("v1.0.0", dep.version);
    try std.testing.expect(dep.source == .git);
}

test "parse path dependency" {
    const allocator = std.testing.allocator;

    var dep = try parseDependencyString(allocator, "path:./libs/mylib");
    defer dep.deinit(allocator);

    try std.testing.expectEqualStrings("mylib", dep.name);
    try std.testing.expect(dep.source == .path);
}

test "parse vcpkg dependency" {
    const allocator = std.testing.allocator;

    var dep = try parseDependencyString(allocator, "vcpkg:openssl[tools,weak-ssl-ciphers]");
    defer dep.deinit(allocator);

    try std.testing.expectEqualStrings("openssl", dep.name);
    try std.testing.expect(dep.source == .vcpkg);
}

test "parse registry dependency" {
    const allocator = std.testing.allocator;

    var dep = try parseDependencyString(allocator, "somepackage@^1.2.3");
    defer dep.deinit(allocator);

    try std.testing.expectEqualStrings("somepackage", dep.name);
    try std.testing.expectEqualStrings("^1.2.3", dep.version);
    try std.testing.expect(dep.source == .registry_pkg);
}

test "extract name from git url" {
    try std.testing.expectEqualStrings("repo", extractNameFromGitUrl("https://github.com/owner/repo.git"));
    try std.testing.expectEqualStrings("mylib", extractNameFromGitUrl("https://gitlab.com/user/mylib"));
}
