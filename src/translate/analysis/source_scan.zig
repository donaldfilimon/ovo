//! Source Scanner - Find sources and headers in project
//!
//! Scans project directories to discover:
//! - Source files (C, C++, Objective-C, etc.)
//! - Header files
//! - Build configuration files
//! - Resource files
//!
//! Useful for auto-generating build configurations from existing codebases.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Scan options
pub const ScanOptions = struct {
    /// Recursively scan subdirectories
    recursive: bool = true,
    /// Follow symbolic links
    follow_symlinks: bool = false,
    /// Include header files in scan
    include_headers: bool = true,
    /// Detect dependencies from includes
    detect_dependencies: bool = true,
    /// Directories to exclude
    exclude_dirs: []const []const u8 = &.{
        ".git",
        ".svn",
        ".hg",
        "node_modules",
        "build",
        "cmake-build-debug",
        "cmake-build-release",
        ".cache",
        "__pycache__",
        "zig-cache",
        "zig-out",
    },
    /// File patterns to exclude
    exclude_patterns: []const []const u8 = &.{
        ".*", // Hidden files
    },
};

/// File type classification
pub const FileType = enum {
    c_source,
    cpp_source,
    objc_source,
    objcpp_source,
    c_header,
    cpp_header,
    asm_source,
    zig_source,
    build_file,
    resource,
    unknown,

    pub fn fromExtension(ext: []const u8) FileType {
        const map = std.StaticStringMap(FileType).initComptime(.{
            // C sources
            .{ ".c", .c_source },
            // C++ sources
            .{ ".cpp", .cpp_source },
            .{ ".cc", .cpp_source },
            .{ ".cxx", .cpp_source },
            .{ ".c++", .cpp_source },
            .{ ".C", .cpp_source },
            // Objective-C
            .{ ".m", .objc_source },
            .{ ".mm", .objcpp_source },
            // Headers
            .{ ".h", .c_header },
            .{ ".hpp", .cpp_header },
            .{ ".hh", .cpp_header },
            .{ ".hxx", .cpp_header },
            .{ ".H", .cpp_header },
            .{ ".inl", .cpp_header },
            .{ ".inc", .c_header },
            // Assembly
            .{ ".s", .asm_source },
            .{ ".S", .asm_source },
            .{ ".asm", .asm_source },
            // Zig
            .{ ".zig", .zig_source },
        });

        return map.get(ext) orelse .unknown;
    }

    pub fn isSource(self: FileType) bool {
        return switch (self) {
            .c_source, .cpp_source, .objc_source, .objcpp_source, .asm_source, .zig_source => true,
            else => false,
        };
    }

    pub fn isHeader(self: FileType) bool {
        return switch (self) {
            .c_header, .cpp_header => true,
            else => false,
        };
    }
};

/// Scanned file information
pub const ScannedFile = struct {
    path: []const u8,
    file_type: FileType,
    size: u64,
    mtime: i128,
    includes: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator, path: []const u8, file_type: FileType, size: u64, mtime: i128) ScannedFile {
        return .{
            .path = path,
            .file_type = file_type,
            .size = size,
            .mtime = mtime,
            .includes = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ScannedFile) void {
        self.includes.deinit();
    }
};

/// Build file detection
pub const BuildFile = struct {
    path: []const u8,
    system: BuildSystem,

    pub const BuildSystem = enum {
        cmake,
        meson,
        makefile,
        autotools,
        bazel,
        buck,
        ninja,
        vcxproj,
        xcodeproj,
        zig_build,
        vcpkg,
        conan,
        cargo,
        unknown,
    };

    pub fn detect(filename: []const u8) ?BuildSystem {
        const map = std.StaticStringMap(BuildSystem).initComptime(.{
            .{ "CMakeLists.txt", .cmake },
            .{ "meson.build", .meson },
            .{ "Makefile", .makefile },
            .{ "makefile", .makefile },
            .{ "GNUmakefile", .makefile },
            .{ "configure.ac", .autotools },
            .{ "configure.in", .autotools },
            .{ "BUILD", .bazel },
            .{ "BUILD.bazel", .bazel },
            .{ "WORKSPACE", .bazel },
            .{ "BUCK", .buck },
            .{ "build.ninja", .ninja },
            .{ "build.zig", .zig_build },
            .{ "build.zig.zon", .zig_build },
            .{ "vcpkg.json", .vcpkg },
            .{ "conanfile.txt", .conan },
            .{ "conanfile.py", .conan },
            .{ "Cargo.toml", .cargo },
        });

        if (map.get(filename)) |sys| return sys;

        // Check extensions
        if (std.mem.endsWith(u8, filename, ".vcxproj")) return .vcxproj;
        if (std.mem.endsWith(u8, filename, ".xcodeproj")) return .xcodeproj;
        if (std.mem.endsWith(u8, filename, ".sln")) return .vcxproj;

        return null;
    }
};

