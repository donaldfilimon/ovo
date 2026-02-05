//! Archive source (tarball/zip).
//!
//! Handles downloading and extracting archives from URLs,
//! with support for various formats and integrity verification.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const integrity = @import("../integrity.zig");

/// Archive-specific errors.
pub const ArchiveError = error{
    DownloadFailed,
    ExtractionFailed,
    UnsupportedFormat,
    HashMismatch,
    InvalidArchive,
    CorruptedArchive,
    OutOfMemory,
    NetworkError,
    Timeout,
};

/// Supported archive formats.
pub const ArchiveFormat = enum {
    tar_gz,
    tar_xz,
    tar_bz2,
    tar,
    zip,

    pub fn fromFilename(filename: []const u8) ?ArchiveFormat {
        if (std.mem.endsWith(u8, filename, ".tar.gz") or std.mem.endsWith(u8, filename, ".tgz")) {
            return .tar_gz;
        }
        if (std.mem.endsWith(u8, filename, ".tar.xz") or std.mem.endsWith(u8, filename, ".txz")) {
            return .tar_xz;
        }
        if (std.mem.endsWith(u8, filename, ".tar.bz2") or std.mem.endsWith(u8, filename, ".tbz2")) {
            return .tar_bz2;
        }
        if (std.mem.endsWith(u8, filename, ".tar")) {
            return .tar;
        }
        if (std.mem.endsWith(u8, filename, ".zip")) {
            return .zip;
        }
        return null;
    }

    pub fn extension(self: ArchiveFormat) []const u8 {
        return switch (self) {
            .tar_gz => ".tar.gz",
            .tar_xz => ".tar.xz",
            .tar_bz2 => ".tar.bz2",
            .tar => ".tar",
            .zip => ".zip",
        };
    }
};

/// Archive configuration.
pub const ArchiveConfig = struct {
    /// Archive URL.
    url: []const u8,

    /// Expected integrity hash (SHA256).
    integrity_hash: ?[]const u8 = null,

    /// Number of leading path components to strip.
    strip_prefix: u32 = 0,

    /// Archive format (auto-detected if not specified).
    format: ?ArchiveFormat = null,

    /// Download timeout in milliseconds.
    timeout_ms: u32 = 300000,

    /// HTTP headers for download.
    headers: []const Header = &.{},

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };
};

/// Result of an archive fetch operation.
pub const FetchResult = struct {
    /// Path to extracted contents.
    path: []const u8,

    /// Content hash of extracted contents.
    content_hash: []const u8,

    /// Archive hash (before extraction).
    archive_hash: []const u8,

    /// Detected or specified format.
    format: ArchiveFormat,

    pub fn deinit(self: *FetchResult, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content_hash);
        allocator.free(self.archive_hash);
    }
};

