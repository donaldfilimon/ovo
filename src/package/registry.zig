//! Package registry interface for central package discovery.
//!
//! While ovo is decentralized by default (git URLs, paths), this module
//! provides an interface for optional central registries that can provide
//! package discovery, search, and metadata.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const Uri = std.Uri;

/// Default registry URL (can be overridden in config).
pub const default_registry_url = "https://registry.ovo.dev/api/v1";

/// Package metadata from registry.
pub const PackageMetadata = struct {
    /// Package name.
    name: []const u8,

    /// Latest version.
    latest_version: []const u8,

    /// All available versions.
    versions: []const []const u8,

    /// Package description.
    description: ?[]const u8 = null,

    /// Package homepage.
    homepage: ?[]const u8 = null,

    /// Repository URL.
    repository: ?[]const u8 = null,

    /// Package license.
    license: ?[]const u8 = null,

    /// Package authors.
    authors: []const []const u8 = &.{},

    /// Keywords/tags.
    keywords: []const []const u8 = &.{},

    /// Download count.
    downloads: u64 = 0,

    /// When last updated.
    updated_at: ?i64 = null,

    pub fn deinit(self: *PackageMetadata, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.latest_version);
        for (self.versions) |v| allocator.free(v);
        allocator.free(self.versions);
        if (self.description) |d| allocator.free(d);
        if (self.homepage) |h| allocator.free(h);
        if (self.repository) |r| allocator.free(r);
        if (self.license) |l| allocator.free(l);
        for (self.authors) |a| allocator.free(a);
        allocator.free(self.authors);
        for (self.keywords) |k| allocator.free(k);
        allocator.free(self.keywords);
    }
};

/// Version-specific metadata.
pub const VersionMetadata = struct {
    /// Version string.
    version: []const u8,

    /// Download URL.
    download_url: []const u8,

    /// Integrity hash (SHA256).
    integrity: []const u8,

    /// Dependencies.
    dependencies: []const Dependency = &.{},

    /// When published.
    published_at: ?i64 = null,

    /// Yanked flag.
    yanked: bool = false,

    /// Yanked reason.
    yanked_reason: ?[]const u8 = null,

    pub const Dependency = struct {
        name: []const u8,
        version_req: []const u8,
        optional: bool = false,
    };

    pub fn deinit(self: *VersionMetadata, allocator: Allocator) void {
        allocator.free(self.version);
        allocator.free(self.download_url);
        allocator.free(self.integrity);
        for (self.dependencies) |d| {
            allocator.free(d.name);
            allocator.free(d.version_req);
        }
        allocator.free(self.dependencies);
        if (self.yanked_reason) |r| allocator.free(r);
    }
};

/// Search result from registry.
pub const SearchResult = struct {
    /// Total number of results.
    total: u64,

    /// Results for current page.
    packages: []PackageMetadata,

    /// Pagination info.
    page: u32 = 1,
    per_page: u32 = 20,

    pub fn deinit(self: *SearchResult, allocator: Allocator) void {
        for (self.packages) |*pkg| {
            pkg.deinit(allocator);
        }
        allocator.free(self.packages);
    }
};

/// Registry error types.
pub const RegistryError = error{
    NetworkError,
    PackageNotFound,
    VersionNotFound,
    InvalidResponse,
    RateLimited,
    Unauthorized,
    ServerError,
    OutOfMemory,
};

/// Registry configuration.
pub const RegistryConfig = struct {
    /// Registry URL.
    url: []const u8 = default_registry_url,

    /// Authentication token.
    token: ?[]const u8 = null,

    /// Request timeout in milliseconds.
    timeout_ms: u32 = 30000,

    /// Enable caching.
    cache_enabled: bool = true,

    /// Cache TTL in seconds.
    cache_ttl_seconds: u32 = 3600,
};

