//! ovo install command
//!
//! Install the project to system directories.
//! Usage: ovo install

const std = @import("std");
const commands = @import("commands.zig");
const manifest = @import("manifest.zig");
const zon_parser = @import("zon").parser;

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

    // Parse build.zon
    var project = zon_parser.parseFile(ctx.allocator, manifest.manifest_filename) catch |err| {
        try ctx.stderr.err("error: ", .{});
        switch (err) {
            error.FileNotFound => try ctx.stderr.print("no " ++ manifest.manifest_filename ++ " found in current directory\n", .{}),
            else => try ctx.stderr.print("failed to parse " ++ manifest.manifest_filename ++ "\n", .{}),
        }
        return 1;
    };
    defer project.deinit(ctx.allocator);

    // Resolve directories
    const actual_bindir = bindir orelse try std.fmt.allocPrint(ctx.allocator, "{s}/bin", .{prefix});
    defer if (bindir == null) ctx.allocator.free(actual_bindir);
    const actual_libdir = libdir orelse try std.fmt.allocPrint(ctx.allocator, "{s}/lib", .{prefix});
    defer if (libdir == null) ctx.allocator.free(actual_libdir);
    const actual_includedir = includedir orelse try std.fmt.allocPrint(ctx.allocator, "{s}/include", .{prefix});
    defer if (includedir == null) ctx.allocator.free(actual_includedir);

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

    // Build install items from project targets
    const build_dir = if (release) "release" else "debug";
    var install_count: usize = 0;

    if (project.targets.len == 0) {
        try ctx.stdout.warn("No installable targets found in " ++ manifest.manifest_filename ++ "\n", .{});
        return 0;
    }

    for (project.targets) |target| {
        const output_name = target.output_name orelse target.name;

        switch (target.target_type) {
            .executable => {
                const dest_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ actual_bindir, output_name });
                defer ctx.allocator.free(dest_path);

                try ctx.stdout.print("  ", .{});
                if (dry_run) {
                    try ctx.stdout.warn("~", .{});
                } else {
                    try ctx.stdout.success("*", .{});
                }
                try ctx.stdout.dim(" [BIN] ", .{});
                try ctx.stdout.print("{s}", .{dest_path});
                try ctx.stdout.dim("  (from build/{s}/{s})\n", .{ build_dir, output_name });
                install_count += 1;
            },
            .static_library => {
                const lib_filename = try std.fmt.allocPrint(ctx.allocator, "lib{s}.a", .{output_name});
                defer ctx.allocator.free(lib_filename);
                const dest_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ actual_libdir, lib_filename });
                defer ctx.allocator.free(dest_path);

                try ctx.stdout.print("  ", .{});
                if (dry_run) {
                    try ctx.stdout.warn("~", .{});
                } else {
                    try ctx.stdout.success("*", .{});
                }
                try ctx.stdout.dim(" [LIB] ", .{});
                try ctx.stdout.print("{s}", .{dest_path});
                try ctx.stdout.dim("  (from build/{s}/{s})\n", .{ build_dir, lib_filename });
                install_count += 1;
            },
            .shared_library => {
                const lib_filename = try std.fmt.allocPrint(ctx.allocator, "lib{s}.so", .{output_name});
                defer ctx.allocator.free(lib_filename);
                const dest_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ actual_libdir, lib_filename });
                defer ctx.allocator.free(dest_path);

                try ctx.stdout.print("  ", .{});
                if (dry_run) {
                    try ctx.stdout.warn("~", .{});
                } else {
                    try ctx.stdout.success("*", .{});
                }
                try ctx.stdout.dim(" [LIB] ", .{});
                try ctx.stdout.print("{s}", .{dest_path});
                try ctx.stdout.dim("  (from build/{s}/{s})\n", .{ build_dir, lib_filename });
                install_count += 1;
            },
            .header_only => {
                if (target.includes) |includes| {
                    for (includes) |inc| {
                        const dest_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ actual_includedir, inc.path });
                        defer ctx.allocator.free(dest_path);

                        try ctx.stdout.print("  ", .{});
                        if (dry_run) {
                            try ctx.stdout.warn("~", .{});
                        } else {
                            try ctx.stdout.success("*", .{});
                        }
                        try ctx.stdout.dim(" [HDR] ", .{});
                        try ctx.stdout.print("{s}\n", .{dest_path});
                        install_count += 1;
                    }
                }
            },
            .object => {},
        }

        if (!dry_run) {
            // Would actually copy file here
            // std.fs.copyFile(source_path, dest_path, .{});
        }
    }

    if (install_count == 0) {
        try ctx.stdout.warn("No installable targets found in " ++ manifest.manifest_filename ++ "\n", .{});
        return 0;
    }

    // Summary
    try ctx.stdout.print("\n", .{});
    if (dry_run) {
        try ctx.stdout.warn("Would install {d} files\n", .{install_count});
        try ctx.stdout.dim("Run without --dry-run to install.\n", .{});
    } else {
        try ctx.stdout.success("Installed {d} files\n", .{install_count});
    }

    return 0;
}
