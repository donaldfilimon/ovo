//! Parallel task execution scheduler for the ovo build system.
//! Implements a thread pool that respects dependency ordering from the build graph.
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
    /// Maximum number of parallel jobs (0 = auto-detect)
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

    pub fn getEffectiveJobCount(self: SchedulerConfig) u32 {
        if (self.max_jobs == 0) {
            return @intCast(std.Thread.getCpuCount() catch 4);
        }
        return self.max_jobs;
    }
};

/// A task to be executed by the scheduler.
pub const Task = struct {
    node_id: u64,
    command_args: []const []const u8,
    working_dir: ?[]const u8,
    env: ?std.process.EnvMap,
};

/// Thread-safe task queue.
const TaskQueue = struct {
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    tasks: std.ArrayList(Task),
    shutdown: bool,

    fn init(allocator: std.mem.Allocator) TaskQueue {
        return .{
            .mutex = .{},
            .condition = .{},
            .tasks = std.ArrayList(Task).init(allocator),
            .shutdown = false,
        };
    }

    fn deinit(self: *TaskQueue) void {
        self.tasks.deinit();
    }

    fn push(self: *TaskQueue, task: Task) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.tasks.append(task);
        self.condition.signal();
    }

    fn pop(self: *TaskQueue) ?Task {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.tasks.items.len == 0 and !self.shutdown) {
            self.condition.wait(&self.mutex);
        }

        if (self.shutdown and self.tasks.items.len == 0) {
            return null;
        }

        return self.tasks.orderedRemove(0);
    }

    fn signalShutdown(self: *TaskQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.shutdown = true;
        self.condition.broadcast();
    }
};

/// Thread-safe result queue.
const ResultQueue = struct {
    mutex: std.Thread.Mutex,
    results: std.ArrayList(TaskResult),

    fn init(allocator: std.mem.Allocator) ResultQueue {
        return .{
            .mutex = .{},
            .results = std.ArrayList(TaskResult).init(allocator),
        };
    }

    fn deinit(self: *ResultQueue) void {
        self.results.deinit();
    }

    fn push(self: *ResultQueue, result: TaskResult) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.results.append(result);
    }

    fn popAll(self: *ResultQueue, out: *std.ArrayList(TaskResult)) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try out.appendSlice(self.results.items);
        self.results.clearRetainingCapacity();
    }
};

