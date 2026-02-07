//! Build dependency graph for the ovo build system.
//! Provides directed acyclic graph (DAG) structure with topological ordering
//! and C++ module-aware compilation ordering.
const std = @import("std");

/// Type of build node.
pub const NodeKind = enum {
    /// Compile a source file to object
    compile,
    /// Compile a C++ module interface unit
    compile_module,
    /// Link objects into executable or library
    link,
    /// Generate precompiled header
    precompile_header,
    /// Copy/install artifact
    install,
    /// Custom command
    custom,
    /// Module dependency scan
    module_scan,

    pub fn description(self: NodeKind) []const u8 {
        return switch (self) {
            .compile => "Compiling",
            .compile_module => "Compiling module",
            .link => "Linking",
            .precompile_header => "Precompiling header",
            .install => "Installing",
            .custom => "Running",
            .module_scan => "Scanning modules",
        };
    }
};

/// State of a build node.
pub const NodeState = enum {
    /// Not yet processed
    pending,
    /// Ready to execute (all dependencies satisfied)
    ready,
    /// Currently executing
    running,
    /// Successfully completed
    completed,
    /// Failed execution
    failed,
    /// Skipped (cached)
    skipped,
};

/// A node in the build graph representing a single build task.
pub const BuildNode = struct {
    /// Unique identifier
    id: u64,
    /// Human-readable name
    name: []const u8,
    /// Type of task
    kind: NodeKind,
    /// Current state
    state: NodeState,
    /// IDs of nodes this depends on
    dependencies: []const u64,
    /// IDs of nodes that depend on this
    dependents: []const u64,
    /// Input files for this node
    inputs: []const []const u8,
    /// Output files produced
    outputs: []const []const u8,
    /// Command arguments to execute
    command_args: []const []const u8,
    /// Working directory
    working_dir: ?[]const u8,
    /// Associated artifact ID (if any)
    artifact_id: ?u64,
    /// Module name (for C++ modules)
    module_name: ?[]const u8,
    /// Error message if failed
    error_msg: ?[]const u8,
    /// Execution time in nanoseconds
    execution_time_ns: u64,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: u64, name: []const u8, kind: NodeKind) !BuildNode {
        return .{
            .id = id,
            .name = try allocator.dupe(u8, name),
            .kind = kind,
            .state = .pending,
            .dependencies = &.{},
            .dependents = &.{},
            .inputs = &.{},
            .outputs = &.{},
            .command_args = &.{},
            .working_dir = null,
            .artifact_id = null,
            .module_name = null,
            .error_msg = null,
            .execution_time_ns = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BuildNode) void {
        self.allocator.free(self.name);
        if (self.dependencies.len > 0) self.allocator.free(self.dependencies);
        if (self.dependents.len > 0) self.allocator.free(self.dependents);

        for (self.inputs) |input| self.allocator.free(input);
        if (self.inputs.len > 0) self.allocator.free(self.inputs);

        for (self.outputs) |output| self.allocator.free(output);
        if (self.outputs.len > 0) self.allocator.free(self.outputs);

        for (self.command_args) |arg| self.allocator.free(arg);
        if (self.command_args.len > 0) self.allocator.free(self.command_args);

        if (self.working_dir) |wd| self.allocator.free(wd);
        if (self.module_name) |mn| self.allocator.free(mn);
        if (self.error_msg) |em| self.allocator.free(em);

        self.* = undefined;
    }

    pub fn setDependencies(self: *BuildNode, deps: []const u64) !void {
        if (self.dependencies.len > 0) self.allocator.free(self.dependencies);
        self.dependencies = try self.allocator.dupe(u64, deps);
    }

    pub fn addDependent(self: *BuildNode, dep_id: u64) !void {
        var list = std.ArrayList(u64){};
        defer list.deinit(self.allocator);
        try list.appendSlice(self.allocator, self.dependents);
        try list.append(self.allocator, dep_id);

        if (self.dependents.len > 0) self.allocator.free(self.dependents);
        self.dependents = try list.toOwnedSlice(self.allocator);
    }

    pub fn setInputs(self: *BuildNode, inputs: []const []const u8) !void {
        for (self.inputs) |input| self.allocator.free(input);
        if (self.inputs.len > 0) self.allocator.free(self.inputs);

        const new_inputs = try self.allocator.alloc([]const u8, inputs.len);
        for (inputs, 0..) |input, i| {
            new_inputs[i] = try self.allocator.dupe(u8, input);
        }
        self.inputs = new_inputs;
    }

    pub fn setOutputs(self: *BuildNode, outputs: []const []const u8) !void {
        for (self.outputs) |output| self.allocator.free(output);
        if (self.outputs.len > 0) self.allocator.free(self.outputs);

        const new_outputs = try self.allocator.alloc([]const u8, outputs.len);
        for (outputs, 0..) |output, i| {
            new_outputs[i] = try self.allocator.dupe(u8, output);
        }
        self.outputs = new_outputs;
    }

    pub fn setCommandArgs(self: *BuildNode, args: []const []const u8) !void {
        for (self.command_args) |arg| self.allocator.free(arg);
        if (self.command_args.len > 0) self.allocator.free(self.command_args);

        const new_args = try self.allocator.alloc([]const u8, args.len);
        for (args, 0..) |arg, i| {
            new_args[i] = try self.allocator.dupe(u8, arg);
        }
        self.command_args = new_args;
    }

    pub fn setWorkingDir(self: *BuildNode, dir: []const u8) !void {
        if (self.working_dir) |wd| self.allocator.free(wd);
        self.working_dir = try self.allocator.dupe(u8, dir);
    }

    pub fn setModuleName(self: *BuildNode, name: []const u8) !void {
        if (self.module_name) |mn| self.allocator.free(mn);
        self.module_name = try self.allocator.dupe(u8, name);
    }

    pub fn setError(self: *BuildNode, msg: []const u8) !void {
        if (self.error_msg) |em| self.allocator.free(em);
        self.error_msg = try self.allocator.dupe(u8, msg);
        self.state = .failed;
    }

    pub fn isReady(self: *const BuildNode, graph: *const BuildGraph) bool {
        if (self.state != .pending) return false;
        for (self.dependencies) |dep_id| {
            if (graph.get(dep_id)) |dep| {
                if (dep.state != .completed and dep.state != .skipped) {
                    return false;
                }
            }
        }
        return true;
    }
};