/// Archive source handler.
pub const ArchiveSource = struct {
    allocator: Allocator,
    cache_dir: []const u8,

    pub fn init(allocator: Allocator, cache_dir: []const u8) ArchiveSource {
        return .{
            .allocator = allocator,
            .cache_dir = cache_dir,
        };
    }

    /// Fetch and extract an archive.
    pub fn fetch(self: *ArchiveSource, config: ArchiveConfig, dest: []const u8) ArchiveError!FetchResult {
        // Detect format
        const format = config.format orelse ArchiveFormat.fromFilename(config.url) orelse
            return error.UnsupportedFormat;

        // Download archive
        const archive_path = try self.download(config.url, format, config.timeout_ms);
        defer self.allocator.free(archive_path);
        defer fs.cwd().deleteFile(archive_path) catch {};

        // Calculate archive hash
        const archive_hash = integrity.hashFile(self.allocator, archive_path) catch return error.DownloadFailed;
        const archive_hash_str = integrity.hashToString(archive_hash);

        // Verify integrity if hash provided
        if (config.integrity_hash) |expected| {
            const result = integrity.verifyFileHex(self.allocator, archive_path, expected) catch
                return error.HashMismatch;
            if (!result.valid) {
                return error.HashMismatch;
            }
        }

        // Create extraction directory
        fs.cwd().makePath(dest) catch return error.ExtractionFailed;

        // Extract archive
        try self.extract(archive_path, dest, format, config.strip_prefix);

        // Calculate content hash
        const content_hash = integrity.hashDirectory(self.allocator, dest) catch
            return error.ExtractionFailed;
        const content_hash_str = integrity.hashToString(content_hash);

        return FetchResult{
            .path = self.allocator.dupe(u8, dest) catch return error.OutOfMemory,
            .content_hash = self.allocator.dupe(u8, &content_hash_str) catch return error.OutOfMemory,
            .archive_hash = self.allocator.dupe(u8, &archive_hash_str) catch return error.OutOfMemory,
            .format = format,
        };
    }

    /// Download an archive to a temporary file.
    fn download(
        self: *ArchiveSource,
        url: []const u8,
        format: ArchiveFormat,
        timeout_ms: u32,
    ) ArchiveError![]const u8 {
        // Create temp file path
        const timestamp = std.time.timestamp();
        const temp_path = std.fmt.allocPrint(
            self.allocator,
            "{s}/download-{d}{s}",
            .{ self.cache_dir, timestamp, format.extension() },
        ) catch return error.OutOfMemory;
        errdefer self.allocator.free(temp_path);

        // Ensure cache directory exists
        fs.cwd().makePath(self.cache_dir) catch return error.DownloadFailed;

        // Use curl for download
        const timeout_str = std.fmt.allocPrint(
            self.allocator,
            "{d}",
            .{timeout_ms / 1000},
        ) catch return error.OutOfMemory;
        defer self.allocator.free(timeout_str);

        var child = std.process.Child.init(&.{
            "curl",
            "-L", // Follow redirects
            "-f", // Fail on HTTP errors
            "-o",
            temp_path,
            "--max-time",
            timeout_str,
            "--progress-bar",
            url,
        }, self.allocator);

        child.spawn() catch return error.DownloadFailed;
        const result = child.wait() catch return error.DownloadFailed;

        if (result.Exited != 0) {
            self.allocator.free(temp_path);
            return error.DownloadFailed;
        }

        return temp_path;
    }

    /// Extract an archive.
    fn extract(
        self: *ArchiveSource,
        archive_path: []const u8,
        dest: []const u8,
        format: ArchiveFormat,
        strip_prefix: u32,
    ) ArchiveError!void {
        switch (format) {
            .tar_gz => try self.extractTar(archive_path, dest, "z", strip_prefix),
            .tar_xz => try self.extractTar(archive_path, dest, "J", strip_prefix),
            .tar_bz2 => try self.extractTar(archive_path, dest, "j", strip_prefix),
            .tar => try self.extractTar(archive_path, dest, "", strip_prefix),
            .zip => try self.extractZip(archive_path, dest),
        }
    }

    fn extractTar(
        self: *ArchiveSource,
        archive_path: []const u8,
        dest: []const u8,
        compression_flag: []const u8,
        strip_prefix: u32,
    ) ArchiveError!void {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        args.append("tar") catch return error.OutOfMemory;

        // Build flags
        if (compression_flag.len > 0) {
            const flags = std.fmt.allocPrint(self.allocator, "-x{s}f", .{compression_flag}) catch
                return error.OutOfMemory;
            defer self.allocator.free(flags);
            args.append(flags) catch return error.OutOfMemory;
        } else {
            args.append("-xf") catch return error.OutOfMemory;
        }

        args.append(archive_path) catch return error.OutOfMemory;
        args.appendSlice(&.{ "-C", dest }) catch return error.OutOfMemory;

        // Strip prefix
        if (strip_prefix > 0) {
            const strip_str = std.fmt.allocPrint(self.allocator, "--strip-components={d}", .{strip_prefix}) catch
                return error.OutOfMemory;
            defer self.allocator.free(strip_str);
            args.append(strip_str) catch return error.OutOfMemory;
        }

        var child = std.process.Child.init(args.items, self.allocator);
        child.spawn() catch return error.ExtractionFailed;
        const result = child.wait() catch return error.ExtractionFailed;

        if (result.Exited != 0) {
            return error.ExtractionFailed;
        }
    }

    fn extractZip(
        self: *ArchiveSource,
        archive_path: []const u8,
        dest: []const u8,
    ) ArchiveError!void {
        var child = std.process.Child.init(&.{
            "unzip",
            "-q", // Quiet
            "-o", // Overwrite
            archive_path,
            "-d",
            dest,
        }, self.allocator);

        child.spawn() catch return error.ExtractionFailed;
        const result = child.wait() catch return error.ExtractionFailed;

        if (result.Exited != 0) {
            return error.ExtractionFailed;
        }
    }

    /// List contents of an archive without extracting.
    pub fn list(self: *ArchiveSource, archive_path: []const u8) ArchiveError![][]const u8 {
        const format = ArchiveFormat.fromFilename(archive_path) orelse return error.UnsupportedFormat;

        return switch (format) {
            .tar_gz => self.listTar(archive_path, "z"),
            .tar_xz => self.listTar(archive_path, "J"),
            .tar_bz2 => self.listTar(archive_path, "j"),
            .tar => self.listTar(archive_path, ""),
            .zip => self.listZip(archive_path),
        };
    }

    fn listTar(
        self: *ArchiveSource,
        archive_path: []const u8,
        compression_flag: []const u8,
    ) ArchiveError![][]const u8 {
        const flags = if (compression_flag.len > 0)
            std.fmt.allocPrint(self.allocator, "-t{s}f", .{compression_flag}) catch return error.OutOfMemory
        else
            self.allocator.dupe(u8, "-tf") catch return error.OutOfMemory;
        defer self.allocator.free(flags);

        var child = std.process.Child.init(&.{ "tar", flags, archive_path }, self.allocator);
        child.stdout_behavior = .Pipe;

        child.spawn() catch return error.ExtractionFailed;
        const stdout = child.stdout orelse return error.ExtractionFailed;
        const output = stdout.reader().readAllAlloc(self.allocator, 10 * 1024 * 1024) catch
            return error.ExtractionFailed;
        defer self.allocator.free(output);

        _ = child.wait() catch return error.ExtractionFailed;

        return self.parseFileList(output);
    }

    fn listZip(
        self: *ArchiveSource,
        archive_path: []const u8,
    ) ArchiveError![][]const u8 {
        var child = std.process.Child.init(&.{ "unzip", "-l", archive_path }, self.allocator);
        child.stdout_behavior = .Pipe;

        child.spawn() catch return error.ExtractionFailed;
        const stdout = child.stdout orelse return error.ExtractionFailed;
        const output = stdout.reader().readAllAlloc(self.allocator, 10 * 1024 * 1024) catch
            return error.ExtractionFailed;
        defer self.allocator.free(output);

        _ = child.wait() catch return error.ExtractionFailed;

        return self.parseFileList(output);
    }

    fn parseFileList(self: *ArchiveSource, output: []const u8) ArchiveError![][]const u8 {
        var files = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (files.items) |f| self.allocator.free(f);
            files.deinit();
        }

        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0) {
                const file = self.allocator.dupe(u8, trimmed) catch return error.OutOfMemory;
                files.append(file) catch return error.OutOfMemory;
            }
        }

        return files.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// Verify an archive's integrity.
    pub fn verify(
        self: *ArchiveSource,
        archive_path: []const u8,
        expected_hash: []const u8,
    ) ArchiveError!bool {
        const result = integrity.verifyFileHex(self.allocator, archive_path, expected_hash) catch
            return false;
        return result.valid;
    }
};

