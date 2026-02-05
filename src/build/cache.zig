//! Incremental build cache for the ovo build system.
//! Provides content hashing, dirty detection, and manifest management.
const std = @import("std");

/// Hash algorithm used for content hashing.
pub const HashAlgorithm = std.hash.XxHash64;

/// A unique identifier for a cached item based on its inputs.
pub const CacheKey = struct {
    /// Hash of the source file content
    source_hash: u64,
    /// Hash of compiler flags and options
    flags_hash: u64,
    /// Hash of dependency file contents
    deps_hash: u64,
    /// Combined hash for lookup
    combined: u64,

    pub fn compute(source_hash: u64, flags_hash: u64, deps_hash: u64) CacheKey {
        var hasher = HashAlgorithm.init(0);
        hasher.update(std.mem.asBytes(&source_hash));
        hasher.update(std.mem.asBytes(&flags_hash));
        hasher.update(std.mem.asBytes(&deps_hash));
        return .{
            .source_hash = source_hash,
            .flags_hash = flags_hash,
            .deps_hash = deps_hash,
            .combined = hasher.final(),
        };
    }

    pub fn eql(self: CacheKey, other: CacheKey) bool {
        return self.combined == other.combined and
            self.source_hash == other.source_hash and
            self.flags_hash == other.flags_hash and
            self.deps_hash == other.deps_hash;
    }
};

/// Entry in the build cache representing a compiled unit.
pub const CacheEntry = struct {
    /// The cache key for this entry
    key: CacheKey,
    /// Path to the cached output file
    output_path: []const u8,
    /// Size of the output in bytes
    output_size: u64,
    /// Timestamp when entry was created
    timestamp: i64,
    /// List of input file paths (for invalidation)
    input_files: []const []const u8,
    /// Whether this entry has been verified this session
    verified: bool,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, key: CacheKey, output_path: []const u8) !CacheEntry {
        return .{
            .key = key,
            .output_path = try allocator.dupe(u8, output_path),
            .output_size = 0,
            .timestamp = std.time.timestamp(),
            .input_files = &.{},
            .verified = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CacheEntry) void {
        self.allocator.free(self.output_path);
        for (self.input_files) |path| {
            self.allocator.free(path);
        }
        if (self.input_files.len > 0) {
            self.allocator.free(self.input_files);
        }
        self.* = undefined;
    }

    pub fn setInputFiles(self: *CacheEntry, files: []const []const u8) !void {
        // Free old input files
        for (self.input_files) |path| {
            self.allocator.free(path);
        }
        if (self.input_files.len > 0) {
            self.allocator.free(self.input_files);
        }

        // Copy new input files
        const new_files = try self.allocator.alloc([]const u8, files.len);
        errdefer self.allocator.free(new_files);

        for (files, 0..) |file, i| {
            new_files[i] = try self.allocator.dupe(u8, file);
        }
        self.input_files = new_files;
    }
};

/// Result of checking if an item is dirty.
pub const DirtyCheckResult = union(enum) {
    /// Item is clean and can be reused
    clean: CacheKey,
    /// Item is dirty and needs rebuilding
    dirty: DirtyReason,
};

/// Reason why an item is considered dirty.
pub const DirtyReason = enum {
    /// No cache entry exists
    not_cached,
    /// Source file was modified
    source_modified,
    /// Dependency was modified
    dependency_modified,
    /// Compiler flags changed
    flags_changed,
    /// Output file is missing
    output_missing,
    /// Cache entry is corrupted
    cache_corrupted,
};

