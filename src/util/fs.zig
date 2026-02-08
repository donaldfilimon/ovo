//! File system utilities for ovo package manager.
//! Provides recursive operations, path manipulation, and glob expansion.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const Dir = fs.Dir;
const File = fs.File;
const compat = @import("compat.zig");

/// Error types for file system operations.
pub const FsError = error{
    PathNotFound,
    PermissionDenied,
    InvalidPath,
    IoError,
    OutOfMemory,
    GlobPatternInvalid,
} || File.OpenError || Dir.OpenError;

/// Options for recursive copy operations.
pub const CopyOptions = struct {
    /// Overwrite existing files.
    overwrite: bool = false,
    /// Follow symbolic links instead of copying them.
    follow_symlinks: bool = false,
    /// Preserve file permissions and timestamps.
    preserve_metadata: bool = true,
    /// Skip hidden files (starting with '.').
    skip_hidden: bool = false,
};

/// Options for recursive delete operations.
pub const DeleteOptions = struct {
    /// Continue on errors instead of stopping.
    force: bool = false,
    /// Only delete empty directories.
    dirs_only: bool = false,
};

/// Recursively copy a directory or file from src to dst.
pub fn copyRecursive(
    allocator: Allocator,
    src_path: []const u8,
    dst_path: []const u8,
    options: CopyOptions,
) !void {
    const src_stat = fs.cwd().statFile(src_path) catch |err| switch (err) {
        error.FileNotFound => return FsError.PathNotFound,
        else => return err,
    };

    if (src_stat.kind == .directory) {
        try copyDirRecursive(allocator, src_path, dst_path, options);
    } else {
        try copySingleFile(src_path, dst_path, options);
    }
}

fn copyDirRecursive(
    allocator: Allocator,
    src_path: []const u8,
    dst_path: []const u8,
    options: CopyOptions,
) !void {
    // Create destination directory
    fs.cwd().makePath(dst_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var src_dir = try fs.cwd().openDir(src_path, .{ .iterate = true });
    defer src_dir.close();

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        if (options.skip_hidden and entry.name.len > 0 and entry.name[0] == '.') {
            continue;
        }

        const src_sub = try std.fs.path.join(allocator, &.{ src_path, entry.name });
        defer allocator.free(src_sub);

        const dst_sub = try std.fs.path.join(allocator, &.{ dst_path, entry.name });
        defer allocator.free(dst_sub);

        switch (entry.kind) {
            .directory => {
                try copyDirRecursive(allocator, src_sub, dst_sub, options);
            },
            .file => {
                try copySingleFile(src_sub, dst_sub, options);
            },
            .sym_link => {
                if (options.follow_symlinks) {
                    // Read link target and copy the actual file
                    var link_buf: [Dir.max_path_bytes]u8 = undefined;
                    const link_target = try src_dir.readLink(entry.name, &link_buf);
                    _ = link_target;
                    try copySingleFile(src_sub, dst_sub, options);
                } else {
                    // Copy the symlink itself
                    var link_buf: [Dir.max_path_bytes]u8 = undefined;
                    const link_target = try src_dir.readLink(entry.name, &link_buf);
                    try fs.cwd().symLink(link_target, dst_sub, .{});
                }
            },
            else => {}, // Skip special files
        }
    }
}

fn copySingleFile(src_path: []const u8, dst_path: []const u8, options: CopyOptions) !void {
    const cur_dir = fs.cwd();

    // Check if destination exists
    if (!options.overwrite) {
        if (cur_dir.statFile(dst_path)) |_| {
            return; // File exists, skip
        } else |_| {
            // File doesn't exist, continue
        }
    }

    // Copy the file
    try cur_dir.copyFile(src_path, cur_dir, dst_path, .{});

    // Preserve metadata if requested
    if (options.preserve_metadata) {
        const src_stat = try cur_dir.statFile(src_path);
        var dst_file = try cur_dir.openFile(dst_path, .{ .mode = .read_write });
        defer dst_file.close();

        // Update timestamps
        dst_file.updateTimes(src_stat.atime, src_stat.mtime) catch {};
    }
}

