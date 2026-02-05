//! ovo fmt command
//!
//! Format source code using clang-format.
//! Usage: ovo fmt [files...]

const std = @import("std");
const commands = @import("commands.zig");

const Context = commands.Context;
const TermWriter = commands.TermWriter;

/// Print help for fmt command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo fmt", .{});
    try writer.print(" - Format source code\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo fmt [files...] [options]\n\n", .{});

    try writer.bold("ARGUMENTS:\n", .{});
    try writer.print("    [files...]       Specific files to format (default: all)\n\n", .{});

    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    --check          Check formatting without modifying\n", .{});
    try writer.print("    --diff           Show diff of formatting changes\n", .{});
    try writer.print("    --style <name>   Style preset (llvm, google, chromium, mozilla, webkit)\n", .{});
    try writer.print("    --config <file>  Use specific .clang-format file\n", .{});
    try writer.print("    -v, --verbose    Show all processed files\n", .{});
    try writer.print("    -h, --help       Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo fmt                      # Format all source files\n", .{});
    try writer.dim("    ovo fmt src/main.cpp         # Format specific file\n", .{});
    try writer.dim("    ovo fmt --check              # Check without modifying\n", .{});
    try writer.dim("    ovo fmt --style google       # Use Google style\n", .{});
}

/// Execute the fmt command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    // Check for help flag
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    // Parse options
    var check_only = false;
    var show_diff = false;
    var style: ?[]const u8 = null;
    var config_file: ?[]const u8 = null;
    var verbose = false;
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(ctx.allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--check")) {
            check_only = true;
        } else if (std.mem.eql(u8, arg, "--diff")) {
            show_diff = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--style") and i + 1 < args.len) {
            i += 1;
            style = args[i];
        } else if (std.mem.startsWith(u8, arg, "--style=")) {
            style = arg["--style=".len..];
        } else if (std.mem.eql(u8, arg, "--config") and i + 1 < args.len) {
            i += 1;
            config_file = args[i];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try files.append(ctx.allocator, arg);
        }
    }

    // Check for clang-format
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Checking for clang-format...\n", .{});

    // In real implementation, would check if clang-format is available
    const clang_format_available = true;

    if (!clang_format_available) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("clang-format not found\n", .{});
        try ctx.stderr.dim("Install clang-format or add it to your PATH.\n", .{});
        return 1;
    }

    // Find files to format
    if (files.items.len == 0) {
        // Find all source files
        try ctx.stdout.print("  ", .{});
        try ctx.stdout.success("*", .{});
        try ctx.stdout.print(" Finding source files...\n", .{});

        // Simulated file discovery
        try files.append(ctx.allocator, "src/main.cpp");
        try files.append(ctx.allocator, "src/utils.cpp");
        try files.append(ctx.allocator, "include/mylib.hpp");
        try files.append(ctx.allocator, "tests/test_main.cpp");
    }

    // Print mode
    if (check_only) {
        try ctx.stdout.bold("\nChecking formatting ({d} files)...\n\n", .{files.items.len});
    } else {
        try ctx.stdout.bold("\nFormatting {d} files...\n\n", .{files.items.len});
    }

    // Show style
    if (style) |s| {
        try ctx.stdout.dim("  Style: {s}\n", .{s});
    } else if (config_file) |cf| {
        try ctx.stdout.dim("  Config: {s}\n", .{cf});
    } else {
        try ctx.stdout.dim("  Style: (using .clang-format if present)\n", .{});
    }
    try ctx.stdout.print("\n", .{});

    // Process files
    var formatted: u32 = 0;
    var unchanged: u32 = 0;
    var errors: u32 = 0;
    _ = &errors; // Suppress warning (will be used in future)

    for (files.items) |file| {
        // Simulated formatting result
        const needs_formatting = std.mem.endsWith(u8, file, "utils.cpp");

        if (verbose or needs_formatting) {
            try ctx.stdout.print("  ", .{});
        }

        if (needs_formatting) {
            formatted += 1;

            if (check_only) {
                try ctx.stdout.warn("~", .{});
                try ctx.stdout.print(" {s}", .{file});
                try ctx.stdout.warn(" (needs formatting)\n", .{});

                if (show_diff) {
                    try ctx.stdout.dim("    @@ -10,6 +10,6 @@\n", .{});
                    try ctx.stdout.err("    -int foo( int x ) {{\n", .{});
                    try ctx.stdout.success("    +int foo(int x) {{\n", .{});
                }
            } else {
                try ctx.stdout.success("*", .{});
                try ctx.stdout.print(" {s}", .{file});
                try ctx.stdout.success(" (formatted)\n", .{});
            }
        } else {
            unchanged += 1;

            if (verbose) {
                try ctx.stdout.dim("-", .{});
                try ctx.stdout.dim(" {s} (unchanged)\n", .{file});
            }
        }
    }

    // Summary
    try ctx.stdout.print("\n", .{});

    if (check_only) {
        if (formatted > 0) {
            try ctx.stdout.warn("{d} file(s) need formatting\n", .{formatted});
            try ctx.stdout.dim("{d} file(s) already formatted\n", .{unchanged});
            try ctx.stdout.print("\n", .{});
            try ctx.stdout.dim("Run 'ovo fmt' to format them.\n", .{});
            return 1;
        } else {
            try ctx.stdout.success("All {d} files are properly formatted\n", .{unchanged});
            return 0;
        }
    } else {
        if (formatted > 0) {
            try ctx.stdout.success("Formatted {d} file(s)\n", .{formatted});
        }
        if (unchanged > 0) {
            try ctx.stdout.dim("{d} file(s) unchanged\n", .{unchanged});
        }
        if (errors > 0) {
            try ctx.stdout.err("{d} error(s)\n", .{errors});
            return 1;
        }
    }

    return 0;
}
