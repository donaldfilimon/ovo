//! Workspace and monorepo support for multi-project builds.
//!
//! This module provides the `Workspace` type which enables managing multiple
//! related projects (members) in a single repository. Workspaces support shared
//! settings, coordinated versioning, and cross-project dependencies.
//!
//! ## Workspace Features
//! - Multiple member projects under a single root
//! - Shared dependencies and settings
//! - Coordinated build and test runs
//! - Path-based dependency resolution between members
//!
//! ## Example
//! ```zig
//! const workspace = Workspace{
//!     .name = "my-monorepo",
//!     .members = &.{
//!         .{ .path = "packages/core" },
//!         .{ .path = "packages/cli" },
//!         .{ .path = "packages/gui" },
//!     },
//!     .shared = .{
//!         .cpp_standard = .cpp20,
//!     },
//! };
//! ```

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const platform_mod = @import("platform.zig");
const standard_mod = @import("standard.zig");
const profile_mod = @import("profile.zig");
const dependency_mod = @import("dependency.zig");
const validation = @import("validation.zig");

const Platform = platform_mod.Platform;
const CStandard = standard_mod.CStandard;
const CppStandard = standard_mod.CppStandard;
const Profile = profile_mod.Profile;
const Dependency = dependency_mod.Dependency;

/// Workspace member project specification.
pub const Member = struct {
    /// Path to the member project directory (relative to workspace root).
    path: []const u8,
    /// Optional display name override.
    name: ?[]const u8 = null,
    /// Whether this member is included by default in workspace builds.
    default_build: bool = true,
    /// Whether this member is included in workspace tests.
    default_test: bool = true,
    /// Tags for filtering/grouping members.
    tags: []const []const u8 = &.{},
    /// Member-specific configuration overrides.
    config_overrides: ?ConfigOverrides = null,

    const Self = @This();

    /// Returns the effective name of this member (display name or derived from path).
    pub fn effectiveName(self: Self) []const u8 {
        if (self.name) |n| return n;
        // Use the last path component as the name
        return std.fs.path.basename(self.path);
    }
};

/// Configuration overrides that can be applied to members.
pub const ConfigOverrides = struct {
    /// C standard override.
    c_standard: ?CStandard = null,
    /// C++ standard override.
    cpp_standard: ?CppStandard = null,
    /// Build profile override.
    profile: ?[]const u8 = null,
    /// Additional defines.
    defines: []const []const u8 = &.{},
    /// Additional compiler flags.
    cflags: []const []const u8 = &.{},
    /// Additional C++ compiler flags.
    cxxflags: []const []const u8 = &.{},
};

/// Shared settings applied to all workspace members.
pub const SharedSettings = struct {
    /// Shared C standard for all members.
    c_standard: ?CStandard = null,
    /// Shared C++ standard for all members.
    cpp_standard: ?CppStandard = null,
    /// Shared defines for all members.
    defines: []const []const u8 = &.{},
    /// Shared compiler flags for all members.
    cflags: []const []const u8 = &.{},
    /// Shared C++ compiler flags for all members.
    cxxflags: []const []const u8 = &.{},
    /// Shared linker flags for all members.
    ldflags: []const []const u8 = &.{},
    /// Shared include paths for all members.
    include_paths: []const []const u8 = &.{},

    const Self = @This();

    /// Returns true if any settings are configured.
    pub fn hasAnySettings(self: Self) bool {
        return self.c_standard != null or
            self.cpp_standard != null or
            self.defines.len > 0 or
            self.cflags.len > 0 or
            self.cxxflags.len > 0 or
            self.ldflags.len > 0 or
            self.include_paths.len > 0;
    }
};

/// Dependency resolution strategy for workspace members.
pub const DependencyResolution = enum {
    /// Members can reference each other by name directly.
    by_name,
    /// Members must use path dependencies explicitly.
    by_path,
    /// Automatic resolution based on proximity and naming.
    automatic,
};

/// Build ordering strategy for workspace members.
pub const BuildOrder = enum {
    /// Build in topological order based on dependencies.
    topological,
    /// Build members in parallel where possible.
    parallel,
    /// Build in the order members are listed.
    sequential,
};