/// The incremental build cache.
pub const BuildCache = struct {
    /// Map from combined hash to cache entry
    entries: std.AutoHashMap(u64, CacheEntry),
    /// Path to source -> last known hash
    file_hashes: std.StringHashMap(u64),
    /// Cache directory path
    cache_dir: []const u8,
    /// Manifest file path
    manifest_path: []const u8,
    /// Statistics
    stats: CacheStats,

    allocator: std.mem.Allocator,

    pub const CacheStats = struct {
        hits: u64 = 0,
        misses: u64 = 0,
        evictions: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, cache_dir: []const u8) !BuildCache {
        const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.bin", .{cache_dir});
        errdefer allocator.free(manifest_path);

        // Ensure cache directory exists
        std.fs.cwd().makePath(cache_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var cache = BuildCache{
            .entries = std.AutoHashMap(u64, CacheEntry).init(allocator),
            .file_hashes = std.StringHashMap(u64).init(allocator),
            .cache_dir = try allocator.dupe(u8, cache_dir),
            .manifest_path = manifest_path,
            .stats = .{},
            .allocator = allocator,
        };

        // Try to load existing manifest
        cache.loadManifest() catch {};

        return cache;
    }

    pub fn deinit(self: *BuildCache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            var e = entry.*;
            e.deinit();
        }
        self.entries.deinit();

        var file_it = self.file_hashes.keyIterator();
        while (file_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.file_hashes.deinit();

        self.allocator.free(self.cache_dir);
        self.allocator.free(self.manifest_path);
        self.* = undefined;
    }

    /// Hash file contents.
    pub fn hashFile(self: *BuildCache, path: []const u8) !u64 {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        var hasher = HashAlgorithm.init(0);
        var buf: [8192]u8 = undefined;

        while (true) {
            const bytes_read = try file.read(&buf);
            if (bytes_read == 0) break;
            hasher.update(buf[0..bytes_read]);
        }

        const hash = hasher.final();

        // Update cached hash
        const path_key = self.file_hashes.getKey(path) orelse blk: {
            const key = try self.allocator.dupe(u8, path);
            break :blk key;
        };
        try self.file_hashes.put(path_key, hash);

        return hash;
    }

    /// Hash a string (for flags, etc.).
    pub fn hashString(data: []const u8) u64 {
        var hasher = HashAlgorithm.init(0);
        hasher.update(data);
        return hasher.final();
    }

    /// Hash multiple strings combined.
    pub fn hashStrings(strings: []const []const u8) u64 {
        var hasher = HashAlgorithm.init(0);
        for (strings) |s| {
            hasher.update(s);
            hasher.update(&[_]u8{0}); // Separator
        }
        return hasher.final();
    }

    /// Check if an item needs rebuilding.
    pub fn checkDirty(
        self: *BuildCache,
        source_path: []const u8,
        flags: []const []const u8,
        deps: []const []const u8,
    ) !DirtyCheckResult {
        // Hash source file
        const source_hash = self.hashFile(source_path) catch |err| switch (err) {
            error.FileNotFound => return .{ .dirty = .source_modified },
            else => return err,
        };

        // Hash flags
        const flags_hash = hashStrings(flags);

        // Hash dependencies
        var deps_hasher = HashAlgorithm.init(0);
        for (deps) |dep| {
            const dep_hash = self.hashFile(dep) catch |err| switch (err) {
                error.FileNotFound => return .{ .dirty = .dependency_modified },
                else => return err,
            };
            deps_hasher.update(std.mem.asBytes(&dep_hash));
        }
        const deps_hash = deps_hasher.final();

        const key = CacheKey.compute(source_hash, flags_hash, deps_hash);

        // Look up in cache
        const entry = self.entries.get(key.combined) orelse {
            self.stats.misses += 1;
            return .{ .dirty = .not_cached };
        };

        // Verify key matches exactly
        if (!entry.key.eql(key)) {
            self.stats.misses += 1;
            return .{ .dirty = .cache_corrupted };
        }

        // Check output file exists
        std.fs.cwd().access(entry.output_path, .{}) catch {
            self.stats.misses += 1;
            return .{ .dirty = .output_missing };
        };

        self.stats.hits += 1;
        return .{ .clean = key };
    }

    /// Store a cache entry after successful compilation.
    pub fn store(
        self: *BuildCache,
        key: CacheKey,
        output_path: []const u8,
        output_size: u64,
        input_files: []const []const u8,
    ) !void {
        // Remove old entry if exists
        if (self.entries.fetchRemove(key.combined)) |kv| {
            var old_entry = kv.value;
            old_entry.deinit();
        }

        var entry = try CacheEntry.init(self.allocator, key, output_path);
        errdefer entry.deinit();

        entry.output_size = output_size;
        try entry.setInputFiles(input_files);
        entry.verified = true;

        try self.entries.put(key.combined, entry);
    }

    /// Get the cached output path for a key.
    pub fn getCachedOutput(self: *BuildCache, key: CacheKey) ?[]const u8 {
        const entry = self.entries.get(key.combined) orelse return null;
        if (!entry.key.eql(key)) return null;
        return entry.output_path;
    }

    /// Invalidate all entries that depend on a given file.
    pub fn invalidateFile(self: *BuildCache, file_path: []const u8) void {
        var to_remove: std.ArrayList(u64) = std.ArrayList(u64).init(self.allocator);
        defer to_remove.deinit();

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            for (kv.value_ptr.input_files) |input| {
                if (std.mem.eql(u8, input, file_path)) {
                    to_remove.append(kv.key_ptr.*) catch continue;
                    break;
                }
            }
        }

        for (to_remove.items) |key| {
            if (self.entries.fetchRemove(key)) |kv| {
                var entry = kv.value;
                entry.deinit();
                self.stats.evictions += 1;
            }
        }

        // Remove from file hash cache
        if (self.file_hashes.fetchRemove(file_path)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Save the cache manifest to disk.
    pub fn saveManifest(self: *BuildCache) !void {
        const file = try std.fs.cwd().createFile(self.manifest_path, .{});
        defer file.close();

        var writer = file.writer();

        // Write magic and version
        try writer.writeAll("OVO_CACHE");
        try writer.writeInt(u32, 1, .little);

        // Write entry count
        try writer.writeInt(u64, self.entries.count(), .little);

        // Write each entry
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            // Write key
            try writer.writeInt(u64, entry.key.source_hash, .little);
            try writer.writeInt(u64, entry.key.flags_hash, .little);
            try writer.writeInt(u64, entry.key.deps_hash, .little);
            try writer.writeInt(u64, entry.key.combined, .little);

            // Write output path
            try writer.writeInt(u32, @intCast(entry.output_path.len), .little);
            try writer.writeAll(entry.output_path);

            // Write metadata
            try writer.writeInt(u64, entry.output_size, .little);
            try writer.writeInt(i64, entry.timestamp, .little);

            // Write input files
            try writer.writeInt(u32, @intCast(entry.input_files.len), .little);
            for (entry.input_files) |path| {
                try writer.writeInt(u32, @intCast(path.len), .little);
                try writer.writeAll(path);
            }
        }
    }

    /// Load the cache manifest from disk.
    pub fn loadManifest(self: *BuildCache) !void {
        const file = std.fs.cwd().openFile(self.manifest_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        var reader = file.reader();

        // Read and verify magic
        var magic: [9]u8 = undefined;
        _ = try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, "OVO_CACHE")) return error.InvalidFormat;

        // Read version
        const version = try reader.readInt(u32, .little);
        if (version != 1) return error.UnsupportedVersion;

        // Read entry count
        const count = try reader.readInt(u64, .little);

        // Read entries
        for (0..count) |_| {
            const key = CacheKey{
                .source_hash = try reader.readInt(u64, .little),
                .flags_hash = try reader.readInt(u64, .little),
                .deps_hash = try reader.readInt(u64, .little),
                .combined = try reader.readInt(u64, .little),
            };

            const path_len = try reader.readInt(u32, .little);
            const path_buf = try self.allocator.alloc(u8, path_len);
            defer self.allocator.free(path_buf);
            _ = try reader.readAll(path_buf);

            var entry = try CacheEntry.init(self.allocator, key, path_buf);
            errdefer entry.deinit();

            entry.output_size = try reader.readInt(u64, .little);
            entry.timestamp = try reader.readInt(i64, .little);

            const input_count = try reader.readInt(u32, .little);
            var input_files: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(self.allocator);
            defer input_files.deinit();

            for (0..input_count) |_| {
                const input_len = try reader.readInt(u32, .little);
                const input_buf = try self.allocator.alloc(u8, input_len);
                _ = try reader.readAll(input_buf);
                try input_files.append(input_buf);
            }

            const owned_files = try input_files.toOwnedSlice();
            entry.input_files = owned_files;

            try self.entries.put(key.combined, entry);
        }
    }

    /// Clear the entire cache.
    pub fn clear(self: *BuildCache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            var e = entry.*;
            e.deinit();
        }
        self.entries.clearRetainingCapacity();

        var file_it = self.file_hashes.keyIterator();
        while (file_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.file_hashes.clearRetainingCapacity();

        self.stats = .{};
    }

    /// Get cache statistics.
    pub fn getStats(self: *const BuildCache) CacheStats {
        return self.stats;
    }

    /// Get cache hit rate as a percentage.
    pub fn getHitRate(self: *const BuildCache) f64 {
        const total = self.stats.hits + self.stats.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.stats.hits)) / @as(f64, @floatFromInt(total)) * 100.0;
    }
};

