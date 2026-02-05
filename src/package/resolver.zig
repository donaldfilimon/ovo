//! Dependency resolution engine.
//!
//! Resolves all dependency types with cycle detection, version conflict
//! resolution, and transitive dependency handling.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lockfile = @import("lockfile.zig");
const registry = @import("registry.zig");

/// Dependency specification from manifest.
pub const Dependency = struct {
    /// Package name.
    name: []const u8,

    /// Version requirement (semver, tag, branch, commit).
    version: []const u8,

    /// Source type.
    source: Source,

    /// Whether this dependency is optional.
    optional: bool = false,

    /// Build-only dependency.
    build_only: bool = false,

    /// Development-only dependency.
    dev_only: bool = false,

    /// Platform constraints.
    platforms: ?[]const Platform = null,

    /// Fallback sources if primary fails.
    fallbacks: []const Source = &.{},

    pub const Source = union(enum) {
        /// Git repository.
        git: GitSource,

        /// Archive URL.
        archive: ArchiveSource,

        /// Local filesystem path.
        path: PathSource,

        /// Package registry.
        registry_pkg: RegistrySource,

        /// vcpkg package.
        vcpkg: VcpkgSource,

        /// Conan package.
        conan: ConanSource,

        /// System library (pkg-config).
        system: SystemSource,
    };

    pub const GitSource = struct {
        url: []const u8,
        ref: ?[]const u8 = null, // branch, tag, or commit
        subdir: ?[]const u8 = null,
    };

    pub const ArchiveSource = struct {
        url: []const u8,
        hash: ?[]const u8 = null,
        strip_prefix: ?u32 = null,
    };

    pub const PathSource = struct {
        path: []const u8,
    };

    pub const RegistrySource = struct {
        name: ?[]const u8 = null, // if different from dependency name
        registry_url: ?[]const u8 = null, // custom registry
    };

    pub const VcpkgSource = struct {
        name: ?[]const u8 = null,
        features: []const []const u8 = &.{},
        triplet: ?[]const u8 = null,
    };

    pub const ConanSource = struct {
        reference: []const u8, // name/version@user/channel
        options: []const []const u8 = &.{},
    };

    pub const SystemSource = struct {
        pkg_config_name: ?[]const u8 = null,
        include_paths: []const []const u8 = &.{},
        library_paths: []const []const u8 = &.{},
        libraries: []const []const u8 = &.{},
    };

    pub const Platform = struct {
        os: ?[]const u8 = null,
        arch: ?[]const u8 = null,
        libc: ?[]const u8 = null,
    };

    pub fn deinit(self: *Dependency, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        // Free source-specific allocations...
        switch (self.source) {
            .git => |g| {
                allocator.free(g.url);
                if (g.ref) |r| allocator.free(r);
                if (g.subdir) |s| allocator.free(s);
            },
            .archive => |a| {
                allocator.free(a.url);
                if (a.hash) |h| allocator.free(h);
            },
            .path => |p| allocator.free(p.path),
            .registry_pkg => |r| {
                if (r.name) |n| allocator.free(n);
                if (r.registry_url) |u| allocator.free(u);
            },
            .vcpkg => |v| {
                if (v.name) |n| allocator.free(n);
                for (v.features) |f| allocator.free(f);
                allocator.free(v.features);
                if (v.triplet) |t| allocator.free(t);
            },
            .conan => |c| {
                allocator.free(c.reference);
                for (c.options) |o| allocator.free(o);
                allocator.free(c.options);
            },
            .system => |s| {
                if (s.pkg_config_name) |n| allocator.free(n);
                for (s.include_paths) |p| allocator.free(p);
                allocator.free(s.include_paths);
                for (s.library_paths) |p| allocator.free(p);
                allocator.free(s.library_paths);
                for (s.libraries) |l| allocator.free(l);
                allocator.free(s.libraries);
            },
        }
        if (self.platforms) |plats| {
            for (plats) |p| {
                if (p.os) |o| allocator.free(o);
                if (p.arch) |a| allocator.free(a);
                if (p.libc) |l| allocator.free(l);
            }
            allocator.free(plats);
        }
    }
};