/// The build dependency graph.
pub const BuildGraph = struct {
    /// All nodes in the graph
    nodes: std.AutoHashMap(u64, BuildNode),
    /// Module name to node ID mapping (for C++ module dependency resolution)
    module_providers: std.StringHashMap(u64),
    /// Root nodes (no dependents)
    roots: std.ArrayList(u64),
    /// Leaf nodes (no dependencies)
    leaves: std.ArrayList(u64),
    /// Next node ID
    next_id: u64,
    /// Total nodes
    total_nodes: u64,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BuildGraph {
        return .{
            .nodes = std.AutoHashMap(u64, BuildNode).init(allocator),
            .module_providers = std.StringHashMap(u64).init(allocator),
            .roots = .{},
            .leaves = .{},
            .next_id = 1,
            .total_nodes = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BuildGraph) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |node| {
            var n = node.*;
            n.deinit();
        }
        self.nodes.deinit();

        var mod_it = self.module_providers.keyIterator();
        while (mod_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.module_providers.deinit();

        self.roots.deinit(self.allocator);
        self.leaves.deinit(self.allocator);
        self.* = undefined;
    }

    /// Add a new node to the graph.
    pub fn addNode(self: *BuildGraph, name: []const u8, kind: NodeKind) !u64 {
        const id = self.next_id;
        self.next_id += 1;
        self.total_nodes += 1;

        var node = try BuildNode.init(self.allocator, id, name, kind);
        errdefer node.deinit();

        try self.nodes.put(id, node);
        try self.leaves.append(self.allocator, id);
        try self.roots.append(self.allocator, id);

        return id;
    }

    /// Get a node by ID.
    pub fn get(self: *const BuildGraph, id: u64) ?*const BuildNode {
        return self.nodes.getPtr(id);
    }

    /// Get a mutable node by ID.
    pub fn getMut(self: *BuildGraph, id: u64) ?*BuildNode {
        return self.nodes.getPtr(id);
    }

    /// Add a dependency edge: `dependent` depends on `dependency`.
    pub fn addEdge(self: *BuildGraph, dependent: u64, dependency: u64) !void {
        var dep_node = self.getMut(dependent) orelse return error.NodeNotFound;
        var dependency_node = self.getMut(dependency) orelse return error.NodeNotFound;

        // Update dependent's dependencies
        var deps_list: std.ArrayList(u64) = .{};
        defer deps_list.deinit(self.allocator);
        try deps_list.appendSlice(self.allocator, dep_node.dependencies);
        try deps_list.append(self.allocator, dependency);

        if (dep_node.dependencies.len > 0) {
            self.allocator.free(dep_node.dependencies);
        }
        dep_node.dependencies = try deps_list.toOwnedSlice(self.allocator);

        // Update dependency's dependents
        try dependency_node.addDependent(dependent);

        // Update roots/leaves
        self.removeFromLeaves(dependent);
        self.removeFromRoots(dependency);
    }

    fn removeFromLeaves(self: *BuildGraph, id: u64) void {
        for (self.leaves.items, 0..) |leaf, i| {
            if (leaf == id) {
                _ = self.leaves.swapRemove(i);
                return;
            }
        }
    }

    fn removeFromRoots(self: *BuildGraph, id: u64) void {
        for (self.roots.items, 0..) |root, i| {
            if (root == id) {
                _ = self.roots.swapRemove(i);
                return;
            }
        }
    }

    /// Register a C++ module provider.
    pub fn registerModuleProvider(self: *BuildGraph, module_name: []const u8, node_id: u64) !void {
        const key = try self.allocator.dupe(u8, module_name);
        try self.module_providers.put(key, node_id);

        if (self.getMut(node_id)) |node| {
            try node.setModuleName(module_name);
        }
    }

    /// Find the node that provides a C++ module.
    pub fn findModuleProvider(self: *const BuildGraph, module_name: []const u8) ?u64 {
        return self.module_providers.get(module_name);
    }

    /// Resolve C++ module dependencies by adding edges.
    pub fn resolveModuleDependencies(self: *BuildGraph, node_id: u64, imported_modules: []const []const u8) !void {
        for (imported_modules) |module_name| {
            if (self.findModuleProvider(module_name)) |provider_id| {
                if (provider_id != node_id) {
                    try self.addEdge(node_id, provider_id);
                }
            }
        }
    }

    /// Check if the graph has cycles.
    pub fn hasCycle(self: *const BuildGraph) bool {
        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();
        var rec_stack = std.AutoHashMap(u64, void).init(self.allocator);
        defer rec_stack.deinit();

        var it = self.nodes.keyIterator();
        while (it.next()) |id| {
            if (self.hasCycleDfs(id.*, &visited, &rec_stack)) {
                return true;
            }
        }
        return false;
    }

    fn hasCycleDfs(
        self: *const BuildGraph,
        node_id: u64,
        visited: *std.AutoHashMap(u64, void),
        rec_stack: *std.AutoHashMap(u64, void),
    ) bool {
        if (rec_stack.contains(node_id)) return true;
        if (visited.contains(node_id)) return false;

        visited.put(node_id, {}) catch return false;
        rec_stack.put(node_id, {}) catch return false;

        if (self.get(node_id)) |node| {
            for (node.dependencies) |dep_id| {
                if (self.hasCycleDfs(dep_id, visited, rec_stack)) {
                    return true;
                }
            }
        }

        _ = rec_stack.remove(node_id);
        return false;
    }

    /// Get topological ordering of nodes (dependencies before dependents).
    pub fn topologicalOrder(self: *const BuildGraph) ![]u64 {
        var result = std.ArrayList(u64){};
        errdefer result.deinit(self.allocator);

        var in_degree = std.AutoHashMap(u64, usize).init(self.allocator);
        defer in_degree.deinit();

        // Calculate in-degrees
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            try in_degree.put(entry.key_ptr.*, entry.value_ptr.dependencies.len);
        }

        // Start with nodes that have no dependencies
        var queue = std.ArrayList(u64){};
        defer queue.deinit(self.allocator);

        var deg_it = in_degree.iterator();
        while (deg_it.next()) |entry| {
            if (entry.value_ptr.* == 0) {
                try queue.append(self.allocator, entry.key_ptr.*);
            }
        }

        while (queue.items.len > 0) {
            const node_id = queue.orderedRemove(0);
            try result.append(self.allocator, node_id);

            if (self.get(node_id)) |node| {
                for (node.dependents) |dep_id| {
                    const deg_ptr = in_degree.getPtr(dep_id) orelse continue;
                    deg_ptr.* -= 1;
                    if (deg_ptr.* == 0) {
                        try queue.append(self.allocator, dep_id);
                    }
                }
            }
        }

        if (result.items.len != self.total_nodes) {
            return error.CycleDetected;
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Get all nodes that are ready to execute.
    pub fn getReadyNodes(self: *BuildGraph, out: *std.ArrayList(u64)) !void {
        out.clearRetainingCapacity();
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.isReady(self)) {
                try out.append(self.allocator, entry.key_ptr.*);
            }
        }
    }

    /// Mark a node as completed and update dependent states.
    pub fn markCompleted(self: *BuildGraph, node_id: u64) void {
        if (self.getMut(node_id)) |node| {
            node.state = .completed;
        }
    }

    /// Mark a node as failed.
    pub fn markFailed(self: *BuildGraph, node_id: u64, error_msg: []const u8) !void {
        if (self.getMut(node_id)) |node| {
            try node.setError(error_msg);
        }
    }

    /// Mark a node as skipped (cached).
    pub fn markSkipped(self: *BuildGraph, node_id: u64) void {
        if (self.getMut(node_id)) |node| {
            node.state = .skipped;
        }
    }

    /// Count nodes in each state.
    pub fn countByState(self: *const BuildGraph) StateCount {
        var count = StateCount{};
        var it = self.nodes.valueIterator();
        while (it.next()) |node| {
            switch (node.state) {
                .pending => count.pending += 1,
                .ready => count.ready += 1,
                .running => count.running += 1,
                .completed => count.completed += 1,
                .failed => count.failed += 1,
                .skipped => count.skipped += 1,
            }
        }
        return count;
    }

    pub const StateCount = struct {
        pending: u64 = 0,
        ready: u64 = 0,
        running: u64 = 0,
        completed: u64 = 0,
        failed: u64 = 0,
        skipped: u64 = 0,

        pub fn isDone(self: StateCount) bool {
            return self.pending == 0 and self.ready == 0 and self.running == 0;
        }

        pub fn hasFailed(self: StateCount) bool {
            return self.failed > 0;
        }
    };

    /// Reset all nodes to pending state.
    pub fn reset(self: *BuildGraph) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |node| {
            node.state = .pending;
            node.execution_time_ns = 0;
            if (node.error_msg) |em| {
                node.allocator.free(em);
                node.error_msg = null;
            }
        }
    }

    /// Get total execution time.
    pub fn totalExecutionTime(self: *const BuildGraph) u64 {
        var total: u64 = 0;
        var it = self.nodes.valueIterator();
        while (it.next()) |node| {
            total += node.execution_time_ns;
        }
        return total;
    }
};

