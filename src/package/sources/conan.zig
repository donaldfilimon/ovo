//! Conan integration.
//!
//! Provides integration with Conan C/C++ package manager,
//! allowing ovo projects to use packages from Conan repositories.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const json = std.json;

/// Conan-specific errors.
pub const ConanError = error{
    ConanNotFound,
    InstallFailed,
    PackageNotFound,
    ProfileNotFound,
    InvalidReference,
    BuildInfoParseError,
    OutOfMemory,
    CommandFailed,
    NetworkError,
};

/// Conan package reference.
pub const PackageReference = struct {
    name: []const u8,
    version: []const u8,
    user: ?[]const u8 = null,
    channel: ?[]const u8 = null,

    pub fn parse(allocator: Allocator, reference: []const u8) !PackageReference {
        // Format: name/version[@user/channel]
        var at_split = std.mem.splitScalar(u8, reference, '@');
        const name_version = at_split.next() orelse return error.InvalidReference;
        const user_channel = at_split.next();

        var slash_split = std.mem.splitScalar(u8, name_version, '/');
        const name = slash_split.next() orelse return error.InvalidReference;
        const version = slash_split.next() orelse return error.InvalidReference;

        var user: ?[]const u8 = null;
        var channel: ?[]const u8 = null;

        if (user_channel) |uc| {
            var uc_split = std.mem.splitScalar(u8, uc, '/');
            if (uc_split.next()) |u| user = try allocator.dupe(u8, u);
            if (uc_split.next()) |c| channel = try allocator.dupe(u8, c);
        }

        return .{
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, version),
            .user = user,
            .channel = channel,
        };
    }

    pub fn toString(self: PackageReference, allocator: Allocator) ![]const u8 {
        if (self.user) |user| {
            if (self.channel) |channel| {
                return std.fmt.allocPrint(allocator, "{s}/{s}@{s}/{s}", .{
                    self.name,
                    self.version,
                    user,
                    channel,
                });
            }
            return std.fmt.allocPrint(allocator, "{s}/{s}@{s}", .{
                self.name,
                self.version,
                user,
            });
        }
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.name, self.version });
    }

    pub fn deinit(self: *PackageReference, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        if (self.user) |u| allocator.free(u);
        if (self.channel) |c| allocator.free(c);
    }
};

/// Conan build settings.
pub const Settings = struct {
    os: ?[]const u8 = null,
    arch: ?[]const u8 = null,
    compiler: ?[]const u8 = null,
    compiler_version: ?[]const u8 = null,
    build_type: BuildType = .Release,

    pub const BuildType = enum {
        Debug,
        Release,
        RelWithDebInfo,
        MinSizeRel,

        pub fn toString(self: BuildType) []const u8 {
            return switch (self) {
                .Debug => "Debug",
                .Release => "Release",
                .RelWithDebInfo => "RelWithDebInfo",
                .MinSizeRel => "MinSizeRel",
            };
        }
    };

    pub fn detect() Settings {
        return .{
            .os = switch (@import("builtin").os.tag) {
                .linux => "Linux",
                .macos => "Macos",
                .windows => "Windows",
                else => null,
            },
            .arch = switch (@import("builtin").cpu.arch) {
                .x86_64 => "x86_64",
                .x86 => "x86",
                .aarch64 => "armv8",
                .arm => "armv7",
                else => null,
            },
        };
    }
};

/// Build information from Conan.
pub const BuildInfo = struct {
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

    /// C++ compiler flags.
    cxxflags: []const []const u8,

    /// Linker flags.
    ldflags: []const []const u8,

    /// Binary directories.
    bin_dirs: []const []const u8,

    pub fn deinit(self: *BuildInfo, allocator: Allocator) void {
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
        for (self.cxxflags) |f| allocator.free(f);
        allocator.free(self.cxxflags);
        for (self.ldflags) |f| allocator.free(f);
        allocator.free(self.ldflags);
        for (self.bin_dirs) |d| allocator.free(d);
        allocator.free(self.bin_dirs);
    }
};

