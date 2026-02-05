//! Dependency Detector - Detect dependencies from includes
//!
//! Analyzes source files to detect:
//! - System library dependencies from #include patterns
//! - Third-party library usage
//! - Internal vs external headers
//! - Missing dependencies

const std = @import("std");
const Allocator = std.mem.Allocator;
const source_scan = @import("source_scan.zig");

/// Known library detection patterns
const LibraryPattern = struct {
    header_pattern: []const u8,
    library_name: []const u8,
    package_name: []const u8,
    system_library: bool = false,
};

/// Common library patterns for detection
const known_libraries = [_]LibraryPattern{
    // Standard C/C++ (system)
    .{ .header_pattern = "stdio.h", .library_name = "c", .package_name = "libc", .system_library = true },
    .{ .header_pattern = "stdlib.h", .library_name = "c", .package_name = "libc", .system_library = true },
    .{ .header_pattern = "string.h", .library_name = "c", .package_name = "libc", .system_library = true },
    .{ .header_pattern = "iostream", .library_name = "stdc++", .package_name = "libstdc++", .system_library = true },
    .{ .header_pattern = "vector", .library_name = "stdc++", .package_name = "libstdc++", .system_library = true },
    .{ .header_pattern = "memory", .library_name = "stdc++", .package_name = "libstdc++", .system_library = true },

    // POSIX
    .{ .header_pattern = "pthread.h", .library_name = "pthread", .package_name = "pthread", .system_library = true },
    .{ .header_pattern = "unistd.h", .library_name = "c", .package_name = "libc", .system_library = true },
    .{ .header_pattern = "sys/socket.h", .library_name = "c", .package_name = "libc", .system_library = true },

    // Compression
    .{ .header_pattern = "zlib.h", .library_name = "z", .package_name = "zlib", .system_library = false },
    .{ .header_pattern = "bzlib.h", .library_name = "bz2", .package_name = "bzip2", .system_library = false },
    .{ .header_pattern = "lzma.h", .library_name = "lzma", .package_name = "xz", .system_library = false },
    .{ .header_pattern = "zstd.h", .library_name = "zstd", .package_name = "zstd", .system_library = false },

    // Crypto/SSL
    .{ .header_pattern = "openssl/", .library_name = "ssl", .package_name = "openssl", .system_library = false },
    .{ .header_pattern = "mbedtls/", .library_name = "mbedtls", .package_name = "mbedtls", .system_library = false },

    // Networking
    .{ .header_pattern = "curl/curl.h", .library_name = "curl", .package_name = "curl", .system_library = false },

    // Image
    .{ .header_pattern = "png.h", .library_name = "png", .package_name = "libpng", .system_library = false },
    .{ .header_pattern = "jpeglib.h", .library_name = "jpeg", .package_name = "libjpeg", .system_library = false },
    .{ .header_pattern = "gif_lib.h", .library_name = "gif", .package_name = "giflib", .system_library = false },
    .{ .header_pattern = "webp/", .library_name = "webp", .package_name = "libwebp", .system_library = false },

    // Audio/Video
    .{ .header_pattern = "SDL.h", .library_name = "SDL2", .package_name = "sdl2", .system_library = false },
    .{ .header_pattern = "SDL2/", .library_name = "SDL2", .package_name = "sdl2", .system_library = false },
    .{ .header_pattern = "portaudio.h", .library_name = "portaudio", .package_name = "portaudio", .system_library = false },
    .{ .header_pattern = "libavcodec/", .library_name = "avcodec", .package_name = "ffmpeg", .system_library = false },
    .{ .header_pattern = "libavformat/", .library_name = "avformat", .package_name = "ffmpeg", .system_library = false },

    // Graphics
    .{ .header_pattern = "GL/gl.h", .library_name = "GL", .package_name = "opengl", .system_library = true },
    .{ .header_pattern = "GLFW/glfw3.h", .library_name = "glfw", .package_name = "glfw", .system_library = false },
    .{ .header_pattern = "vulkan/", .library_name = "vulkan", .package_name = "vulkan", .system_library = false },

    // UI
    .{ .header_pattern = "gtk/gtk.h", .library_name = "gtk-3", .package_name = "gtk3", .system_library = false },
    .{ .header_pattern = "gtk-4.0/", .library_name = "gtk-4", .package_name = "gtk4", .system_library = false },
    .{ .header_pattern = "Qt", .library_name = "Qt5Core", .package_name = "qt5", .system_library = false },

    // Database
    .{ .header_pattern = "sqlite3.h", .library_name = "sqlite3", .package_name = "sqlite", .system_library = false },
    .{ .header_pattern = "mysql/", .library_name = "mysqlclient", .package_name = "mysql", .system_library = false },
    .{ .header_pattern = "postgresql/", .library_name = "pq", .package_name = "postgresql", .system_library = false },

    // JSON
    .{ .header_pattern = "nlohmann/json.hpp", .library_name = "nlohmann_json", .package_name = "nlohmann-json", .system_library = false },
    .{ .header_pattern = "rapidjson/", .library_name = "rapidjson", .package_name = "rapidjson", .system_library = false },
    .{ .header_pattern = "cJSON.h", .library_name = "cjson", .package_name = "cjson", .system_library = false },

    // XML
    .{ .header_pattern = "libxml/", .library_name = "xml2", .package_name = "libxml2", .system_library = false },
    .{ .header_pattern = "expat.h", .library_name = "expat", .package_name = "expat", .system_library = false },
    .{ .header_pattern = "tinyxml2.h", .library_name = "tinyxml2", .package_name = "tinyxml2", .system_library = false },

    // Testing
    .{ .header_pattern = "gtest/gtest.h", .library_name = "gtest", .package_name = "googletest", .system_library = false },
    .{ .header_pattern = "gmock/gmock.h", .library_name = "gmock", .package_name = "googletest", .system_library = false },
    .{ .header_pattern = "catch2/", .library_name = "Catch2", .package_name = "catch2", .system_library = false },
    .{ .header_pattern = "doctest/", .library_name = "doctest", .package_name = "doctest", .system_library = false },

    // Logging
    .{ .header_pattern = "spdlog/", .library_name = "spdlog", .package_name = "spdlog", .system_library = false },

    // Format
    .{ .header_pattern = "fmt/", .library_name = "fmt", .package_name = "fmt", .system_library = false },

    // Boost (partial)
    .{ .header_pattern = "boost/", .library_name = "boost", .package_name = "boost", .system_library = false },

    // Apple frameworks
    .{ .header_pattern = "Cocoa/Cocoa.h", .library_name = "Cocoa", .package_name = "macos-sdk", .system_library = true },
    .{ .header_pattern = "Foundation/Foundation.h", .library_name = "Foundation", .package_name = "macos-sdk", .system_library = true },
    .{ .header_pattern = "CoreFoundation/", .library_name = "CoreFoundation", .package_name = "macos-sdk", .system_library = true },
    .{ .header_pattern = "Metal/Metal.h", .library_name = "Metal", .package_name = "macos-sdk", .system_library = true },

    // Windows
    .{ .header_pattern = "windows.h", .library_name = "kernel32", .package_name = "windows-sdk", .system_library = true },
    .{ .header_pattern = "winsock2.h", .library_name = "ws2_32", .package_name = "windows-sdk", .system_library = true },
};