/// Complete workspace specification.
pub const Workspace = struct {
    /// Workspace name.
    name: []const u8,
    /// Workspace version.
    version: ?[]const u8 = null,
    /// Member projects.
    members: []const Member = &.{},
    /// Glob patterns for discovering members (alternative to explicit listing).
    member_patterns: []const []const u8 = &.{},
    /// Directories to exclude from member discovery.
    exclude_patterns: []const []const u8 = &.{},
    /// Shared settings applied to all members.
    shared: SharedSettings = .{},
    /// Shared dependencies available to all members.
    shared_dependencies: []const Dependency = &.{},
    /// Custom build profiles for the workspace.
    profiles: []const Profile = &.{},
    /// Default profile name.
    default_profile: ?[]const u8 = null,
    /// How to resolve inter-member dependencies.
    dependency_resolution: DependencyResolution = .automatic,
    /// How to order builds.
    build_order: BuildOrder = .topological,
    /// Root output directory for all builds.
    output_dir: ?[]const u8 = null,
    /// Workspace-level metadata.
    metadata: Metadata = .{},

    pub const Metadata = struct {
        /// Authors of the workspace.
        authors: []const []const u8 = &.{},
        /// License identifier (SPDX).
        license: ?[]const u8 = null,
        /// Homepage URL.
        homepage: ?[]const u8 = null,
        /// Repository URL.
        repository: ?[]const u8 = null,
        /// Description.
        description: ?[]const u8 = null,
    };

    const Self = @This();

    /// Returns all member names.
    pub fn memberNames(self: Self, allocator: Allocator) Allocator.Error![]const []const u8 {
        var names = std.ArrayList([]const u8).init(allocator);
        errdefer names.deinit();

        for (self.members) |m| {
            try names.append(m.effectiveName());
        }

        return names.toOwnedSlice();
    }

    /// Finds a member by name.
    pub fn findMember(self: Self, name: []const u8) ?Member {
        for (self.members) |m| {
            if (std.mem.eql(u8, m.effectiveName(), name)) {
                return m;
            }
        }
        return null;
    }

    /// Finds a member by path.
    pub fn findMemberByPath(self: Self, path: []const u8) ?Member {
        for (self.members) |m| {
            if (std.mem.eql(u8, m.path, path)) {
                return m;
            }
        }
        return null;
    }

    /// Returns members with the given tag.
    pub fn membersWithTag(self: Self, tag: []const u8, allocator: Allocator) Allocator.Error![]const Member {
        var result = std.ArrayList(Member).init(allocator);
        errdefer result.deinit();

        for (self.members) |m| {
            for (m.tags) |t| {
                if (std.mem.eql(u8, t, tag)) {
                    try result.append(m);
                    break;
                }
            }
        }

        return result.toOwnedSlice();
    }

    /// Returns members that should be built by default.
    pub fn defaultBuildMembers(self: Self, allocator: Allocator) Allocator.Error![]const Member {
        var result = std.ArrayList(Member).init(allocator);
        errdefer result.deinit();

        for (self.members) |m| {
            if (m.default_build) {
                try result.append(m);
            }
        }

        return result.toOwnedSlice();
    }

    /// Returns members that should be tested by default.
    pub fn defaultTestMembers(self: Self, allocator: Allocator) Allocator.Error![]const Member {
        var result = std.ArrayList(Member).init(allocator);
        errdefer result.deinit();

        for (self.members) |m| {
            if (m.default_test) {
                try result.append(m);
            }
        }

        return result.toOwnedSlice();
    }

    /// Returns the effective profile for this workspace.
    pub fn effectiveProfile(self: Self, profile_name: ?[]const u8) ?Profile {
        const name = profile_name orelse self.default_profile orelse return Profile.fromName("debug");

        // Check custom profiles first
        for (self.profiles) |p| {
            if (std.mem.eql(u8, p.name, name)) {
                return p;
            }
        }

        // Fall back to built-in profiles
        return Profile.fromName(name);
    }

    /// Validates the workspace configuration.
    pub fn validate(self: Self) ValidateError!void {
        if (self.name.len == 0) {
            return ValidateError.MissingName;
        }

        // Check for duplicate member names
        if (validation.hasDuplicateName(Member, self.members, memberName)) {
            return ValidateError.DuplicateMemberName;
        }

        // Validate each member
        for (self.members) |m| {
            if (m.path.len == 0) {
                return ValidateError.InvalidMemberPath;
            }
        }
    }
};