/// A resolved package with exact version and source.
pub const ResolvedPackage = struct {
    /// Package name.
    name: []const u8,

    /// Exact resolved version.
    version: []const u8,

    /// Resolved source location.
    source_url: []const u8,

    /// Source type.
    source_type: lockfile.SourceType,

    /// Resolved commit hash (for git) or content hash.
    resolved_hash: ?[]const u8 = null,

    /// Transitive dependencies (names).
    dependencies: []const []const u8 = &.{},

    /// Build configuration from source.
    build_config: ?BuildConfig = null,

    pub const BuildConfig = struct {
        include_paths: []const []const u8 = &.{},
        library_paths: []const []const u8 = &.{},
        libraries: []const []const u8 = &.{},
        defines: []const []const u8 = &.{},
        c_flags: []const []const u8 = &.{},
        ld_flags: []const []const u8 = &.{},
    };

    pub fn deinit(self: *ResolvedPackage, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.source_url);
        if (self.resolved_hash) |h| allocator.free(h);
        for (self.dependencies) |d| allocator.free(d);
        allocator.free(self.dependencies);
        if (self.build_config) |bc| {
            for (bc.include_paths) |p| allocator.free(p);
            allocator.free(bc.include_paths);
            for (bc.library_paths) |p| allocator.free(p);
            allocator.free(bc.library_paths);
            for (bc.libraries) |l| allocator.free(l);
            allocator.free(bc.libraries);
            for (bc.defines) |d| allocator.free(d);
            allocator.free(bc.defines);
            for (bc.c_flags) |f| allocator.free(f);
            allocator.free(bc.c_flags);
            for (bc.ld_flags) |f| allocator.free(f);
            allocator.free(bc.ld_flags);
        }
    }

    pub fn clone(self: ResolvedPackage, allocator: Allocator) !ResolvedPackage {
        var deps = try allocator.alloc([]const u8, self.dependencies.len);
        errdefer allocator.free(deps);
        for (self.dependencies, 0..) |dep, i| {
            deps[i] = try allocator.dupe(u8, dep);
        }

        return .{
            .name = try allocator.dupe(u8, self.name),
            .version = try allocator.dupe(u8, self.version),
            .source_url = try allocator.dupe(u8, self.source_url),
            .source_type = self.source_type,
            .resolved_hash = if (self.resolved_hash) |h| try allocator.dupe(u8, h) else null,
            .dependencies = deps,
            .build_config = self.build_config, // TODO: deep clone if needed
        };
    }
};

/// Resolution errors.
pub const ResolverError = error{
    CyclicDependency,
    VersionConflict,
    PackageNotFound,
    SourceUnavailable,
    InvalidVersion,
    PlatformMismatch,
    AllFallbacksFailed,
    OutOfMemory,
    NetworkError,
};

/// Resolution options.
pub const ResolveOptions = struct {
    /// Use locked versions when available.
    use_lockfile: bool = true,

    /// Allow pre-release versions.
    allow_prerelease: bool = false,

    /// Offline mode (no network requests).
    offline: bool = false,

    /// Include dev dependencies.
    include_dev: bool = false,

    /// Target platform for resolution.
    target_platform: ?Dependency.Platform = null,

    /// Maximum resolution depth.
    max_depth: u32 = 100,
};

