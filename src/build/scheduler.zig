//! Simplified task execution scheduler for the ovo build system.
//! Single-threaded implementation for Zig 0.16 compatibility.
const std = @import("std");
const graph = @import("graph.zig");

/// Task execution result.
pub const TaskResult = struct {
    node_id: u64,
    success: bool,
    error_msg: ?[]const u8,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: ?u32,
    execution_time_ns: u64,

    pub fn deinit(self: *TaskResult, allocator: std.mem.Allocator) void {
        if (self.error_msg) |msg| allocator.free(msg);
        if (self.stdout.len > 0) allocator.free(self.stdout);
        if (self.stderr.len > 0) allocator.free(self.stderr);
        self.* = undefined;
    }
};

/// Progress callback for reporting build progress.
pub const ProgressCallback = *const fn (info: ProgressInfo) void;

/// Information about build progress.
pub const ProgressInfo = struct {
    /// Total number of tasks
    total: u64,
    /// Number of completed tasks
    completed: u64,
    /// Number of currently running tasks
    running: u64,
    /// Number of skipped tasks (cached)
    skipped: u64,
    /// Number of failed tasks
    failed: u64,
    /// Currently executing task name (if single)
    current_task: ?[]const u8,
    /// Elapsed time in nanoseconds
    elapsed_ns: u64,
};

/// Configuration for the scheduler.
pub const SchedulerConfig = struct {
    /// Maximum number of parallel jobs (0 = auto-detect, ignored in sequential mode)
    max_jobs: u32 = 0,
    /// Keep going on errors
    keep_going: bool = false,
    /// Verbose output
    verbose: bool = false,
    /// Dry run (don't execute, just report)
    dry_run: bool = false,
    /// Progress callback
    progress_callback: ?ProgressCallback = null,
    /// Stop on first failure
    stop_on_failure: bool = true,

    pub fn getEffectiveJobCount(_: SchedulerConfig) u32 {
        // Always return 1 for sequential execution
        return 1;
    }
};

/// A task to be executed by the scheduler.
pub const Task = struct {
    node_id: u64,
    command_args: []const []const u8,
    working_dir: ?[]const u8,
    env: ?std.StringHashMap([]const u8),
};

/// Simple task queue (non-thread-safe since we're sequential).
const TaskQueue = struct {
    tasks: std.ArrayList(Task),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) TaskQueue {
        return .{
            .tasks = .{},
            .allocator = allocator,
        };
    }

    fn deinit(self: *TaskQueue) void {
        self.tasks.deinit(self.allocator);
    }

    fn push(self: *TaskQueue, task: Task) !void {
        try self.tasks.append(self.allocator, task);
    }

    fn pop(self: *TaskQueue) ?Task {
        if (self.tasks.items.len == 0) return null;
        return self.tasks.orderedRemove(0);
    }
};

