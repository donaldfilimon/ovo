//! Lockfile management for reproducible builds.
//!
//! The lockfile (ovo.lock) records the exact versions, commits, and hashes
//! of all dependencies resolved during a build, enabling reproducible builds
//! across different machines and times.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const fs = std.fs;
const integrity = @import("integrity.zig");

/// Default lockfile name.
pub const default_filename = "ovo.lock";

/// Lockfile format version for compatibility checking.
pub const format_version: u32 = 1;

/// Source type for a locked package.
pub const SourceType = enum {
    git,
    archive,
    path,
    vcpkg,
    conan,
    system,
    registry,

    pub fn toString(self: SourceType) []const u8 {
        return switch (self) {
            .git => "git",
            .archive => "archive",
            .path => "path",
            .vcpkg => "vcpkg",
            .conan => "conan",
            .system => "system",
            .registry => "registry",
        };
    }

    pub fn fromString(s: []const u8) ?SourceType {
        const map = std.StaticStringMap(SourceType).initComptime(.{
            .{ "git", .git },
            .{ "archive", .archive },
            .{ "path", .path },
            .{ "vcpkg", .vcpkg },
            .{ "conan", .conan },
            .{ "system", .system },
            .{ "registry", .registry },
        });
        return map.get(s);
    }
};

/// A locked package entry with all information needed for reproducible resolution.
pub const LockedPackage = struct {
    /// Package name (as declared in dependencies).
    name: []const u8,

    /// Resolved version string.
    version: []const u8,

    /// Source type.
    source_type: SourceType,

    /// Source-specific location (URL, path, etc.).
    source_url: []const u8,

    /// For git: resolved commit hash. For archives: content hash.
    resolved_hash: ?[]const u8 = null,

    /// Integrity hash of the package contents (SHA256).
    integrity_hash: ?[]const u8 = null,

    /// Dependencies of this package (names only, versions in their own entries).
    dependencies: []const []const u8 = &.{},

    /// Platform-specific information.
    platform: ?PlatformInfo = null,

    /// Timestamp when this entry was created/updated.
    locked_at: ?i64 = null,

    pub const PlatformInfo = struct {
        os: ?[]const u8 = null,
        arch: ?[]const u8 = null,
        libc: ?[]const u8 = null,
    };

    pub fn deinit(self: *LockedPackage, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.source_url);
        if (self.resolved_hash) |h| allocator.free(h);
        if (self.integrity_hash) |h| allocator.free(h);
        for (self.dependencies) |dep| allocator.free(dep);
        allocator.free(self.dependencies);
        if (self.platform) |p| {
            if (p.os) |os| allocator.free(os);
            if (p.arch) |arch| allocator.free(arch);
            if (p.libc) |libc| allocator.free(libc);
        }
    }

    pub fn clone(self: LockedPackage, allocator: Allocator) Allocator.Error!LockedPackage {
        var deps = try allocator.alloc([]const u8, self.dependencies.len);
        errdefer allocator.free(deps);
        for (self.dependencies, 0..) |dep, i| {
            deps[i] = try allocator.dupe(u8, dep);
        }

        return .{
            .name = try allocator.dupe(u8, self.name),
            .version = try allocator.dupe(u8, self.version),
            .source_type = self.source_type,
            .source_url = try allocator.dupe(u8, self.source_url),
            .resolved_hash = if (self.resolved_hash) |h| try allocator.dupe(u8, h) else null,
            .integrity_hash = if (self.integrity_hash) |h| try allocator.dupe(u8, h) else null,
            .dependencies = deps,
            .platform = if (self.platform) |p| .{
                .os = if (p.os) |os| try allocator.dupe(u8, os) else null,
                .arch = if (p.arch) |arch| try allocator.dupe(u8, arch) else null,
                .libc = if (p.libc) |libc| try allocator.dupe(u8, libc) else null,
            } else null,
            .locked_at = self.locked_at,
        };
    }
};