/// Scan result
pub const ScanResult = struct {
    allocator: Allocator,
    root_path: []const u8,
    sources: std.ArrayList(ScannedFile),
    headers: std.ArrayList(ScannedFile),
    build_files: std.ArrayList(BuildFile),
    directories: std.ArrayList([]const u8),
    total_size: u64 = 0,
    file_count: usize = 0,

    pub fn init(allocator: Allocator, root_path: []const u8) ScanResult {
        return .{
            .allocator = allocator,
            .root_path = root_path,
            .sources = std.ArrayList(ScannedFile).init(allocator),
            .headers = std.ArrayList(ScannedFile).init(allocator),
            .build_files = std.ArrayList(BuildFile).init(allocator),
            .directories = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ScanResult) void {
        for (self.sources.items) |*f| f.deinit();
        for (self.headers.items) |*f| f.deinit();
        self.sources.deinit();
        self.headers.deinit();
        self.build_files.deinit();
        self.directories.deinit();
    }

    /// Get all source files as paths
    pub fn getSourcePaths(self: *const ScanResult, allocator: Allocator) ![]const []const u8 {
        var paths = std.ArrayList([]const u8).init(allocator);
        errdefer paths.deinit();

        for (self.sources.items) |f| {
            try paths.append(f.path);
        }

        return paths.toOwnedSlice();
    }

    /// Get all header directories
    pub fn getIncludeDirectories(self: *const ScanResult, allocator: Allocator) ![]const []const u8 {
        var dirs = std.StringHashMap(void).init(allocator);
        defer dirs.deinit();

        for (self.headers.items) |f| {
            const dir = std.fs.path.dirname(f.path) orelse continue;
            try dirs.put(dir, {});
        }

        var result = std.ArrayList([]const u8).init(allocator);
        errdefer result.deinit();

        var iter = dirs.keyIterator();
        while (iter.next()) |key| {
            try result.append(key.*);
        }

        return result.toOwnedSlice();
    }

    /// Check if project uses C++
    pub fn hasCpp(self: *const ScanResult) bool {
        for (self.sources.items) |f| {
            if (f.file_type == .cpp_source or f.file_type == .objcpp_source) {
                return true;
            }
        }
        return false;
    }

    /// Check if project uses Objective-C
    pub fn hasObjC(self: *const ScanResult) bool {
        for (self.sources.items) |f| {
            if (f.file_type == .objc_source or f.file_type == .objcpp_source) {
                return true;
            }
        }
        return false;
    }

    /// Get detected build systems
    pub fn getDetectedBuildSystems(self: *const ScanResult) []const BuildFile.BuildSystem {
        var systems = std.ArrayList(BuildFile.BuildSystem).init(self.allocator);
        var seen = std.AutoHashMap(BuildFile.BuildSystem, void).init(self.allocator);
        defer seen.deinit();

        for (self.build_files.items) |bf| {
            if (!seen.contains(bf.system)) {
                seen.put(bf.system, {}) catch continue;
                systems.append(bf.system) catch continue;
            }
        }

        return systems.toOwnedSlice() catch &.{};
    }
};

/// Scan a directory for source files
pub fn scan(allocator: Allocator, root_path: []const u8, options: ScanOptions) !ScanResult {
    var result = ScanResult.init(allocator, root_path);
    errdefer result.deinit();

    try scanDirectory(allocator, &result, root_path, options, 0);

    return result;
}

fn scanDirectory(allocator: Allocator, result: *ScanResult, dir_path: []const u8, options: ScanOptions, depth: usize) !void {
    // Prevent infinite recursion
    if (depth > 100) return;

    const dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    try result.directories.append(try allocator.dupe(u8, dir_path));

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Check exclusions
        if (shouldExclude(entry.name, options)) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });

        switch (entry.kind) {
            .directory => {
                if (options.recursive) {
                    try scanDirectory(allocator, result, full_path, options, depth + 1);
                }
            },
            .file => {
                try processFile(allocator, result, full_path, entry.name, options);
            },
            .sym_link => {
                if (options.follow_symlinks) {
                    // Would resolve and process symlink
                }
            },
            else => {},
        }
    }
}

fn processFile(allocator: Allocator, result: *ScanResult, full_path: []const u8, filename: []const u8, options: ScanOptions) !void {
    result.file_count += 1;

    // Check for build files
    if (BuildFile.detect(filename)) |system| {
        try result.build_files.append(.{
            .path = try allocator.dupe(u8, full_path),
            .system = system,
        });
    }

    // Get file extension
    const ext = std.fs.path.extension(filename);
    const file_type = FileType.fromExtension(ext);

    if (file_type == .unknown) return;

    // Get file stats
    const stat = std.fs.cwd().statFile(full_path) catch return;
    result.total_size += stat.size;

    var scanned = ScannedFile.init(
        allocator,
        try allocator.dupe(u8, full_path),
        file_type,
        stat.size,
        stat.mtime,
    );
    errdefer scanned.deinit();

    // Extract includes if requested
    if (options.detect_dependencies and (file_type.isSource() or file_type.isHeader())) {
        try extractIncludes(allocator, &scanned);
    }

    // Add to appropriate list
    if (file_type.isSource()) {
        try result.sources.append(scanned);
    } else if (file_type.isHeader() and options.include_headers) {
        try result.headers.append(scanned);
    }
}

