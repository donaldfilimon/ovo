//! Package fetching and caching.
//!
//! Handles downloading packages from various sources (git, archives, etc.),
//! caching them locally, and verifying their integrity.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const json = std.json;
const integrity = @import("integrity.zig");
const lockfile = @import("lockfile.zig");
const resolver = @import("resolver.zig");

/// Fetch errors.
pub const FetchError = error{
    NetworkError,
    DownloadFailed,
    ExtractionFailed,
    HashMismatch,
    InvalidArchive,
    GitCloneFailed,
    CacheError,
    OutOfMemory,
    FileNotFound,
    AccessDenied,
    Timeout,
} || fs.File.OpenError || fs.File.ReadError;

/// Fetch result containing the local path and metadata.
pub const FetchResult = struct {
    /// Local path where the package is stored.
    path: []const u8,

    /// Content hash of the fetched package.
    content_hash: []const u8,

    /// For git: the resolved commit hash.
    resolved_ref: ?[]const u8 = null,

    /// Whether this was served from cache.
    from_cache: bool = false,

    pub fn deinit(self: *FetchResult, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content_hash);
        if (self.resolved_ref) |r| allocator.free(r);
    }
};

/// Fetch options.
pub const FetchOptions = struct {
    /// Force re-fetch even if cached.
    force: bool = false,

    /// Verify integrity after fetch.
    verify: bool = true,

    /// Offline mode (only use cache).
    offline: bool = false,

    /// Timeout in milliseconds.
    timeout_ms: u32 = 300000, // 5 minutes

    /// Number of retry attempts.
    retries: u32 = 3,

    /// Progress callback.
    on_progress: ?*const fn (current: u64, total: u64) void = null,
};

/// Cache configuration.
pub const CacheConfig = struct {
    /// Cache directory path.
    cache_dir: []const u8,

    /// Maximum cache size in bytes (0 = unlimited).
    max_size: u64 = 0,

    /// Cache TTL in seconds (0 = never expire).
    ttl_seconds: u64 = 0,
};

