//! C++20/23/26 Modules Support
//!
//! Handles Binary Module Interface (BMI) management, module dependency scanning,
//! and topological compilation ordering for C++ modules.

const std = @import("std");
const Allocator = std.mem.Allocator;
const interface = @import("interface.zig");

/// Module dependency type
pub const DependencyKind = enum {
    /// import <module>;
    module_import,
    /// import <header>;
    header_unit,
    /// import :partition;
    partition_import,
    /// export import <module>;
    export_import,
};

/// Represents a single module dependency
pub const ModuleDependency = struct {
    /// Module name (e.g., "std", "std.io", ":impl")
    name: []const u8,
    /// Kind of dependency
    kind: DependencyKind,
    /// Source file that provides this module (resolved later)
    source_path: ?[]const u8 = null,
    /// BMI path once compiled
    bmi_path: ?[]const u8 = null,
    /// Is this from the standard library
    is_std: bool = false,
};

/// Module unit information
pub const ModuleUnit = struct {
    /// Source file path
    source_path: []const u8,
    /// Module name this unit provides (null for implementation units)
    provides: ?[]const u8,
    /// Is this a module interface unit
    is_interface: bool,
    /// Is this a module partition
    is_partition: bool,
    /// Parent module (for partitions)
    parent_module: ?[]const u8 = null,
    /// Dependencies this unit requires
    dependencies: []ModuleDependency,
    /// BMI output path
    bmi_path: ?[]const u8 = null,
    /// Object output path
    object_path: ?[]const u8 = null,
    /// Compilation state
    state: CompilationState = .pending,
};

/// Compilation state for a module unit
pub const CompilationState = enum {
    pending,
    scanning,
    compiling_interface,
    compiling_object,
    completed,
    failed,
};

/// Dependency graph node
const GraphNode = struct {
    unit: *ModuleUnit,
    edges: std.ArrayList(*GraphNode),
    in_degree: usize = 0,

    fn init(allocator: Allocator, unit: *ModuleUnit) GraphNode {
        return .{
            .unit = unit,
            .edges = std.ArrayList(*GraphNode).init(allocator),
        };
    }

    fn deinit(self: *GraphNode) void {
        self.edges.deinit();
    }
};

