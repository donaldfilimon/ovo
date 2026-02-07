//! Process spawning and management utilities for ovo package manager.
//! Provides subprocess execution, output capture, and pipe handling.
//! Uses Zig's std.process.Child which is the safe equivalent of execFile.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ChildProcess = std.process.Child;

/// Error types for process operations.
pub const ProcessError = error{
    SpawnFailed,
    Timeout,
    SignalInterrupt,
    PipeFailed,
    InvalidArgument,
    OutOfMemory,
} || std.process.Child.SpawnError;

/// Result of a completed process.
pub const ProcessResult = struct {
    /// Exit code (0 typically means success).
    exit_code: u8,
    /// Standard output contents.
    stdout: []const u8,
    /// Standard error contents.
    stderr: []const u8,
    /// Whether the process was terminated by a signal.
    signal: ?u32,
    /// Allocator used for stdout/stderr.
    allocator: Allocator,

    pub fn deinit(self: *ProcessResult) void {
        if (self.stdout.len > 0) self.allocator.free(self.stdout);
        if (self.stderr.len > 0) self.allocator.free(self.stderr);
    }

    /// Check if process succeeded (exit code 0).
    pub fn success(self: ProcessResult) bool {
        return self.exit_code == 0 and self.signal == null;
    }
};

/// Options for process execution.
pub const ProcessOptions = struct {
    /// Working directory for the process.
    cwd: ?[]const u8 = null,
    /// Environment variables (null means inherit).
    env: ?*const std.StringHashMap([]const u8) = null,
    /// Maximum time to wait in milliseconds (0 = no timeout).
    timeout_ms: u64 = 0,
    /// Maximum stdout buffer size.
    max_stdout: usize = 10 * 1024 * 1024, // 10 MB
    /// Maximum stderr buffer size.
    max_stderr: usize = 10 * 1024 * 1024, // 10 MB
    /// Stdin data to feed to the process.
    stdin_data: ?[]const u8 = null,
};

/// Execute a command and capture its output.
/// Uses std.process.Child which directly executes the program without shell interpolation,
/// preventing command injection vulnerabilities (equivalent to execFile in Node.js).
pub fn run(
    allocator: Allocator,
    argv: []const []const u8,
    options: ProcessOptions,
) !ProcessResult {
    if (argv.len == 0) {
        return ProcessError.InvalidArgument;
    }

    var child = ChildProcess.init(argv, allocator);
    child.cwd = options.cwd;

    // Set up environment
    if (options.env) |env| {
        child.env_map = env.*;
    }

    // Configure pipes
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.stdin_behavior = if (options.stdin_data != null) .Pipe else .Inherit;

    try child.spawn();
    errdefer _ = child.kill() catch {};

    // Write stdin if provided
    if (options.stdin_data) |data| {
        if (child.stdin) |stdin| {
            stdin.writeAll(data) catch {};
            stdin.close();
            child.stdin = null;
        }
    }

    // Read stdout and stderr
    var stdout_list: std.ArrayList(u8) = .empty;
    defer stdout_list.deinit(allocator);
    var stderr_list: std.ArrayList(u8) = .empty;
    defer stderr_list.deinit(allocator);

    // Use collectOutput for simpler handling
    child.collectOutput(allocator, &stdout_list, &stderr_list, options.max_stdout, options.max_stderr);

    const term = try child.wait();

    const stdout = try stdout_list.toOwnedSlice(allocator);
    errdefer allocator.free(stdout);
    const stderr = try stderr_list.toOwnedSlice(allocator);

    return ProcessResult{
        .exit_code = switch (term) {
            .Exited => |code| code,
            else => 1,
        },
        .stdout = stdout,
        .stderr = stderr,
        .signal = switch (term) {
            .Signal => |sig| sig,
            else => null,
        },
        .allocator = allocator,
    };
}

/// Execute a shell command (via /bin/sh on Unix, cmd.exe on Windows).
/// WARNING: This function passes input to a shell interpreter.
/// Only use when shell features are required and input is trusted.
/// Prefer run() with explicit argv for user-provided input.
pub fn shell(
    allocator: Allocator,
    command: []const u8,
    options: ProcessOptions,
) !ProcessResult {
    const argv = if (@import("builtin").os.tag == .windows)
        &[_][]const u8{ "cmd.exe", "/c", command }
    else
        &[_][]const u8{ "/bin/sh", "-c", command };

    return run(allocator, argv, options);
}

/// Streaming output handler callback type.
pub const OutputHandler = *const fn (data: []const u8, is_stderr: bool, context: ?*anyopaque) void;