/// Builder for constructing compilation graphs from source files.
pub const GraphBuilder = struct {
    graph: *BuildGraph,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, graph: *BuildGraph) GraphBuilder {
        return .{
            .graph = graph,
            .allocator = allocator,
        };
    }

    /// Add a compilation node for a source file.
    pub fn addCompileNode(
        self: *GraphBuilder,
        source_file: []const u8,
        output_file: []const u8,
        compiler_args: []const []const u8,
    ) !u64 {
        const name = try std.fmt.allocPrint(self.allocator, "compile:{s}", .{source_file});
        defer self.allocator.free(name);

        const id = try self.graph.addNode(name, .compile);
        var node = self.graph.getMut(id).?;

        try node.setInputs(&.{source_file});
        try node.setOutputs(&.{output_file});
        try node.setCommandArgs(compiler_args);

        return id;
    }

    /// Add a C++ module compilation node.
    pub fn addModuleCompileNode(
        self: *GraphBuilder,
        module_name: []const u8,
        source_file: []const u8,
        bmi_file: []const u8,
        object_file: []const u8,
        compiler_args: []const []const u8,
    ) !u64 {
        const name = try std.fmt.allocPrint(self.allocator, "module:{s}", .{module_name});
        defer self.allocator.free(name);

        const id = try self.graph.addNode(name, .compile_module);
        var node = self.graph.getMut(id).?;

        try node.setInputs(&.{source_file});
        try node.setOutputs(&.{ bmi_file, object_file });
        try node.setCommandArgs(compiler_args);
        try node.setModuleName(module_name);

        try self.graph.registerModuleProvider(module_name, id);

        return id;
    }

    /// Add a link node.
    pub fn addLinkNode(
        self: *GraphBuilder,
        output_name: []const u8,
        output_file: []const u8,
        object_files: []const []const u8,
        linker_args: []const []const u8,
    ) !u64 {
        const name = try std.fmt.allocPrint(self.allocator, "link:{s}", .{output_name});
        defer self.allocator.free(name);

        const id = try self.graph.addNode(name, .link);
        var node = self.graph.getMut(id).?;

        try node.setInputs(object_files);
        try node.setOutputs(&.{output_file});
        try node.setCommandArgs(linker_args);

        return id;
    }

    /// Add an install node.
    pub fn addInstallNode(
        self: *GraphBuilder,
        source_file: []const u8,
        dest_file: []const u8,
    ) !u64 {
        const name = try std.fmt.allocPrint(self.allocator, "install:{s}", .{dest_file});
        defer self.allocator.free(name);

        const id = try self.graph.addNode(name, .install);
        var node = self.graph.getMut(id).?;

        try node.setInputs(&.{source_file});
        try node.setOutputs(&.{dest_file});

        return id;
    }
};