/// Module dependency graph for managing compilation order
pub const ModuleGraph = struct {
    allocator: Allocator,
    /// All module units in the graph
    units: std.ArrayList(ModuleUnit),
    /// Map from module name to unit
    module_map: std.StringHashMap(*ModuleUnit),
    /// Map from source path to unit
    source_map: std.StringHashMap(*ModuleUnit),
    /// Graph nodes for topological sort
    nodes: std.ArrayList(GraphNode),
    /// Node lookup by unit pointer
    node_map: std.AutoHashMap(*ModuleUnit, *GraphNode),
    /// BMI cache directory
    cache_dir: []const u8,

    pub fn init(allocator: Allocator, cache_dir: []const u8) ModuleGraph {
        return .{
            .allocator = allocator,
            .units = std.ArrayList(ModuleUnit).init(allocator),
            .module_map = std.StringHashMap(*ModuleUnit).init(allocator),
            .source_map = std.StringHashMap(*ModuleUnit).init(allocator),
            .nodes = std.ArrayList(GraphNode).init(allocator),
            .node_map = std.AutoHashMap(*ModuleUnit, *GraphNode).init(allocator),
            .cache_dir = cache_dir,
        };
    }

    pub fn deinit(self: *ModuleGraph) void {
        for (self.nodes.items) |*node| {
            node.deinit();
        }
        self.nodes.deinit();
        self.node_map.deinit();

        for (self.units.items) |*unit| {
            self.allocator.free(unit.source_path);
            if (unit.provides) |p| self.allocator.free(p);
            if (unit.parent_module) |p| self.allocator.free(p);
            for (unit.dependencies) |*dep| {
                self.allocator.free(dep.name);
                if (dep.source_path) |p| self.allocator.free(p);
                if (dep.bmi_path) |p| self.allocator.free(p);
            }
            self.allocator.free(unit.dependencies);
            if (unit.bmi_path) |p| self.allocator.free(p);
            if (unit.object_path) |p| self.allocator.free(p);
        }
        self.units.deinit();
        self.module_map.deinit();
        self.source_map.deinit();
    }

    /// Add a module unit to the graph
    pub fn addUnit(self: *ModuleGraph, unit: ModuleUnit) !*ModuleUnit {
        try self.units.append(unit);
        const unit_ptr = &self.units.items[self.units.items.len - 1];

        // Register in maps
        if (unit.provides) |name| {
            try self.module_map.put(name, unit_ptr);
        }
        try self.source_map.put(unit.source_path, unit_ptr);

        return unit_ptr;
    }

    /// Get unit by module name
    pub fn getByName(self: *ModuleGraph, name: []const u8) ?*ModuleUnit {
        return self.module_map.get(name);
    }

    /// Get unit by source path
    pub fn getBySource(self: *ModuleGraph, path: []const u8) ?*ModuleUnit {
        return self.source_map.get(path);
    }

    /// Build the dependency graph edges
    pub fn buildGraph(self: *ModuleGraph) !void {
        // Create nodes for all units
        for (self.units.items) |*unit| {
            const node = GraphNode.init(self.allocator, unit);
            try self.nodes.append(node);
        }

        // Update node map with stable pointers
        for (self.nodes.items, 0..) |*node, i| {
            try self.node_map.put(&self.units.items[i], node);
        }

        // Add edges based on dependencies
        for (self.nodes.items) |*node| {
            for (node.unit.dependencies) |dep| {
                if (self.module_map.get(dep.name)) |dep_unit| {
                    if (self.node_map.get(dep_unit)) |dep_node| {
                        try node.edges.append(dep_node);
                        dep_node.in_degree += 1;
                    }
                }
            }
        }
    }

    /// Perform topological sort to get compilation order
    /// Returns slices into the internal nodes array
    pub fn topologicalSort(self: *ModuleGraph) ![]const *ModuleUnit {
        var result = std.ArrayList(*ModuleUnit).init(self.allocator);
        errdefer result.deinit();

        // Find all nodes with in_degree == 0
        var queue = std.ArrayList(*GraphNode).init(self.allocator);
        defer queue.deinit();

        // Copy in_degrees to work with
        var in_degrees = std.AutoHashMap(*GraphNode, usize).init(self.allocator);
        defer in_degrees.deinit();

        for (self.nodes.items) |*node| {
            try in_degrees.put(node, node.in_degree);
            if (node.in_degree == 0) {
                try queue.append(node);
            }
        }

        while (queue.items.len > 0) {
            const node = queue.orderedRemove(0);
            try result.append(node.unit);

            // Reduce in_degree of dependents
            for (self.nodes.items) |*other| {
                for (other.edges.items) |edge| {
                    if (edge == node) {
                        const current = in_degrees.get(other).?;
                        try in_degrees.put(other, current - 1);
                        if (current - 1 == 0) {
                            try queue.append(other);
                        }
                    }
                }
            }
        }

        // Check for cycles
        if (result.items.len != self.nodes.items.len) {
            return error.CyclicDependency;
        }

        return result.toOwnedSlice();
    }

    /// Get BMI path for a module
    pub fn getBmiPath(self: *ModuleGraph, module_name: []const u8) ![]const u8 {
        // Sanitize module name for filesystem
        var sanitized = std.ArrayList(u8).init(self.allocator);
        defer sanitized.deinit();

        for (module_name) |c| {
            if (c == ':' or c == '.' or c == '/') {
                try sanitized.append('-');
            } else {
                try sanitized.append(c);
            }
        }

        return std.fmt.allocPrint(self.allocator, "{s}/{s}.pcm", .{
            self.cache_dir,
            sanitized.items,
        });
    }

    /// Detect cycles in the dependency graph
    pub fn detectCycles(self: *ModuleGraph) !?[]const []const u8 {
        const State = enum { unvisited, visiting, visited };

        var state_map = std.AutoHashMap(*GraphNode, State).init(self.allocator);
        defer state_map.deinit();

        for (self.nodes.items) |*node| {
            try state_map.put(node, .unvisited);
        }

        var cycle_path = std.ArrayList([]const u8).init(self.allocator);
        defer cycle_path.deinit();

        const CycleDetector = struct {
            fn visit(
                node: *GraphNode,
                states: *std.AutoHashMap(*GraphNode, State),
                path: *std.ArrayList([]const u8),
                graph: *ModuleGraph,
            ) !bool {
                const current_state = states.get(node).?;

                if (current_state == .visiting) {
                    // Found cycle
                    if (node.unit.provides) |name| {
                        try path.append(name);
                    }
                    return true;
                }

                if (current_state == .visited) {
                    return false;
                }

                try states.put(node, .visiting);
                if (node.unit.provides) |name| {
                    try path.append(name);
                }

                for (node.edges.items) |edge| {
                    if (try visit(edge, states, path, graph)) {
                        return true;
                    }
                }

                try states.put(node, .visited);
                _ = path.popOrNull();
                return false;
            }
        };

        for (self.nodes.items) |*node| {
            if (state_map.get(node).? == .unvisited) {
                if (try CycleDetector.visit(node, &state_map, &cycle_path, self)) {
                    return cycle_path.toOwnedSlice();
                }
            }
        }

        return null;
    }
};