/// Recursively delete a directory or file.
pub fn deleteRecursive(
    allocator: Allocator,
    path: []const u8,
    options: DeleteOptions,
) !void {
    const stat = fs.cwd().statFile(path) catch |err| switch (err) {
        error.FileNotFound => return, // Already gone
        else => if (options.force) return else return err,
    };

    if (stat.kind == .directory) {
        try deleteDirRecursive(allocator, path, options);
    } else if (!options.dirs_only) {
        fs.cwd().deleteFile(path) catch |err| {
            if (!options.force) return err;
        };
    }
}

fn deleteDirRecursive(
    allocator: Allocator,
    path: []const u8,
    options: DeleteOptions,
) !void {
    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        if (options.force) return else return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const sub_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(sub_path);

        switch (entry.kind) {
            .directory => {
                try deleteDirRecursive(allocator, sub_path, options);
            },
            else => {
                if (!options.dirs_only) {
                    fs.cwd().deleteFile(sub_path) catch |err| {
                        if (!options.force) return err;
                    };
                }
            },
        }
    }

    // Remove the now-empty directory
    fs.cwd().deleteDir(path) catch |err| {
        if (!options.force) return err;
    };
}

/// Check if a path exists.
pub fn exists(path: []const u8) bool {
    fs.cwd().statFile(path) catch return false;
    return true;
}

/// Check if a path is a directory.
pub fn isDirectory(path: []const u8) bool {
    const stat = fs.cwd().statFile(path) catch return false;
    return stat.kind == .directory;
}

/// Check if a path is a regular file.
pub fn isFile(path: []const u8) bool {
    const stat = fs.cwd().statFile(path) catch return false;
    return stat.kind == .file;
}

/// Get file size in bytes.
pub fn fileSize(path: []const u8) !u64 {
    const stat = try fs.cwd().statFile(path);
    return stat.size;
}

/// Read entire file contents.
pub fn readFile(allocator: Allocator, path: []const u8) ![]u8 {
    return compat.readFileAlloc(allocator, path, std.math.maxInt(usize));
}

/// Write data to a file, creating parent directories if needed.
pub fn writeFile(allocator: Allocator, path: []const u8, data: []const u8) !void {
    // Ensure parent directory exists
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(allocator, parent);
    }

    const file = try fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

/// Ensure a directory exists, creating it and parents if needed.
pub fn ensureDir(_: Allocator, path: []const u8) !void {
    fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Get the canonical absolute path.
pub fn realPath(allocator: Allocator, path: []const u8) ![]u8 {
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const result = try fs.cwd().realpath(path, &buf);
    return allocator.dupe(u8, result);
}

/// Join path components.
pub fn joinPath(allocator: Allocator, components: []const []const u8) ![]u8 {
    return std.fs.path.join(allocator, components);
}

/// Get the file extension (without the dot).
pub fn extension(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len > 0 and ext[0] == '.') {
        return ext[1..];
    }
    return if (ext.len > 0) ext else null;
}