// Tests
test "build graph basic operations" {
    const allocator = std.testing.allocator;
    var graph = BuildGraph.init(allocator);
    defer graph.deinit();

    const id1 = try graph.addNode("compile:foo.c", .compile);
    const id2 = try graph.addNode("compile:bar.c", .compile);
    const id3 = try graph.addNode("link:app", .link);

    try graph.addEdge(id3, id1);
    try graph.addEdge(id3, id2);

    try std.testing.expect(!graph.hasCycle());

    const order = try graph.topologicalOrder();
    defer allocator.free(order);

    // Link should come after both compiles
    var link_idx: usize = 0;
    var foo_idx: usize = 0;
    var bar_idx: usize = 0;
    for (order, 0..) |id, i| {
        if (id == id3) link_idx = i;
        if (id == id1) foo_idx = i;
        if (id == id2) bar_idx = i;
    }

    try std.testing.expect(link_idx > foo_idx);
    try std.testing.expect(link_idx > bar_idx);
}

test "build graph cycle detection" {
    const allocator = std.testing.allocator;
    var graph = BuildGraph.init(allocator);
    defer graph.deinit();

    const id1 = try graph.addNode("a", .compile);
    const id2 = try graph.addNode("b", .compile);

    try graph.addEdge(id2, id1);
    try std.testing.expect(!graph.hasCycle());

    // Create cycle: a -> b -> a
    try graph.addEdge(id1, id2);
    try std.testing.expect(graph.hasCycle());
}

