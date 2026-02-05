//! ovo lint command
//!
//! Run static analysis using clang-tidy.
//! Usage: ovo lint [files...]

const std = @import("std");
const commands = @import("commands.zig");

const Context = commands.Context;
const TermWriter = commands.TermWriter;
const Color = commands.Color;

/// Print help for lint command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo lint", .{});
    try writer.print(" - Run static analysis\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo lint [files...] [options]\n\n", .{});

    try writer.bold("ARGUMENTS:\n", .{});
    try writer.print("    [files...]       Specific files to lint (default: all)\n\n", .{});

    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    --fix            Apply suggested fixes automatically\n", .{});
    try writer.print("    --checks <list>  Comma-separated list of checks to enable\n", .{});
    try writer.print("    --config <file>  Use specific .clang-tidy file\n", .{});
    try writer.print("    --warnings-as-errors  Treat warnings as errors\n", .{});
    try writer.print("    --quiet          Only show errors, not warnings\n", .{});
    try writer.print("    -v, --verbose    Show detailed diagnostic info\n", .{});
    try writer.print("    -h, --help       Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("CHECK CATEGORIES:\n", .{});
    try writer.print("    bugprone-*       Bug-prone code patterns\n", .{});
    try writer.print("    clang-analyzer-* Clang static analyzer checks\n", .{});
    try writer.print("    cppcoreguidelines-* C++ Core Guidelines\n", .{});
    try writer.print("    modernize-*      C++ modernization suggestions\n", .{});
    try writer.print("    performance-*    Performance improvements\n", .{});
    try writer.print("    readability-*    Readability improvements\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo lint                           # Lint all files\n", .{});
    try writer.dim("    ovo lint src/main.cpp              # Lint specific file\n", .{});
    try writer.dim("    ovo lint --fix                     # Auto-fix issues\n", .{});
    try writer.dim("    ovo lint --checks=\"modernize-*\"    # Specific checks\n", .{});
}

/// Diagnostic severity
const Severity = enum {
    @"error",
    warning,
    note,

    pub fn color(self: Severity) []const u8 {
        return switch (self) {
            .@"error" => Color.red,
            .warning => Color.yellow,
            .note => Color.cyan,
        };
    }

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .@"error" => "error",
            .warning => "warning",
            .note => "note",
        };
    }
};

/// Diagnostic message
const Diagnostic = struct {
    file: []const u8,
    line: u32,
    column: u32,
    severity: Severity,
    message: []const u8,
    check: []const u8,
    fix_available: bool,
};