fn memberName(member: Member) []const u8 {
    return member.effectiveName();
}

/// Dependency graph for workspace members.
pub const DependencyGraph = struct {
    allocator: Allocator,
    /// Map from member name to its dependencies.
    edges: std.StringHashMap([]const []const u8),
    /// All member names in the graph.
    nodes: std.ArrayList([]const u8),

    const Self = @This();

    /// Creates a new empty dependency graph.
    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .edges = std.StringHashMap([]const []const u8).init(allocator),
            .nodes = std.ArrayList([]const u8).init(allocator),
        };
    }

    /// Frees all memory used by the graph.
    pub fn deinit(self: *Self) void {
        self.edges.deinit();
        self.nodes.deinit();
    }

    /// Adds a member to the graph.
    pub fn addMember(self: *Self, name: []const u8, dependencies: []const []const u8) Allocator.Error!void {
        try self.nodes.append(name);
        try self.edges.put(name, dependencies);
    }

    /// Returns a topological ordering of members, or error if cycle detected.
    pub fn topologicalSort(self: Self, allocator: Allocator) ![]const []const u8 {
        var result = std.ArrayList([]const u8).init(allocator);
        errdefer result.deinit();

        var visited = std.StringHashMap(VisitState).init(allocator);
        defer visited.deinit();

        for (self.nodes.items) |node| {
            try self.visit(node, &visited, &result);
        }

        // Reverse to get correct order
        std.mem.reverse([]const u8, result.items);
        return result.toOwnedSlice();
    }

    const VisitState = enum { unvisited, visiting, visited };

    fn visit(
        self: Self,
        node: []const u8,
        visited: *std.StringHashMap(VisitState),
        result: *std.ArrayList([]const u8),
    ) !void {
        const state = visited.get(node) orelse .unvisited;
        switch (state) {
            .visited => return,
            .visiting => return error.CycleDetected,
            .unvisited => {},
        }

        try visited.put(node, .visiting);

        if (self.edges.get(node)) |deps| {
            for (deps) |dep| {
                try self.visit(dep, visited, result);
            }
        }

        try visited.put(node, .visited);
        try result.append(node);
    }
};

/// Errors that can occur during workspace operations.
pub const ValidateError = error{
    MissingName,
    DuplicateMemberName,
    InvalidMemberPath,
    CycleDetected,
};

// ============================================================================
// Tests
// ============================================================================

test "Member.effectiveName" {
    const with_name = Member{ .path = "packages/mylib", .name = "custom-name" };
    try testing.expectEqualStrings("custom-name", with_name.effectiveName());

    const without_name = Member{ .path = "packages/mylib" };
    try testing.expectEqualStrings("mylib", without_name.effectiveName());

    const root = Member{ .path = "." };
    try testing.expectEqualStrings(".", root.effectiveName());
}

test "SharedSettings.hasAnySettings" {
    const empty = SharedSettings{};
    try testing.expect(!empty.hasAnySettings());

    const with_standard = SharedSettings{ .cpp_standard = .cpp20 };
    try testing.expect(with_standard.hasAnySettings());

    const with_defines = SharedSettings{ .defines = &[_][]const u8{"DEBUG"} };
    try testing.expect(with_defines.hasAnySettings());
}

test "Workspace.findMember" {
    const workspace = Workspace{
        .name = "test-workspace",
        .members = &[_]Member{
            .{ .path = "packages/core", .name = "core" },
            .{ .path = "packages/cli" },
            .{ .path = "packages/gui", .name = "gui-app" },
        },
    };

    const core = workspace.findMember("core");
    try testing.expect(core != null);
    try testing.expectEqualStrings("packages/core", core.?.path);

    const cli = workspace.findMember("cli");
    try testing.expect(cli != null);
    try testing.expectEqualStrings("packages/cli", cli.?.path);

    const gui = workspace.findMember("gui-app");
    try testing.expect(gui != null);
    try testing.expectEqualStrings("packages/gui", gui.?.path);

    const nonexistent = workspace.findMember("nonexistent");
    try testing.expect(nonexistent == null);
}

