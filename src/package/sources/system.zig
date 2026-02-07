//! System library detection.
//!
//! Detects system-installed libraries using pkg-config and common paths,
//! with fallback support when system libraries are not found.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const compat = @import("util").compat;

/// System-specific errors.
pub const SystemError = error{
    LibraryNotFound,
    PkgConfigNotFound,
    PkgConfigFailed,
    InvalidFlags,
    OutOfMemory,
    CommandFailed,
};

/// System library information.
pub const LibraryInfo = struct {
    /// Library name.
    name: []const u8,

    /// Version (if available).
    version: ?[]const u8 = null,

    /// Include directories.
    include_dirs: []const []const u8,

    /// Library directories.
    lib_dirs: []const []const u8,

    /// Libraries to link.
    libraries: []const []const u8,

    /// Preprocessor defines.
    defines: []const []const u8,

    /// Compiler flags.
    cflags: []const []const u8,

    /// Linker flags.
    ldflags: []const []const u8,

    /// How the library was found.
    source: Source,

    pub const Source = enum {
        pkg_config,
        manual_search,
        environment,
        builtin,
    };

    pub fn deinit(self: *LibraryInfo, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.version) |v| allocator.free(v);
        for (self.include_dirs) |d| allocator.free(d);
        allocator.free(self.include_dirs);
        for (self.lib_dirs) |d| allocator.free(d);
        allocator.free(self.lib_dirs);
        for (self.libraries) |l| allocator.free(l);
        allocator.free(self.libraries);
        for (self.defines) |d| allocator.free(d);
        allocator.free(self.defines);
        for (self.cflags) |f| allocator.free(f);
        allocator.free(self.cflags);
        for (self.ldflags) |f| allocator.free(f);
        allocator.free(self.ldflags);
    }

    pub fn clone(self: LibraryInfo, allocator: Allocator) !LibraryInfo {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .version = if (self.version) |v| try allocator.dupe(u8, v) else null,
            .include_dirs = try cloneStringSlice(allocator, self.include_dirs),
            .lib_dirs = try cloneStringSlice(allocator, self.lib_dirs),
            .libraries = try cloneStringSlice(allocator, self.libraries),
            .defines = try cloneStringSlice(allocator, self.defines),
            .cflags = try cloneStringSlice(allocator, self.cflags),
            .ldflags = try cloneStringSlice(allocator, self.ldflags),
            .source = self.source,
        };
    }
};

fn cloneStringSlice(allocator: Allocator, slice: []const []const u8) ![]const []const u8 {
    var result = try allocator.alloc([]const u8, slice.len);
    for (slice, 0..) |s, i| {
        result[i] = try allocator.dupe(u8, s);
    }
    return result;
}

/// System library detection configuration.
pub const DetectConfig = struct {
    /// Additional include search paths.
    extra_include_paths: []const []const u8 = &.{},

    /// Additional library search paths.
    extra_lib_paths: []const []const u8 = &.{},

    /// Minimum version requirement.
    min_version: ?[]const u8 = null,

    /// Whether to use pkg-config.
    use_pkg_config: bool = true,

    /// Whether to search common paths.
    search_common_paths: bool = true,

    /// Prefer static libraries.
    prefer_static: bool = false,
};

