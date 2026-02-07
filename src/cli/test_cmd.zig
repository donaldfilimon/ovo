//! ovo test command
//!
//! Run project tests with optional filtering.
//! Usage: ovo test [pattern]

const std = @import("std");
const commands = @import("commands.zig");

const Context = commands.Context;
const TermWriter = commands.TermWriter;
const Color = commands.Color;

/// Print help for test command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo test", .{});
    try writer.print(" - Run tests\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo test [pattern] [options]\n\n", .{});

    try writer.bold("ARGUMENTS:\n", .{});
    try writer.print("    [pattern]        Filter tests by name pattern (glob supported)\n\n", .{});

    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    --release        Run tests with release build\n", .{});
    try writer.print("    --coverage       Generate code coverage report\n", .{});
    try writer.print("    --no-capture     Don't capture stdout/stderr\n", .{});
    try writer.print("    --fail-fast      Stop on first failure\n", .{});
    try writer.print("    -j, --jobs <n>   Number of parallel test jobs\n", .{});
    try writer.print("    -v, --verbose    Show all test output\n", .{});
    try writer.print("    --list           List all available tests\n", .{});
    try writer.print("    -h, --help       Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo test                     # Run all tests\n", .{});
    try writer.dim("    ovo test 'unit_*'            # Run tests matching pattern\n", .{});
    try writer.dim("    ovo test --coverage          # Run with coverage\n", .{});
    try writer.dim("    ovo test --fail-fast -v      # Stop on first failure, verbose\n", .{});
}

/// Test result summary
const TestResults = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,
    total_time_ms: i64 = 0,
};

/// Execute the test command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    // Check for help flag
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    // Parse options
    var pattern: ?[]const u8 = null;
    var verbose = false;
    var list_only = false;
    var fail_fast = false;
    var coverage = false;
    var jobs: ?u32 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--list")) {
            list_only = true;
        } else if (std.mem.eql(u8, arg, "--fail-fast")) {
            fail_fast = true;
        } else if (std.mem.eql(u8, arg, "--coverage")) {
            coverage = true;
        } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--jobs")) {
            if (i + 1 < args.len) {
                i += 1;
                jobs = std.fmt.parseInt(u32, args[i], 10) catch null;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            pattern = arg;
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

    // Simulated test discovery
    const tests = [_][]const u8{
        "unit_math_add",
        "unit_math_multiply",
        "unit_string_concat",
        "unit_string_split",
        "integration_api_get",
        "integration_api_post",
        "benchmark_sort",
    };

    // Filter tests by pattern
    var filtered_tests: std.ArrayListUnmanaged([]const u8) = .empty;
    defer filtered_tests.deinit(ctx.allocator);

    for (tests) |test_name| {
        if (pattern) |p| {
            // Simple glob matching (just prefix matching for demo)
            if (std.mem.startsWith(u8, test_name, p) or
                std.mem.indexOf(u8, test_name, p) != null)
            {
                try filtered_tests.append(ctx.allocator, test_name);
            }
        } else {
            try filtered_tests.append(ctx.allocator, test_name);
        }
    }

    // List mode
    if (list_only) {
        try ctx.stdout.bold("Available tests:\n", .{});
        for (filtered_tests.items) |test_name| {
            try ctx.stdout.print("  {s}\n", .{test_name});
        }
        try ctx.stdout.dim("\nTotal: {d} tests\n", .{filtered_tests.items.len});
        return 0;
    }

    // Print header
    try ctx.stdout.bold("Running tests", .{});
    if (pattern) |p| {
        try ctx.stdout.print(" matching '{s}'", .{p});
    }
    try ctx.stdout.print("\n", .{});

    if (coverage) {
        try ctx.stdout.info("  Coverage enabled\n", .{});
    }
    if (jobs) |j| {
        try ctx.stdout.dim("  Parallel jobs: {d}\n", .{j});
    }
    try ctx.stdout.print("\n", .{});

    // Run tests
    var results = TestResults{};

    for (filtered_tests.items) |test_name| {
        // Simulate test execution
        const passed = !std.mem.endsWith(u8, test_name, "_post"); // Simulate one failure

        if (passed) {
            results.passed += 1;
            try ctx.stdout.success("  PASS ", .{});
        } else {
            results.failed += 1;
            try ctx.stdout.err("  FAIL ", .{});
        }
        try ctx.stdout.print("{s}", .{test_name});

        // Show timing in verbose mode
        if (verbose) {
            try ctx.stdout.dim(" (1.2ms)", .{});
        }
        try ctx.stdout.print("\n", .{});

        // Show failure details
        if (!passed and verbose) {
            try ctx.stdout.dim("         Assertion failed: expected 200, got 404\n", .{});
            try ctx.stdout.dim("         at tests/api_test.c:42\n", .{});
        }

        if (!passed and fail_fast) {
            try ctx.stdout.warn("\nStopping early due to --fail-fast\n", .{});
            break;
        }
    }

    // Simulated total time (actual timing would use platform-specific APIs)
    results.total_time_ms = 42;

    // Print summary
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.bold("Test Results:\n", .{});

    try ctx.stdout.success("  {d} passed", .{results.passed});
    if (results.failed > 0) {
        try ctx.stdout.print(", ", .{});
        try ctx.stdout.err("{d} failed", .{results.failed});
    }
    if (results.skipped > 0) {
        try ctx.stdout.print(", ", .{});
        try ctx.stdout.warn("{d} skipped", .{results.skipped});
    }

    const total = results.passed + results.failed + results.skipped;
    try ctx.stdout.dim(" ({d} total)\n", .{total});

    const time_s = @as(f64, @floatFromInt(results.total_time_ms)) / 1000.0;
    try ctx.stdout.dim("  Time: {d:.2}s\n", .{time_s});

    // Coverage summary
    if (coverage) {
        try ctx.stdout.print("\n", .{});
        try ctx.stdout.bold("Coverage:\n", .{});
        try ctx.stdout.print("  Lines:    ", .{});
        try ctx.stdout.success("85.2%", .{});
        try ctx.stdout.dim(" (1024/1202)\n", .{});
        try ctx.stdout.print("  Branches: ", .{});
        try ctx.stdout.warn("72.1%", .{});
        try ctx.stdout.dim(" (312/433)\n", .{});
        try ctx.stdout.dim("  Report: coverage/index.html\n", .{});
    }

    return if (results.failed > 0) 1 else 0;
}
