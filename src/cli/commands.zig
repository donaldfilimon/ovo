//! ovo CLI Command Dispatcher
//!
//! Parses command line arguments and routes to appropriate command handlers.

const std = @import("std");
const builtin = @import("builtin");

// Command modules
pub const build_cmd = @import("build_cmd.zig");
pub const run_cmd = @import("run_cmd.zig");
pub const test_cmd = @import("test_cmd.zig");
pub const new_cmd = @import("new_cmd.zig");
pub const init_cmd = @import("init_cmd.zig");
pub const add_cmd = @import("add_cmd.zig");
pub const remove_cmd = @import("remove_cmd.zig");
pub const fetch_cmd = @import("fetch_cmd.zig");
pub const clean_cmd = @import("clean_cmd.zig");
pub const install_cmd = @import("install_cmd.zig");
pub const import_cmd = @import("import_cmd.zig");
pub const export_cmd = @import("export_cmd.zig");
pub const info_cmd = @import("info_cmd.zig");
pub const deps_cmd = @import("deps_cmd.zig");
pub const fmt_cmd = @import("fmt_cmd.zig");
pub const lint_cmd = @import("lint_cmd.zig");
pub const doc_cmd = @import("doc_cmd.zig");
pub const doctor_cmd = @import("doctor_cmd.zig");
pub const update_cmd = @import("update_cmd.zig");
pub const lock_cmd = @import("lock_cmd.zig");

/// ANSI color codes for terminal output
pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const cyan = "\x1b[36m";
};

/// Simple progress bar for CLI output
pub const ProgressBar = struct {
    writer: *TermWriter,
    total: usize,
    label: []const u8,
    current: usize,

    pub fn init(writer: *TermWriter, total: usize, label: []const u8) ProgressBar {
        return .{
            .writer = writer,
            .total = total,
            .label = label,
            .current = 0,
        };
    }

    pub fn update(self: *ProgressBar, current: usize) !void {
        self.current = current;
        const percent = if (self.total > 0) (current * 100) / self.total else 0;
        try self.writer.print("\r    {s}: {d}% ({d}/{d})", .{ self.label, percent, current, self.total });
    }

    pub fn finish(self: *ProgressBar) !void {
        self.current = self.total;
        try self.writer.print("\r    {s}: 100% ({d}/{d})\n", .{ self.label, self.total, self.total });
    }
};

/// Simple writer wrapper for CLI output (uses std.debug.print)
pub const TermWriter = struct {
    use_color: bool,

    pub fn init() TermWriter {
        return .{ .use_color = true };
    }

    pub fn print(_: *TermWriter, comptime fmt: []const u8, args: anytype) !void {
        std.debug.print(fmt, args);
    }

    pub fn writeAll(_: *TermWriter, bytes: []const u8) !void {
        std.debug.print("{s}", .{bytes});
    }

    pub fn bold(_: *TermWriter, comptime fmt: []const u8, args: anytype) !void {
        std.debug.print(Color.bold ++ fmt ++ Color.reset, args);
    }

    pub fn dim(_: *TermWriter, comptime fmt: []const u8, args: anytype) !void {
        std.debug.print(Color.dim ++ fmt ++ Color.reset, args);
    }

    pub fn success(_: *TermWriter, comptime fmt: []const u8, args: anytype) !void {
        std.debug.print(Color.green ++ fmt ++ Color.reset, args);
    }

    pub fn warn(_: *TermWriter, comptime fmt: []const u8, args: anytype) !void {
        std.debug.print(Color.yellow ++ fmt ++ Color.reset, args);
    }

    pub fn err(_: *TermWriter, comptime fmt: []const u8, args: anytype) !void {
        std.debug.print(Color.red ++ fmt ++ Color.reset, args);
    }

    pub fn info(_: *TermWriter, comptime fmt: []const u8, args: anytype) !void {
        std.debug.print(Color.cyan ++ fmt ++ Color.reset, args);
    }
};

/// Command descriptor
pub const CommandDescriptor = struct {
    name: []const u8,
    description: []const u8,
    usage: []const u8,
};