/// Simplified sequential task scheduler.
pub const Scheduler = struct {
    config: SchedulerConfig,
    build_graph: *graph.BuildGraph,
    task_queue: TaskQueue,
    allocator: std.mem.Allocator,

    /// Statistics
    stats: SchedulerStats,
    start_time: u64,

    pub const SchedulerStats = struct {
        total_tasks: u64 = 0,
        completed_tasks: u64 = 0,
        failed_tasks: u64 = 0,
        skipped_tasks: u64 = 0,
        total_execution_time_ns: u64 = 0,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        build_graph: *graph.BuildGraph,
        config: SchedulerConfig,
    ) !Scheduler {
        return .{
            .config = config,
            .build_graph = build_graph,
            .task_queue = TaskQueue.init(allocator),
            .allocator = allocator,
            .stats = .{},
            .start_time = 0,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.task_queue.deinit();
        self.* = undefined;
    }

    /// Execute all tasks in the build graph sequentially.
    pub fn execute(self: *Scheduler) !SchedulerStats {
        self.start_time = 0; // Timing stubbed for Zig 0.16
        self.stats = .{};
        self.stats.total_tasks = self.build_graph.total_nodes;

        if (self.config.dry_run) {
            return self.executeDryRun();
        }

        // Get topological order
        const order = try self.build_graph.topologicalOrder();
        defer self.allocator.free(order);

        for (order) |node_id| {
            const node = self.build_graph.get(node_id) orelse continue;

            if (self.config.verbose) {
                std.debug.print("{s}: {s}\n", .{ node.kind.description(), node.name });
            }

            // Update progress
            self.reportProgress(node_id);

            if (node.command_args.len == 0) {
                // No command - just mark as success
                self.build_graph.markCompleted(node_id);
                self.stats.completed_tasks += 1;
                continue;
            }

            // Execute the command using system() for simplicity
            const result = self.executeCommand(node.command_args, node.working_dir);

            if (result.success) {
                self.build_graph.markCompleted(node_id);
                self.stats.completed_tasks += 1;
            } else {
                try self.build_graph.markFailed(node_id, result.error_msg orelse "Command failed");
                self.stats.failed_tasks += 1;

                if (self.config.stop_on_failure) {
                    break;
                }
            }
        }

        return self.stats;
    }

    fn executeDryRun(self: *Scheduler) !SchedulerStats {
        const order = try self.build_graph.topologicalOrder();
        defer self.allocator.free(order);

        for (order) |node_id| {
            if (self.build_graph.get(node_id)) |node| {
                self.build_graph.markCompleted(node_id);
                self.stats.completed_tasks += 1;
                self.reportProgress(node_id);

                if (self.config.verbose) {
                    std.debug.print("[dry-run] {s}: {s}\n", .{ node.kind.description(), node.name });
                }
            }
        }

        return self.stats;
    }

    fn executeCommand(_: *Scheduler, args: []const []const u8, _: ?[]const u8) TaskResult {
        if (args.len == 0) {
            return .{
                .node_id = 0,
                .success = true,
                .error_msg = null,
                .stdout = &.{},
                .stderr = &.{},
                .exit_code = 0,
                .execution_time_ns = 0,
            };
        }

        // Build command string
        var cmd_buf: [8192]u8 = undefined;
        var cmd_len: usize = 0;

        for (args) |arg| {
            if (cmd_len > 0) {
                if (cmd_len < cmd_buf.len) {
                    cmd_buf[cmd_len] = ' ';
                    cmd_len += 1;
                }
            }
            for (arg) |c| {
                if (cmd_len < cmd_buf.len) {
                    cmd_buf[cmd_len] = c;
                    cmd_len += 1;
                }
            }
        }

        // Null-terminate
        if (cmd_len < cmd_buf.len) {
            cmd_buf[cmd_len] = 0;
        } else {
            cmd_buf[cmd_buf.len - 1] = 0;
        }

        // Use fork/exec pattern via extern C function
        const ret = cSystem(@ptrCast(&cmd_buf));

        return .{
            .node_id = 0,
            .success = ret == 0,
            .error_msg = if (ret != 0) "Command failed" else null,
            .stdout = &.{},
            .stderr = &.{},
            .exit_code = @intCast(@as(u32, @bitCast(ret))),
            .execution_time_ns = 0,
        };
    }

    // External C library function for command execution
    extern "c" fn system(command: [*:0]const u8) c_int;

    fn cSystem(cmd: [*:0]const u8) c_int {
        return system(cmd);
    }

    fn reportProgress(self: *Scheduler, current_node_id: u64) void {
        if (self.config.progress_callback) |callback| {
            const current_name: ?[]const u8 = if (self.build_graph.get(current_node_id)) |n| n.name else null;

            callback(.{
                .total = self.stats.total_tasks,
                .completed = self.stats.completed_tasks,
                .running = 1,
                .skipped = self.stats.skipped_tasks,
                .failed = self.stats.failed_tasks,
                .current_task = current_name,
                .elapsed_ns = 0,
            });
        }
    }

    /// Skip a task (mark as cached).
    pub fn skipTask(self: *Scheduler, node_id: u64) void {
        self.build_graph.markSkipped(node_id);
        self.stats.skipped_tasks += 1;
        self.reportProgress(node_id);
    }

    /// Get current statistics.
    pub fn getStats(self: *const Scheduler) SchedulerStats {
        return self.stats;
    }

    /// Cancel all pending tasks.
    pub fn cancel(_: *Scheduler) void {
        // No-op for sequential scheduler
    }
};

/// Simple progress reporter that prints to stderr.
pub fn defaultProgressCallback(info: ProgressInfo) void {
    const percent = if (info.total > 0)
        @as(f64, @floatFromInt(info.completed + info.skipped)) / @as(f64, @floatFromInt(info.total)) * 100.0
    else
        0.0;

    if (info.current_task) |task| {
        std.debug.print("\r[{d:3.0}%] ({d}/{d}) {s}                    ", .{
            percent,
            info.completed + info.skipped,
            info.total,
            task,
        });
    } else {
        std.debug.print("\r[{d:3.0}%] ({d}/{d})          ", .{
            percent,
            info.completed + info.skipped,
            info.total,
        });
    }
}

/// Alias for backwards compatibility
pub const SequentialExecutor = Scheduler;

// Tests
test "scheduler config defaults" {
    const config = SchedulerConfig{};
    const jobs = config.getEffectiveJobCount();
    try std.testing.expect(jobs == 1);
}

test "task queue operations" {
    const allocator = std.testing.allocator;
    var queue = TaskQueue.init(allocator);
    defer queue.deinit();

    try queue.push(.{
        .node_id = 1,
        .command_args = &.{},
        .working_dir = null,
        .env = null,
    });

    const task = queue.pop();
    try std.testing.expect(task != null);
    try std.testing.expect(task.?.node_id == 1);
}

test "progress info calculation" {
    const info = ProgressInfo{
        .total = 100,
        .completed = 50,
        .running = 5,
        .skipped = 10,
        .failed = 0,
        .current_task = "test",
        .elapsed_ns = 1_000_000_000,
    };

    const percent = @as(f64, @floatFromInt(info.completed + info.skipped)) /
        @as(f64, @floatFromInt(info.total)) * 100.0;
    try std.testing.expectApproxEqAbs(@as(f64, 60.0), percent, 0.001);
}
