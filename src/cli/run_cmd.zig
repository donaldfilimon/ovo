//! ovo run command
//!
//! Build and run the project executable.
//! Usage: ovo run [target] [-- args]

const std = @import("std");
const commands = @import("commands.zig");
const build_cmd = @import("build_cmd.zig");
const zon = @import("zon");

// C library function for execution
extern "c" fn system(command: [*:0]const u8) c_int;

const Context = commands.Context;
const TermWriter = commands.TermWriter;

/// Print help for run command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo run", .{});
    try writer.print(" - Build and run the project\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo run [target] [options] [-- args...]\n\n", .{});

    try writer.bold("ARGUMENTS:\n", .{});
    try writer.print("    [target]         Executable target to run\n", .{});
    try writer.print("    [-- args...]     Arguments passed to the executable\n\n", .{});

    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    --release        Run release build\n", .{});
    try writer.print("    --debug          Run debug build (default)\n", .{});
    try writer.print("    --no-build       Don't rebuild before running\n", .{});
    try writer.print("    -v, --verbose    Show detailed output\n", .{});
    try writer.print("    -h, --help       Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo run                      # Build and run default target\n", .{});
    try writer.dim("    ovo run myapp                # Run specific target\n", .{});
    try writer.dim("    ovo run -- --config test     # Pass args to executable\n", .{});
    try writer.dim("    ovo run --release -- -v      # Run release with args\n", .{});
}

/// Execute the run command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    // Check for help flag
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    // Split args at "--" separator
    var build_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer build_args.deinit(ctx.allocator);

    var run_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer run_args.deinit(ctx.allocator);

    var past_separator = false;
    var no_build = false;
    var target: ?[]const u8 = null;
    var release = false;
    var verbose = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) {
            past_separator = true;
            continue;
        }

        if (past_separator) {
            try run_args.append(ctx.allocator, arg);
        } else {
            if (std.mem.eql(u8, arg, "--no-build")) {
                no_build = true;
            } else if (std.mem.eql(u8, arg, "--release")) {
                release = true;
                try build_args.append(ctx.allocator, arg);
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
                verbose = true;
                try build_args.append(ctx.allocator, arg);
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                target = arg;
                try build_args.append(ctx.allocator, arg);
            } else {
                try build_args.append(ctx.allocator, arg);
            }
        }
    }

    // Check for build.zon
    const manifest_exists = blk: {
        ctx.cwd.access("build.zon", .{}) catch break :blk false;
        break :blk true;
    };

    if (!manifest_exists) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("no build.zon found in current directory\n", .{});
        return 1;
    }

    // Build first (unless --no-build)
    if (!no_build) {
        const build_result = try build_cmd.execute(ctx, build_args.items);
        if (build_result != 0) {
            return build_result;
        }
    }

    // Construct executable path: build/{profile}/bin/{target}
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const build_dir = if (release) "build/release" else "build/debug";
    var default_name_buf: [256]u8 = undefined;
    const exe_name = target orelse blk: {
        // Parse build.zon to get first executable target
        var project = zon.parser.parseFile(ctx.allocator, "build.zon") catch break :blk "main";
        defer project.deinit(ctx.allocator);
        for (project.targets) |t| {
            if (t.target_type == .executable) {
                const len = @min(t.name.len, default_name_buf.len - 1);
                @memcpy(default_name_buf[0..len], t.name[0..len]);
                default_name_buf[len] = 0;
                break :blk default_name_buf[0..len];
            }
        }
        break :blk "main";
    };

    const exe_path = std.fmt.bufPrint(&exe_path_buf, "{s}/bin/{s}", .{ build_dir, exe_name }) catch {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("path too long\n", .{});
        return 1;
    };

    try ctx.stdout.print("\n", .{});
    try ctx.stdout.bold("Running", .{});
    try ctx.stdout.print(" {s}", .{exe_path});

    if (run_args.items.len > 0) {
        try ctx.stdout.dim(" with args: ", .{});
        for (run_args.items, 0..) |arg, i| {
            if (i > 0) try ctx.stdout.print(" ", .{});
            try ctx.stdout.print("{s}", .{arg});
        }
    }
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.dim("─────────────────────────────────────────\n", .{});

    // Build command string with any arguments
    var cmd_buf: [1024]u8 = undefined;
    var cmd_len: usize = 0;

    // Add executable path
    @memcpy(cmd_buf[cmd_len..][0..exe_path.len], exe_path);
    cmd_len += exe_path.len;

    // Add run arguments
    for (run_args.items) |arg| {
        cmd_buf[cmd_len] = ' ';
        cmd_len += 1;
        @memcpy(cmd_buf[cmd_len..][0..arg.len], arg);
        cmd_len += arg.len;
    }

    // Null terminate
    cmd_buf[cmd_len] = 0;

    if (verbose) {
        try ctx.stdout.dim("[ovo] Executing: {s}\n", .{cmd_buf[0..cmd_len]});
    }

    // Execute the program
    const result = system(@ptrCast(&cmd_buf));

    try ctx.stdout.dim("─────────────────────────────────────────\n", .{});

    if (result == 0) {
        try ctx.stdout.success("Process exited with code 0\n", .{});
        return 0;
    } else {
        try ctx.stdout.err("Process exited with code {d}\n", .{result});
        return 1;
    }
}