/// Available commands
pub const command_list = [_]CommandDescriptor{
    .{ .name = "build", .description = "Build the project", .usage = "ovo build [options]" },
    .{ .name = "run", .description = "Build and run the project", .usage = "ovo run [-- args]" },
    .{ .name = "test", .description = "Run tests", .usage = "ovo test [filter]" },
    .{ .name = "new", .description = "Create a new project", .usage = "ovo new <name> [--lib|--exe]" },
    .{ .name = "init", .description = "Initialize in current directory", .usage = "ovo init [--lib|--exe]" },
    .{ .name = "add", .description = "Add a dependency", .usage = "ovo add <package> [version]" },
    .{ .name = "remove", .description = "Remove a dependency", .usage = "ovo remove <package>" },
    .{ .name = "fetch", .description = "Download dependencies", .usage = "ovo fetch" },
    .{ .name = "clean", .description = "Clean build artifacts", .usage = "ovo clean [--all]" },
    .{ .name = "install", .description = "Install to system", .usage = "ovo install [--prefix PATH]" },
    .{ .name = "import", .description = "Import from other build systems", .usage = "ovo import <path>" },
    .{ .name = "export", .description = "Export to other formats", .usage = "ovo export <format>" },
    .{ .name = "info", .description = "Show project information", .usage = "ovo info" },
    .{ .name = "deps", .description = "Show dependency tree", .usage = "ovo deps [--why <pkg>]" },
    .{ .name = "fmt", .description = "Format source code", .usage = "ovo fmt [files...]" },
    .{ .name = "lint", .description = "Run linter", .usage = "ovo lint [files...]" },
    .{ .name = "doc", .description = "Generate documentation", .usage = "ovo doc" },
    .{ .name = "doctor", .description = "Diagnose environment", .usage = "ovo doctor" },
    .{ .name = "update", .description = "Update dependencies", .usage = "ovo update [pkg]" },
    .{ .name = "lock", .description = "Generate lock file", .usage = "ovo lock" },
};

/// Simple directory handle wrapper (uses cwd via C library)
/// This abstraction allows commands to work with the current working directory
/// without directly depending on the std.Io APIs which changed in Zig 0.16.
pub const DirHandle = struct {
    /// Check if a path is accessible (exists and readable)
    pub fn access(_: DirHandle, path: []const u8, _: anytype) !void {
        // Use C library for basic file access check
        // Need null-terminated string
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) return error.NameTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        if (std.c.access(@ptrCast(&path_buf), std.c.F_OK) != 0) {
            return error.FileNotFound;
        }
    }

    /// Open a file for reading (uses C library)
    pub fn openFile(_: DirHandle, path: []const u8, _: anytype) !CFile {
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) return error.NameTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const file = std.c.fopen(@ptrCast(&path_buf), "r");
        if (file == null) return error.FileNotFound;
        return CFile{ .handle = file };
    }

    /// Create a new file for writing (uses C library)
    pub fn createFile(_: DirHandle, path: []const u8, _: anytype) !CFile {
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) return error.NameTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const file = std.c.fopen(@ptrCast(&path_buf), "w");
        if (file == null) return error.AccessDenied;
        return CFile{ .handle = file };
    }

    /// Create a directory
    pub fn makeDir(_: DirHandle, path: []const u8) !void {
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) return error.NameTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        _ = std.c.mkdir(@ptrCast(&path_buf), 0o755);
    }

    /// Create a directory and all parent directories
    pub fn makePath(_: DirHandle, path: []const u8) !void {
        // Simple implementation: try to create each component
        var i: usize = 0;
        while (i < path.len) {
            while (i < path.len and path[i] != '/') i += 1;
            if (i > 0) {
                var path_buf: [4096]u8 = undefined;
                @memcpy(path_buf[0..i], path[0..i]);
                path_buf[i] = 0;
                _ = std.c.mkdir(@ptrCast(&path_buf), 0o755);
            }
            i += 1;
        }
    }

    /// Delete a directory tree recursively using C library APIs
    pub fn deleteTree(_: DirHandle, path: []const u8) !void {
        deleteTreeRecursive(path) catch return error.AccessDenied;
    }

    const extern_c = struct {
        extern "c" fn unlink(path: [*:0]const u8) c_int;
        extern "c" fn rmdir(path: [*:0]const u8) c_int;
    };

    fn getDirentName(entry: *const std.c.dirent) [*:0]const u8 {
        return @ptrCast(&entry.name);
    }

    fn deleteTreeRecursive(path: []const u8) !void {
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) return error.NameTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        const dir = std.c.opendir(@ptrCast(&path_buf)) orelse return error.FileNotFound;
        defer _ = std.c.closedir(dir);

        while (std.c.readdir(dir)) |entry| {
            const name = std.mem.span(getDirentName(entry));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            var child_buf: [4096]u8 = undefined;
            if (path.len + 1 + name.len >= child_buf.len) continue;
            @memcpy(child_buf[0..path.len], path);
            child_buf[path.len] = '/';
            @memcpy(child_buf[path.len + 1 ..][0..name.len], name);
            child_buf[path.len + 1 + name.len] = 0;

            const child_path = child_buf[0 .. path.len + 1 + name.len];

            if (entry.type == std.c.DT.DIR) {
                try deleteTreeRecursive(child_path);
            } else {
                _ = extern_c.unlink(@ptrCast(&child_buf));
            }
        }

        _ = extern_c.rmdir(@ptrCast(&path_buf));
    }

    /// Get the real path of a file
    pub fn realpath(_: DirHandle, subpath: []const u8, buf: []u8) []u8 {
        var path_buf: [4096]u8 = undefined;
        if (subpath.len >= path_buf.len) return buf[0..0];
        @memcpy(path_buf[0..subpath.len], subpath);
        path_buf[subpath.len] = 0;
        const result = std.c.realpath(@ptrCast(&path_buf), @ptrCast(buf.ptr));
        if (result == null) return buf[0..0];
        return std.mem.sliceTo(buf, 0);
    }
};