/// The complete lockfile structure.
pub const Lockfile = struct {
    allocator: Allocator,

    /// Format version for compatibility.
    version: u32 = format_version,

    /// Map of package name to locked package info.
    packages: std.StringHashMap(LockedPackage),

    /// Root packages (direct dependencies).
    roots: std.ArrayList([]const u8),

    /// Metadata about the lock operation.
    metadata: Metadata = .{},

    pub const Metadata = struct {
        /// When the lockfile was last updated.
        updated_at: ?i64 = null,

        /// Hash of the manifest that generated this lockfile.
        manifest_hash: ?[]const u8 = null,

        /// Ovo version that created this lockfile.
        ovo_version: ?[]const u8 = null,
    };

    pub fn init(allocator: Allocator) Lockfile {
        return .{
            .allocator = allocator,
            .packages = std.StringHashMap(LockedPackage).init(allocator),
            .roots = .empty,
        };
    }

    pub fn deinit(self: *Lockfile) void {
        var iter = self.packages.iterator();
        while (iter.next()) |entry| {
            var pkg = entry.value_ptr.*;
            pkg.deinit(self.allocator);
        }
        self.packages.deinit();

        for (self.roots.items) |root| {
            self.allocator.free(root);
        }
        self.roots.deinit(self.allocator);

        if (self.metadata.manifest_hash) |h| self.allocator.free(h);
        if (self.metadata.ovo_version) |v| self.allocator.free(v);
    }

    /// Add or update a locked package.
    pub fn putPackage(self: *Lockfile, pkg: LockedPackage) !void {
        const name = try self.allocator.dupe(u8, pkg.name);
        errdefer self.allocator.free(name);

        const cloned = try pkg.clone(self.allocator);

        if (self.packages.fetchRemove(name)) |old| {
            var old_pkg = old.value;
            old_pkg.deinit(self.allocator);
            self.allocator.free(old.key);
        }

        try self.packages.put(name, cloned);
    }

    /// Get a locked package by name.
    pub fn getPackage(self: *const Lockfile, name: []const u8) ?LockedPackage {
        return self.packages.get(name);
    }

    /// Check if a package is locked.
    pub fn hasPackage(self: *const Lockfile, name: []const u8) bool {
        return self.packages.contains(name);
    }

    /// Add a root dependency.
    pub fn addRoot(self: *Lockfile, name: []const u8) !void {
        for (self.roots.items) |root| {
            if (std.mem.eql(u8, root, name)) return;
        }
        const duped = try self.allocator.dupe(u8, name);
        try self.roots.append(self.allocator, duped);
    }

    /// Load lockfile from disk.
    pub fn load(allocator: Allocator, path: []const u8) !Lockfile {
        const file = try fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
        defer allocator.free(content);

        return parse(allocator, content);
    }

    /// Load from default location.
    pub fn loadDefault(allocator: Allocator) !Lockfile {
        return load(allocator, default_filename);
    }

    /// Try to load, return null if not found.
    pub fn tryLoad(allocator: Allocator, path: []const u8) !?Lockfile {
        return load(allocator, path) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
    }

    /// Parse lockfile from JSON content.
    pub fn parse(allocator: Allocator, content: []const u8) !Lockfile {
        const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
        defer parsed.deinit();

        var lockfile = Lockfile.init(allocator);
        errdefer lockfile.deinit();

        const root = parsed.value;

        // Check version
        if (root.object.get("version")) |v| {
            lockfile.version = @intCast(v.integer);
        }

        // Parse packages
        if (root.object.get("packages")) |packages_val| {
            var pkg_iter = packages_val.object.iterator();
            while (pkg_iter.next()) |entry| {
                const pkg_obj = entry.value_ptr.object;
                var pkg = LockedPackage{
                    .name = try allocator.dupe(u8, entry.key_ptr.*),
                    .version = try allocator.dupe(u8, pkg_obj.get("version").?.string),
                    .source_type = SourceType.fromString(pkg_obj.get("source_type").?.string) orelse .git,
                    .source_url = try allocator.dupe(u8, pkg_obj.get("source_url").?.string),
                };

                if (pkg_obj.get("resolved_hash")) |h| {
                    if (h != .null) pkg.resolved_hash = try allocator.dupe(u8, h.string);
                }
                if (pkg_obj.get("integrity_hash")) |h| {
                    if (h != .null) pkg.integrity_hash = try allocator.dupe(u8, h.string);
                }

                if (pkg_obj.get("dependencies")) |deps| {
                    var dep_list = std.ArrayList([]const u8).init(allocator);
                    for (deps.array.items) |dep| {
                        try dep_list.append(try allocator.dupe(u8, dep.string));
                    }
                    pkg.dependencies = try dep_list.toOwnedSlice();
                }

                if (pkg_obj.get("locked_at")) |t| {
                    if (t != .null) pkg.locked_at = t.integer;
                }

                try lockfile.putPackage(pkg);
                pkg.deinit(allocator);
            }
        }

        // Parse roots
        if (root.object.get("roots")) |roots_val| {
            for (roots_val.array.items) |root_name| {
                try lockfile.addRoot(root_name.string);
            }
        }

        // Parse metadata
        if (root.object.get("metadata")) |meta| {
            if (meta.object.get("updated_at")) |t| {
                if (t != .null) lockfile.metadata.updated_at = t.integer;
            }
            if (meta.object.get("manifest_hash")) |h| {
                if (h != .null) lockfile.metadata.manifest_hash = try allocator.dupe(u8, h.string);
            }
            if (meta.object.get("ovo_version")) |v| {
                if (v != .null) lockfile.metadata.ovo_version = try allocator.dupe(u8, v.string);
            }
        }

        return lockfile;
    }

    /// Save lockfile to disk.
    pub fn save(self: *const Lockfile, path: []const u8) !void {
        const file = try fs.cwd().createFile(path, .{});
        defer file.close();

        var buffered = std.io.bufferedWriter(file.writer());
        try self.serialize(buffered.writer());
        try buffered.flush();
    }

    /// Save to default location.
    pub fn saveDefault(self: *const Lockfile) !void {
        return self.save(default_filename);
    }

    /// Serialize to JSON.
    pub fn serialize(self: *const Lockfile, writer: anytype) !void {
        try writer.writeAll("{\n");

        // Version
        try writer.print("  \"version\": {d},\n", .{self.version});

        // Roots
        try writer.writeAll("  \"roots\": [");
        for (self.roots.items, 0..) |root, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("\"{s}\"", .{root});
        }
        try writer.writeAll("],\n");

        // Metadata
        try writer.writeAll("  \"metadata\": {\n");
        if (self.metadata.updated_at) |t| {
            try writer.print("    \"updated_at\": {d},\n", .{t});
        }
        if (self.metadata.manifest_hash) |h| {
            try writer.print("    \"manifest_hash\": \"{s}\",\n", .{h});
        }
        if (self.metadata.ovo_version) |v| {
            try writer.print("    \"ovo_version\": \"{s}\"\n", .{v});
        } else {
            try writer.writeAll("    \"ovo_version\": null\n");
        }
        try writer.writeAll("  },\n");

        // Packages (sorted for deterministic output)
        try writer.writeAll("  \"packages\": {\n");

        var names = std.ArrayList([]const u8).init(self.allocator);
        defer names.deinit();

        var iter = self.packages.keyIterator();
        while (iter.next()) |key| {
            try names.append(key.*);
        }

        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        for (names.items, 0..) |name, i| {
            const pkg = self.packages.get(name).?;

            if (i > 0) try writer.writeAll(",\n");
            try writer.print("    \"{s}\": {{\n", .{name});
            try writer.print("      \"version\": \"{s}\",\n", .{pkg.version});
            try writer.print("      \"source_type\": \"{s}\",\n", .{pkg.source_type.toString()});
            try writer.print("      \"source_url\": \"{s}\",\n", .{pkg.source_url});

            if (pkg.resolved_hash) |h| {
                try writer.print("      \"resolved_hash\": \"{s}\",\n", .{h});
            } else {
                try writer.writeAll("      \"resolved_hash\": null,\n");
            }

            if (pkg.integrity_hash) |h| {
                try writer.print("      \"integrity_hash\": \"{s}\",\n", .{h});
            } else {
                try writer.writeAll("      \"integrity_hash\": null,\n");
            }

            try writer.writeAll("      \"dependencies\": [");
            for (pkg.dependencies, 0..) |dep, j| {
                if (j > 0) try writer.writeAll(", ");
                try writer.print("\"{s}\"", .{dep});
            }
            try writer.writeAll("],\n");

            if (pkg.locked_at) |t| {
                try writer.print("      \"locked_at\": {d}\n", .{t});
            } else {
                try writer.writeAll("      \"locked_at\": null\n");
            }

            try writer.writeAll("    }");
        }

        try writer.writeAll("\n  }\n");
        try writer.writeAll("}\n");
    }

    /// Check if lockfile is up to date with manifest.
    pub fn isUpToDate(self: *const Lockfile, manifest_hash: []const u8) bool {
        if (self.metadata.manifest_hash) |h| {
            return std.mem.eql(u8, h, manifest_hash);
        }
        return false;
    }

    /// Get all packages in topological order (dependencies first).
    pub fn getTopologicalOrder(self: *const Lockfile, allocator: Allocator) ![][]const u8 {
        var result = std.ArrayList([]const u8).init(allocator);
        var visited = std.StringHashMap(void).init(allocator);
        defer visited.deinit();

        for (self.roots.items) |root| {
            try self.topologicalVisit(root, &result, &visited);
        }

        return result.toOwnedSlice();
    }

    fn topologicalVisit(
        self: *const Lockfile,
        name: []const u8,
        result: *std.ArrayList([]const u8),
        visited: *std.StringHashMap(void),
    ) !void {
        if (visited.contains(name)) return;
        try visited.put(name, {});

        if (self.packages.get(name)) |pkg| {
            for (pkg.dependencies) |dep| {
                try self.topologicalVisit(dep, result, visited);
            }
        }

        try result.append(name);
    }
};

// Tests
test "lockfile round trip" {
    const allocator = std.testing.allocator;

    var lockfile = Lockfile.init(allocator);
    defer lockfile.deinit();

    try lockfile.putPackage(.{
        .name = "test-pkg",
        .version = "1.0.0",
        .source_type = .git,
        .source_url = "https://github.com/test/pkg.git",
        .resolved_hash = "abc123",
        .integrity_hash = "def456",
        .dependencies = &.{"dep1"},
    });

    try lockfile.addRoot("test-pkg");
    lockfile.metadata.updated_at = 1234567890;

    // Serialize
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try lockfile.serialize(&writer);

    // Parse back
    var parsed = try Lockfile.parse(allocator, buf[0..writer.end]);
    defer parsed.deinit();

    const pkg = parsed.getPackage("test-pkg").?;
    try std.testing.expectEqualStrings("1.0.0", pkg.version);
    try std.testing.expectEqualStrings("abc123", pkg.resolved_hash.?);
}

test "source type conversion" {
    try std.testing.expectEqualStrings("git", SourceType.git.toString());
    try std.testing.expect(SourceType.fromString("vcpkg") == .vcpkg);
    try std.testing.expect(SourceType.fromString("invalid") == null);
}
