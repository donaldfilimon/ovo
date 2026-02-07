//! Output artifact management for the ovo build system.
//! Handles executables, static/shared libraries, and C++ Binary Module Interfaces (BMIs).
const std = @import("std");

/// Type of artifact being produced.
pub const ArtifactKind = enum {
    executable,
    static_library,
    shared_library,
    object,
    /// C++20 module interface unit (BMI)
    module_interface,
    /// Precompiled header
    precompiled_header,

    pub fn extension(self: ArtifactKind, target_os: std.Target.Os.Tag) []const u8 {
        return switch (self) {
            .executable => switch (target_os) {
                .windows => ".exe",
                else => "",
            },
            .static_library => switch (target_os) {
                .windows => ".lib",
                else => ".a",
            },
            .shared_library => switch (target_os) {
                .windows => ".dll",
                .macos => ".dylib",
                else => ".so",
            },
            .object => switch (target_os) {
                .windows => ".obj",
                else => ".o",
            },
            .module_interface => ".pcm", // Clang BMI format
            .precompiled_header => ".pch",
        };
    }
};

/// Represents a build artifact with its metadata.
pub const Artifact = struct {
    /// Unique identifier for the artifact
    id: u64,
    /// Name of the artifact (without extension)
    name: []const u8,
    /// Kind of artifact
    kind: ArtifactKind,
    /// Output path relative to build directory
    output_path: []const u8,
    /// Hash of the artifact contents (for caching)
    content_hash: ?u64,
    /// Size in bytes
    size: u64,
    /// Timestamp of creation/modification
    timestamp: i64,
    /// Dependencies (other artifact IDs)
    dependencies: []const u64,
    /// Whether this artifact is up-to-date
    is_valid: bool,
    /// Target triple for cross-compilation
    target_triple: ?[]const u8,

    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        id: u64,
        name: []const u8,
        kind: ArtifactKind,
        target_triple: ?[]const u8,
    ) !Artifact {
        return .{
            .id = id,
            .name = try allocator.dupe(u8, name),
            .kind = kind,
            .output_path = &.{},
            .content_hash = null,
            .size = 0,
            .timestamp = 0,
            .dependencies = &.{},
            .is_valid = false,
            .target_triple = if (target_triple) |t| try allocator.dupe(u8, t) else null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Artifact) void {
        self.allocator.free(self.name);
        if (self.output_path.len > 0) {
            self.allocator.free(self.output_path);
        }
        if (self.dependencies.len > 0) {
            self.allocator.free(self.dependencies);
        }
        if (self.target_triple) |t| {
            self.allocator.free(t);
        }
        self.* = undefined;
    }

    pub fn setOutputPath(self: *Artifact, path: []const u8) !void {
        if (self.output_path.len > 0) {
            self.allocator.free(self.output_path);
        }
        self.output_path = try self.allocator.dupe(u8, path);
    }

    pub fn setDependencies(self: *Artifact, deps: []const u64) !void {
        if (self.dependencies.len > 0) {
            self.allocator.free(self.dependencies);
        }
        self.dependencies = try self.allocator.dupe(u64, deps);
    }

    pub fn markValid(self: *Artifact, hash: u64, size: u64) void {
        self.content_hash = hash;
        self.size = size;
        self.timestamp = std.time.timestamp();
        self.is_valid = true;
    }

    pub fn invalidate(self: *Artifact) void {
        self.is_valid = false;
    }
};

