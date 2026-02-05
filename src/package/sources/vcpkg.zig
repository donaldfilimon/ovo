//! vcpkg integration.
//!
//! Provides integration with Microsoft's vcpkg C/C++ package manager,
//! allowing ovo projects to seamlessly use vcpkg packages.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const json = std.json;

/// vcpkg-specific errors.
pub const VcpkgError = error{
    VcpkgNotFound,
    BootstrapFailed,
    InstallFailed,
    PackageNotFound,
    InvalidTriplet,
    ManifestParseError,
    OutOfMemory,
    CommandFailed,
};

/// vcpkg triplet (target specification).
pub const Triplet = struct {
    arch: Arch,
    os: Os,
    linkage: Linkage = .dynamic,

    pub const Arch = enum {
        x64,
        x86,
        arm64,
        arm,

        pub fn toString(self: Arch) []const u8 {
            return switch (self) {
                .x64 => "x64",
                .x86 => "x86",
                .arm64 => "arm64",
                .arm => "arm",
            };
        }
    };

    pub const Os = enum {
        windows,
        linux,
        osx,

        pub fn toString(self: Os) []const u8 {
            return switch (self) {
                .windows => "windows",
                .linux => "linux",
                .osx => "osx",
            };
        }
    };

    pub const Linkage = enum {
        dynamic,
        static,

        pub fn toString(self: Linkage) []const u8 {
            return switch (self) {
                .dynamic => "",
                .static => "-static",
            };
        }
    };

    pub fn toString(self: Triplet, allocator: Allocator) ![]const u8 {
        if (self.linkage == .static) {
            return std.fmt.allocPrint(allocator, "{s}-{s}-static", .{
                self.arch.toString(),
                self.os.toString(),
            });
        }
        return std.fmt.allocPrint(allocator, "{s}-{s}", .{
            self.arch.toString(),
            self.os.toString(),
        });
    }

    pub fn detect() Triplet {
        const arch: Arch = switch (@import("builtin").cpu.arch) {
            .x86_64 => .x64,
            .x86 => .x86,
            .aarch64 => .arm64,
            .arm => .arm,
            else => .x64,
        };

        const os: Os = switch (@import("builtin").os.tag) {
            .windows => .windows,
            .linux => .linux,
            .macos => .osx,
            else => .linux,
        };

        return .{ .arch = arch, .os = os };
    }
};

/// vcpkg package specification.
pub const PackageSpec = struct {
    name: []const u8,
    features: []const []const u8 = &.{},
    triplet: ?Triplet = null,

    pub fn toString(self: PackageSpec, allocator: Allocator) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        try result.appendSlice(self.name);

        if (self.features.len > 0) {
            try result.append('[');
            for (self.features, 0..) |feature, i| {
                if (i > 0) try result.append(',');
                try result.appendSlice(feature);
            }
            try result.append(']');
        }

        if (self.triplet) |t| {
            try result.append(':');
            const triplet_str = try t.toString(allocator);
            defer allocator.free(triplet_str);
            try result.appendSlice(triplet_str);
        }

        return result.toOwnedSlice();
    }
};

/// Build information extracted from vcpkg.
pub const BuildInfo = struct {
    /// Include directories.
    include_dirs: []const []const u8,

    /// Library directories.
    lib_dirs: []const []const u8,

    /// Libraries to link.
    libraries: []const []const u8,

    /// Preprocessor defines.
    defines: []const []const u8,

    /// Binary directory (for DLLs).
    bin_dir: ?[]const u8 = null,

    pub fn deinit(self: *BuildInfo, allocator: Allocator) void {
        for (self.include_dirs) |d| allocator.free(d);
        allocator.free(self.include_dirs);
        for (self.lib_dirs) |d| allocator.free(d);
        allocator.free(self.lib_dirs);
        for (self.libraries) |l| allocator.free(l);
        allocator.free(self.libraries);
        for (self.defines) |d| allocator.free(d);
        allocator.free(self.defines);
        if (self.bin_dir) |b| allocator.free(b);
    }
};

