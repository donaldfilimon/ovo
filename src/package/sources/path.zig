//! Local path source.
//!
//! Handles dependencies from local filesystem paths, useful for
//! development, monorepos, and local-first workflows.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const integrity = @import("../integrity.zig");

/// Path-specific errors.
pub const PathError = error{
    PathNotFound,
    NotADirectory,
    AccessDenied,
    InvalidManifest,
    OutOfMemory,
    SymlinkLoop,
};

/// Path configuration.
pub const PathConfig = struct {
    /// Filesystem path (absolute or relative to manifest).
    path: []const u8,

    /// Whether to follow symlinks.
    follow_symlinks: bool = true,

    /// Watch for changes (for dev mode).
    watch: bool = false,

    /// Copy to cache instead of linking.
    copy: bool = false,
};

/// Result of resolving a path source.
pub const PathResult = struct {
    /// Resolved absolute path.
    absolute_path: []const u8,

    /// Content hash.
    content_hash: []const u8,

    /// Whether this is a symlink.
    is_symlink: bool = false,

    /// Package manifest found at path (if any).
    manifest_path: ?[]const u8 = null,

    pub fn deinit(self: *PathResult, allocator: Allocator) void {
        allocator.free(self.absolute_path);
        allocator.free(self.content_hash);
        if (self.manifest_path) |m| allocator.free(m);
    }
};