/// Execute a command with streaming output handling.
pub fn runStreaming(
    allocator: Allocator,
    argv: []const []const u8,
    options: ProcessOptions,
    handler: OutputHandler,
    context: ?*anyopaque,
) !u8 {
    if (argv.len == 0) {
        return ProcessError.InvalidArgument;
    }

    var child = ChildProcess.init(argv, allocator);
    child.cwd = options.cwd;

    if (options.env) |env| {
        child.env_map = env.*;
    }

    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.stdin_behavior = if (options.stdin_data != null) .Pipe else .Inherit;

    try child.spawn();
    errdefer _ = child.kill() catch {};

    // Write stdin if provided
    if (options.stdin_data) |data| {
        if (child.stdin) |stdin| {
            stdin.writeAll(data) catch {};
            stdin.close();
            child.stdin = null;
        }
    }

    var buf: [4096]u8 = undefined;

    // Read in a loop
    while (true) {
        var fds: [2]std.posix.pollfd = undefined;
        var nfds: usize = 0;

        if (child.stdout) |stdout| {
            fds[nfds] = .{
                .fd = stdout.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
            nfds += 1;
        }
        if (child.stderr) |stderr| {
            fds[nfds] = .{
                .fd = stderr.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
            nfds += 1;
        }

        if (nfds == 0) break;

        const poll_result = std.posix.poll(fds[0..nfds], 100);
        if (poll_result == 0) continue; // Timeout, retry

        for (fds[0..nfds]) |*fd| {
            if (fd.revents & std.posix.POLL.IN != 0) {
                const file = std.fs.File{ .handle = fd.fd };
                const n = file.read(&buf) catch 0;
                if (n > 0) {
                    const is_stderr = child.stderr != null and fd.fd == child.stderr.?.handle;
                    handler(buf[0..n], is_stderr, context);
                }
            }
        }

        // Check if process has exited
        if (child.stdout == null and child.stderr == null) break;
    }

    const term = try child.wait();
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

/// Simple command execution that returns true on success.
pub fn exec(allocator: Allocator, argv: []const []const u8) !bool {
    var result = try run(allocator, argv, .{});
    defer result.deinit();
    return result.success();
}

/// Execute and return stdout as a string (trimmed).
pub fn execOutput(allocator: Allocator, argv: []const []const u8) ![]u8 {
    var result = try run(allocator, argv, .{});
    defer {
        allocator.free(result.stderr);
    }

    // Trim trailing whitespace
    var end = result.stdout.len;
    while (end > 0 and std.ascii.isWhitespace(result.stdout[end - 1])) {
        end -= 1;
    }

    if (end == result.stdout.len) {
        return result.stdout;
    }

    const trimmed = try allocator.dupe(u8, result.stdout[0..end]);
    allocator.free(result.stdout);
    return trimmed;
}

/// Get the path to an executable in PATH.
pub fn which(allocator: Allocator, name: []const u8) !?[]u8 {
    const path_env = std.posix.getenv("PATH") orelse return null;
    var path_iter = std.mem.splitScalar(u8, path_env, ':');

    while (path_iter.next()) |dir| {
        const full_path = try std.fs.path.join(allocator, &.{ dir, name });
        defer allocator.free(full_path);

        const stat = std.fs.cwd().statFile(full_path) catch continue;
        if (stat.kind == .file) {
            // Check if executable
            const file = std.fs.cwd().openFile(full_path, .{}) catch continue;
            defer file.close();
            const md = file.metadata() catch continue;
            const perms = md.permissions();
            if (perms.inner.unixHas(.user, .execute)) {
                return allocator.dupe(u8, full_path);
            }
        }
    }

    return null;
}

/// Builder for complex process invocations.
pub const ProcessBuilder = struct {
    allocator: Allocator,
    argv: std.ArrayList([]const u8),
    options: ProcessOptions,

    pub fn init(allocator: Allocator) ProcessBuilder {
        return .{
            .allocator = allocator,
            .argv = .empty,
            .options = .{},
        };
    }

    pub fn deinit(self: *ProcessBuilder) void {
        for (self.argv.items) |item| {
            self.allocator.free(item);
        }
        self.argv.deinit(self.allocator);
    }

    pub fn arg(self: *ProcessBuilder, value: []const u8) !*ProcessBuilder {
        try self.argv.append(self.allocator, try self.allocator.dupe(u8, value));
        return self;
    }

    pub fn args(self: *ProcessBuilder, values: []const []const u8) !*ProcessBuilder {
        for (values) |v| {
            _ = try self.arg(v);
        }
        return self;
    }

    pub fn cwd(self: *ProcessBuilder, dir: []const u8) *ProcessBuilder {
        self.options.cwd = dir;
        return self;
    }

    pub fn timeout(self: *ProcessBuilder, ms: u64) *ProcessBuilder {
        self.options.timeout_ms = ms;
        return self;
    }

    pub fn stdin(self: *ProcessBuilder, data: []const u8) *ProcessBuilder {
        self.options.stdin_data = data;
        return self;
    }

    pub fn run(self: *ProcessBuilder) !ProcessResult {
        return process.run(self.allocator, self.argv.items, self.options);
    }

    pub fn exec(self: *ProcessBuilder) !bool {
        var result = try self.run();
        defer result.deinit();
        return result.success();
    }
};

const process = @This();

test "exec simple command" {
    const allocator = std.testing.allocator;
    const success_result = try exec(allocator, &.{"true"});
    try std.testing.expect(success_result);
}

test "execOutput" {
    const allocator = std.testing.allocator;
    const output = try execOutput(allocator, &.{ "echo", "hello" });
    defer allocator.free(output);
    try std.testing.expectEqualStrings("hello", output);
}