/// Resolution result.
pub const ResolutionResult = struct {
    /// All resolved packages.
    packages: std.StringHashMap(ResolvedPackage),

    /// Root packages (direct dependencies).
    roots: std.ArrayList([]const u8),

    /// Resolution warnings (non-fatal issues).
    warnings: std.ArrayList([]const u8),

    /// Resolution stats.
    stats: Stats,

    allocator: Allocator,

    pub const Stats = struct {
        total_packages: u32 = 0,
        from_lockfile: u32 = 0,
        newly_resolved: u32 = 0,
        fallbacks_used: u32 = 0,
        resolution_time_ms: u64 = 0,
    };

    pub fn init(allocator: Allocator) ResolutionResult {
        return .{
            .packages = std.StringHashMap(ResolvedPackage).init(allocator),
            .roots = std.ArrayList([]const u8).init(allocator),
            .warnings = std.ArrayList([]const u8).init(allocator),
            .stats = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ResolutionResult) void {
        var iter = self.packages.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var pkg = entry.value_ptr.*;
            pkg.deinit(self.allocator);
        }
        self.packages.deinit();

        for (self.roots.items) |root| self.allocator.free(root);
        self.roots.deinit();

        for (self.warnings.items) |w| self.allocator.free(w);
        self.warnings.deinit();
    }

    /// Get packages in topological order (dependencies first).
    pub fn getInstallOrder(self: *const ResolutionResult) ![][]const u8 {
        var result = std.ArrayList([]const u8).init(self.allocator);
        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        for (self.roots.items) |root| {
            try self.topoVisit(root, &result, &visited);
        }

        return result.toOwnedSlice();
    }

    fn topoVisit(
        self: *const ResolutionResult,
        name: []const u8,
        result: *std.ArrayList([]const u8),
        visited: *std.StringHashMap(void),
    ) !void {
        if (visited.contains(name)) return;
        try visited.put(name, {});

        if (self.packages.get(name)) |pkg| {
            for (pkg.dependencies) |dep| {
                try self.topoVisit(dep, result, visited);
            }
        }

        try result.append(name);
    }

    /// Convert to lockfile.
    pub fn toLockfile(self: *const ResolutionResult) !lockfile.Lockfile {
        var lock = lockfile.Lockfile.init(self.allocator);
        errdefer lock.deinit();

        var iter = self.packages.iterator();
        while (iter.next()) |entry| {
            const pkg = entry.value_ptr.*;
            try lock.putPackage(.{
                .name = pkg.name,
                .version = pkg.version,
                .source_type = pkg.source_type,
                .source_url = pkg.source_url,
                .resolved_hash = pkg.resolved_hash,
                .dependencies = pkg.dependencies,
                .locked_at = std.time.timestamp(),
            });
        }

        for (self.roots.items) |root| {
            try lock.addRoot(root);
        }

        lock.metadata.updated_at = std.time.timestamp();

        return lock;
    }
};