/// Get the base name of a path.
pub fn baseName(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

/// Get the directory name of a path.
pub fn dirName(path: []const u8) ?[]const u8 {
    return std.fs.path.dirname(path);
}

/// Result of glob expansion.
pub const GlobResult = struct {
    paths: [][]const u8,
    allocator: Allocator,

    pub fn deinit(self: *GlobResult) void {
        for (self.paths) |path| {
            self.allocator.free(path);
        }
        self.allocator.free(self.paths);
    }
};

/// Expand a glob pattern into matching paths.
/// Supports: * (any chars), ? (single char), ** (recursive)
pub fn glob(allocator: Allocator, pattern: []const u8) !GlobResult {
    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |path| {
            allocator.free(path);
        }
        results.deinit(allocator);
    }

    try expandGlob(allocator, &results, ".", pattern);

    return GlobResult{
        .paths = try results.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn expandGlob(
    allocator: Allocator,
    results: *std.ArrayList([]const u8),
    base_path: []const u8,
    pattern: []const u8,
) !void {
    // Find the first glob character
    var first_glob: ?usize = null;
    for (pattern, 0..) |c, i| {
        if (c == '*' or c == '?' or c == '[') {
            first_glob = i;
            break;
        }
    }

    if (first_glob == null) {
        // No glob characters, literal path
        const full_path = if (std.mem.eql(u8, base_path, "."))
            try allocator.dupe(u8, pattern)
        else
            try std.fs.path.join(allocator, &.{ base_path, pattern });

        if (exists(full_path)) {
            try results.append(full_path);
        } else {
            allocator.free(full_path);
        }
        return;
    }

    // Find the directory prefix before the glob
    const glob_start = first_glob.?;
    var dir_end: usize = 0;
    for (pattern[0..glob_start], 0..) |c, i| {
        if (c == '/' or c == '\\') {
            dir_end = i + 1;
        }
    }

    const dir_prefix = if (dir_end > 0) pattern[0 .. dir_end - 1] else "";
    const remaining = pattern[dir_end..];

    const search_dir = if (dir_prefix.len > 0)
        if (std.mem.eql(u8, base_path, "."))
            try allocator.dupe(u8, dir_prefix)
        else
            try std.fs.path.join(allocator, &.{ base_path, dir_prefix })
    else
        try allocator.dupe(u8, base_path);
    defer allocator.free(search_dir);

    // Check for ** pattern
    if (std.mem.startsWith(u8, remaining, "**")) {
        try expandRecursiveGlob(allocator, results, search_dir, remaining[2..]);
    } else {
        try expandSimpleGlob(allocator, results, search_dir, remaining);
    }
}

fn expandRecursiveGlob(
    allocator: Allocator,
    results: *std.ArrayList([]const u8),
    dir_path: []const u8,
    pattern_suffix: []const u8,
) !void {
    const suffix = if (pattern_suffix.len > 0 and (pattern_suffix[0] == '/' or pattern_suffix[0] == '\\'))
        pattern_suffix[1..]
    else
        pattern_suffix;

    // Match in current directory
    if (suffix.len > 0) {
        try expandGlob(allocator, results, dir_path, suffix);
    }

    // Recurse into subdirectories
    var dir = fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            if (entry.name[0] == '.') continue; // Skip hidden

            const sub_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(sub_path);

            // Continue recursive search
            const recursive_pattern = try std.fmt.allocPrint(allocator, "**{s}", .{pattern_suffix});
            defer allocator.free(recursive_pattern);
            try expandGlob(allocator, results, sub_path, recursive_pattern);
        }
    }
}

fn expandSimpleGlob(
    allocator: Allocator,
    results: *std.ArrayList([]const u8),
    dir_path: []const u8,
    pattern: []const u8,
) !void {
    // Find next path separator
    var pattern_end: usize = pattern.len;
    for (pattern, 0..) |c, i| {
        if (c == '/' or c == '\\') {
            pattern_end = i;
            break;
        }
    }

    const current_pattern = pattern[0..pattern_end];
    const remaining_pattern = if (pattern_end < pattern.len) pattern[pattern_end + 1 ..] else "";

    var dir = fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (matchGlobPattern(current_pattern, entry.name)) {
            const match_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });

            if (remaining_pattern.len > 0) {
                defer allocator.free(match_path);
                if (entry.kind == .directory) {
                    try expandGlob(allocator, results, match_path, remaining_pattern);
                }
            } else {
                try results.append(match_path);
            }
        }
    }
}

/// Match a simple glob pattern against a string.
fn matchGlobPattern(pattern: []const u8, str: []const u8) bool {
    var p_idx: usize = 0;
    var s_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (s_idx < str.len) {
        if (p_idx < pattern.len and (pattern[p_idx] == '?' or pattern[p_idx] == str[s_idx])) {
            p_idx += 1;
            s_idx += 1;
        } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            star_idx = p_idx;
            match_idx = s_idx;
            p_idx += 1;
        } else if (star_idx != null) {
            p_idx = star_idx.? + 1;
            match_idx += 1;
            s_idx = match_idx;
        } else {
            return false;
        }
    }

    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}

test "exists" {
    try std.testing.expect(exists("."));
    try std.testing.expect(!exists("nonexistent_file_xyz_123"));
}

test "matchGlobPattern" {
    try std.testing.expect(matchGlobPattern("*.zig", "test.zig"));
    try std.testing.expect(matchGlobPattern("test.*", "test.zig"));
    try std.testing.expect(matchGlobPattern("t?st.zig", "test.zig"));
    try std.testing.expect(!matchGlobPattern("*.cpp", "test.zig"));
    try std.testing.expect(matchGlobPattern("*", "anything"));
    try std.testing.expect(matchGlobPattern("a*b*c", "aXXbYYc"));
}