// Tests
test "cache key computation" {
    const key1 = CacheKey.compute(100, 200, 300);
    const key2 = CacheKey.compute(100, 200, 300);
    const key3 = CacheKey.compute(100, 200, 301);

    try std.testing.expect(key1.eql(key2));
    try std.testing.expect(!key1.eql(key3));
}

test "build cache basic operations" {
    const allocator = std.testing.allocator;

    // Create a temporary directory for the cache
    var cache = try BuildCache.init(allocator, "/tmp/ovo-test-cache");
    defer cache.deinit();

    const key = CacheKey.compute(1, 2, 3);
    try cache.store(key, "/tmp/test.o", 1024, &.{"test.c"});

    const output = cache.getCachedOutput(key);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("/tmp/test.o", output.?);
}

test "hash string" {
    const hash1 = BuildCache.hashString("hello");
    const hash2 = BuildCache.hashString("hello");
    const hash3 = BuildCache.hashString("world");

    try std.testing.expect(hash1 == hash2);
    try std.testing.expect(hash1 != hash3);
}

test "hash strings" {
    const strings = [_][]const u8{ "-O2", "-Wall", "-std=c++20" };
    const hash1 = BuildCache.hashStrings(&strings);
    const hash2 = BuildCache.hashStrings(&strings);

    try std.testing.expect(hash1 == hash2);

    const different = [_][]const u8{ "-O3", "-Wall", "-std=c++20" };
    const hash3 = BuildCache.hashStrings(&different);
    try std.testing.expect(hash1 != hash3);
}

test "cache statistics" {
    const allocator = std.testing.allocator;
    var cache = try BuildCache.init(allocator, "/tmp/ovo-test-cache-stats");
    defer cache.deinit();

    try std.testing.expect(cache.getHitRate() == 0.0);

    const stats = cache.getStats();
    try std.testing.expect(stats.hits == 0);
    try std.testing.expect(stats.misses == 0);
}