test "Workspace.membersWithTag" {
    const allocator = testing.allocator;

    const workspace = Workspace{
        .name = "test-workspace",
        .members = &[_]Member{
            .{ .path = "packages/core", .tags = &[_][]const u8{ "lib", "core" } },
            .{ .path = "packages/cli", .tags = &[_][]const u8{"app"} },
            .{ .path = "packages/gui", .tags = &[_][]const u8{ "app", "gui" } },
        },
    };

    const apps = try workspace.membersWithTag("app", allocator);
    defer allocator.free(apps);
    try testing.expectEqual(@as(usize, 2), apps.len);

    const libs = try workspace.membersWithTag("lib", allocator);
    defer allocator.free(libs);
    try testing.expectEqual(@as(usize, 1), libs.len);

    const none = try workspace.membersWithTag("nonexistent", allocator);
    defer allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "Workspace.validate" {
    // Valid workspace
    const valid = Workspace{
        .name = "test-workspace",
        .members = &[_]Member{
            .{ .path = "packages/core" },
            .{ .path = "packages/cli" },
        },
    };
    try valid.validate();

    // Invalid: missing name
    const no_name = Workspace{
        .name = "",
    };
    try testing.expectError(ValidateError.MissingName, no_name.validate());

    // Invalid: duplicate member names
    const dup_names = Workspace{
        .name = "test",
        .members = &[_]Member{
            .{ .path = "packages/core", .name = "core" },
            .{ .path = "libs/core", .name = "core" },
        },
    };
    try testing.expectError(ValidateError.DuplicateMemberName, dup_names.validate());

    // Invalid: empty member path
    const empty_path = Workspace{
        .name = "test",
        .members = &[_]Member{
            .{ .path = "" },
        },
    };
    try testing.expectError(ValidateError.InvalidMemberPath, empty_path.validate());
}

test "Workspace.effectiveProfile" {
    const custom_release = Profile{
        .name = "custom-release",
        .optimization = .aggressive,
        .debug_info = .none,
        .sanitizers = .{},
        .lto = .full,
        .strip = true,
        .pic = false,
        .extra_cflags = &.{},
        .extra_cxxflags = &.{},
        .extra_ldflags = &.{},
        .defines = &.{},
    };

    const workspace = Workspace{
        .name = "test",
        .profiles = &[_]Profile{custom_release},
        .default_profile = "debug",
    };

    // Get default profile
    const default = workspace.effectiveProfile(null);
    try testing.expect(default != null);
    try testing.expectEqualStrings("debug", default.?.name);

    // Get custom profile
    const custom = workspace.effectiveProfile("custom-release");
    try testing.expect(custom != null);
    try testing.expectEqualStrings("custom-release", custom.?.name);

    // Get built-in profile
    const release = workspace.effectiveProfile("release");
    try testing.expect(release != null);
    try testing.expectEqualStrings("release", release.?.name);
}

test "DependencyGraph.topologicalSort" {
    const allocator = testing.allocator;

    var graph = DependencyGraph.init(allocator);
    defer graph.deinit();

    // Add members with dependencies: cli -> core, gui -> core
    try graph.addMember("core", &.{});
    try graph.addMember("cli", &[_][]const u8{"core"});
    try graph.addMember("gui", &[_][]const u8{"core"});

    const order = try graph.topologicalSort(allocator);
    defer allocator.free(order);

    // core should come before cli and gui
    var core_idx: ?usize = null;
    var cli_idx: ?usize = null;
    var gui_idx: ?usize = null;

    for (order, 0..) |name, i| {
        if (std.mem.eql(u8, name, "core")) core_idx = i;
        if (std.mem.eql(u8, name, "cli")) cli_idx = i;
        if (std.mem.eql(u8, name, "gui")) gui_idx = i;
    }

    try testing.expect(core_idx != null);
    try testing.expect(cli_idx != null);
    try testing.expect(gui_idx != null);
    try testing.expect(core_idx.? < cli_idx.?);
    try testing.expect(core_idx.? < gui_idx.?);
}

test "DependencyGraph cycle detection" {
    const allocator = testing.allocator;

    var graph = DependencyGraph.init(allocator);
    defer graph.deinit();

    // Create a cycle: a -> b -> c -> a
    try graph.addMember("a", &[_][]const u8{"b"});
    try graph.addMember("b", &[_][]const u8{"c"});
    try graph.addMember("c", &[_][]const u8{"a"});

    const result = graph.topologicalSort(allocator);
    try testing.expectError(error.CycleDetected, result);
}