/// Detected dependency
pub const DetectedDependency = struct {
    name: []const u8,
    package_name: []const u8,
    is_system: bool,
    confidence: f32,
    source_files: std.ArrayList([]const u8),
    header_matches: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator, name: []const u8, package_name: []const u8, is_system: bool) DetectedDependency {
        return .{
            .name = name,
            .package_name = package_name,
            .is_system = is_system,
            .confidence = 0.0,
            .source_files = std.ArrayList([]const u8).init(allocator),
            .header_matches = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *DetectedDependency) void {
        self.source_files.deinit();
        self.header_matches.deinit();
    }
};

/// Detection result
pub const DetectionResult = struct {
    allocator: Allocator,
    dependencies: std.ArrayList(DetectedDependency),
    unresolved_includes: std.ArrayList([]const u8),
    internal_headers: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator) DetectionResult {
        return .{
            .allocator = allocator,
            .dependencies = std.ArrayList(DetectedDependency).init(allocator),
            .unresolved_includes = std.ArrayList([]const u8).init(allocator),
            .internal_headers = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *DetectionResult) void {
        for (self.dependencies.items) |*dep| {
            dep.deinit();
        }
        self.dependencies.deinit();
        self.unresolved_includes.deinit();
        self.internal_headers.deinit();
    }

    /// Get non-system dependencies
    pub fn getExternalDependencies(self: *const DetectionResult, allocator: Allocator) ![]const DetectedDependency {
        var result = std.ArrayList(DetectedDependency).init(allocator);
        errdefer result.deinit();

        for (self.dependencies.items) |dep| {
            if (!dep.is_system) {
                try result.append(dep);
            }
        }

        return result.toOwnedSlice();
    }

    /// Get package names for package manager
    pub fn getPackageNames(self: *const DetectionResult, allocator: Allocator, include_system: bool) ![]const []const u8 {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();

        var result = std.ArrayList([]const u8).init(allocator);
        errdefer result.deinit();

        for (self.dependencies.items) |dep| {
            if (!include_system and dep.is_system) continue;
            if (seen.contains(dep.package_name)) continue;

            try seen.put(dep.package_name, {});
            try result.append(dep.package_name);
        }

        return result.toOwnedSlice();
    }
};