/// Conan source handler.
pub const ConanSource = struct {
    allocator: Allocator,
    conan_path: ?[]const u8 = null,
    default_profile: ?[]const u8 = null,

    pub fn init(allocator: Allocator) ConanSource {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConanSource) void {
        if (self.conan_path) |p| self.allocator.free(p);
        if (self.default_profile) |p| self.allocator.free(p);
    }

    /// Find Conan installation.
    pub fn findConan(self: *ConanSource) ConanError![]const u8 {
        if (self.conan_path) |p| return p;

        // Try common locations
        const paths = [_][]const u8{
            "conan",
            "/usr/local/bin/conan",
            "/usr/bin/conan",
        };

        for (paths) |path| {
            if (self.verifyConan(path)) {
                self.conan_path = self.allocator.dupe(u8, path) catch return error.OutOfMemory;
                return self.conan_path.?;
            }
        }

        // Try to find in PATH
        var child = std.process.Child.init(&.{ "which", "conan" }, self.allocator);
        child.stdout_behavior = .Pipe;

        child.spawn() catch return error.ConanNotFound;
        const stdout = child.stdout orelse return error.ConanNotFound;
        const output = stdout.reader().readAllAlloc(self.allocator, 1024) catch return error.ConanNotFound;
        defer self.allocator.free(output);

        const result = child.wait() catch return error.ConanNotFound;
        if (result.Exited != 0) return error.ConanNotFound;

        const trimmed = std.mem.trim(u8, output, " \t\n\r");
        self.conan_path = self.allocator.dupe(u8, trimmed) catch return error.OutOfMemory;
        return self.conan_path.?;
    }

    fn verifyConan(self: *ConanSource, path: []const u8) bool {
        var child = std.process.Child.init(&.{ path, "--version" }, self.allocator);
        child.spawn() catch return false;
        const result = child.wait() catch return false;
        return result.Exited == 0;
    }

    /// Install a Conan package.
    pub fn install(
        self: *ConanSource,
        reference: PackageReference,
        options: InstallOptions,
    ) ConanError!void {
        const conan = try self.findConan();

        const ref_str = reference.toString(self.allocator) catch return error.OutOfMemory;
        defer self.allocator.free(ref_str);

        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        args.appendSlice(&.{ conan, "install", ref_str }) catch return error.OutOfMemory;

        // Add settings
        if (options.settings.os) |os| {
            args.appendSlice(&.{ "-s", "os=" }) catch return error.OutOfMemory;
            const setting = std.fmt.allocPrint(self.allocator, "os={s}", .{os}) catch return error.OutOfMemory;
            defer self.allocator.free(setting);
            _ = args.pop();
            args.append(setting) catch return error.OutOfMemory;
        }

        // Add build type
        const build_type = std.fmt.allocPrint(
            self.allocator,
            "build_type={s}",
            .{options.settings.build_type.toString()},
        ) catch return error.OutOfMemory;
        defer self.allocator.free(build_type);
        args.appendSlice(&.{ "-s", build_type }) catch return error.OutOfMemory;

        // Add profile
        if (options.profile) |profile| {
            args.appendSlice(&.{ "-pr", profile }) catch return error.OutOfMemory;
        }

        // Add output directory
        if (options.output_dir) |dir| {
            args.appendSlice(&.{ "-of", dir }) catch return error.OutOfMemory;
        }

        // Add options
        for (options.options) |opt| {
            args.appendSlice(&.{ "-o", opt }) catch return error.OutOfMemory;
        }

        // Build missing
        if (options.build_missing) {
            args.append("--build=missing") catch return error.OutOfMemory;
        }

        var child = std.process.Child.init(args.items, self.allocator);
        child.spawn() catch return error.InstallFailed;
        const result = child.wait() catch return error.InstallFailed;

        if (result.Exited != 0) {
            return error.InstallFailed;
        }
    }

    pub const InstallOptions = struct {
        settings: Settings = Settings.detect(),
        profile: ?[]const u8 = null,
        output_dir: ?[]const u8 = null,
        options: []const []const u8 = &.{},
        build_missing: bool = true,
    };

    /// Get build information for an installed package.
    pub fn getBuildInfo(self: *ConanSource, output_dir: []const u8) ConanError!BuildInfo {
        // Parse conanbuildinfo.json
        const info_path = std.fs.path.join(self.allocator, &.{ output_dir, "conanbuildinfo.json" }) catch
            return error.OutOfMemory;
        defer self.allocator.free(info_path);

        const file = fs.cwd().openFile(info_path, .{}) catch {
            // Try CMake format
            return self.getBuildInfoCMake(output_dir);
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch
            return error.BuildInfoParseError;
        defer self.allocator.free(content);

        return self.parseBuildInfoJson(content);
    }

    fn parseBuildInfoJson(self: *ConanSource, content: []const u8) ConanError!BuildInfo {
        const parsed = json.parseFromSlice(json.Value, self.allocator, content, .{}) catch
            return error.BuildInfoParseError;
        defer parsed.deinit();

        const root = parsed.value.object;

        var include_dirs = std.ArrayList([]const u8).init(self.allocator);
        var lib_dirs = std.ArrayList([]const u8).init(self.allocator);
        var libraries = std.ArrayList([]const u8).init(self.allocator);
        var defines = std.ArrayList([]const u8).init(self.allocator);
        var bin_dirs = std.ArrayList([]const u8).init(self.allocator);

        errdefer {
            for (include_dirs.items) |d| self.allocator.free(d);
            include_dirs.deinit();
            for (lib_dirs.items) |d| self.allocator.free(d);
            lib_dirs.deinit();
            for (libraries.items) |l| self.allocator.free(l);
            libraries.deinit();
            for (defines.items) |d| self.allocator.free(d);
            defines.deinit();
            for (bin_dirs.items) |d| self.allocator.free(d);
            bin_dirs.deinit();
        }

        // Parse dependencies
        if (root.get("dependencies")) |deps| {
            for (deps.array.items) |dep| {
                const obj = dep.object;

                if (obj.get("include_paths")) |paths| {
                    for (paths.array.items) |p| {
                        const path = self.allocator.dupe(u8, p.string) catch return error.OutOfMemory;
                        include_dirs.append(path) catch return error.OutOfMemory;
                    }
                }

                if (obj.get("lib_paths")) |paths| {
                    for (paths.array.items) |p| {
                        const path = self.allocator.dupe(u8, p.string) catch return error.OutOfMemory;
                        lib_dirs.append(path) catch return error.OutOfMemory;
                    }
                }

                if (obj.get("libs")) |libs| {
                    for (libs.array.items) |l| {
                        const lib = self.allocator.dupe(u8, l.string) catch return error.OutOfMemory;
                        libraries.append(lib) catch return error.OutOfMemory;
                    }
                }

                if (obj.get("defines")) |defs| {
                    for (defs.array.items) |d| {
                        const define = self.allocator.dupe(u8, d.string) catch return error.OutOfMemory;
                        defines.append(define) catch return error.OutOfMemory;
                    }
                }

                if (obj.get("bin_paths")) |paths| {
                    for (paths.array.items) |p| {
                        const path = self.allocator.dupe(u8, p.string) catch return error.OutOfMemory;
                        bin_dirs.append(path) catch return error.OutOfMemory;
                    }
                }
            }
        }

        return BuildInfo{
            .include_dirs = include_dirs.toOwnedSlice() catch return error.OutOfMemory,
            .lib_dirs = lib_dirs.toOwnedSlice() catch return error.OutOfMemory,
            .libraries = libraries.toOwnedSlice() catch return error.OutOfMemory,
            .defines = defines.toOwnedSlice() catch return error.OutOfMemory,
            .cflags = &.{},
            .cxxflags = &.{},
            .ldflags = &.{},
            .bin_dirs = bin_dirs.toOwnedSlice() catch return error.OutOfMemory,
        };
    }

    fn getBuildInfoCMake(self: *ConanSource, output_dir: []const u8) ConanError!BuildInfo {
        // Parse conan_toolchain.cmake or conanbuildinfo.cmake
        const cmake_path = std.fs.path.join(self.allocator, &.{ output_dir, "conan_toolchain.cmake" }) catch
            return error.OutOfMemory;
        defer self.allocator.free(cmake_path);

        const file = fs.cwd().openFile(cmake_path, .{}) catch return error.BuildInfoParseError;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch
            return error.BuildInfoParseError;
        defer self.allocator.free(content);

        // Parse CMake variables
        var include_dirs = std.ArrayList([]const u8).init(self.allocator);
        var lib_dirs = std.ArrayList([]const u8).init(self.allocator);
        var libraries = std.ArrayList([]const u8).init(self.allocator);

        // Basic parsing - real implementation would be more robust
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "CONAN_INCLUDE_DIRS")) |_| {
                // Extract paths from set() command
                if (std.mem.indexOf(u8, line, "\"")) |start| {
                    if (std.mem.lastIndexOf(u8, line, "\"")) |end| {
                        if (end > start) {
                            const path = self.allocator.dupe(u8, line[start + 1 .. end]) catch return error.OutOfMemory;
                            include_dirs.append(path) catch return error.OutOfMemory;
                        }
                    }
                }
            }
        }

        return BuildInfo{
            .include_dirs = include_dirs.toOwnedSlice() catch return error.OutOfMemory,
            .lib_dirs = lib_dirs.toOwnedSlice() catch return error.OutOfMemory,
            .libraries = libraries.toOwnedSlice() catch return error.OutOfMemory,
            .defines = &.{},
            .cflags = &.{},
            .cxxflags = &.{},
            .ldflags = &.{},
            .bin_dirs = &.{},
        };
    }

    /// Search for packages in Conan repositories.
    pub fn search(self: *ConanSource, pattern: []const u8) ConanError![]SearchResult {
        const conan = try self.findConan();

        var child = std.process.Child.init(&.{
            conan, "search", pattern, "-r", "conancenter",
        }, self.allocator);
        child.stdout_behavior = .Pipe;

        child.spawn() catch return error.CommandFailed;
        const stdout = child.stdout orelse return error.CommandFailed;
        const output = stdout.reader().readAllAlloc(self.allocator, 10 * 1024 * 1024) catch
            return error.CommandFailed;
        defer self.allocator.free(output);

        _ = child.wait() catch return error.CommandFailed;

        return self.parseSearchResults(output);
    }

    pub const SearchResult = struct {
        reference: []const u8,
        remote: []const u8,

        pub fn deinit(self_result: *SearchResult, allocator: Allocator) void {
            allocator.free(self_result.reference);
            allocator.free(self_result.remote);
        }
    };

    fn parseSearchResults(self: *ConanSource, output: []const u8) ConanError![]SearchResult {
        var results = std.ArrayList(SearchResult).init(self.allocator);
        errdefer {
            for (results.items) |*r| r.deinit(self.allocator);
            results.deinit();
        }

        var lines = std.mem.splitScalar(u8, output, '\n');
        var current_remote: ?[]const u8 = null;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            if (std.mem.startsWith(u8, trimmed, "Remote")) {
                // Extract remote name
                if (std.mem.indexOf(u8, trimmed, "'")) |start| {
                    if (std.mem.lastIndexOf(u8, trimmed, "'")) |end| {
                        if (end > start) {
                            if (current_remote) |r| self.allocator.free(r);
                            current_remote = self.allocator.dupe(u8, trimmed[start + 1 .. end]) catch return error.OutOfMemory;
                        }
                    }
                }
            } else if (std.mem.indexOf(u8, trimmed, "/") != null and !std.mem.startsWith(u8, trimmed, " ")) {
                // This looks like a package reference
                results.append(.{
                    .reference = self.allocator.dupe(u8, trimmed) catch return error.OutOfMemory,
                    .remote = if (current_remote) |r| self.allocator.dupe(u8, r) catch return error.OutOfMemory else self.allocator.dupe(u8, "unknown") catch return error.OutOfMemory,
                }) catch return error.OutOfMemory;
            }
        }

        if (current_remote) |r| self.allocator.free(r);

        return results.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// List profiles.
    pub fn listProfiles(self: *ConanSource) ConanError![][]const u8 {
        const conan = try self.findConan();

        var child = std.process.Child.init(&.{
            conan, "profile", "list",
        }, self.allocator);
        child.stdout_behavior = .Pipe;

        child.spawn() catch return error.CommandFailed;
        const stdout = child.stdout orelse return error.CommandFailed;
        const output = stdout.reader().readAllAlloc(self.allocator, 1024 * 1024) catch
            return error.CommandFailed;
        defer self.allocator.free(output);

        _ = child.wait() catch return error.CommandFailed;

        var profiles = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (profiles.items) |p| self.allocator.free(p);
            profiles.deinit();
        }

        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (std.mem.startsWith(u8, trimmed, "Profiles")) continue;

            const profile = self.allocator.dupe(u8, trimmed) catch return error.OutOfMemory;
            profiles.append(profile) catch return error.OutOfMemory;
        }

        return profiles.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// Create a profile.
    pub fn createProfile(self: *ConanSource, name: []const u8) ConanError!void {
        const conan = try self.findConan();

        var child = std.process.Child.init(&.{
            conan, "profile", "new", name, "--detect",
        }, self.allocator);

        child.spawn() catch return error.CommandFailed;
        const result = child.wait() catch return error.CommandFailed;

        if (result.Exited != 0) {
            return error.CommandFailed;
        }
    }
};

// Tests
test "package reference parse" {
    const allocator = std.testing.allocator;

    var ref = try PackageReference.parse(allocator, "openssl/3.0.0@_/_");
    defer ref.deinit(allocator);

    try std.testing.expectEqualStrings("openssl", ref.name);
    try std.testing.expectEqualStrings("3.0.0", ref.version);
    try std.testing.expectEqualStrings("_", ref.user.?);
    try std.testing.expectEqualStrings("_", ref.channel.?);
}

test "package reference to string" {
    const allocator = std.testing.allocator;

    const ref = PackageReference{
        .name = "zlib",
        .version = "1.2.13",
        .user = null,
        .channel = null,
    };

    const str = try ref.toString(allocator);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("zlib/1.2.13", str);
}

test "settings detect" {
    const settings = Settings.detect();
    // Just verify it doesn't crash
    _ = settings.os;
    _ = settings.arch;
}

test "conan source init" {
    const allocator = std.testing.allocator;
    var source = ConanSource.init(allocator);
    defer source.deinit();
}