/// Registry client for interacting with package registries.
pub const Registry = struct {
    allocator: Allocator,
    config: RegistryConfig,

    /// Response cache.
    cache: std.StringHashMap(CacheEntry),

    const CacheEntry = struct {
        data: []const u8,
        expires_at: i64,
    };

    pub fn init(allocator: Allocator, config: RegistryConfig) Registry {
        return .{
            .allocator = allocator,
            .config = config,
            .cache = std.StringHashMap(CacheEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.data);
        }
        self.cache.deinit();
    }

    /// Get package metadata.
    pub fn getPackage(self: *Registry, name: []const u8) RegistryError!PackageMetadata {
        const path = std.fmt.allocPrint(self.allocator, "/packages/{s}", .{name}) catch return error.OutOfMemory;
        defer self.allocator.free(path);

        const response = try self.request(path);
        defer self.allocator.free(response);

        return self.parsePackageMetadata(response);
    }

    /// Get version-specific metadata.
    pub fn getVersion(self: *Registry, name: []const u8, version: []const u8) RegistryError!VersionMetadata {
        const path = std.fmt.allocPrint(self.allocator, "/packages/{s}/versions/{s}", .{ name, version }) catch return error.OutOfMemory;
        defer self.allocator.free(path);

        const response = try self.request(path);
        defer self.allocator.free(response);

        return self.parseVersionMetadata(response);
    }

    /// Search packages.
    pub fn search(self: *Registry, query: []const u8, options: SearchOptions) RegistryError!SearchResult {
        const path = std.fmt.allocPrint(
            self.allocator,
            "/search?q={s}&page={d}&per_page={d}",
            .{ query, options.page, options.per_page },
        ) catch return error.OutOfMemory;
        defer self.allocator.free(path);

        const response = try self.request(path);
        defer self.allocator.free(response);

        return self.parseSearchResult(response);
    }

    pub const SearchOptions = struct {
        page: u32 = 1,
        per_page: u32 = 20,
        sort: SortBy = .relevance,

        pub const SortBy = enum {
            relevance,
            downloads,
            updated,
            name,
        };
    };

    /// Check if a package exists.
    pub fn exists(self: *Registry, name: []const u8) bool {
        _ = self.getPackage(name) catch return false;
        return true;
    }

    /// Get download URL for a version.
    pub fn getDownloadUrl(self: *Registry, name: []const u8, version: []const u8) RegistryError![]const u8 {
        const meta = try self.getVersion(name, version);
        defer {
            var m = meta;
            m.deinit(self.allocator);
        }
        return self.allocator.dupe(u8, meta.download_url) catch return error.OutOfMemory;
    }

    /// Resolve version requirement to exact version.
    pub fn resolveVersion(self: *Registry, name: []const u8, requirement: []const u8) RegistryError![]const u8 {
        const pkg = try self.getPackage(name);
        defer {
            var p = pkg;
            p.deinit(self.allocator);
        }

        // If requirement is "latest" or "*", return latest version
        if (std.mem.eql(u8, requirement, "latest") or std.mem.eql(u8, requirement, "*")) {
            return self.allocator.dupe(u8, pkg.latest_version) catch return error.OutOfMemory;
        }

        // Try to find exact match first
        for (pkg.versions) |v| {
            if (std.mem.eql(u8, v, requirement)) {
                return self.allocator.dupe(u8, v) catch return error.OutOfMemory;
            }
        }

        // Try semver matching (simplified)
        if (requirement[0] == '^' or requirement[0] == '~') {
            const base = requirement[1..];
            for (pkg.versions) |v| {
                if (semverCompatible(base, v)) {
                    return self.allocator.dupe(u8, v) catch return error.OutOfMemory;
                }
            }
        }

        return error.VersionNotFound;
    }

    fn request(self: *Registry, path: []const u8) RegistryError![]const u8 {
        // Check cache first
        if (self.config.cache_enabled) {
            if (self.cache.get(path)) |entry| {
                const now = std.time.timestamp();
                if (now < entry.expires_at) {
                    return self.allocator.dupe(u8, entry.data) catch return error.OutOfMemory;
                }
            }
        }

        const full_url = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.config.url, path }) catch return error.OutOfMemory;
        defer self.allocator.free(full_url);

        // TODO: Implement actual HTTP request using std.http.Client
        // For now, return a placeholder that indicates network functionality
        // would be implemented here with proper HTTP handling.
        //
        // In a real implementation:
        // var client = std.http.Client{ .allocator = self.allocator };
        // defer client.deinit();
        // const result = try client.fetch(.{
        //     .url = full_url,
        //     .headers = .{
        //         .authorization = if (self.config.token) |t| t else null,
        //     },
        // });

        return error.NetworkError;
    }

    fn parsePackageMetadata(self: *Registry, data: []const u8) RegistryError!PackageMetadata {
        const parsed = json.parseFromSlice(json.Value, self.allocator, data, .{}) catch return error.InvalidResponse;
        defer parsed.deinit();

        const root = parsed.value.object;

        var versions = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (versions.items) |v| self.allocator.free(v);
            versions.deinit();
        }

        if (root.get("versions")) |vers| {
            for (vers.array.items) |v| {
                const ver = self.allocator.dupe(u8, v.string) catch return error.OutOfMemory;
                versions.append(ver) catch return error.OutOfMemory;
            }
        }

        return .{
            .name = self.allocator.dupe(u8, root.get("name").?.string) catch return error.OutOfMemory,
            .latest_version = self.allocator.dupe(u8, root.get("latest_version").?.string) catch return error.OutOfMemory,
            .versions = versions.toOwnedSlice() catch return error.OutOfMemory,
            .description = if (root.get("description")) |d| self.allocator.dupe(u8, d.string) catch return error.OutOfMemory else null,
            .repository = if (root.get("repository")) |r| self.allocator.dupe(u8, r.string) catch return error.OutOfMemory else null,
        };
    }

    fn parseVersionMetadata(self: *Registry, data: []const u8) RegistryError!VersionMetadata {
        const parsed = json.parseFromSlice(json.Value, self.allocator, data, .{}) catch return error.InvalidResponse;
        defer parsed.deinit();

        const root = parsed.value.object;

        return .{
            .version = self.allocator.dupe(u8, root.get("version").?.string) catch return error.OutOfMemory,
            .download_url = self.allocator.dupe(u8, root.get("download_url").?.string) catch return error.OutOfMemory,
            .integrity = self.allocator.dupe(u8, root.get("integrity").?.string) catch return error.OutOfMemory,
            .yanked = if (root.get("yanked")) |y| y.bool else false,
        };
    }

    fn parseSearchResult(self: *Registry, data: []const u8) RegistryError!SearchResult {
        const parsed = json.parseFromSlice(json.Value, self.allocator, data, .{}) catch return error.InvalidResponse;
        defer parsed.deinit();

        const root = parsed.value.object;

        var packages = std.ArrayList(PackageMetadata).init(self.allocator);
        errdefer {
            for (packages.items) |*p| p.deinit(self.allocator);
            packages.deinit();
        }

        if (root.get("packages")) |pkgs| {
            for (pkgs.array.items) |pkg_val| {
                var buffer = std.ArrayList(u8).init(self.allocator);
                defer buffer.deinit();
                json.stringify(pkg_val, .{}, buffer.writer()) catch return error.OutOfMemory;
                const pkg = self.parsePackageMetadata(buffer.items) catch continue;
                packages.append(pkg) catch return error.OutOfMemory;
            }
        }

        return .{
            .total = @intCast(root.get("total").?.integer),
            .packages = packages.toOwnedSlice() catch return error.OutOfMemory,
            .page = @intCast(root.get("page").?.integer),
            .per_page = @intCast(root.get("per_page").?.integer),
        };
    }
};