/// Detect dependencies from scan results
pub fn detect(allocator: Allocator, scan_result: *const source_scan.ScanResult) !DetectionResult {
    var result = DetectionResult.init(allocator);
    errdefer result.deinit();

    // Track which dependencies we've found
    var dep_map = std.StringHashMap(*DetectedDependency).init(allocator);
    defer dep_map.deinit();

    // Track all project headers
    var project_headers = std.StringHashMap(void).init(allocator);
    defer project_headers.deinit();

    for (scan_result.headers.items) |header| {
        const basename = std.fs.path.basename(header.path);
        try project_headers.put(basename, {});
    }

    // Analyze includes from all source files
    for (scan_result.sources.items) |source| {
        for (source.includes.items) |include| {
            // Check if it's a project header
            const basename = std.fs.path.basename(include);
            if (project_headers.contains(basename) or project_headers.contains(include)) {
                try result.internal_headers.append(include);
                continue;
            }

            // Try to match against known libraries
            var matched = false;
            for (known_libraries) |lib| {
                if (matchesPattern(include, lib.header_pattern)) {
                    matched = true;

                    // Get or create dependency
                    const dep = dep_map.get(lib.library_name) orelse blk: {
                        const new_dep = DetectedDependency.init(
                            allocator,
                            lib.library_name,
                            lib.package_name,
                            lib.system_library,
                        );
                        try result.dependencies.append(new_dep);
                        const ptr = &result.dependencies.items[result.dependencies.items.len - 1];
                        try dep_map.put(lib.library_name, ptr);
                        break :blk ptr;
                    };

                    try dep.source_files.append(source.path);
                    try dep.header_matches.append(include);

                    // Update confidence based on number of matches
                    const match_count: f32 = @floatFromInt(dep.header_matches.items.len);
                    dep.confidence = @min(1.0, match_count / 5.0);

                    break;
                }
            }

            if (!matched) {
                // Unresolved include
                var already_unresolved = false;
                for (result.unresolved_includes.items) |u| {
                    if (std.mem.eql(u8, u, include)) {
                        already_unresolved = true;
                        break;
                    }
                }
                if (!already_unresolved) {
                    try result.unresolved_includes.append(include);
                }
            }
        }
    }

    return result;
}

fn matchesPattern(include: []const u8, pattern: []const u8) bool {
    // Direct match
    if (std.mem.eql(u8, include, pattern)) return true;

    // Prefix match (for directory patterns like "boost/")
    if (pattern.len > 0 and pattern[pattern.len - 1] == '/') {
        if (std.mem.startsWith(u8, include, pattern)) return true;
    }

    // Contains match for complex patterns
    if (std.mem.indexOf(u8, include, pattern)) |_| return true;

    return false;
}

/// Suggest missing dependencies based on unresolved includes
pub fn suggestDependencies(allocator: Allocator, unresolved: []const []const u8) ![]const struct {
    include: []const u8,
    suggestions: []const []const u8,
} {
    var result = std.ArrayList(struct {
        include: []const u8,
        suggestions: []const []const u8,
    }).init(allocator);
    errdefer result.deinit();

    for (unresolved) |include| {
        var suggestions = std.ArrayList([]const u8).init(allocator);
        errdefer suggestions.deinit();

        // Heuristic suggestions based on include path
        if (std.mem.indexOf(u8, include, "json")) |_| {
            try suggestions.append("nlohmann-json");
            try suggestions.append("rapidjson");
        }
        if (std.mem.indexOf(u8, include, "xml")) |_| {
            try suggestions.append("libxml2");
            try suggestions.append("tinyxml2");
        }
        if (std.mem.indexOf(u8, include, "http")) |_| {
            try suggestions.append("curl");
            try suggestions.append("cpp-httplib");
        }
        if (std.mem.indexOf(u8, include, "socket")) |_| {
            try suggestions.append("asio");
            try suggestions.append("boost");
        }

        if (suggestions.items.len > 0) {
            try result.append(.{
                .include = include,
                .suggestions = try suggestions.toOwnedSlice(),
            });
        }
    }

    return result.toOwnedSlice();
}

// Tests
test "matchesPattern" {
    // Direct match
    try std.testing.expect(matchesPattern("zlib.h", "zlib.h"));

    // Prefix match
    try std.testing.expect(matchesPattern("boost/asio.hpp", "boost/"));
    try std.testing.expect(matchesPattern("openssl/ssl.h", "openssl/"));

    // No match
    try std.testing.expect(!matchesPattern("mylib.h", "zlib.h"));
}

test "DetectionResult lifecycle" {
    const allocator = std.testing.allocator;

    var result = DetectionResult.init(allocator);
    defer result.deinit();

    var dep = DetectedDependency.init(allocator, "test", "test-pkg", false);
    try dep.source_files.append("main.c");
    try result.dependencies.append(dep);

    try std.testing.expectEqual(@as(usize, 1), result.dependencies.items.len);
}