test "module dependency resolution" {
    const allocator = std.testing.allocator;
    var graph = BuildGraph.init(allocator);
    defer graph.deinit();

    var builder = GraphBuilder.init(allocator, &graph);

    // Module interface unit
    const mod_id = try builder.addModuleCompileNode(
        "mymodule",
        "mymodule.cppm",
        "mymodule.pcm",
        "mymodule.o",
        &.{},
    );

    // Consumer
    const consumer_id = try builder.addCompileNode(
        "main.cpp",
        "main.o",
        &.{},
    );

    // Resolve module dependency
    try graph.resolveModuleDependencies(consumer_id, &.{"mymodule"});

    const order = try graph.topologicalOrder();
    defer allocator.free(order);

    // Module should come before consumer
    var mod_idx: usize = 0;
    var consumer_idx: usize = 0;
    for (order, 0..) |id, i| {
        if (id == mod_id) mod_idx = i;
        if (id == consumer_id) consumer_idx = i;
    }

    try std.testing.expect(mod_idx < consumer_idx);
}

test "ready nodes detection" {
    const allocator = std.testing.allocator;
    var graph = BuildGraph.init(allocator);
    defer graph.deinit();

    const id1 = try graph.addNode("a", .compile);
    const id2 = try graph.addNode("b", .compile);
    const id3 = try graph.addNode("c", .link);

    try graph.addEdge(id3, id1);
    try graph.addEdge(id3, id2);

    var ready: std.ArrayList(u64) = .{};
    defer ready.deinit(allocator);

    try graph.getReadyNodes(&ready);
    // a and b should be ready
    try std.testing.expect(ready.items.len == 2);

    // Complete a
    graph.markCompleted(id1);

    try graph.getReadyNodes(&ready);
    // Only b should be ready now
    try std.testing.expect(ready.items.len == 1);

    // Complete b
    graph.markCompleted(id2);

    try graph.getReadyNodes(&ready);
    // c should be ready now
    try std.testing.expect(ready.items.len == 1);
    try std.testing.expect(ready.items[0] == id3);
}