/// Simple C FILE wrapper for compatibility
pub const CFile = struct {
    handle: ?*std.c.FILE,

    pub fn close(self: *const CFile) void {
        if (self.handle) |h| {
            _ = std.c.fclose(h);
        }
    }

    pub fn writeAll(self: *const CFile, bytes: []const u8) !void {
        if (self.handle) |h| {
            const written = std.c.fwrite(bytes.ptr, 1, bytes.len, h);
            if (written != bytes.len) return error.WriteError;
        }
    }

    pub fn readAll(self: *const CFile, allocator: std.mem.Allocator) ![]u8 {
        if (self.handle) |h| {
            var list = std.ArrayList(u8).empty;
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = std.c.fread(&buf, 1, buf.len, h);
                if (n == 0) break;
                try list.appendSlice(allocator, buf[0..n]);
            }
            return try list.toOwnedSlice(allocator);
        }
        return error.FileNotFound;
    }
};

/// Context passed to all command handlers
pub const Context = struct {
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *TermWriter,
    stderr: *TermWriter,
    cwd: DirHandle,

    // Static writers for use
    var static_stdout: TermWriter = TermWriter.init();
    var static_stderr: TermWriter = TermWriter.init();

    pub fn init(allocator: std.mem.Allocator, args: []const []const u8) Context {
        return .{
            .allocator = allocator,
            .args = args,
            .stdout = &static_stdout,
            .stderr = &static_stderr,
            .cwd = .{},
        };
    }

    pub fn deinit(_: *Context) void {}

    // Output helpers using debug.print
    pub fn print(_: *Context, comptime fmt: []const u8, args: anytype) void {
        std.debug.print(fmt, args);
    }

    pub fn printSuccess(_: *Context, comptime fmt: []const u8, args: anytype) void {
        std.debug.print(Color.green ++ fmt ++ Color.reset, args);
    }

    pub fn printError(_: *Context, comptime fmt: []const u8, args: anytype) void {
        std.debug.print(Color.red ++ fmt ++ Color.reset, args);
    }

    pub fn printWarning(_: *Context, comptime fmt: []const u8, args: anytype) void {
        std.debug.print(Color.yellow ++ fmt ++ Color.reset, args);
    }

    pub fn printInfo(_: *Context, comptime fmt: []const u8, args: anytype) void {
        std.debug.print(Color.cyan ++ fmt ++ Color.reset, args);
    }
};

/// Print help message
pub fn printHelp() void {
    std.debug.print(Color.bold ++ "ovo" ++ Color.reset ++ " - Modern C/C++ Package Manager\n\n", .{});

    std.debug.print(Color.bold ++ "USAGE:\n" ++ Color.reset, .{});
    std.debug.print("    ovo <command> [options]\n\n", .{});

    std.debug.print(Color.bold ++ "COMMANDS:\n" ++ Color.reset, .{});
    for (command_list) |cmd| {
        std.debug.print(Color.green ++ "    {s:<12}" ++ Color.reset ++ "{s}\n", .{ cmd.name, cmd.description });
    }

    std.debug.print("\n", .{});
    std.debug.print(Color.bold ++ "OPTIONS:\n" ++ Color.reset, .{});
    std.debug.print("    -h, --help       Show this help message\n", .{});
    std.debug.print("    -V, --version    Show version information\n", .{});
    std.debug.print("    -v, --verbose    Enable verbose output\n", .{});
    std.debug.print("    -q, --quiet      Suppress non-essential output\n", .{});

    std.debug.print("\n", .{});
    std.debug.print(Color.dim ++ "Run 'ovo <command> --help' for more information on a specific command.\n" ++ Color.reset, .{});
}