/// BMI (Binary Module Interface) cache manager
pub const BmiCache = struct {
    allocator: Allocator,
    cache_dir: []const u8,
    /// Map from module name to BMI metadata
    entries: std.StringHashMap(BmiEntry),

    pub const BmiEntry = struct {
        /// Module name
        module_name: []const u8,
        /// BMI file path
        bmi_path: []const u8,
        /// Source file that generated this BMI
        source_path: []const u8,
        /// Source file modification time
        source_mtime: i128,
        /// BMI file modification time
        bmi_mtime: i128,
        /// Dependencies (other module names)
        dependencies: []const []const u8,
        /// Compiler that generated this BMI
        compiler: interface.CompilerKind,
        /// Compiler version
        compiler_version: []const u8,
        /// Is entry valid
        valid: bool,
    };

    pub fn init(allocator: Allocator, cache_dir: []const u8) !BmiCache {
        // Ensure cache directory exists
        std.fs.makeDirAbsolute(cache_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        return .{
            .allocator = allocator,
            .cache_dir = cache_dir,
            .entries = std.StringHashMap(BmiEntry).init(allocator),
        };
    }

    pub fn deinit(self: *BmiCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.module_name);
            self.allocator.free(entry.value_ptr.bmi_path);
            self.allocator.free(entry.value_ptr.source_path);
            for (entry.value_ptr.dependencies) |d| {
                self.allocator.free(d);
            }
            self.allocator.free(entry.value_ptr.dependencies);
            self.allocator.free(entry.value_ptr.compiler_version);
        }
        self.entries.deinit();
    }

    /// Check if BMI is up to date
    pub fn isValid(self: *BmiCache, module_name: []const u8, source_path: []const u8) !bool {
        const entry = self.entries.get(module_name) orelse return false;

        // Check if source file changed
        const source_stat = try std.fs.cwd().statFile(source_path);
        if (source_stat.mtime != entry.source_mtime) {
            return false;
        }

        // Check if BMI exists
        _ = std.fs.cwd().statFile(entry.bmi_path) catch return false;

        // Check if dependencies are valid
        for (entry.dependencies) |dep| {
            const dep_entry = self.entries.get(dep) orelse return false;
            if (!dep_entry.valid) return false;
        }

        return true;
    }

    /// Get BMI path for a module
    pub fn getBmiPath(self: *BmiCache, module_name: []const u8) ?[]const u8 {
        const entry = self.entries.get(module_name) orelse return null;
        return entry.bmi_path;
    }

    /// Register a new BMI entry
    pub fn register(
        self: *BmiCache,
        module_name: []const u8,
        bmi_path: []const u8,
        source_path: []const u8,
        dependencies: []const []const u8,
        compiler: interface.CompilerKind,
        compiler_version: []const u8,
    ) !void {
        const source_stat = try std.fs.cwd().statFile(source_path);
        const bmi_stat = try std.fs.cwd().statFile(bmi_path);

        // Duplicate strings for storage
        const owned_name = try self.allocator.dupe(u8, module_name);
        const owned_bmi = try self.allocator.dupe(u8, bmi_path);
        const owned_source = try self.allocator.dupe(u8, source_path);
        const owned_version = try self.allocator.dupe(u8, compiler_version);

        var owned_deps = try self.allocator.alloc([]const u8, dependencies.len);
        for (dependencies, 0..) |dep, i| {
            owned_deps[i] = try self.allocator.dupe(u8, dep);
        }

        const entry = BmiEntry{
            .module_name = owned_name,
            .bmi_path = owned_bmi,
            .source_path = owned_source,
            .source_mtime = source_stat.mtime,
            .bmi_mtime = bmi_stat.mtime,
            .dependencies = owned_deps,
            .compiler = compiler,
            .compiler_version = owned_version,
            .valid = true,
        };

        try self.entries.put(owned_name, entry);
    }

    /// Invalidate a BMI entry
    pub fn invalidate(self: *BmiCache, module_name: []const u8) void {
        if (self.entries.getPtr(module_name)) |entry| {
            entry.valid = false;
        }
    }

    /// Clear all entries
    pub fn clear(self: *BmiCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.module_name);
            self.allocator.free(entry.value_ptr.bmi_path);
            self.allocator.free(entry.value_ptr.source_path);
            for (entry.value_ptr.dependencies) |d| {
                self.allocator.free(d);
            }
            self.allocator.free(entry.value_ptr.dependencies);
            self.allocator.free(entry.value_ptr.compiler_version);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Save cache to disk
    pub fn save(self: *BmiCache, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var writer = file.writer();

        // Simple text format for now
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const e = entry.value_ptr;
            try writer.print("{s}\t{s}\t{s}\t{d}\t{d}\t{s}\n", .{
                e.module_name,
                e.bmi_path,
                e.source_path,
                e.source_mtime,
                e.bmi_mtime,
                e.compiler_version,
            });
        }
    }
};