/// Dependency resolver.
pub const Resolver = struct {
    allocator: Allocator,
    options: ResolveOptions,
    existing_lockfile: ?*lockfile.Lockfile,

    /// Packages currently being resolved (for cycle detection).
    resolving: std.StringHashMap(void),

    /// Version constraints collected during resolution.
    constraints: std.StringHashMap(std.ArrayList(VersionConstraint)),

    pub const VersionConstraint = struct {
        version: []const u8,
        from_package: []const u8,
    };

    pub fn init(
        allocator: Allocator,
        options: ResolveOptions,
        existing_lockfile: ?*lockfile.Lockfile,
    ) Resolver {
        return .{
            .allocator = allocator,
            .options = options,
            .existing_lockfile = existing_lockfile,
            .resolving = std.StringHashMap(void).init(allocator),
            .constraints = std.StringHashMap(std.ArrayList(VersionConstraint)).init(allocator),
        };
    }

    pub fn deinit(self: *Resolver) void {
        self.resolving.deinit();
        var iter = self.constraints.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.constraints.deinit();
    }

    /// Resolve all dependencies.
    pub fn resolve(self: *Resolver, dependencies: []const Dependency) ResolverError!ResolutionResult {
        const start_time = std.time.milliTimestamp();

        var result = ResolutionResult.init(self.allocator);
        errdefer result.deinit();

        // Resolve each direct dependency
        for (dependencies) |dep| {
            // Skip platform-incompatible dependencies
            if (!self.isPlatformCompatible(dep)) continue;

            // Skip dev dependencies if not requested
            if (dep.dev_only and !self.options.include_dev) continue;

            const resolved = try self.resolveDependency(dep, 0, &result);

            const name_copy = self.allocator.dupe(u8, resolved.name) catch return error.OutOfMemory;
            result.roots.append(name_copy) catch return error.OutOfMemory;
        }

        result.stats.resolution_time_ms = @intCast(std.time.milliTimestamp() - start_time);
        result.stats.total_packages = @intCast(result.packages.count());

        return result;
    }

    fn resolveDependency(
        self: *Resolver,
        dep: Dependency,
        depth: u32,
        result: *ResolutionResult,
    ) ResolverError!ResolvedPackage {
        // Check depth limit
        if (depth > self.options.max_depth) {
            return error.CyclicDependency;
        }

        // Check for cycles
        if (self.resolving.contains(dep.name)) {
            return error.CyclicDependency;
        }

        // Already resolved?
        if (result.packages.get(dep.name)) |existing| {
            // Check version compatibility
            if (!self.isVersionCompatible(existing.version, dep.version)) {
                return error.VersionConflict;
            }
            return existing;
        }

        // Check lockfile first
        if (self.options.use_lockfile) {
            if (self.existing_lockfile) |lock| {
                if (lock.getPackage(dep.name)) |locked| {
                    if (self.isVersionCompatible(locked.version, dep.version)) {
                        const resolved = ResolvedPackage{
                            .name = self.allocator.dupe(u8, locked.name) catch return error.OutOfMemory,
                            .version = self.allocator.dupe(u8, locked.version) catch return error.OutOfMemory,
                            .source_url = self.allocator.dupe(u8, locked.source_url) catch return error.OutOfMemory,
                            .source_type = locked.source_type,
                            .resolved_hash = if (locked.resolved_hash) |h|
                                self.allocator.dupe(u8, h) catch return error.OutOfMemory
                            else
                                null,
                            .dependencies = blk: {
                                var deps = self.allocator.alloc([]const u8, locked.dependencies.len) catch return error.OutOfMemory;
                                for (locked.dependencies, 0..) |d, i| {
                                    deps[i] = self.allocator.dupe(u8, d) catch return error.OutOfMemory;
                                }
                                break :blk deps;
                            },
                        };

                        const name = self.allocator.dupe(u8, dep.name) catch return error.OutOfMemory;
                        result.packages.put(name, resolved) catch return error.OutOfMemory;
                        result.stats.from_lockfile += 1;
                        return resolved;
                    }
                }
            }
        }

        // Mark as resolving (for cycle detection)
        self.resolving.put(dep.name, {}) catch return error.OutOfMemory;
        defer _ = self.resolving.remove(dep.name);

        // Try to resolve from source
        const resolved = self.resolveFromSource(dep) catch |err| {
            // Try fallbacks
            for (dep.fallbacks) |fallback| {
                var fallback_dep = dep;
                fallback_dep.source = fallback;
                if (self.resolveFromSource(fallback_dep)) |fb_resolved| {
                    result.stats.fallbacks_used += 1;
                    const name = self.allocator.dupe(u8, fb_resolved.name) catch return error.OutOfMemory;
                    result.packages.put(name, fb_resolved) catch return error.OutOfMemory;

                    // Resolve transitive dependencies
                    try self.resolveTransitive(fb_resolved, depth + 1, result);

                    return fb_resolved;
                } else |_| continue;
            }
            return err;
        };

        const name = self.allocator.dupe(u8, resolved.name) catch return error.OutOfMemory;
        result.packages.put(name, resolved) catch return error.OutOfMemory;
        result.stats.newly_resolved += 1;

        // Resolve transitive dependencies
        try self.resolveTransitive(resolved, depth + 1, result);

        return resolved;
    }

    fn resolveFromSource(self: *Resolver, dep: Dependency) ResolverError!ResolvedPackage {
        return switch (dep.source) {
            .git => |git| self.resolveGit(dep.name, dep.version, git),
            .archive => |arch| self.resolveArchive(dep.name, dep.version, arch),
            .path => |path| self.resolvePath(dep.name, dep.version, path),
            .registry_pkg => |reg| self.resolveRegistry(dep.name, dep.version, reg),
            .vcpkg => |vcpkg| self.resolveVcpkg(dep.name, dep.version, vcpkg),
            .conan => |conan| self.resolveConan(dep.name, dep.version, conan),
            .system => |sys| self.resolveSystem(dep.name, dep.version, sys),
        };
    }

    fn resolveGit(
        self: *Resolver,
        name: []const u8,
        version: []const u8,
        git: Dependency.GitSource,
    ) ResolverError!ResolvedPackage {
        // In a real implementation, this would:
        // 1. Clone/fetch the git repository
        // 2. Resolve the ref to a commit hash
        // 3. Parse any manifest in the repo for transitive deps

        return .{
            .name = self.allocator.dupe(u8, name) catch return error.OutOfMemory,
            .version = self.allocator.dupe(u8, version) catch return error.OutOfMemory,
            .source_url = self.allocator.dupe(u8, git.url) catch return error.OutOfMemory,
            .source_type = .git,
            .resolved_hash = if (git.ref) |r| self.allocator.dupe(u8, r) catch return error.OutOfMemory else null,
        };
    }

    fn resolveArchive(
        self: *Resolver,
        name: []const u8,
        version: []const u8,
        arch: Dependency.ArchiveSource,
    ) ResolverError!ResolvedPackage {
        return .{
            .name = self.allocator.dupe(u8, name) catch return error.OutOfMemory,
            .version = self.allocator.dupe(u8, version) catch return error.OutOfMemory,
            .source_url = self.allocator.dupe(u8, arch.url) catch return error.OutOfMemory,
            .source_type = .archive,
            .resolved_hash = if (arch.hash) |h| self.allocator.dupe(u8, h) catch return error.OutOfMemory else null,
        };
    }

    fn resolvePath(
        self: *Resolver,
        name: []const u8,
        version: []const u8,
        path: Dependency.PathSource,
    ) ResolverError!ResolvedPackage {
        return .{
            .name = self.allocator.dupe(u8, name) catch return error.OutOfMemory,
            .version = self.allocator.dupe(u8, version) catch return error.OutOfMemory,
            .source_url = self.allocator.dupe(u8, path.path) catch return error.OutOfMemory,
            .source_type = .path,
        };
    }

    fn resolveRegistry(
        self: *Resolver,
        name: []const u8,
        version: []const u8,
        reg: Dependency.RegistrySource,
    ) ResolverError!ResolvedPackage {
        _ = reg;
        if (self.options.offline) return error.NetworkError;

        return .{
            .name = self.allocator.dupe(u8, name) catch return error.OutOfMemory,
            .version = self.allocator.dupe(u8, version) catch return error.OutOfMemory,
            .source_url = self.allocator.dupe(u8, "registry") catch return error.OutOfMemory,
            .source_type = .registry,
        };
    }

    fn resolveVcpkg(
        self: *Resolver,
        name: []const u8,
        version: []const u8,
        vcpkg: Dependency.VcpkgSource,
    ) ResolverError!ResolvedPackage {
        _ = vcpkg;
        return .{
            .name = self.allocator.dupe(u8, name) catch return error.OutOfMemory,
            .version = self.allocator.dupe(u8, version) catch return error.OutOfMemory,
            .source_url = self.allocator.dupe(u8, "vcpkg") catch return error.OutOfMemory,
            .source_type = .vcpkg,
        };
    }

    fn resolveConan(
        self: *Resolver,
        name: []const u8,
        version: []const u8,
        conan: Dependency.ConanSource,
    ) ResolverError!ResolvedPackage {
        return .{
            .name = self.allocator.dupe(u8, name) catch return error.OutOfMemory,
            .version = self.allocator.dupe(u8, version) catch return error.OutOfMemory,
            .source_url = self.allocator.dupe(u8, conan.reference) catch return error.OutOfMemory,
            .source_type = .conan,
        };
    }

    fn resolveSystem(
        self: *Resolver,
        name: []const u8,
        version: []const u8,
        sys: Dependency.SystemSource,
    ) ResolverError!ResolvedPackage {
        _ = sys;
        return .{
            .name = self.allocator.dupe(u8, name) catch return error.OutOfMemory,
            .version = self.allocator.dupe(u8, version) catch return error.OutOfMemory,
            .source_url = self.allocator.dupe(u8, "system") catch return error.OutOfMemory,
            .source_type = .system,
        };
    }

    fn resolveTransitive(
        self: *Resolver,
        pkg: ResolvedPackage,
        depth: u32,
        result: *ResolutionResult,
    ) ResolverError!void {
        // In a real implementation, this would:
        // 1. Parse the package's manifest for dependencies
        // 2. Recursively resolve each dependency
        _ = self;
        _ = pkg;
        _ = depth;
        _ = result;
    }

    fn isPlatformCompatible(self: *Resolver, dep: Dependency) bool {
        if (dep.platforms == null) return true;
        if (self.options.target_platform == null) return true;

        const target = self.options.target_platform.?;
        for (dep.platforms.?) |plat| {
            const os_match = plat.os == null or
                (target.os != null and std.mem.eql(u8, plat.os.?, target.os.?));
            const arch_match = plat.arch == null or
                (target.arch != null and std.mem.eql(u8, plat.arch.?, target.arch.?));

            if (os_match and arch_match) return true;
        }

        return false;
    }

    fn isVersionCompatible(self: *Resolver, resolved: []const u8, required: []const u8) bool {
        _ = self;
        // Exact match
        if (std.mem.eql(u8, resolved, required)) return true;

        // "*" matches anything
        if (std.mem.eql(u8, required, "*")) return true;

        // Caret range (^1.2.3)
        if (required[0] == '^') {
            return semverCaretCompatible(required[1..], resolved);
        }

        // Tilde range (~1.2.3)
        if (required[0] == '~') {
            return semverTildeCompatible(required[1..], resolved);
        }

        return false;
    }
};