fn shouldExclude(name: []const u8, options: ScanOptions) bool {
    // Check excluded directories
    for (options.exclude_dirs) |exclude| {
        if (std.mem.eql(u8, name, exclude)) return true;
    }

    // Check patterns (simple prefix match for now)
    for (options.exclude_patterns) |pattern| {
        if (pattern.len > 0 and pattern[0] == '.' and name.len > 0 and name[0] == '.') {
            return true;
        }
    }

    return false;
}

fn extractIncludes(allocator: Allocator, file: *ScannedFile) !void {
    const content = std.fs.cwd().readFileAlloc(allocator, file.path, 10 * 1024 * 1024) catch return;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        // Look for #include
        if (std.mem.startsWith(u8, trimmed, "#include")) {
            const after_include = std.mem.trimLeft(u8, trimmed[8..], " \t");

            // Extract header name
            if (after_include.len > 0) {
                const delim: u8 = if (after_include[0] == '<') '>' else if (after_include[0] == '"') '"' else continue;
                const start = after_include[1..];
                if (std.mem.indexOf(u8, start, &.{delim})) |end| {
                    const header = start[0..end];
                    try file.includes.append(try allocator.dupe(u8, header));
                }
            }
        }
    }
}

/// Suggest project structure based on scan results
pub fn suggestStructure(result: *const ScanResult) struct {
    src_dirs: []const []const u8,
    include_dirs: []const []const u8,
    has_tests: bool,
    has_examples: bool,
    primary_language: []const u8,
} {
    var src_dirs = std.ArrayList([]const u8).init(result.allocator);
    var include_dirs = std.ArrayList([]const u8).init(result.allocator);
    var has_tests = false;
    var has_examples = false;

    // Analyze directory structure
    for (result.directories.items) |dir| {
        const basename = std.fs.path.basename(dir);

        if (std.mem.eql(u8, basename, "src") or
            std.mem.eql(u8, basename, "source") or
            std.mem.eql(u8, basename, "lib"))
        {
            src_dirs.append(dir) catch {};
        }

        if (std.mem.eql(u8, basename, "include") or
            std.mem.eql(u8, basename, "inc") or
            std.mem.eql(u8, basename, "headers"))
        {
            include_dirs.append(dir) catch {};
        }

        if (std.mem.eql(u8, basename, "test") or
            std.mem.eql(u8, basename, "tests") or
            std.mem.eql(u8, basename, "testing"))
        {
            has_tests = true;
        }

        if (std.mem.eql(u8, basename, "examples") or
            std.mem.eql(u8, basename, "samples") or
            std.mem.eql(u8, basename, "demo"))
        {
            has_examples = true;
        }
    }

    // Determine primary language
    var c_count: usize = 0;
    var cpp_count: usize = 0;

    for (result.sources.items) |f| {
        switch (f.file_type) {
            .c_source => c_count += 1,
            .cpp_source, .objcpp_source => cpp_count += 1,
            else => {},
        }
    }

    const primary_language: []const u8 = if (cpp_count > c_count) "C++" else "C";

    return .{
        .src_dirs = src_dirs.toOwnedSlice() catch &.{},
        .include_dirs = include_dirs.toOwnedSlice() catch &.{},
        .has_tests = has_tests,
        .has_examples = has_examples,
        .primary_language = primary_language,
    };
}

// Tests
test "FileType.fromExtension" {
    try std.testing.expectEqual(FileType.c_source, FileType.fromExtension(".c"));
    try std.testing.expectEqual(FileType.cpp_source, FileType.fromExtension(".cpp"));
    try std.testing.expectEqual(FileType.cpp_source, FileType.fromExtension(".cc"));
    try std.testing.expectEqual(FileType.c_header, FileType.fromExtension(".h"));
    try std.testing.expectEqual(FileType.cpp_header, FileType.fromExtension(".hpp"));
    try std.testing.expectEqual(FileType.unknown, FileType.fromExtension(".txt"));
}

test "BuildFile.detect" {
    try std.testing.expectEqual(BuildFile.BuildSystem.cmake, BuildFile.detect("CMakeLists.txt").?);
    try std.testing.expectEqual(BuildFile.BuildSystem.meson, BuildFile.detect("meson.build").?);
    try std.testing.expectEqual(BuildFile.BuildSystem.makefile, BuildFile.detect("Makefile").?);
    try std.testing.expectEqual(BuildFile.BuildSystem.zig_build, BuildFile.detect("build.zig").?);
    try std.testing.expect(BuildFile.detect("random.txt") == null);
}

test "shouldExclude" {
    const options = ScanOptions{};
    try std.testing.expect(shouldExclude(".git", options));
    try std.testing.expect(shouldExclude("node_modules", options));
    try std.testing.expect(!shouldExclude("src", options));
}