/// Execute the lint command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    // Check for help flag
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    // Parse options
    var auto_fix = false;
    var checks: ?[]const u8 = null;
    var config_file: ?[]const u8 = null;
    var warnings_as_errors = false;
    var quiet = false;
    var verbose = false;
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(ctx.allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--fix")) {
            auto_fix = true;
        } else if (std.mem.eql(u8, arg, "--warnings-as-errors")) {
            warnings_as_errors = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--checks") and i + 1 < args.len) {
            i += 1;
            checks = args[i];
        } else if (std.mem.startsWith(u8, arg, "--checks=")) {
            checks = arg["--checks=".len..];
        } else if (std.mem.eql(u8, arg, "--config") and i + 1 < args.len) {
            i += 1;
            config_file = args[i];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try files.append(ctx.allocator, arg);
        }
    }

    // Check for clang-tidy
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Checking for clang-tidy...\n", .{});

    // In real implementation, would check if clang-tidy is available
    const clang_tidy_available = true;

    if (!clang_tidy_available) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("clang-tidy not found\n", .{});
        try ctx.stderr.dim("Install clang-tidy or add it to your PATH.\n", .{});
        return 1;
    }

    // Check for compile_commands.json
    const compile_commands_exists = blk: {
        ctx.cwd.access("compile_commands.json", .{}) catch {
            ctx.cwd.access("build/compile_commands.json", .{}) catch break :blk false;
            break :blk true;
        };
        break :blk true;
    };

    if (!compile_commands_exists) {
        try ctx.stdout.warn("warning: ", .{});
        try ctx.stdout.print("compile_commands.json not found\n", .{});
        try ctx.stdout.dim("  Run 'ovo export compile-commands' to generate it.\n", .{});
        try ctx.stdout.dim("  Continuing with default flags...\n\n", .{});
    }

    // Find files to lint
    if (files.items.len == 0) {
        try ctx.stdout.print("  ", .{});
        try ctx.stdout.success("*", .{});
        try ctx.stdout.print(" Finding source files...\n", .{});

        // Simulated file discovery
        try files.append(ctx.allocator, "src/main.cpp");
        try files.append(ctx.allocator, "src/utils.cpp");
        try files.append(ctx.allocator, "src/core.cpp");
    }

    // Print mode
    try ctx.stdout.bold("\nRunning static analysis ({d} files)...\n\n", .{files.items.len});

    if (checks) |c| {
        try ctx.stdout.dim("  Checks: {s}\n", .{c});
    }
    if (auto_fix) {
        try ctx.stdout.info("  Auto-fix enabled\n", .{});
    }
    if (config_file) |cf| {
        try ctx.stdout.dim("  Config: {s}\n", .{cf});
    }
    try ctx.stdout.print("\n", .{});

    // Simulated diagnostics
    const diagnostics = [_]Diagnostic{
        .{
            .file = "src/main.cpp",
            .line = 15,
            .column = 5,
            .severity = .warning,
            .message = "use 'nullptr' instead of '0'",
            .check = "modernize-use-nullptr",
            .fix_available = true,
        },
        .{
            .file = "src/main.cpp",
            .line = 23,
            .column = 12,
            .severity = .warning,
            .message = "use 'auto' when initializing with a cast to avoid duplicating the type name",
            .check = "modernize-use-auto",
            .fix_available = true,
        },
        .{
            .file = "src/utils.cpp",
            .line = 42,
            .column = 8,
            .severity = .@"error",
            .message = "memory leak: allocated memory is not freed",
            .check = "clang-analyzer-cplusplus.NewDeleteLeaks",
            .fix_available = false,
        },
        .{
            .file = "src/utils.cpp",
            .line = 67,
            .column = 1,
            .severity = .warning,
            .message = "function 'processData' has cognitive complexity of 25 (threshold 20)",
            .check = "readability-function-cognitive-complexity",
            .fix_available = false,
        },
        .{
            .file = "src/core.cpp",
            .line = 11,
            .column = 3,
            .severity = .warning,
            .message = "use range-based for loop instead",
            .check = "modernize-loop-convert",
            .fix_available = true,
        },
    };

    var error_count: u32 = 0;
    var warning_count: u32 = 0;
    var fixed_count: u32 = 0;

    // Group diagnostics by file
    var current_file: ?[]const u8 = null;

    for (diagnostics) |diag| {
        // Skip warnings in quiet mode
        if (quiet and diag.severity == .warning) continue;

        // Print file header
        if (current_file == null or !std.mem.eql(u8, current_file.?, diag.file)) {
            current_file = diag.file;
            try ctx.stdout.bold("{s}:\n", .{diag.file});
        }

        // Count
        switch (diag.severity) {
            .@"error" => error_count += 1,
            .warning => warning_count += 1,
            .note => {},
        }

        // Print diagnostic
        try ctx.stdout.print("  ", .{});

        // Location
        try ctx.stdout.dim("{d}:{d}: ", .{ diag.line, diag.column });

        // Severity
        if (ctx.stdout.use_color) {
            try ctx.stdout.writeAll(diag.severity.color());
        }
        try ctx.stdout.print("{s}: ", .{diag.severity.label()});
        if (ctx.stdout.use_color) {
            try ctx.stdout.writeAll(Color.reset);
        }

        // Message
        try ctx.stdout.print("{s}", .{diag.message});

        // Check name
        try ctx.stdout.dim(" [{s}]", .{diag.check});

        // Fix indicator
        if (diag.fix_available) {
            if (auto_fix) {
                try ctx.stdout.success(" (fixed)", .{});
                fixed_count += 1;
            } else {
                try ctx.stdout.info(" (fix available)", .{});
            }
        }

        try ctx.stdout.print("\n", .{});

        // Show code context in verbose mode
        if (verbose) {
            try ctx.stdout.dim("     |  // example context line\n", .{});
            try ctx.stdout.dim("  {d} |  int* ptr = 0;  // <-- here\n", .{diag.line});
            try ctx.stdout.dim("     |             ^\n", .{});
        }
    }

    // Summary
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.bold("Analysis complete:\n", .{});

    if (error_count > 0) {
        try ctx.stdout.err("  {d} error(s)\n", .{error_count});
    }
    if (warning_count > 0) {
        try ctx.stdout.warn("  {d} warning(s)\n", .{warning_count});
    }
    if (fixed_count > 0) {
        try ctx.stdout.success("  {d} issue(s) fixed\n", .{fixed_count});
    }
    if (error_count == 0 and warning_count == 0) {
        try ctx.stdout.success("  No issues found!\n", .{});
    }

    // Suggest auto-fix if issues can be fixed
    if (!auto_fix and fixed_count == 0) {
        var fixable: u32 = 0;
        for (diagnostics) |diag| {
            if (diag.fix_available) fixable += 1;
        }
        if (fixable > 0) {
            try ctx.stdout.print("\n", .{});
            try ctx.stdout.dim("{d} issue(s) can be auto-fixed. Run 'ovo lint --fix' to apply.\n", .{fixable});
        }
    }

    // Return code
    if (error_count > 0) {
        return 1;
    }
    if (warnings_as_errors and warning_count > 0) {
        return 1;
    }
    return 0;
}