/// Package fetcher.
pub const Fetcher = struct {
    allocator: Allocator,
    cache_config: CacheConfig,
    options: FetchOptions,

    /// Cache index mapping content hashes to paths.
    cache_index: std.StringHashMap(CacheEntry),

    pub const CacheEntry = struct {
        path: []const u8,
        size: u64,
        fetched_at: i64,
        source_type: lockfile.SourceType,
    };

    pub fn init(allocator: Allocator, cache_config: CacheConfig, options: FetchOptions) !Fetcher {
        // Ensure cache directory exists
        fs.cwd().makePath(cache_config.cache_dir) catch |err| {
            if (err != error.PathAlreadyExists) return FetchError.CacheError;
        };

        var fetcher = Fetcher{
            .allocator = allocator,
            .cache_config = cache_config,
            .options = options,
            .cache_index = std.StringHashMap(CacheEntry).init(allocator),
        };

        // Load existing cache index
        try fetcher.loadCacheIndex();

        return fetcher;
    }

    pub fn deinit(self: *Fetcher) void {
        var iter = self.cache_index.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.path);
        }
        self.cache_index.deinit();
    }

    /// Fetch a package from resolved source.
    pub fn fetch(self: *Fetcher, pkg: resolver.ResolvedPackage) FetchError!FetchResult {
        return switch (pkg.source_type) {
            .git => self.fetchGit(pkg.name, pkg.source_url, pkg.resolved_hash),
            .archive => self.fetchArchive(pkg.name, pkg.source_url, pkg.resolved_hash),
            .path => self.fetchPath(pkg.name, pkg.source_url),
            .vcpkg => self.fetchVcpkg(pkg.name, pkg.version),
            .conan => self.fetchConan(pkg.name, pkg.source_url),
            .system => self.fetchSystem(pkg.name),
            .registry => self.fetchRegistry(pkg.name, pkg.version),
        };
    }

    /// Fetch a git repository.
    pub fn fetchGit(
        self: *Fetcher,
        name: []const u8,
        url: []const u8,
        ref: ?[]const u8,
    ) FetchError!FetchResult {
        // Check cache first
        const cache_key = self.makeCacheKey("git", url, ref);
        defer self.allocator.free(cache_key);

        if (!self.options.force) {
            if (self.cache_index.get(cache_key)) |entry| {
                // Verify cache entry still exists
                if (self.verifyCacheEntry(entry)) {
                    return FetchResult{
                        .path = self.allocator.dupe(u8, entry.path) catch return error.OutOfMemory,
                        .content_hash = self.allocator.dupe(u8, cache_key) catch return error.OutOfMemory,
                        .resolved_ref = if (ref) |r| self.allocator.dupe(u8, r) catch return error.OutOfMemory else null,
                        .from_cache = true,
                    };
                }
            }
        }

        if (self.options.offline) {
            return error.NetworkError;
        }

        // Create destination directory
        const dest_path = self.getCachePath(name, "git") catch return error.CacheError;
        defer self.allocator.free(dest_path);

        // Clone the repository
        try self.gitClone(url, dest_path, ref);

        // Get the resolved commit hash
        const commit_hash = try self.gitGetHead(dest_path);
        defer self.allocator.free(commit_hash);

        // Calculate content hash
        const content_hash = integrity.hashDirectory(self.allocator, dest_path) catch return error.CacheError;
        const hash_str = integrity.hashToString(content_hash);

        // Update cache index
        try self.updateCacheIndex(cache_key, dest_path, .git);

        return FetchResult{
            .path = self.allocator.dupe(u8, dest_path) catch return error.OutOfMemory,
            .content_hash = self.allocator.dupe(u8, &hash_str) catch return error.OutOfMemory,
            .resolved_ref = self.allocator.dupe(u8, commit_hash) catch return error.OutOfMemory,
            .from_cache = false,
        };
    }

    /// Fetch an archive (tarball, zip).
    pub fn fetchArchive(
        self: *Fetcher,
        name: []const u8,
        url: []const u8,
        expected_hash: ?[]const u8,
    ) FetchError!FetchResult {
        // Check cache first
        if (expected_hash) |hash| {
            if (!self.options.force) {
                if (self.cache_index.get(hash)) |entry| {
                    if (self.verifyCacheEntry(entry)) {
                        return FetchResult{
                            .path = self.allocator.dupe(u8, entry.path) catch return error.OutOfMemory,
                            .content_hash = self.allocator.dupe(u8, hash) catch return error.OutOfMemory,
                            .from_cache = true,
                        };
                    }
                }
            }
        }

        if (self.options.offline) {
            return error.NetworkError;
        }

        // Download the archive
        const archive_path = try self.download(url, name);
        defer self.allocator.free(archive_path);
        defer fs.cwd().deleteFile(archive_path) catch {};

        // Verify hash if provided
        if (expected_hash) |hash| {
            if (self.options.verify) {
                const result = integrity.verifyFileHex(self.allocator, archive_path, hash) catch return error.HashMismatch;
                if (!result.valid) {
                    return error.HashMismatch;
                }
            }
        }

        // Extract archive
        const dest_path = self.getCachePath(name, "archive") catch return error.CacheError;
        errdefer self.allocator.free(dest_path);

        try self.extractArchive(archive_path, dest_path);

        // Calculate content hash
        const content_hash = integrity.hashDirectory(self.allocator, dest_path) catch return error.CacheError;
        const hash_str = integrity.hashToString(content_hash);

        // Update cache index
        try self.updateCacheIndex(&hash_str, dest_path, .archive);

        return FetchResult{
            .path = dest_path,
            .content_hash = self.allocator.dupe(u8, &hash_str) catch return error.OutOfMemory,
            .from_cache = false,
        };
    }

    /// Fetch from local path (just validate and return).
    pub fn fetchPath(
        self: *Fetcher,
        name: []const u8,
        path: []const u8,
    ) FetchError!FetchResult {
        _ = name;

        // Verify path exists
        fs.cwd().access(path, .{}) catch return error.FileNotFound;

        // Calculate content hash
        const content_hash = integrity.hashDirectory(self.allocator, path) catch {
            // Might be a file, not directory
            const file_hash = integrity.hashFile(self.allocator, path) catch return error.FileNotFound;
            const hash_str = integrity.hashToString(file_hash);
            return FetchResult{
                .path = self.allocator.dupe(u8, path) catch return error.OutOfMemory,
                .content_hash = self.allocator.dupe(u8, &hash_str) catch return error.OutOfMemory,
                .from_cache = false,
            };
        };

        const hash_str = integrity.hashToString(content_hash);

        return FetchResult{
            .path = self.allocator.dupe(u8, path) catch return error.OutOfMemory,
            .content_hash = self.allocator.dupe(u8, &hash_str) catch return error.OutOfMemory,
            .from_cache = false,
        };
    }

    /// Fetch via vcpkg.
    pub fn fetchVcpkg(
        self: *Fetcher,
        name: []const u8,
        version: []const u8,
    ) FetchError!FetchResult {
        // vcpkg manages its own cache, we just need to ensure it's installed
        const vcpkg_root = self.getVcpkgRoot() catch return error.FileNotFound;
        defer self.allocator.free(vcpkg_root);

        const package_path = std.fmt.allocPrint(
            self.allocator,
            "{s}/installed/{s}",
            .{ vcpkg_root, name },
        ) catch return error.OutOfMemory;

        // Check if already installed
        fs.cwd().access(package_path, .{}) catch {
            // Need to install
            try self.vcpkgInstall(name, vcpkg_root);
        };

        const hash_str = std.fmt.allocPrint(
            self.allocator,
            "vcpkg:{s}@{s}",
            .{ name, version },
        ) catch return error.OutOfMemory;

        return FetchResult{
            .path = package_path,
            .content_hash = hash_str,
            .from_cache = true,
        };
    }

    /// Fetch via Conan.
    pub fn fetchConan(
        self: *Fetcher,
        name: []const u8,
        reference: []const u8,
    ) FetchError!FetchResult {
        // Conan manages its own cache
        const conan_cache = self.getConanCache() catch return error.FileNotFound;
        defer self.allocator.free(conan_cache);

        // Install the package
        try self.conanInstall(reference);

        const hash_str = std.fmt.allocPrint(
            self.allocator,
            "conan:{s}",
            .{reference},
        ) catch return error.OutOfMemory;

        const package_path = std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ conan_cache, name },
        ) catch return error.OutOfMemory;

        return FetchResult{
            .path = package_path,
            .content_hash = hash_str,
            .from_cache = true,
        };
    }

    /// Fetch system library info.
    pub fn fetchSystem(
        self: *Fetcher,
        name: []const u8,
    ) FetchError!FetchResult {
        // System libraries aren't fetched, just located
        const hash_str = std.fmt.allocPrint(
            self.allocator,
            "system:{s}",
            .{name},
        ) catch return error.OutOfMemory;

        return FetchResult{
            .path = self.allocator.dupe(u8, "system") catch return error.OutOfMemory,
            .content_hash = hash_str,
            .from_cache = true,
        };
    }

    /// Fetch from registry.
    pub fn fetchRegistry(
        self: *Fetcher,
        name: []const u8,
        version: []const u8,
    ) FetchError!FetchResult {
        if (self.options.offline) {
            return error.NetworkError;
        }

        // In a real implementation, this would:
        // 1. Query the registry for download URL
        // 2. Download the archive
        // 3. Verify integrity
        // 4. Extract to cache

        const hash_str = std.fmt.allocPrint(
            self.allocator,
            "registry:{s}@{s}",
            .{ name, version },
        ) catch return error.OutOfMemory;

        const path = self.getCachePath(name, "registry") catch return error.CacheError;

        return FetchResult{
            .path = path,
            .content_hash = hash_str,
            .from_cache = false,
        };
    }

    // --- Helper functions ---

    fn makeCacheKey(self: *Fetcher, source: []const u8, url: []const u8, ref: ?[]const u8) []const u8 {
        if (ref) |r| {
            return std.fmt.allocPrint(self.allocator, "{s}:{s}@{s}", .{ source, url, r }) catch "";
        }
        return std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ source, url }) catch "";
    }

    fn getCachePath(self: *Fetcher, name: []const u8, source: []const u8) ![]const u8 {
        const timestamp = std.time.timestamp();
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/{s}-{d}",
            .{ self.cache_config.cache_dir, source, name, timestamp },
        );
    }

    fn verifyCacheEntry(self: *Fetcher, entry: CacheEntry) bool {
        // Check TTL
        if (self.cache_config.ttl_seconds > 0) {
            const now = std.time.timestamp();
            const age: u64 = @intCast(now - entry.fetched_at);
            if (age > self.cache_config.ttl_seconds) {
                return false;
            }
        }

        // Verify path exists
        fs.cwd().access(entry.path, .{}) catch return false;

        return true;
    }

    fn updateCacheIndex(
        self: *Fetcher,
        key: []const u8,
        path: []const u8,
        source_type: lockfile.SourceType,
    ) !void {
        const key_copy = self.allocator.dupe(u8, key) catch return error.OutOfMemory;
        errdefer self.allocator.free(key_copy);

        const path_copy = self.allocator.dupe(u8, path) catch return error.OutOfMemory;
        errdefer self.allocator.free(path_copy);

        const entry = CacheEntry{
            .path = path_copy,
            .size = 0, // TODO: calculate actual size
            .fetched_at = std.time.timestamp(),
            .source_type = source_type,
        };

        self.cache_index.put(key_copy, entry) catch return error.OutOfMemory;

        // Save cache index
        self.saveCacheIndex() catch {};
    }

    fn loadCacheIndex(self: *Fetcher) !void {
        const index_path = std.fs.path.join(self.allocator, &.{
            self.cache_config.cache_dir,
            "index.json",
        }) catch return;
        defer self.allocator.free(index_path);

        const file = fs.cwd().openFile(index_path, .{}) catch return;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch return;
        defer self.allocator.free(content);

        const parsed = json.parseFromSlice(json.Value, self.allocator, content, .{}) catch return;
        defer parsed.deinit();

        const entries = parsed.value.object.get("entries") orelse return;
        var iter = entries.object.iterator();
        while (iter.next()) |entry| {
            const obj = entry.value_ptr.object;
            const key = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
            const path = self.allocator.dupe(u8, obj.get("path").?.string) catch {
                self.allocator.free(key);
                continue;
            };

            self.cache_index.put(key, .{
                .path = path,
                .size = @intCast(obj.get("size").?.integer),
                .fetched_at = obj.get("fetched_at").?.integer,
                .source_type = lockfile.SourceType.fromString(obj.get("source_type").?.string) orelse .git,
            }) catch {
                self.allocator.free(key);
                self.allocator.free(path);
            };
        }
    }

    fn saveCacheIndex(self: *Fetcher) !void {
        const index_path = try std.fs.path.join(self.allocator, &.{
            self.cache_config.cache_dir,
            "index.json",
        });
        defer self.allocator.free(index_path);

        const file = try fs.cwd().createFile(index_path, .{});
        defer file.close();

        var buffered = std.io.bufferedWriter(file.writer());
        const writer = buffered.writer();

        try writer.writeAll("{\"entries\":{");

        var first = true;
        var iter = self.cache_index.iterator();
        while (iter.next()) |entry| {
            if (!first) try writer.writeAll(",");
            first = false;

            try writer.print("\"{s}\":{{", .{entry.key_ptr.*});
            try writer.print("\"path\":\"{s}\",", .{entry.value_ptr.path});
            try writer.print("\"size\":{d},", .{entry.value_ptr.size});
            try writer.print("\"fetched_at\":{d},", .{entry.value_ptr.fetched_at});
            try writer.print("\"source_type\":\"{s}\"", .{entry.value_ptr.source_type.toString()});
            try writer.writeAll("}");
        }

        try writer.writeAll("}}");
        try buffered.flush();
    }

    fn gitClone(self: *Fetcher, url: []const u8, dest: []const u8, ref: ?[]const u8) !void {
        // Create destination directory
        fs.cwd().makePath(dest) catch |err| {
            if (err != error.PathAlreadyExists) return error.CacheError;
        };

        // Build git clone command
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.appendSlice(&.{ "git", "clone", "--depth", "1" });

        if (ref) |r| {
            try args.appendSlice(&.{ "--branch", r });
        }

        try args.appendSlice(&.{ url, dest });

        // Execute git clone
        var child = std.process.Child.init(args.items, self.allocator);
        child.spawn() catch return error.GitCloneFailed;
        const result = child.wait() catch return error.GitCloneFailed;

        if (result.Exited != 0) {
            return error.GitCloneFailed;
        }
    }

    fn gitGetHead(self: *Fetcher, repo_path: []const u8) ![]const u8 {
        var child = std.process.Child.init(&.{ "git", "-C", repo_path, "rev-parse", "HEAD" }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.spawn() catch return error.GitCloneFailed;

        const stdout = child.stdout orelse return error.GitCloneFailed;
        const output = stdout.reader().readAllAlloc(self.allocator, 1024) catch return error.GitCloneFailed;

        _ = child.wait() catch return error.GitCloneFailed;

        // Trim newline
        const trimmed = std.mem.trim(u8, output, "\n\r ");
        if (trimmed.len != output.len) {
            const result = self.allocator.dupe(u8, trimmed) catch return error.OutOfMemory;
            self.allocator.free(output);
            return result;
        }

        return output;
    }

    fn download(self: *Fetcher, url: []const u8, name: []const u8) ![]const u8 {
        const dest_path = std.fmt.allocPrint(
            self.allocator,
            "{s}/downloads/{s}",
            .{ self.cache_config.cache_dir, name },
        ) catch return error.OutOfMemory;

        // Use curl or wget for download
        var child = std.process.Child.init(&.{
            "curl", "-L", "-o", dest_path, "--max-time", "300", url,
        }, self.allocator);

        child.spawn() catch return error.DownloadFailed;
        const result = child.wait() catch return error.DownloadFailed;

        if (result.Exited != 0) {
            self.allocator.free(dest_path);
            return error.DownloadFailed;
        }

        return dest_path;
    }

    fn extractArchive(self: *Fetcher, archive: []const u8, dest: []const u8) !void {
        // Create destination
        fs.cwd().makePath(dest) catch |err| {
            if (err != error.PathAlreadyExists) return error.ExtractionFailed;
        };

        // Detect archive type and extract
        if (std.mem.endsWith(u8, archive, ".tar.gz") or std.mem.endsWith(u8, archive, ".tgz")) {
            var child = std.process.Child.init(&.{
                "tar", "-xzf", archive, "-C", dest,
            }, self.allocator);
            child.spawn() catch return error.ExtractionFailed;
            const result = child.wait() catch return error.ExtractionFailed;
            if (result.Exited != 0) return error.ExtractionFailed;
        } else if (std.mem.endsWith(u8, archive, ".zip")) {
            var child = std.process.Child.init(&.{
                "unzip", "-q", archive, "-d", dest,
            }, self.allocator);
            child.spawn() catch return error.ExtractionFailed;
            const result = child.wait() catch return error.ExtractionFailed;
            if (result.Exited != 0) return error.ExtractionFailed;
        } else if (std.mem.endsWith(u8, archive, ".tar.xz")) {
            var child = std.process.Child.init(&.{
                "tar", "-xJf", archive, "-C", dest,
            }, self.allocator);
            child.spawn() catch return error.ExtractionFailed;
            const result = child.wait() catch return error.ExtractionFailed;
            if (result.Exited != 0) return error.ExtractionFailed;
        } else {
            return error.InvalidArchive;
        }
    }

    fn getVcpkgRoot(self: *Fetcher) ![]const u8 {
        // Check VCPKG_ROOT environment variable
        if (std.posix.getenv("VCPKG_ROOT")) |root| {
            return self.allocator.dupe(u8, root);
        }

        // Check common locations
        const home = std.posix.getenv("HOME") orelse return error.FileNotFound;
        const vcpkg_path = std.fmt.allocPrint(self.allocator, "{s}/vcpkg", .{home}) catch return error.OutOfMemory;

        fs.cwd().access(vcpkg_path, .{}) catch {
            self.allocator.free(vcpkg_path);
            return error.FileNotFound;
        };

        return vcpkg_path;
    }

    fn vcpkgInstall(self: *Fetcher, name: []const u8, vcpkg_root: []const u8) !void {
        const vcpkg_exe = std.fmt.allocPrint(self.allocator, "{s}/vcpkg", .{vcpkg_root}) catch return error.OutOfMemory;
        defer self.allocator.free(vcpkg_exe);

        var child = std.process.Child.init(&.{ vcpkg_exe, "install", name }, self.allocator);
        child.spawn() catch return error.DownloadFailed;
        const result = child.wait() catch return error.DownloadFailed;

        if (result.Exited != 0) {
            return error.DownloadFailed;
        }
    }

    fn getConanCache(self: *Fetcher) ![]const u8 {
        // Check CONAN_USER_HOME environment variable
        if (std.posix.getenv("CONAN_USER_HOME")) |home| {
            return std.fmt.allocPrint(self.allocator, "{s}/.conan/data", .{home});
        }

        const home = std.posix.getenv("HOME") orelse return error.FileNotFound;
        return std.fmt.allocPrint(self.allocator, "{s}/.conan/data", .{home});
    }

    fn conanInstall(self: *Fetcher, reference: []const u8) !void {
        var child = std.process.Child.init(&.{ "conan", "install", reference }, self.allocator);
        child.spawn() catch return error.DownloadFailed;
        const result = child.wait() catch return error.DownloadFailed;

        if (result.Exited != 0) {
            return error.DownloadFailed;
        }
    }

    /// Clean old cache entries.
    pub fn cleanCache(self: *Fetcher) !void {
        const now = std.time.timestamp();
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();

        var iter = self.cache_index.iterator();
        while (iter.next()) |entry| {
            const age: u64 = @intCast(now - entry.value_ptr.fetched_at);
            if (self.cache_config.ttl_seconds > 0 and age > self.cache_config.ttl_seconds) {
                try to_remove.append(entry.key_ptr.*);
            }
        }

        for (to_remove.items) |key| {
            if (self.cache_index.fetchRemove(key)) |removed| {
                // Delete the cached files
                fs.cwd().deleteTree(removed.value.path) catch {};
                self.allocator.free(removed.key);
                self.allocator.free(removed.value.path);
            }
        }

        try self.saveCacheIndex();
    }

    /// Get cache statistics.
    pub fn getCacheStats(self: *Fetcher) CacheStats {
        var stats = CacheStats{};

        var iter = self.cache_index.iterator();
        while (iter.next()) |entry| {
            stats.total_entries += 1;
            stats.total_size += entry.value_ptr.size;

            switch (entry.value_ptr.source_type) {
                .git => stats.git_entries += 1,
                .archive => stats.archive_entries += 1,
                .vcpkg => stats.vcpkg_entries += 1,
                .conan => stats.conan_entries += 1,
                else => {},
            }
        }

        return stats;
    }

    pub const CacheStats = struct {
        total_entries: u32 = 0,
        total_size: u64 = 0,
        git_entries: u32 = 0,
        archive_entries: u32 = 0,
        vcpkg_entries: u32 = 0,
        conan_entries: u32 = 0,
    };
};

// Tests
test "fetcher init" {
    const allocator = std.testing.allocator;

    var fetcher = try Fetcher.init(allocator, .{
        .cache_dir = "/tmp/ovo-test-cache",
    }, .{});
    defer fetcher.deinit();
}

test "cache key generation" {
    const allocator = std.testing.allocator;

    var fetcher = try Fetcher.init(allocator, .{
        .cache_dir = "/tmp/ovo-test-cache",
    }, .{});
    defer fetcher.deinit();

    const key1 = fetcher.makeCacheKey("git", "https://github.com/test/repo", "v1.0.0");
    defer allocator.free(key1);
    try std.testing.expect(std.mem.indexOf(u8, key1, "git:") != null);
    try std.testing.expect(std.mem.indexOf(u8, key1, "@v1.0.0") != null);

    const key2 = fetcher.makeCacheKey("git", "https://github.com/test/repo", null);
    defer allocator.free(key2);
    try std.testing.expect(std.mem.indexOf(u8, key2, "@") == null);
}