/// vcpkg source handler.
pub const VcpkgSource = struct {
    allocator: Allocator,
    vcpkg_root: ?[]const u8 = null,
    default_triplet: Triplet,

    pub fn init(allocator: Allocator) VcpkgSource {
        return .{
            .allocator = allocator,
            .vcpkg_root = null,
            .default_triplet = Triplet.detect(),
        };
    }

    pub fn deinit(self: *VcpkgSource) void {
        if (self.vcpkg_root) |r| self.allocator.free(r);
    }

    /// Find vcpkg installation.
    pub fn findVcpkg(self: *VcpkgSource) VcpkgError![]const u8 {
        if (self.vcpkg_root) |r| return r;

        // Check VCPKG_ROOT environment variable
        if (std.posix.getenv("VCPKG_ROOT")) |root| {
            self.vcpkg_root = self.allocator.dupe(u8, root) catch return error.OutOfMemory;
            return self.vcpkg_root.?;
        }

        // Check common locations
        const home = std.posix.getenv("HOME") orelse std.posix.getenv("USERPROFILE") orelse
            return error.VcpkgNotFound;

        const search_paths = [_][]const u8{
            "/vcpkg",
            "/.vcpkg",
            "/src/vcpkg",
            "/dev/vcpkg",
        };

        for (search_paths) |suffix| {
            const path = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ home, suffix }) catch
                return error.OutOfMemory;
            defer self.allocator.free(path);

            const vcpkg_exe = std.fmt.allocPrint(self.allocator, "{s}/vcpkg", .{path}) catch
                return error.OutOfMemory;
            defer self.allocator.free(vcpkg_exe);

            fs.cwd().access(vcpkg_exe, .{}) catch continue;

            self.vcpkg_root = self.allocator.dupe(u8, path) catch return error.OutOfMemory;
            return self.vcpkg_root.?;
        }

        return error.VcpkgNotFound;
    }

    /// Bootstrap vcpkg if needed.
    pub fn bootstrap(self: *VcpkgSource, install_path: []const u8) VcpkgError!void {
        // Clone vcpkg repository
        var child = std.process.Child.init(&.{
            "git", "clone", "https://github.com/microsoft/vcpkg.git", install_path,
        }, self.allocator);

        child.spawn() catch return error.BootstrapFailed;
        const clone_result = child.wait() catch return error.BootstrapFailed;
        if (clone_result.Exited != 0) return error.BootstrapFailed;

        // Run bootstrap script
        const bootstrap_script = if (@import("builtin").os.tag == .windows)
            "bootstrap-vcpkg.bat"
        else
            "./bootstrap-vcpkg.sh";

        const bootstrap_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{
            install_path,
            bootstrap_script,
        }) catch return error.OutOfMemory;
        defer self.allocator.free(bootstrap_path);

        var bootstrap_child = std.process.Child.init(&.{bootstrap_path}, self.allocator);
        bootstrap_child.cwd = install_path;

        bootstrap_child.spawn() catch return error.BootstrapFailed;
        const bootstrap_result = bootstrap_child.wait() catch return error.BootstrapFailed;
        if (bootstrap_result.Exited != 0) return error.BootstrapFailed;

        self.vcpkg_root = self.allocator.dupe(u8, install_path) catch return error.OutOfMemory;
    }

    /// Install a vcpkg package.
    pub fn install(self: *VcpkgSource, spec: PackageSpec) VcpkgError!void {
        const vcpkg_root = try self.findVcpkg();

        const spec_str = spec.toString(self.allocator) catch return error.OutOfMemory;
        defer self.allocator.free(spec_str);

        const vcpkg_exe = std.fmt.allocPrint(self.allocator, "{s}/vcpkg", .{vcpkg_root}) catch
            return error.OutOfMemory;
        defer self.allocator.free(vcpkg_exe);

        var child = std.process.Child.init(&.{
            vcpkg_exe, "install", spec_str,
        }, self.allocator);

        child.spawn() catch return error.InstallFailed;
        const result = child.wait() catch return error.InstallFailed;

        if (result.Exited != 0) {
            return error.InstallFailed;
        }
    }

    /// Get build information for an installed package.
    pub fn getBuildInfo(self: *VcpkgSource, name: []const u8, triplet: ?Triplet) VcpkgError!BuildInfo {
        const vcpkg_root = try self.findVcpkg();
        const t = triplet orelse self.default_triplet;
        const triplet_str = t.toString(self.allocator) catch return error.OutOfMemory;
        defer self.allocator.free(triplet_str);

        const installed_dir = std.fmt.allocPrint(
            self.allocator,
            "{s}/installed/{s}",
            .{ vcpkg_root, triplet_str },
        ) catch return error.OutOfMemory;
        defer self.allocator.free(installed_dir);

        // Check if package is installed
        const include_dir = std.fmt.allocPrint(
            self.allocator,
            "{s}/include",
            .{installed_dir},
        ) catch return error.OutOfMemory;
        errdefer self.allocator.free(include_dir);

        fs.cwd().access(include_dir, .{}) catch return error.PackageNotFound;

        const lib_dir = std.fmt.allocPrint(
            self.allocator,
            "{s}/lib",
            .{installed_dir},
        ) catch return error.OutOfMemory;
        errdefer self.allocator.free(lib_dir);

        // Find libraries for this package
        const libraries = try self.findPackageLibraries(lib_dir, name);

        var include_dirs = self.allocator.alloc([]const u8, 1) catch return error.OutOfMemory;
        include_dirs[0] = include_dir;

        var lib_dirs = self.allocator.alloc([]const u8, 1) catch return error.OutOfMemory;
        lib_dirs[0] = lib_dir;

        return BuildInfo{
            .include_dirs = include_dirs,
            .lib_dirs = lib_dirs,
            .libraries = libraries,
            .defines = &.{},
            .bin_dir = if (t.os == .windows)
                std.fmt.allocPrint(self.allocator, "{s}/bin", .{installed_dir}) catch null
            else
                null,
        };
    }

    fn findPackageLibraries(self: *VcpkgSource, lib_dir: []const u8, name: []const u8) VcpkgError![]const []const u8 {
        var libraries = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (libraries.items) |l| self.allocator.free(l);
            libraries.deinit();
        }

        var dir = fs.cwd().openDir(lib_dir, .{ .iterate = true }) catch return error.PackageNotFound;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch return error.PackageNotFound) |entry| {
            if (entry.kind != .file) continue;

            const is_lib = std.mem.endsWith(u8, entry.name, ".a") or
                std.mem.endsWith(u8, entry.name, ".lib") or
                std.mem.endsWith(u8, entry.name, ".so") or
                std.mem.endsWith(u8, entry.name, ".dylib");

            if (!is_lib) continue;

            // Check if library name matches package
            if (std.mem.indexOf(u8, entry.name, name) != null) {
                const lib_name = self.allocator.dupe(u8, entry.name) catch return error.OutOfMemory;
                libraries.append(lib_name) catch return error.OutOfMemory;
            }
        }

        // If no specific libraries found, add the package name as a library
        if (libraries.items.len == 0) {
            const lib_name = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
            libraries.append(lib_name) catch return error.OutOfMemory;
        }

        return libraries.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// List installed packages.
    pub fn listInstalled(self: *VcpkgSource, triplet: ?Triplet) VcpkgError![][]const u8 {
        const vcpkg_root = try self.findVcpkg();
        const vcpkg_exe = std.fmt.allocPrint(self.allocator, "{s}/vcpkg", .{vcpkg_root}) catch
            return error.OutOfMemory;
        defer self.allocator.free(vcpkg_exe);

        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        args.append(vcpkg_exe) catch return error.OutOfMemory;
        args.append("list") catch return error.OutOfMemory;

        if (triplet) |t| {
            const triplet_str = t.toString(self.allocator) catch return error.OutOfMemory;
            defer self.allocator.free(triplet_str);
            args.append("--triplet") catch return error.OutOfMemory;
            args.append(triplet_str) catch return error.OutOfMemory;
        }

        var child = std.process.Child.init(args.items, self.allocator);
        child.stdout_behavior = .Pipe;

        child.spawn() catch return error.CommandFailed;
        const stdout = child.stdout orelse return error.CommandFailed;
        const output = stdout.reader().readAllAlloc(self.allocator, 10 * 1024 * 1024) catch
            return error.CommandFailed;
        defer self.allocator.free(output);

        _ = child.wait() catch return error.CommandFailed;

        return self.parsePackageList(output);
    }

    fn parsePackageList(self: *VcpkgSource, output: []const u8) VcpkgError![][]const u8 {
        var packages = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (packages.items) |p| self.allocator.free(p);
            packages.deinit();
        }

        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            // Format: name:triplet version
            var parts = std.mem.splitScalar(u8, trimmed, ':');
            if (parts.next()) |name| {
                const pkg_name = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
                packages.append(pkg_name) catch return error.OutOfMemory;
            }
        }

        return packages.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// Search for packages.
    pub fn search(self: *VcpkgSource, query: []const u8) VcpkgError![]SearchResult {
        const vcpkg_root = try self.findVcpkg();
        const vcpkg_exe = std.fmt.allocPrint(self.allocator, "{s}/vcpkg", .{vcpkg_root}) catch
            return error.OutOfMemory;
        defer self.allocator.free(vcpkg_exe);

        var child = std.process.Child.init(&.{
            vcpkg_exe, "search", query,
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
        name: []const u8,
        version: []const u8,
        description: []const u8,

        pub fn deinit(self_result: *SearchResult, allocator: Allocator) void {
            allocator.free(self_result.name);
            allocator.free(self_result.version);
            allocator.free(self_result.description);
        }
    };

    fn parseSearchResults(self: *VcpkgSource, output: []const u8) VcpkgError![]SearchResult {
        var results = std.ArrayList(SearchResult).init(self.allocator);
        errdefer {
            for (results.items) |*r| r.deinit(self.allocator);
            results.deinit();
        }

        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (std.mem.startsWith(u8, trimmed, "If your library")) continue;
            if (std.mem.startsWith(u8, trimmed, "The result")) continue;

            // Format: name version description
            var parts = std.mem.splitSequence(u8, trimmed, "  ");
            const name = parts.next() orelse continue;
            const version = parts.next() orelse "";
            const description = parts.rest();

            results.append(.{
                .name = self.allocator.dupe(u8, std.mem.trim(u8, name, " ")) catch return error.OutOfMemory,
                .version = self.allocator.dupe(u8, std.mem.trim(u8, version, " ")) catch return error.OutOfMemory,
                .description = self.allocator.dupe(u8, std.mem.trim(u8, description, " ")) catch return error.OutOfMemory,
            }) catch return error.OutOfMemory;
        }

        return results.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// Remove an installed package.
    pub fn remove(self: *VcpkgSource, name: []const u8, triplet: ?Triplet) VcpkgError!void {
        const vcpkg_root = try self.findVcpkg();
        const vcpkg_exe = std.fmt.allocPrint(self.allocator, "{s}/vcpkg", .{vcpkg_root}) catch
            return error.OutOfMemory;
        defer self.allocator.free(vcpkg_exe);

        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        args.append(vcpkg_exe) catch return error.OutOfMemory;
        args.append("remove") catch return error.OutOfMemory;

        if (triplet) |t| {
            const spec = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{
                name,
                t.toString(self.allocator) catch return error.OutOfMemory,
            }) catch return error.OutOfMemory;
            defer self.allocator.free(spec);
            args.append(spec) catch return error.OutOfMemory;
        } else {
            args.append(name) catch return error.OutOfMemory;
        }

        var child = std.process.Child.init(args.items, self.allocator);
        child.spawn() catch return error.CommandFailed;
        const result = child.wait() catch return error.CommandFailed;

        if (result.Exited != 0) {
            return error.CommandFailed;
        }
    }
};

// Tests
test "triplet detection" {
    const triplet = Triplet.detect();
    // Just verify it doesn't crash
    _ = triplet.arch;
    _ = triplet.os;
}

test "triplet to string" {
    const allocator = std.testing.allocator;
    const triplet = Triplet{ .arch = .x64, .os = .linux, .linkage = .dynamic };
    const str = try triplet.toString(allocator);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("x64-linux", str);
}

test "static triplet to string" {
    const allocator = std.testing.allocator;
    const triplet = Triplet{ .arch = .x64, .os = .windows, .linkage = .static };
    const str = try triplet.toString(allocator);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("x64-windows-static", str);
}

test "package spec to string" {
    const allocator = std.testing.allocator;
    const spec = PackageSpec{
        .name = "openssl",
        .features = &.{ "tools", "weak-ssl-ciphers" },
    };
    const str = try spec.toString(allocator);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("openssl[tools,weak-ssl-ciphers]", str);
}

test "vcpkg source init" {
    const allocator = std.testing.allocator;
    var source = VcpkgSource.init(allocator);
    defer source.deinit();
}