/// System library detector.
pub const SystemSource = struct {
    allocator: Allocator,
    pkg_config_path: ?[]const u8 = null,

    /// Common include search paths.
    const common_include_paths = [_][]const u8{
        "/usr/include",
        "/usr/local/include",
        "/opt/local/include",
        "/opt/homebrew/include",
    };

    /// Common library search paths.
    const common_lib_paths = [_][]const u8{
        "/usr/lib",
        "/usr/lib64",
        "/usr/local/lib",
        "/usr/local/lib64",
        "/opt/local/lib",
        "/opt/homebrew/lib",
    };

    pub fn init(allocator: Allocator) SystemSource {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SystemSource) void {
        if (self.pkg_config_path) |p| self.allocator.free(p);
    }

    /// Detect a system library.
    pub fn detect(self: *SystemSource, name: []const u8, config: DetectConfig) SystemError!LibraryInfo {
        // Try pkg-config first
        if (config.use_pkg_config) {
            if (self.detectPkgConfig(name, config)) |info| {
                return info;
            } else |_| {}
        }

        // Try manual search
        if (config.search_common_paths) {
            if (self.detectManual(name, config)) |info| {
                return info;
            } else |_| {}
        }

        // Check for environment variables
        if (self.detectEnvironment(name)) |info| {
            return info;
        } else |_| {}

        return error.LibraryNotFound;
    }

    /// Detect using pkg-config.
    fn detectPkgConfig(self: *SystemSource, name: []const u8, config: DetectConfig) SystemError!LibraryInfo {
        // Check if pkg-config is available
        const pkg_config = try self.findPkgConfig();

        // Check if package exists
        var exists_child = std.process.Child.init(&.{
            pkg_config, "--exists", name,
        }, self.allocator);
        exists_child.spawn() catch return error.PkgConfigFailed;
        const exists_result = exists_child.wait() catch return error.PkgConfigFailed;
        if (exists_result.Exited != 0) return error.LibraryNotFound;

        // Check version if required
        if (config.min_version) |min_ver| {
            var version_child = std.process.Child.init(&.{
                pkg_config, "--atleast-version", min_ver, name,
            }, self.allocator);
            version_child.spawn() catch return error.PkgConfigFailed;
            const version_result = version_child.wait() catch return error.PkgConfigFailed;
            if (version_result.Exited != 0) return error.LibraryNotFound;
        }

        // Get version
        const version = self.runPkgConfig(&.{ pkg_config, "--modversion", name }) catch null;
        errdefer if (version) |v| self.allocator.free(v);

        // Get cflags
        const cflags_output = try self.runPkgConfig(&.{ pkg_config, "--cflags", name });
        defer self.allocator.free(cflags_output);

        // Get libs
        const static_flag: []const u8 = if (config.prefer_static) "--static" else "";
        const libs_args = if (config.prefer_static)
            &[_][]const u8{ pkg_config, "--libs", static_flag, name }
        else
            &[_][]const u8{ pkg_config, "--libs", name };
        const libs_output = try self.runPkgConfig(libs_args);
        defer self.allocator.free(libs_output);

        // Parse flags
        var include_dirs = std.ArrayList([]const u8).init(self.allocator);
        var lib_dirs = std.ArrayList([]const u8).init(self.allocator);
        var libraries = std.ArrayList([]const u8).init(self.allocator);
        var defines = std.ArrayList([]const u8).init(self.allocator);
        var cflags = std.ArrayList([]const u8).init(self.allocator);
        var ldflags = std.ArrayList([]const u8).init(self.allocator);

        errdefer {
            for (include_dirs.items) |d| self.allocator.free(d);
            include_dirs.deinit();
            for (lib_dirs.items) |d| self.allocator.free(d);
            lib_dirs.deinit();
            for (libraries.items) |l| self.allocator.free(l);
            libraries.deinit();
            for (defines.items) |d| self.allocator.free(d);
            defines.deinit();
            for (cflags.items) |f| self.allocator.free(f);
            cflags.deinit();
            for (ldflags.items) |f| self.allocator.free(f);
            ldflags.deinit();
        }

        // Parse cflags
        var cflags_iter = std.mem.splitScalar(u8, cflags_output, ' ');
        while (cflags_iter.next()) |flag| {
            const trimmed = std.mem.trim(u8, flag, " \t\n\r");
            if (trimmed.len == 0) continue;

            if (std.mem.startsWith(u8, trimmed, "-I")) {
                const path = self.allocator.dupe(u8, trimmed[2..]) catch return error.OutOfMemory;
                include_dirs.append(path) catch return error.OutOfMemory;
            } else if (std.mem.startsWith(u8, trimmed, "-D")) {
                const define = self.allocator.dupe(u8, trimmed[2..]) catch return error.OutOfMemory;
                defines.append(define) catch return error.OutOfMemory;
            } else {
                const cflag = self.allocator.dupe(u8, trimmed) catch return error.OutOfMemory;
                cflags.append(cflag) catch return error.OutOfMemory;
            }
        }

        // Parse libs
        var libs_iter = std.mem.splitScalar(u8, libs_output, ' ');
        while (libs_iter.next()) |flag| {
            const trimmed = std.mem.trim(u8, flag, " \t\n\r");
            if (trimmed.len == 0) continue;

            if (std.mem.startsWith(u8, trimmed, "-L")) {
                const path = self.allocator.dupe(u8, trimmed[2..]) catch return error.OutOfMemory;
                lib_dirs.append(path) catch return error.OutOfMemory;
            } else if (std.mem.startsWith(u8, trimmed, "-l")) {
                const lib = self.allocator.dupe(u8, trimmed[2..]) catch return error.OutOfMemory;
                libraries.append(lib) catch return error.OutOfMemory;
            } else {
                const ldflag = self.allocator.dupe(u8, trimmed) catch return error.OutOfMemory;
                ldflags.append(ldflag) catch return error.OutOfMemory;
            }
        }

        return LibraryInfo{
            .name = self.allocator.dupe(u8, name) catch return error.OutOfMemory,
            .version = version,
            .include_dirs = include_dirs.toOwnedSlice() catch return error.OutOfMemory,
            .lib_dirs = lib_dirs.toOwnedSlice() catch return error.OutOfMemory,
            .libraries = libraries.toOwnedSlice() catch return error.OutOfMemory,
            .defines = defines.toOwnedSlice() catch return error.OutOfMemory,
            .cflags = cflags.toOwnedSlice() catch return error.OutOfMemory,
            .ldflags = ldflags.toOwnedSlice() catch return error.OutOfMemory,
            .source = .pkg_config,
        };
    }

    fn findPkgConfig(self: *SystemSource) SystemError![]const u8 {
        if (self.pkg_config_path) |p| return p;

        // Check PKG_CONFIG environment variable
        if (compat.getenv("PKG_CONFIG")) |path| {
            self.pkg_config_path = self.allocator.dupe(u8, path) catch return error.OutOfMemory;
            return self.pkg_config_path.?;
        }

        // Try common names
        const names = [_][]const u8{ "pkg-config", "pkgconf" };
        for (names) |name| {
            var child = std.process.Child.init(&.{ "which", name }, self.allocator);
            child.stdout_behavior = .Pipe;
            child.spawn() catch continue;
            const stdout = child.stdout orelse continue;
            const output = stdout.reader().readAllAlloc(self.allocator, 1024) catch continue;
            defer self.allocator.free(output);
            const result = child.wait() catch continue;
            if (result.Exited == 0) {
                self.pkg_config_path = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
                return self.pkg_config_path.?;
            }
        }

        return error.PkgConfigNotFound;
    }

    fn runPkgConfig(self: *SystemSource, args: []const []const u8) SystemError![]const u8 {
        var child = std.process.Child.init(args, self.allocator);
        child.stdout_behavior = .Pipe;

        child.spawn() catch return error.PkgConfigFailed;
        const stdout = child.stdout orelse return error.PkgConfigFailed;
        const output = stdout.reader().readAllAlloc(self.allocator, 1024 * 1024) catch
            return error.PkgConfigFailed;
        errdefer self.allocator.free(output);

        const result = child.wait() catch return error.PkgConfigFailed;
        if (result.Exited != 0) {
            self.allocator.free(output);
            return error.PkgConfigFailed;
        }

        const trimmed = std.mem.trim(u8, output, " \t\n\r");
        if (trimmed.len != output.len) {
            const trimmed_copy = self.allocator.dupe(u8, trimmed) catch return error.OutOfMemory;
            self.allocator.free(output);
            return trimmed_copy;
        }

        return output;
    }

    /// Detect by searching common paths.
    fn detectManual(self: *SystemSource, name: []const u8, config: DetectConfig) SystemError!LibraryInfo {
        var found_include: ?[]const u8 = null;
        var found_lib: ?[]const u8 = null;
        var found_library: ?[]const u8 = null;

        // Search for header
        const header_names = [_][]const u8{
            std.fmt.allocPrint(self.allocator, "{s}.h", .{name}) catch return error.OutOfMemory,
            std.fmt.allocPrint(self.allocator, "{s}/{s}.h", .{ name, name }) catch return error.OutOfMemory,
        };
        defer for (header_names) |h| self.allocator.free(h);

        const all_include_paths = blk: {
            var paths = std.ArrayList([]const u8).init(self.allocator);
            paths.appendSlice(config.extra_include_paths) catch return error.OutOfMemory;
            paths.appendSlice(&common_include_paths) catch return error.OutOfMemory;
            break :blk paths.items;
        };

        for (all_include_paths) |include_path| {
            for (header_names) |header| {
                const full_path = std.fs.path.join(self.allocator, &.{ include_path, header }) catch continue;
                defer self.allocator.free(full_path);

                fs.cwd().access(full_path, .{}) catch continue;
                found_include = self.allocator.dupe(u8, include_path) catch return error.OutOfMemory;
                break;
            }
            if (found_include != null) break;
        }

        // Search for library
        const lib_prefix = if (config.prefer_static) "lib" else "lib";
        const lib_suffix = if (config.prefer_static)
            ".a"
        else switch (@import("builtin").os.tag) {
            .macos => ".dylib",
            .windows => ".dll",
            else => ".so",
        };

        const lib_name = std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{
            lib_prefix,
            name,
            lib_suffix,
        }) catch return error.OutOfMemory;
        defer self.allocator.free(lib_name);

        const all_lib_paths = blk: {
            var paths = std.ArrayList([]const u8).init(self.allocator);
            paths.appendSlice(config.extra_lib_paths) catch return error.OutOfMemory;
            paths.appendSlice(&common_lib_paths) catch return error.OutOfMemory;
            break :blk paths.items;
        };

        for (all_lib_paths) |lib_path| {
            const full_path = std.fs.path.join(self.allocator, &.{ lib_path, lib_name }) catch continue;
            defer self.allocator.free(full_path);

            fs.cwd().access(full_path, .{}) catch continue;
            found_lib = self.allocator.dupe(u8, lib_path) catch return error.OutOfMemory;
            found_library = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
            break;
        }

        if (found_include == null and found_lib == null) {
            return error.LibraryNotFound;
        }

        var include_dirs = std.ArrayList([]const u8).init(self.allocator);
        var lib_dirs = std.ArrayList([]const u8).init(self.allocator);
        var libraries = std.ArrayList([]const u8).init(self.allocator);

        if (found_include) |inc| {
            include_dirs.append(inc) catch return error.OutOfMemory;
        }
        if (found_lib) |lib| {
            lib_dirs.append(lib) catch return error.OutOfMemory;
        }
        if (found_library) |lib| {
            libraries.append(lib) catch return error.OutOfMemory;
        }

        return LibraryInfo{
            .name = self.allocator.dupe(u8, name) catch return error.OutOfMemory,
            .version = null,
            .include_dirs = include_dirs.toOwnedSlice() catch return error.OutOfMemory,
            .lib_dirs = lib_dirs.toOwnedSlice() catch return error.OutOfMemory,
            .libraries = libraries.toOwnedSlice() catch return error.OutOfMemory,
            .defines = &.{},
            .cflags = &.{},
            .ldflags = &.{},
            .source = .manual_search,
        };
    }

    /// Detect from environment variables.
    fn detectEnvironment(self: *SystemSource, name: []const u8) SystemError!LibraryInfo {
        // Check for <NAME>_INCLUDE_DIR, <NAME>_LIB_DIR environment variables
        var upper_name = self.allocator.alloc(u8, name.len) catch return error.OutOfMemory;
        defer self.allocator.free(upper_name);
        for (name, 0..) |c, i| {
            upper_name[i] = std.ascii.toUpper(c);
        }

        const include_var = std.fmt.allocPrintZ(self.allocator, "{s}_INCLUDE_DIR", .{upper_name}) catch
            return error.OutOfMemory;
        defer self.allocator.free(include_var);

        const lib_var = std.fmt.allocPrintZ(self.allocator, "{s}_LIB_DIR", .{upper_name}) catch
            return error.OutOfMemory;
        defer self.allocator.free(lib_var);

        const include_dir = compat.getenv(include_var);
        const lib_dir = compat.getenv(lib_var);

        if (include_dir == null and lib_dir == null) {
            return error.LibraryNotFound;
        }

        var include_dirs = std.ArrayList([]const u8).init(self.allocator);
        var lib_dirs = std.ArrayList([]const u8).init(self.allocator);

        if (include_dir) |d| {
            const dir = self.allocator.dupe(u8, d) catch return error.OutOfMemory;
            include_dirs.append(dir) catch return error.OutOfMemory;
        }

        if (lib_dir) |d| {
            const dir = self.allocator.dupe(u8, d) catch return error.OutOfMemory;
            lib_dirs.append(dir) catch return error.OutOfMemory;
        }

        var libraries = std.ArrayList([]const u8).init(self.allocator);
        const lib = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
        libraries.append(lib) catch return error.OutOfMemory;

        return LibraryInfo{
            .name = self.allocator.dupe(u8, name) catch return error.OutOfMemory,
            .version = null,
            .include_dirs = include_dirs.toOwnedSlice() catch return error.OutOfMemory,
            .lib_dirs = lib_dirs.toOwnedSlice() catch return error.OutOfMemory,
            .libraries = libraries.toOwnedSlice() catch return error.OutOfMemory,
            .defines = &.{},
            .cflags = &.{},
            .ldflags = &.{},
            .source = .environment,
        };
    }

    /// Check if a library is available.
    pub fn isAvailable(self: *SystemSource, name: []const u8) bool {
        _ = self.detect(name, .{}) catch return false;
        return true;
    }

    /// List all available packages via pkg-config.
    pub fn listAvailable(self: *SystemSource) SystemError![][]const u8 {
        const pkg_config = try self.findPkgConfig();

        var child = std.process.Child.init(&.{
            pkg_config, "--list-all",
        }, self.allocator);
        child.stdout_behavior = .Pipe;

        child.spawn() catch return error.PkgConfigFailed;
        const stdout = child.stdout orelse return error.PkgConfigFailed;
        const output = stdout.reader().readAllAlloc(self.allocator, 10 * 1024 * 1024) catch
            return error.PkgConfigFailed;
        defer self.allocator.free(output);

        _ = child.wait() catch return error.PkgConfigFailed;

        var packages = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (packages.items) |p| self.allocator.free(p);
            packages.deinit();
        }

        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            // Format: name description
            var parts = std.mem.splitScalar(u8, trimmed, ' ');
            if (parts.next()) |name| {
                const pkg = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
                packages.append(pkg) catch return error.OutOfMemory;
            }
        }

        return packages.toOwnedSlice() catch return error.OutOfMemory;
    }
};

// Tests
test "system source init" {
    const allocator = std.testing.allocator;
    var source = SystemSource.init(allocator);
    defer source.deinit();
}

test "library info clone" {
    const allocator = std.testing.allocator;

    var info = LibraryInfo{
        .name = try allocator.dupe(u8, "test"),
        .version = try allocator.dupe(u8, "1.0.0"),
        .include_dirs = &.{},
        .lib_dirs = &.{},
        .libraries = &.{},
        .defines = &.{},
        .cflags = &.{},
        .ldflags = &.{},
        .source = .pkg_config,
    };
    defer info.deinit(allocator);

    var cloned = try info.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expectEqualStrings("test", cloned.name);
    try std.testing.expectEqualStrings("1.0.0", cloned.version.?);
}