/// Print version information
pub fn printVersion() void {
    std.debug.print(Color.bold ++ "ovo " ++ Color.reset ++ "0.2.0\n", .{});
    std.debug.print(Color.dim ++ "Built with Zig {s}\n" ++ Color.reset, .{builtin.zig_version_string});
}

/// Check if args contain help flag
pub fn hasHelpFlag(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return true;
        }
    }
    return false;
}

/// Check if args contain verbose flag
pub fn hasVerboseFlag(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            return true;
        }
    }
    return false;
}

/// Check if a file exists using C library access()
pub fn fileExistsC(path: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return false;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    return std.c.access(@ptrCast(&path_buf), std.c.F_OK) == 0;
}

/// Search PATH for an executable by name.
pub fn findInPathC(name: []const u8) bool {
    var key_buf: [8]u8 = undefined;
    @memcpy(key_buf[0..4], "PATH");
    key_buf[4] = 0;
    const path_env = std.c.getenv(@ptrCast(&key_buf)) orelse return false;
    const path_str = std.mem.span(path_env);
    const sep: u8 = if (@import("builtin").os.tag == .windows) ';' else ':';
    var iter = std.mem.splitScalar(u8, path_str, sep);
    while (iter.next()) |dir| {
        var check_buf: [4096]u8 = undefined;
        if (dir.len + 1 + name.len >= check_buf.len) continue;
        @memcpy(check_buf[0..dir.len], dir);
        check_buf[dir.len] = '/';
        @memcpy(check_buf[dir.len + 1 ..][0..name.len], name);
        check_buf[dir.len + 1 + name.len] = 0;
        if (std.c.access(@ptrCast(&check_buf), std.c.F_OK) == 0) return true;
    }
    return false;
}

/// Check if the project manifest file exists in the current directory
pub fn manifestExists(cwd: DirHandle) bool {
    const manifest_mod = @import("manifest.zig");
    cwd.access(manifest_mod.manifest_filename, .{}) catch return false;
    return true;
}

/// Command execution error
pub const CommandError = error{
    UnknownCommand,
    InvalidArguments,
    MissingArgument,
    ProjectNotFound,
    DependencyError,
    BuildError,
    IoError,
    OutOfMemory,
};

/// Parse and dispatch commands
pub fn dispatch(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var ctx = Context.init(allocator, args);
    defer ctx.deinit();

    // No arguments - show help
    if (args.len == 0) {
        printHelp();
        return 0;
    }

    const command = args[0];
    const cmd_args = if (args.len > 1) args[1..] else &[_][]const u8{};

    // Handle global flags
    if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        printHelp();
        return 0;
    }
    if (std.mem.eql(u8, command, "-V") or std.mem.eql(u8, command, "--version")) {
        printVersion();
        return 0;
    }

    // Dispatch to command handler
    const result = dispatchCommand(command, cmd_args, &ctx);

    if (result) |exit_code| {
        return exit_code;
    } else |e| {
        if (e == error.UnknownCommand) {
            std.debug.print(Color.red ++ "error: " ++ Color.reset ++ "unknown command '{s}'\n", .{command});
            std.debug.print(Color.dim ++ "Run 'ovo --help' for usage information.\n" ++ Color.reset, .{});
        } else {
            std.debug.print(Color.red ++ "error: " ++ Color.reset ++ "command failed: {}\n", .{e});
        }
        return 1;
    }
}

fn dispatchCommand(command: []const u8, args: []const []const u8, ctx: *Context) !u8 {
    if (std.mem.eql(u8, command, "build")) {
        return build_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "run")) {
        return run_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "test")) {
        return test_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "new")) {
        return new_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "init")) {
        return init_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "add")) {
        return add_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "remove")) {
        return remove_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "fetch")) {
        return fetch_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "clean")) {
        return clean_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "install")) {
        return install_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "import")) {
        return import_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "export")) {
        return export_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "info")) {
        return info_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "deps")) {
        return deps_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "fmt")) {
        return fmt_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "lint")) {
        return lint_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "doc")) {
        return doc_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "doctor")) {
        return doctor_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "update")) {
        return update_cmd.execute(ctx, args);
    } else if (std.mem.eql(u8, command, "lock")) {
        return lock_cmd.execute(ctx, args);
    }

    return error.UnknownCommand;
}

// Tests
test "commands module" {
    _ = build_cmd;
    _ = run_cmd;
    _ = test_cmd;
    _ = new_cmd;
    _ = doc_cmd;
    _ = doctor_cmd;
    _ = update_cmd;
    _ = lock_cmd;
}