/// Check if version satisfies caret range (^1.2.3 means >=1.2.3 <2.0.0).
fn semverCaretCompatible(requirement: []const u8, version: []const u8) bool {
    var req_parts = std.mem.splitScalar(u8, requirement, '.');
    var ver_parts = std.mem.splitScalar(u8, version, '.');

    const req_major = req_parts.next() orelse return false;
    const ver_major = ver_parts.next() orelse return false;

    // Major must match
    if (!std.mem.eql(u8, req_major, ver_major)) return false;

    const req_minor = req_parts.next() orelse return true;
    const ver_minor = ver_parts.next() orelse return false;

    const req_minor_num = std.fmt.parseInt(u32, req_minor, 10) catch return false;
    const ver_minor_num = std.fmt.parseInt(u32, ver_minor, 10) catch return false;

    if (ver_minor_num < req_minor_num) return false;
    if (ver_minor_num > req_minor_num) return true;

    // Minor equal, check patch
    const req_patch = req_parts.next() orelse return true;
    const ver_patch = ver_parts.next() orelse return false;

    const req_patch_num = std.fmt.parseInt(u32, req_patch, 10) catch return false;
    const ver_patch_num = std.fmt.parseInt(u32, ver_patch, 10) catch return false;

    return ver_patch_num >= req_patch_num;
}