/// Build a download URL for common hosting services.
pub const UrlBuilder = struct {
    /// GitHub release archive URL.
    pub fn githubRelease(
        allocator: Allocator,
        owner: []const u8,
        repo: []const u8,
        tag: []const u8,
        format: ArchiveFormat,
    ) ![]const u8 {
        const ext = switch (format) {
            .tar_gz => "tar.gz",
            .zip => "zip",
            else => return error.UnsupportedFormat,
        };

        return std.fmt.allocPrint(
            allocator,
            "https://github.com/{s}/{s}/archive/refs/tags/{s}.{s}",
            .{ owner, repo, tag, ext },
        );
    }

    /// GitHub source archive URL.
    pub fn githubSource(
        allocator: Allocator,
        owner: []const u8,
        repo: []const u8,
        ref: []const u8,
        format: ArchiveFormat,
    ) ![]const u8 {
        const ext = switch (format) {
            .tar_gz => "tar.gz",
            .zip => "zip",
            else => return error.UnsupportedFormat,
        };

        return std.fmt.allocPrint(
            allocator,
            "https://github.com/{s}/{s}/archive/{s}.{s}",
            .{ owner, repo, ref, ext },
        );
    }

    /// GitLab release archive URL.
    pub fn gitlabRelease(
        allocator: Allocator,
        project_path: []const u8,
        tag: []const u8,
        format: ArchiveFormat,
    ) ![]const u8 {
        const ext = switch (format) {
            .tar_gz => "tar.gz",
            .zip => "zip",
            else => return error.UnsupportedFormat,
        };

        return std.fmt.allocPrint(
            allocator,
            "https://gitlab.com/{s}/-/archive/{s}/{s}.{s}",
            .{ project_path, tag, tag, ext },
        );
    }
};

// Tests
test "archive format detection" {
    try std.testing.expect(ArchiveFormat.fromFilename("package.tar.gz") == .tar_gz);
    try std.testing.expect(ArchiveFormat.fromFilename("package.tgz") == .tar_gz);
    try std.testing.expect(ArchiveFormat.fromFilename("package.tar.xz") == .tar_xz);
    try std.testing.expect(ArchiveFormat.fromFilename("package.zip") == .zip);
    try std.testing.expect(ArchiveFormat.fromFilename("package.txt") == null);
}

test "url builder github release" {
    const allocator = std.testing.allocator;
    const url = try UrlBuilder.githubRelease(allocator, "owner", "repo", "v1.0.0", .tar_gz);
    defer allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://github.com/owner/repo/archive/refs/tags/v1.0.0.tar.gz",
        url,
    );
}

test "url builder github source" {
    const allocator = std.testing.allocator;
    const url = try UrlBuilder.githubSource(allocator, "owner", "repo", "main", .zip);
    defer allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://github.com/owner/repo/archive/main.zip",
        url,
    );
}
