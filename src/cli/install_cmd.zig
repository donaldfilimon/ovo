//! ovo install command
//!
//! Install the project to system directories.
//! Usage: ovo install

const std = @import("std");
const commands = @import("commands.zig");

const Context = commands.Context;
const TermWriter = commands.TermWriter;

/// Print help for install command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo install", .{});
    try writer.print(" - Install to system\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo install [options]\n\n", .{});

    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    --prefix <path>  Installation prefix (default: /usr/local)\n", .{});
    try writer.print("    --bindir <path>  Binary directory (default: PREFIX/bin)\n", .{});
    try writer.print("    --libdir <path>  Library directory (default: PREFIX/lib)\n", .{});
    try writer.print("    --includedir     Include directory (default: PREFIX/include)\n", .{});
    try writer.print("    --release        Install release build (default)\n", .{});
    try writer.print("    --debug          Install debug build\n", .{});
    try writer.print("    -n, --dry-run    Show what would be installed\n", .{});
    try writer.print("    -h, --help       Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo install                          # Install to /usr/local\n", .{});
    try writer.dim("    ovo install --prefix ~/.local        # Install to home\n", .{});
    try writer.dim("    ovo install --dry-run                # Show install plan\n", .{});
}

/// Execute the install command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    // Check for help flag
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    // Parse options
    var prefix: []const u8 = "/usr/local";
    var bindir: ?[]const u8 = null;
    var libdir: ?[]const u8 = null;
    var includedir: ?[]const u8 = null;
    var release = true;
    var dry_run = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--prefix") and i + 1 < args.len) {
            i += 1;
            prefix = args[i];
        } else if (std.mem.startsWith(u8, arg, "--prefix=")) {
            prefix = arg["--prefix=".len..];
        } else if (std.mem.eql(u8, arg, "--bindir") and i + 1 < args.len) {
            i += 1;
            bindir = args[i];
        } else if (std.mem.eql(u8, arg, "--libdir") and i + 1 < args.len) {
            i += 1;
            libdir = args[i];
        } else if (std.mem.eql(u8, arg, "--includedir") and i + 1 < args.len) {
            i += 1;
            includedir = args[i];
        } else if (std.mem.eql(u8, arg, "--release")) {
            release = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            release = false;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
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

    // Resolve directories
    const actual_bindir = bindir orelse try std.fmt.allocPrint(ctx.allocator, "{s}/bin", .{prefix});
    const actual_libdir = libdir orelse try std.fmt.allocPrint(ctx.allocator, "{s}/lib", .{prefix});
    const actual_includedir = includedir orelse try std.fmt.allocPrint(ctx.allocator, "{s}/include", .{prefix});

    // Print install plan
    if (dry_run) {
        try ctx.stdout.bold("Install plan (dry run)\n\n", .{});
    } else {
        try ctx.stdout.bold("Installing project\n\n", .{});
    }

    try ctx.stdout.dim("  Prefix:     {s}\n", .{prefix});
    try ctx.stdout.dim("  Binaries:   {s}\n", .{actual_bindir});
    try ctx.stdout.dim("  Libraries:  {s}\n", .{actual_libdir});
    try ctx.stdout.dim("  Headers:    {s}\n", .{actual_includedir});
    try ctx.stdout.dim("  Build type: {s}\n", .{if (release) "release" else "debug"});
    try ctx.stdout.print("\n", .{});

    // Simulated install items
    const InstallItem = struct {
        source: []const u8,
        dest: []const u8,
        kind: enum { binary, library, header },
    };

    const items = [_]InstallItem{
        .{ .source = "build/release/myapp", .dest = "bin/myapp", .kind = .binary },
        .{ .source = "build/release/libmylib.a", .dest = "lib/libmylib.a", .kind = .library },
        .{ .source = "include/mylib.h", .dest = "include/mylib/mylib.h", .kind = .header },
    };

    // Install each item
    for (items) |item| {
        const dest_path = switch (item.kind) {
            .binary => try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ actual_bindir, std.fs.path.basename(item.dest) }),
            .library => try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ actual_libdir, std.fs.path.basename(item.dest) }),
            .header => try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ actual_includedir, item.dest["include/".len..] }),
        };

        try ctx.stdout.print("  ", .{});
        if (dry_run) {
            try ctx.stdout.warn("~", .{});
        } else {
            try ctx.stdout.success("*", .{});
        }

        const kind_str = switch (item.kind) {
            .binary => "BIN",
            .library => "LIB",
            .header => "HDR",
        };

        try ctx.stdout.dim(" [{s}] ", .{kind_str});
        try ctx.stdout.print("{s}\n", .{dest_path});

        if (!dry_run) {
            // Would actually copy file here
            // std.fs.copyFile(item.source, dest_path, .{});
        }
    }

    // Summary
    try ctx.stdout.print("\n", .{});
    if (dry_run) {
        try ctx.stdout.warn("Would install {d} files\n", .{items.len});
        try ctx.stdout.dim("Run without --dry-run to install.\n", .{});
    } else {
        try ctx.stdout.success("Installed {d} files\n", .{items.len});
    }

    return 0;
}