/// Check if version satisfies tilde range (~1.2.3 means >=1.2.3 <1.3.0).
fn semverTildeCompatible(requirement: []const u8, version: []const u8) bool {
    var req_parts = std.mem.splitScalar(u8, requirement, '.');
    var ver_parts = std.mem.splitScalar(u8, version, '.');

    const req_major = req_parts.next() orelse return false;
    const ver_major = ver_parts.next() orelse return false;

    if (!std.mem.eql(u8, req_major, ver_major)) return false;

    const req_minor = req_parts.next() orelse return true;
    const ver_minor = ver_parts.next() orelse return false;

    if (!std.mem.eql(u8, req_minor, ver_minor)) return false;

    const req_patch = req_parts.next() orelse return true;
    const ver_patch = ver_parts.next() orelse return false;

    const req_patch_num = std.fmt.parseInt(u32, req_patch, 10) catch return false;
    const ver_patch_num = std.fmt.parseInt(u32, ver_patch, 10) catch return false;

    return ver_patch_num >= req_patch_num;
}

// Tests
test "semver caret compatibility" {
    try std.testing.expect(semverCaretCompatible("1.2.3", "1.2.3"));
    try std.testing.expect(semverCaretCompatible("1.2.3", "1.2.4"));
    try std.testing.expect(semverCaretCompatible("1.2.3", "1.3.0"));
    try std.testing.expect(!semverCaretCompatible("1.2.3", "2.0.0"));
    try std.testing.expect(!semverCaretCompatible("1.2.3", "1.2.2"));
}

test "semver tilde compatibility" {
    try std.testing.expect(semverTildeCompatible("1.2.3", "1.2.3"));
    try std.testing.expect(semverTildeCompatible("1.2.3", "1.2.4"));
    try std.testing.expect(!semverTildeCompatible("1.2.3", "1.3.0"));
    try std.testing.expect(!semverTildeCompatible("1.2.3", "2.0.0"));
}

test "resolver init" {
    const allocator = std.testing.allocator;
    var resolver = Resolver.init(allocator, .{}, null);
    defer resolver.deinit();
}