/// Path source handler.
pub const PathSource = struct {
    allocator: Allocator,
    base_dir: []const u8,

    pub fn init(allocator: Allocator, base_dir: []const u8) PathSource {
        return .{
            .allocator = allocator,
            .base_dir = base_dir,
        };
    }

    /// Resolve a path dependency.
    pub fn resolve(self: *PathSource, config: PathConfig) PathError!PathResult {
        // Resolve to absolute path
        const absolute_path = try self.resolvePath(config.path);
        errdefer self.allocator.free(absolute_path);

        // Check if path exists and is accessible
        const stat = fs.cwd().statFile(absolute_path) catch |err| {
            return switch (err) {
                error.FileNotFound => error.PathNotFound,
                error.AccessDenied => error.AccessDenied,
                else => error.PathNotFound,
            };
        };

        const is_symlink = stat.kind == .sym_link;

        // Check for symlink loops if following symlinks
        if (config.follow_symlinks and is_symlink) {
            try self.checkSymlinkLoop(absolute_path);
        }

        // Calculate content hash
        const content_hash = if (stat.kind == .directory)
            integrity.hashDirectory(self.allocator, absolute_path) catch return error.AccessDenied
        else
            integrity.hashFile(self.allocator, absolute_path) catch return error.AccessDenied;

        const hash_str = integrity.hashToString(content_hash);

        // Look for package manifest
        const manifest_path = self.findManifest(absolute_path);

        return PathResult{
            .absolute_path = absolute_path,
            .content_hash = self.allocator.dupe(u8, &hash_str) catch return error.OutOfMemory,
            .is_symlink = is_symlink,
            .manifest_path = manifest_path,
        };
    }

    /// Resolve a relative path to absolute.
    fn resolvePath(self: *PathSource, path: []const u8) PathError![]const u8 {
        if (std.fs.path.isAbsolute(path)) {
            return self.allocator.dupe(u8, path) catch return error.OutOfMemory;
        }

        // Resolve relative to base directory
        return std.fs.path.join(self.allocator, &.{ self.base_dir, path }) catch
            return error.OutOfMemory;
    }

    /// Check for symlink loops.
    fn checkSymlinkLoop(self: *PathSource, start_path: []const u8) PathError!void {
        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        var current = start_path;
        var depth: u32 = 0;
        const max_depth = 40; // Same as typical OS limits

        while (depth < max_depth) : (depth += 1) {
            if (visited.contains(current)) {
                return error.SymlinkLoop;
            }
            visited.put(current, {}) catch return error.OutOfMemory;

            // Try to read symlink
            var link_buf: [std.fs.max_path_bytes]u8 = undefined;
            const link = fs.cwd().readLink(current, &link_buf) catch break;

            // Resolve the link target
            if (std.fs.path.isAbsolute(link)) {
                current = link;
            } else {
                const dir = std.fs.path.dirname(current) orelse ".";
                const resolved = std.fs.path.join(self.allocator, &.{ dir, link }) catch
                    return error.OutOfMemory;
                defer self.allocator.free(resolved);
                current = resolved;
            }
        }

        if (depth >= max_depth) {
            return error.SymlinkLoop;
        }
    }

    /// Find package manifest in directory.
    fn findManifest(self: *PathSource, dir_path: []const u8) ?[]const u8 {
        const manifest_names = [_][]const u8{
            "build.zon", // OVO package manifest (primary)
            "ovo.zon", // Legacy Ovo package manifest
            "build.zig.zon", // Zig build manifest
            "build.zig", // Zig build file
        };

        for (manifest_names) |name| {
            const manifest_path = std.fs.path.join(self.allocator, &.{ dir_path, name }) catch continue;

            fs.cwd().access(manifest_path, .{}) catch {
                self.allocator.free(manifest_path);
                continue;
            };

            return manifest_path;
        }

        return null;
    }

    /// Copy path contents to destination (for cache).
    pub fn copyTo(self: *PathSource, src: []const u8, dest: []const u8) PathError!void {
        const stat = fs.cwd().statFile(src) catch return error.PathNotFound;

        if (stat.kind == .directory) {
            try self.copyDirectory(src, dest);
        } else {
            try self.copyFile(src, dest);
        }
    }

    fn copyDirectory(self: *PathSource, src: []const u8, dest: []const u8) PathError!void {
        // Create destination directory
        fs.cwd().makePath(dest) catch return error.AccessDenied;

        // Open source directory
        var dir = fs.cwd().openDir(src, .{ .iterate = true }) catch return error.AccessDenied;
        defer dir.close();

        // Iterate and copy
        var iter = dir.iterate();
        while (iter.next() catch return error.AccessDenied) |entry| {
            const src_path = std.fs.path.join(self.allocator, &.{ src, entry.name }) catch
                return error.OutOfMemory;
            defer self.allocator.free(src_path);

            const dest_path = std.fs.path.join(self.allocator, &.{ dest, entry.name }) catch
                return error.OutOfMemory;
            defer self.allocator.free(dest_path);

            switch (entry.kind) {
                .directory => try self.copyDirectory(src_path, dest_path),
                .file => try self.copyFile(src_path, dest_path),
                .sym_link => try self.copySymlink(src_path, dest_path),
                else => {},
            }
        }
    }

    fn copyFile(self: *PathSource, src: []const u8, dest: []const u8) PathError!void {
        _ = self;

        const src_file = fs.cwd().openFile(src, .{}) catch return error.AccessDenied;
        defer src_file.close();

        const dest_file = fs.cwd().createFile(dest, .{}) catch return error.AccessDenied;
        defer dest_file.close();

        // Copy contents
        var buf: [8192]u8 = undefined;
        while (true) {
            const bytes_read = src_file.read(&buf) catch return error.AccessDenied;
            if (bytes_read == 0) break;
            dest_file.writeAll(buf[0..bytes_read]) catch return error.AccessDenied;
        }

        // Copy permissions
        const stat = src_file.stat() catch return;
        dest_file.chmod(stat.mode) catch {};
    }

    fn copySymlink(self: *PathSource, src: []const u8, dest: []const u8) PathError!void {
        _ = self;

        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const link = fs.cwd().readLink(src, &link_buf) catch return error.AccessDenied;

        fs.cwd().symLink(link, dest, .{}) catch return error.AccessDenied;
    }

    /// Create a symlink to the source (for linking mode).
    pub fn linkTo(self: *PathSource, src: []const u8, dest: []const u8) PathError!void {
        _ = self;

        // Ensure parent directory exists
        if (std.fs.path.dirname(dest)) |parent| {
            fs.cwd().makePath(parent) catch return error.AccessDenied;
        }

        // Create symlink
        fs.cwd().symLink(src, dest, .{}) catch return error.AccessDenied;
    }

    /// Watch a path for changes.
    pub fn watch(self: *PathSource, path: []const u8, callback: *const fn (event: WatchEvent) void) !void {
        _ = self;
        _ = path;
        _ = callback;
        // TODO: Implement file watching using platform-specific APIs
        // (inotify on Linux, FSEvents on macOS, ReadDirectoryChangesW on Windows)
    }

    pub const WatchEvent = struct {
        path: []const u8,
        kind: Kind,

        pub const Kind = enum {
            created,
            modified,
            deleted,
            renamed,
        };
    };
};