/// Parse module dependencies from source file (basic scanner)
pub fn scanModuleDeclarations(allocator: Allocator, source: []const u8) !struct {
    provides: ?[]const u8,
    dependencies: []ModuleDependency,
} {
    var provides: ?[]const u8 = null;
    var deps = std.ArrayList(ModuleDependency).init(allocator);
    errdefer deps.deinit();

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip comments and empty lines
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) continue;

        // Look for module declaration: export module <name>;
        if (std.mem.startsWith(u8, trimmed, "export module ")) {
            const rest = trimmed["export module ".len..];
            if (std.mem.indexOfScalar(u8, rest, ';')) |end| {
                provides = try allocator.dupe(u8, std.mem.trim(u8, rest[0..end], " \t"));
            }
        }
        // Look for module implementation: module <name>;
        else if (std.mem.startsWith(u8, trimmed, "module ") and !std.mem.startsWith(u8, trimmed, "module ;")) {
            const rest = trimmed["module ".len..];
            if (std.mem.indexOfScalar(u8, rest, ';')) |end| {
                const name = std.mem.trim(u8, rest[0..end], " \t");
                // Skip if it's a partition declaration
                if (!std.mem.startsWith(u8, name, ":")) {
                    provides = try allocator.dupe(u8, name);
                }
            }
        }
        // Look for import declarations
        else if (std.mem.startsWith(u8, trimmed, "import ") or std.mem.startsWith(u8, trimmed, "export import ")) {
            const is_export = std.mem.startsWith(u8, trimmed, "export import ");
            const import_start = if (is_export) "export import ".len else "import ".len;
            const rest = trimmed[import_start..];

            if (std.mem.indexOfScalar(u8, rest, ';')) |end| {
                const import_name = std.mem.trim(u8, rest[0..end], " \t");

                // Determine import kind
                var kind: DependencyKind = .module_import;
                var name = import_name;

                if (std.mem.startsWith(u8, import_name, "<") and std.mem.endsWith(u8, import_name, ">")) {
                    kind = .header_unit;
                    name = import_name[1 .. import_name.len - 1];
                } else if (std.mem.startsWith(u8, import_name, ":")) {
                    kind = .partition_import;
                }

                if (is_export) {
                    kind = .export_import;
                }

                const is_std = std.mem.startsWith(u8, name, "std");

                try deps.append(.{
                    .name = try allocator.dupe(u8, name),
                    .kind = kind,
                    .is_std = is_std,
                });
            }
        }
    }

    return .{
        .provides = provides,
        .dependencies = try deps.toOwnedSlice(),
    };
}

/// Discover all module files in a directory
pub fn discoverModuleFiles(allocator: Allocator, root_dir: []const u8) ![]const []const u8 {
    var files = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit();
    }

    var dir = try std.fs.cwd().openDir(root_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        const ext = std.fs.path.extension(entry.basename);
        if (interface.Language.isModuleInterface(entry.path) or
            std.mem.eql(u8, ext, ".cpp") or
            std.mem.eql(u8, ext, ".cxx") or
            std.mem.eql(u8, ext, ".cc"))
        {
            const full_path = try std.fs.path.join(allocator, &.{ root_dir, entry.path });
            try files.append(full_path);
        }
    }

    return files.toOwnedSlice();
}

test "scanModuleDeclarations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        \\export module mymodule;
        \\
        \\import std;
        \\import :impl;
        \\export import other;
        \\import <vector>;
        \\
        \\export void foo();
    ;

    const result = try scanModuleDeclarations(allocator, source);
    defer {
        if (result.provides) |p| allocator.free(p);
        for (result.dependencies) |d| {
            allocator.free(d.name);
        }
        allocator.free(result.dependencies);
    }

    try testing.expectEqualStrings("mymodule", result.provides.?);
    try testing.expectEqual(@as(usize, 4), result.dependencies.len);
    try testing.expectEqualStrings("std", result.dependencies[0].name);
    try testing.expectEqual(DependencyKind.module_import, result.dependencies[0].kind);
    try testing.expectEqualStrings(":impl", result.dependencies[1].name);
    try testing.expectEqual(DependencyKind.partition_import, result.dependencies[1].kind);
}

test "ModuleGraph basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var graph = ModuleGraph.init(allocator, "/tmp/bmi");
    defer graph.deinit();

    // Add module units
    _ = try graph.addUnit(.{
        .source_path = try allocator.dupe(u8, "main.cpp"),
        .provides = null,
        .is_interface = false,
        .is_partition = false,
        .dependencies = &.{},
    });

    try testing.expectEqual(@as(usize, 1), graph.units.items.len);
}
