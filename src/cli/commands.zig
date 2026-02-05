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
};

/// Simple directory handle wrapper (uses cwd)
pub const DirHandle = struct {
    pub fn access(_: DirHandle, path: []const u8, flags: std.fs.Dir.AccessFlags) !void {
        return std.fs.cwd().access(path, flags);
    }

    pub fn openFile(_: DirHandle, path: []const u8, flags: std.fs.Dir.OpenFlags) !std.fs.File {
        return std.fs.cwd().openFile(path, flags);
    }

    pub fn createFile(_: DirHandle, path: []const u8, flags: std.fs.Dir.CreateFlags) !std.fs.File {
        return std.fs.cwd().createFile(path, flags);
    }

    pub fn makeDir(_: DirHandle, path: []const u8) !void {
        return std.fs.cwd().makeDir(path);
    }

    pub fn makePath(_: DirHandle, path: []const u8) !void {
        return std.fs.cwd().makePath(path);
    }

    pub fn deleteTree(_: DirHandle, path: []const u8) !void {
        try std.fs.cwd().deleteTree(path);
    }

    pub fn realpath(_: DirHandle, subpath: []const u8, buf: []u8) []u8 {
        return std.fs.cwd().realpath(subpath, buf) catch buf[0..0];
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
    }

    return error.UnknownCommand;
}

// Tests
test "commands module" {
    _ = build_cmd;
    _ = run_cmd;
    _ = test_cmd;
    _ = new_cmd;
}