/// Workspace resolution for monorepo support.
pub const WorkspaceResolver = struct {
    allocator: Allocator,
    root_dir: []const u8,
    packages: std.StringHashMap([]const u8),

    pub fn init(allocator: Allocator, root_dir: []const u8) WorkspaceResolver {
        return .{
            .allocator = allocator,
            .root_dir = root_dir,
            .packages = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *WorkspaceResolver) void {
        var iter = self.packages.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.packages.deinit();
    }

    /// Scan workspace for packages.
    pub fn scan(self: *WorkspaceResolver, patterns: []const []const u8) !void {
        for (patterns) |pattern| {
            try self.scanPattern(pattern);
        }
    }

    fn scanPattern(self: *WorkspaceResolver, pattern: []const u8) !void {
        // Simple glob-like pattern matching
        // Pattern like "packages/*" scans all subdirectories of packages/

        if (std.mem.indexOf(u8, pattern, "*")) |star_pos| {
            const prefix = pattern[0..star_pos];
            const prefix_path = std.fs.path.join(self.allocator, &.{ self.root_dir, prefix }) catch return;
            defer self.allocator.free(prefix_path);

            var dir = fs.cwd().openDir(prefix_path, .{ .iterate = true }) catch return;
            defer dir.close();

            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind != .directory) continue;
                if (entry.name[0] == '.') continue; // Skip hidden

                const pkg_path = std.fs.path.join(self.allocator, &.{ prefix_path, entry.name }) catch continue;

                // Check for manifest
                const manifest_path = std.fs.path.join(self.allocator, &.{ pkg_path, "ovo.zon" }) catch {
                    self.allocator.free(pkg_path);
                    continue;
                };
                defer self.allocator.free(manifest_path);

                fs.cwd().access(manifest_path, .{}) catch {
                    self.allocator.free(pkg_path);
                    continue;
                };

                // Found a package
                const name = self.allocator.dupe(u8, entry.name) catch {
                    self.allocator.free(pkg_path);
                    continue;
                };
                self.packages.put(name, pkg_path) catch {
                    self.allocator.free(name);
                    self.allocator.free(pkg_path);
                };
            }
        } else {
            // Exact path
            const pkg_path = std.fs.path.join(self.allocator, &.{ self.root_dir, pattern }) catch return;
            errdefer self.allocator.free(pkg_path);

            const manifest_path = std.fs.path.join(self.allocator, &.{ pkg_path, "ovo.zon" }) catch return;
            defer self.allocator.free(manifest_path);

            fs.cwd().access(manifest_path, .{}) catch {
                self.allocator.free(pkg_path);
                return;
            };

            const name = std.fs.path.basename(pattern);
            const name_copy = self.allocator.dupe(u8, name) catch {
                self.allocator.free(pkg_path);
                return;
            };
            self.packages.put(name_copy, pkg_path) catch {
                self.allocator.free(name_copy);
                self.allocator.free(pkg_path);
            };
        }
    }

    /// Resolve a workspace package by name.
    pub fn resolvePackage(self: *WorkspaceResolver, name: []const u8) ?[]const u8 {
        return self.packages.get(name);
    }
};

// Tests
test "path source init" {
    const allocator = std.testing.allocator;
    const source = PathSource.init(allocator, "/tmp");
    _ = source;
}

test "path resolution" {
    const allocator = std.testing.allocator;
    var source = PathSource.init(allocator, "/home/user/project");

    const abs = try source.resolvePath("./libs/foo");
    defer allocator.free(abs);
    try std.testing.expectEqualStrings("/home/user/project/./libs/foo", abs);

    const already_abs = try source.resolvePath("/absolute/path");
    defer allocator.free(already_abs);
    try std.testing.expectEqualStrings("/absolute/path", already_abs);
}

test "workspace resolver init" {
    const allocator = std.testing.allocator;
    var resolver = WorkspaceResolver.init(allocator, "/workspace");
    defer resolver.deinit();
}