/// Registry for managing all build artifacts.
pub const ArtifactRegistry = struct {
    artifacts: std.AutoHashMap(u64, Artifact),
    name_to_id: std.StringHashMap(u64),
    next_id: u64,
    allocator: std.mem.Allocator,
    /// Build output directory
    output_dir: []const u8,
    /// Target OS for extension selection
    target_os: std.Target.Os.Tag,

    pub fn init(allocator: std.mem.Allocator, output_dir: []const u8, target_os: std.Target.Os.Tag) !ArtifactRegistry {
        return .{
            .artifacts = std.AutoHashMap(u64, Artifact).init(allocator),
            .name_to_id = std.StringHashMap(u64).init(allocator),
            .next_id = 1,
            .allocator = allocator,
            .output_dir = try allocator.dupe(u8, output_dir),
            .target_os = target_os,
        };
    }

    pub fn deinit(self: *ArtifactRegistry) void {
        var it = self.artifacts.valueIterator();
        while (it.next()) |artifact| {
            var a = artifact.*;
            a.deinit();
        }
        self.artifacts.deinit();
        self.name_to_id.deinit();
        self.allocator.free(self.output_dir);
        self.* = undefined;
    }

    /// Register a new artifact and return its ID.
    pub fn register(
        self: *ArtifactRegistry,
        name: []const u8,
        kind: ArtifactKind,
        target_triple: ?[]const u8,
    ) !u64 {
        const id = self.next_id;
        self.next_id += 1;

        var artifact = try Artifact.init(self.allocator, id, name, kind, target_triple);
        errdefer artifact.deinit();

        // Generate output path
        const ext = kind.extension(self.target_os);
        const full_name = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ name, ext });
        defer self.allocator.free(full_name);

        const subdir = switch (kind) {
            .executable => "bin",
            .static_library, .shared_library => "lib",
            .object, .module_interface, .precompiled_header => "obj",
        };

        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{
            self.output_dir,
            subdir,
            full_name,
        });
        defer self.allocator.free(path);

        try artifact.setOutputPath(path);

        try self.artifacts.put(id, artifact);

        // Store name mapping (need to dupe for hashmap key)
        const name_key = try self.allocator.dupe(u8, name);
        try self.name_to_id.put(name_key, id);

        return id;
    }

    /// Get artifact by ID.
    pub fn get(self: *ArtifactRegistry, id: u64) ?*Artifact {
        return self.artifacts.getPtr(id);
    }

    /// Get artifact by name.
    pub fn getByName(self: *ArtifactRegistry, name: []const u8) ?*Artifact {
        const id = self.name_to_id.get(name) orelse return null;
        return self.get(id);
    }

    /// Check if an artifact exists and is valid.
    pub fn isValid(self: *ArtifactRegistry, id: u64) bool {
        const artifact = self.get(id) orelse return false;
        return artifact.is_valid;
    }

    /// Invalidate an artifact and all its dependents.
    pub fn invalidateWithDependents(self: *ArtifactRegistry, id: u64) void {
        const artifact = self.get(id) orelse return;
        artifact.invalidate();

        // Find and invalidate dependents
        var it = self.artifacts.valueIterator();
        while (it.next()) |other| {
            for (other.dependencies) |dep_id| {
                if (dep_id == id) {
                    self.invalidateWithDependents(other.id);
                    break;
                }
            }
        }
    }

    /// Create output directories.
    pub fn ensureDirectories(self: *ArtifactRegistry) !void {
        const subdirs = [_][]const u8{ "bin", "lib", "obj" };
        for (subdirs) |subdir| {
            const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.output_dir, subdir });
            defer self.allocator.free(path);
            // Use C library for directory creation (Zig 0.16 compatibility)
            ensureDirC(path);
        }
    }

    fn ensureDirC(path: []const u8) void {
        var path_buf: [4096]u8 = undefined;
        var i: usize = 0;
        while (i < path.len) {
            while (i < path.len and path[i] != '/') i += 1;
            if (i > 0) {
                @memcpy(path_buf[0..i], path[0..i]);
                path_buf[i] = 0;
                _ = std.c.mkdir(@ptrCast(&path_buf), 0o755);
            }
            i += 1;
        }
        if (path.len > 0) {
            @memcpy(path_buf[0..path.len], path);
            path_buf[path.len] = 0;
            _ = std.c.mkdir(@ptrCast(&path_buf), 0o755);
        }
    }

    /// Get all artifacts of a specific kind.
    pub fn getByKind(self: *ArtifactRegistry, kind: ArtifactKind, out: *std.ArrayList(*Artifact)) !void {
        var it = self.artifacts.valueIterator();
        while (it.next()) |artifact| {
            if (artifact.kind == kind) {
                try out.append(artifact);
            }
        }
    }

    /// Clean all artifacts (delete output files).
    pub fn clean(self: *ArtifactRegistry) !void {
        var it = self.artifacts.valueIterator();
        while (it.next()) |artifact| {
            if (artifact.output_path.len > 0) {
                // Use C library for file deletion (Zig 0.16 compatibility)
                var path_buf: [4096]u8 = undefined;
                if (artifact.output_path.len < path_buf.len) {
                    @memcpy(path_buf[0..artifact.output_path.len], artifact.output_path);
                    path_buf[artifact.output_path.len] = 0;
                    _ = std.c.unlink(@ptrCast(&path_buf));
                }
            }
            artifact.invalidate();
        }
    }
};