/// Simplified semver compatibility check.
fn semverCompatible(requirement: []const u8, version: []const u8) bool {
    // Parse major.minor.patch
    var req_parts = std.mem.splitScalar(u8, requirement, '.');
    var ver_parts = std.mem.splitScalar(u8, version, '.');

    const req_major = req_parts.next() orelse return false;
    const ver_major = ver_parts.next() orelse return false;

    // Major version must match for ^
    if (!std.mem.eql(u8, req_major, ver_major)) return false;

    const req_minor = req_parts.next() orelse return true;
    const ver_minor = ver_parts.next() orelse return false;

    // For ^, minor can be >= requirement
    const req_minor_num = std.fmt.parseInt(u32, req_minor, 10) catch return false;
    const ver_minor_num = std.fmt.parseInt(u32, ver_minor, 10) catch return false;

    return ver_minor_num >= req_minor_num;
}

/// Offline registry for local/cached packages.
pub const OfflineRegistry = struct {
    allocator: Allocator,
    cache_dir: []const u8,
    index: std.StringHashMap(PackageMetadata),

    pub fn init(allocator: Allocator, cache_dir: []const u8) OfflineRegistry {
        return .{
            .allocator = allocator,
            .cache_dir = cache_dir,
            .index = std.StringHashMap(PackageMetadata).init(allocator),
        };
    }

    pub fn deinit(self: *OfflineRegistry) void {
        var iter = self.index.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var meta = entry.value_ptr.*;
            meta.deinit(self.allocator);
        }
        self.index.deinit();
    }

    pub fn loadIndex(self: *OfflineRegistry) !void {
        const index_path = try std.fs.path.join(self.allocator, &.{ self.cache_dir, "index.json" });
        defer self.allocator.free(index_path);

        const file = std.fs.cwd().openFile(index_path, .{}) catch return;
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        // Parse and populate index...
        // TODO: Implement actual parsing
        self.allocator.free(content);
    }

    pub fn getPackage(self: *OfflineRegistry, name: []const u8) ?PackageMetadata {
        return self.index.get(name);
    }
};

// Tests
test "semver compatibility" {
    try std.testing.expect(semverCompatible("1.0.0", "1.0.0"));
    try std.testing.expect(semverCompatible("1.0.0", "1.2.0"));
    try std.testing.expect(semverCompatible("1.2.0", "1.2.3"));
    try std.testing.expect(!semverCompatible("1.0.0", "2.0.0"));
    try std.testing.expect(!semverCompatible("1.5.0", "1.4.0"));
}

test "registry init" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator, .{});
    defer registry.deinit();

    try std.testing.expectEqualStrings(default_registry_url, registry.config.url);
}