/// Parallel task scheduler with thread pool.
pub const Scheduler = struct {
    config: SchedulerConfig,
    build_graph: *graph.BuildGraph,
    task_queue: TaskQueue,
    result_queue: ResultQueue,
    workers: []std.Thread,
    allocator: std.mem.Allocator,

    /// Statistics
    stats: SchedulerStats,
    start_time: i128,

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
        const job_count = config.getEffectiveJobCount();
        const workers = try allocator.alloc(std.Thread, job_count);

        return .{
            .config = config,
            .build_graph = build_graph,
            .task_queue = TaskQueue.init(allocator),
            .result_queue = ResultQueue.init(allocator),
            .workers = workers,
            .allocator = allocator,
            .stats = .{},
            .start_time = 0,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.task_queue.deinit();
        self.result_queue.deinit();
        self.allocator.free(self.workers);
        self.* = undefined;
    }

    /// Execute all tasks in the build graph.
    pub fn execute(self: *Scheduler) !SchedulerStats {
        self.start_time = std.time.nanoTimestamp();
        self.stats = .{};
        self.stats.total_tasks = self.build_graph.total_nodes;

        if (self.config.dry_run) {
            return self.executeDryRun();
        }

        // Start worker threads
        for (self.workers, 0..) |*worker, i| {
            worker.* = try std.Thread.spawn(.{}, workerThread, .{ self, i });
        }

        // Main scheduling loop
        var results = std.ArrayList(TaskResult).init(self.allocator);
        defer results.deinit();

        var ready_nodes = std.ArrayList(u64).init(self.allocator);
        defer ready_nodes.deinit();

        var running_count: u64 = 0;
        var should_stop = false;

        while (!should_stop) {
            // Check for completed tasks
            try self.result_queue.popAll(&results);
            for (results.items) |*result| {
                running_count -= 1;
                self.stats.total_execution_time_ns += result.execution_time_ns;

                if (result.success) {
                    self.build_graph.markCompleted(result.node_id);
                    self.stats.completed_tasks += 1;
                } else {
                    try self.build_graph.markFailed(result.node_id, result.error_msg orelse "Unknown error");
                    self.stats.failed_tasks += 1;

                    if (self.config.stop_on_failure) {
                        should_stop = true;
                    }
                }

                // Update progress
                self.reportProgress(result.node_id);

                result.deinit(self.allocator);
            }
            results.clearRetainingCapacity();

            if (should_stop) break;

            // Find ready tasks
            try self.build_graph.getReadyNodes(&ready_nodes);

            // Queue ready tasks
            for (ready_nodes.items) |node_id| {
                if (self.build_graph.getMut(node_id)) |node| {
                    node.state = .running;
                    running_count += 1;

                    try self.task_queue.push(.{
                        .node_id = node_id,
                        .command_args = node.command_args,
                        .working_dir = node.working_dir,
                        .env = null,
                    });
                }
            }

            // Check if done
            const state_count = self.build_graph.countByState();
            if (state_count.isDone()) {
                break;
            }

            // Wait a bit before checking again
            if (running_count > 0 and ready_nodes.items.len == 0) {
                std.time.sleep(1_000_000); // 1ms
            }
        }

        // Shutdown workers
        self.task_queue.signalShutdown();
        for (self.workers) |worker| {
            worker.join();
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

    fn workerThread(self: *Scheduler, worker_id: usize) void {
        _ = worker_id;

        while (true) {
            const task = self.task_queue.pop() orelse break;

            const result = self.executeTask(task);

            self.result_queue.push(result) catch {
                // Log error but continue
            };
        }
    }

    fn executeTask(self: *Scheduler, task: Task) TaskResult {
        const start = std.time.nanoTimestamp();

        if (task.command_args.len == 0) {
            // Empty command - just mark as success
            return .{
                .node_id = task.node_id,
                .success = true,
                .error_msg = null,
                .stdout = &.{},
                .stderr = &.{},
                .exit_code = 0,
                .execution_time_ns = @intCast(std.time.nanoTimestamp() - start),
            };
        }

        // Execute the command
        var child = std.process.Child.init(task.command_args, self.allocator);

        if (task.working_dir) |wd| {
            child.cwd = wd;
        }

        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        const spawn_result = child.spawn();
        if (spawn_result) |_| {
            // Successfully spawned
        } else |err| {
            const error_msg = std.fmt.allocPrint(self.allocator, "Failed to spawn process: {}", .{err}) catch null;
            return .{
                .node_id = task.node_id,
                .success = false,
                .error_msg = error_msg,
                .stdout = &.{},
                .stderr = &.{},
                .exit_code = null,
                .execution_time_ns = @intCast(std.time.nanoTimestamp() - start),
            };
        }

        // Collect output
        var stdout_buf: [65536]u8 = undefined;
        var stderr_buf: [65536]u8 = undefined;
        var stdout_len: usize = 0;
        var stderr_len: usize = 0;

        if (child.stdout) |stdout| {
            stdout_len = stdout.read(&stdout_buf) catch 0;
        }
        if (child.stderr) |stderr| {
            stderr_len = stderr.read(&stderr_buf) catch 0;
        }

        const term = child.wait() catch |err| {
            const error_msg = std.fmt.allocPrint(self.allocator, "Failed to wait for process: {}", .{err}) catch null;
            return .{
                .node_id = task.node_id,
                .success = false,
                .error_msg = error_msg,
                .stdout = &.{},
                .stderr = &.{},
                .exit_code = null,
                .execution_time_ns = @intCast(std.time.nanoTimestamp() - start),
            };
        };

        const success = term.Exited == 0;
        const stdout = self.allocator.dupe(u8, stdout_buf[0..stdout_len]) catch &.{};
        const stderr = self.allocator.dupe(u8, stderr_buf[0..stderr_len]) catch &.{};

        const error_msg: ?[]const u8 = if (!success)
            self.allocator.dupe(u8, stderr) catch null
        else
            null;

        return .{
            .node_id = task.node_id,
            .success = success,
            .error_msg = error_msg,
            .stdout = stdout,
            .stderr = stderr,
            .exit_code = @intCast(term.Exited),
            .execution_time_ns = @intCast(std.time.nanoTimestamp() - start),
        };
    }

    fn reportProgress(self: *Scheduler, current_node_id: u64) void {
        if (self.config.progress_callback) |callback| {
            const elapsed = std.time.nanoTimestamp() - self.start_time;
            const current_name: ?[]const u8 = if (self.build_graph.get(current_node_id)) |n| n.name else null;

            callback(.{
                .total = self.stats.total_tasks,
                .completed = self.stats.completed_tasks,
                .running = self.build_graph.countByState().running,
                .skipped = self.stats.skipped_tasks,
                .failed = self.stats.failed_tasks,
                .current_task = current_name,
                .elapsed_ns = @intCast(elapsed),
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
    pub fn cancel(self: *Scheduler) void {
        self.task_queue.signalShutdown();
    }
};

/// Simple progress reporter that prints to stderr.
pub fn defaultProgressCallback(info: ProgressInfo) void {
    const percent = if (info.total > 0)
        @as(f64, @floatFromInt(info.completed + info.skipped)) / @as(f64, @floatFromInt(info.total)) * 100.0
    else
        0.0;

    const elapsed_ms = info.elapsed_ns / 1_000_000;

    if (info.current_task) |task| {
        std.debug.print("\r[{d:3.0}%] ({d}/{d}) {s}                    ", .{
            percent,
            info.completed + info.skipped,
            info.total,
            task,
        });
    } else {
        std.debug.print("\r[{d:3.0}%] ({d}/{d}) Elapsed: {d}ms          ", .{
            percent,
            info.completed + info.skipped,
            info.total,
            elapsed_ms,
        });
    }
}

/// A simpler single-threaded executor for testing or when parallelism isn't needed.
pub const SequentialExecutor = struct {
    build_graph: *graph.BuildGraph,
    allocator: std.mem.Allocator,
    verbose: bool,

    pub fn init(allocator: std.mem.Allocator, build_graph: *graph.BuildGraph, verbose: bool) SequentialExecutor {
        return .{
            .build_graph = build_graph,
            .allocator = allocator,
            .verbose = verbose,
        };
    }

    pub fn execute(self: *SequentialExecutor) !Scheduler.SchedulerStats {
        var stats = Scheduler.SchedulerStats{};
        stats.total_tasks = self.build_graph.total_nodes;

        const order = try self.build_graph.topologicalOrder();
        defer self.allocator.free(order);

        for (order) |node_id| {
            const node = self.build_graph.get(node_id) orelse continue;

            if (self.verbose) {
                std.debug.print("{s}: {s}\n", .{ node.kind.description(), node.name });
            }

            if (node.command_args.len == 0) {
                self.build_graph.markCompleted(node_id);
                stats.completed_tasks += 1;
                continue;
            }

            // Execute command
            var child = std.process.Child.init(node.command_args, self.allocator);
            if (node.working_dir) |wd| {
                child.cwd = wd;
            }

            const term = child.spawnAndWait() catch |err| {
                try self.build_graph.markFailed(node_id, @errorName(err));
                stats.failed_tasks += 1;
                return stats;
            };

            if (term.Exited == 0) {
                self.build_graph.markCompleted(node_id);
                stats.completed_tasks += 1;
            } else {
                try self.build_graph.markFailed(node_id, "Non-zero exit code");
                stats.failed_tasks += 1;
                return stats;
            }
        }

        return stats;
    }
};

// Tests
test "scheduler config defaults" {
    const config = SchedulerConfig{};
    const jobs = config.getEffectiveJobCount();
    try std.testing.expect(jobs > 0);
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

test "result queue operations" {
    const allocator = std.testing.allocator;
    var queue = ResultQueue.init(allocator);
    defer queue.deinit();

    try queue.push(.{
        .node_id = 1,
        .success = true,
        .error_msg = null,
        .stdout = &.{},
        .stderr = &.{},
        .exit_code = 0,
        .execution_time_ns = 100,
    });

    var results = std.ArrayList(TaskResult).init(allocator);
    defer results.deinit();

    try queue.popAll(&results);
    try std.testing.expect(results.items.len == 1);
    try std.testing.expect(results.items[0].node_id == 1);
}

test "sequential executor" {
    const allocator = std.testing.allocator;
    var build_graph = graph.BuildGraph.init(allocator);
    defer build_graph.deinit();

    // Add some nodes with no commands (no-op)
    const id1 = try build_graph.addNode("task1", .compile);
    const id2 = try build_graph.addNode("task2", .compile);
    const id3 = try build_graph.addNode("task3", .link);

    try build_graph.addEdge(id3, id1);
    try build_graph.addEdge(id3, id2);

    var executor = SequentialExecutor.init(allocator, &build_graph, false);
    const stats = try executor.execute();

    try std.testing.expect(stats.total_tasks == 3);
    try std.testing.expect(stats.completed_tasks == 3);
    try std.testing.expect(stats.failed_tasks == 0);
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