/// Represents a collection of artifacts forming a complete build output.
pub const BuildOutput = struct {
    /// Primary artifact (e.g., the main executable)
    primary: ?u64,
    /// All produced artifacts
    artifacts: []const u64,
    /// Total size of all artifacts
    total_size: u64,
    /// Build timestamp
    timestamp: i64,
    /// Build profile used
    profile: []const u8,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, profile: []const u8) !BuildOutput {
        return .{
            .primary = null,
            .artifacts = &.{},
            .total_size = 0,
            .timestamp = std.time.timestamp(),
            .profile = try allocator.dupe(u8, profile),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BuildOutput) void {
        if (self.artifacts.len > 0) {
            self.allocator.free(self.artifacts);
        }
        self.allocator.free(self.profile);
        self.* = undefined;
    }

    pub fn setArtifacts(self: *BuildOutput, artifacts: []const u64) !void {
        if (self.artifacts.len > 0) {
            self.allocator.free(self.artifacts);
        }
        self.artifacts = try self.allocator.dupe(u64, artifacts);
    }

    pub fn setPrimary(self: *BuildOutput, id: u64) void {
        self.primary = id;
    }

    pub fn calculateTotalSize(self: *BuildOutput, registry: *ArtifactRegistry) void {
        var total: u64 = 0;
        for (self.artifacts) |id| {
            if (registry.get(id)) |artifact| {
                total += artifact.size;
            }
        }
        self.total_size = total;
    }
};

// Tests
test "artifact kind extensions" {
    try std.testing.expectEqualStrings("", ArtifactKind.executable.extension(.linux));
    try std.testing.expectEqualStrings(".exe", ArtifactKind.executable.extension(.windows));
    try std.testing.expectEqualStrings(".dylib", ArtifactKind.shared_library.extension(.macos));
    try std.testing.expectEqualStrings(".a", ArtifactKind.static_library.extension(.linux));
    try std.testing.expectEqualStrings(".pcm", ArtifactKind.module_interface.extension(.linux));
}

test "artifact registry basic operations" {
    const allocator = std.testing.allocator;
    var registry = try ArtifactRegistry.init(allocator, "build", .linux);
    defer registry.deinit();

    const id = try registry.register("myapp", .executable, null);
    try std.testing.expect(id > 0);

    const artifact = registry.get(id);
    try std.testing.expect(artifact != null);
    try std.testing.expectEqualStrings("myapp", artifact.?.name);
    try std.testing.expect(!artifact.?.is_valid);

    artifact.?.markValid(12345, 1024);
    try std.testing.expect(artifact.?.is_valid);
    try std.testing.expect(registry.isValid(id));
}

test "artifact registry name lookup" {
    const allocator = std.testing.allocator;
    var registry = try ArtifactRegistry.init(allocator, "build", .linux);
    defer registry.deinit();

    _ = try registry.register("libfoo", .static_library, null);
    const artifact = registry.getByName("libfoo");
    try std.testing.expect(artifact != null);
    try std.testing.expectEqualStrings("libfoo", artifact.?.name);
}

test "artifact invalidation propagates" {
    const allocator = std.testing.allocator;
    var registry = try ArtifactRegistry.init(allocator, "build", .linux);
    defer registry.deinit();

    const lib_id = try registry.register("libbase", .static_library, null);
    const exe_id = try registry.register("app", .executable, null);

    // Set up dependency: app depends on libbase
    var exe = registry.get(exe_id).?;
    try exe.setDependencies(&.{lib_id});

    // Mark both as valid
    registry.get(lib_id).?.markValid(1, 100);
    exe.markValid(2, 200);

    try std.testing.expect(registry.isValid(lib_id));
    try std.testing.expect(registry.isValid(exe_id));

    // Invalidate library - should propagate to executable
    registry.invalidateWithDependents(lib_id);

    try std.testing.expect(!registry.isValid(lib_id));
    try std.testing.expect(!registry.isValid(exe_id));
}
