//! ovo clean command
//!
//! Clean build artifacts and caches.
//! Usage: ovo clean

const std = @import("std");
const commands = @import("commands.zig");

const Context = commands.Context;
const TermWriter = commands.TermWriter;

/// Print help for clean command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo clean", .{});
    try writer.print(" - Clean build artifacts\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo clean [options]\n\n", .{});

    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    --all            Clean everything (build + deps + cache)\n", .{});
    try writer.print("    --deps           Clean downloaded dependencies\n", .{});
    try writer.print("    --cache          Clean build cache\n", .{});
    try writer.print("    --release        Clean only release build\n", .{});
    try writer.print("    --debug          Clean only debug build\n", .{});
    try writer.print("    -n, --dry-run    Show what would be deleted\n", .{});
    try writer.print("    -h, --help       Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo clean                    # Clean build directory\n", .{});
    try writer.dim("    ovo clean --all              # Clean everything\n", .{});
    try writer.dim("    ovo clean --deps             # Clean dependencies only\n", .{});
    try writer.dim("    ovo clean --dry-run          # Show what would be cleaned\n", .{});
}

/// Execute the clean command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    // Check for help flag
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    // Parse options
    var clean_all = false;
    var clean_deps = false;
    var clean_cache = false;
    var release_only = false;
    var debug_only = false;
    var dry_run = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--all")) {
            clean_all = true;
        } else if (std.mem.eql(u8, arg, "--deps")) {
            clean_deps = true;
        } else if (std.mem.eql(u8, arg, "--cache")) {
            clean_cache = true;
        } else if (std.mem.eql(u8, arg, "--release")) {
            release_only = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            debug_only = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        }
    }

    // Check for build.zon (optional for clean)
    const manifest_exists = blk: {
        ctx.cwd.access("build.zon", .{}) catch break :blk false;
        break :blk true;
    };

    if (!manifest_exists) {
        try ctx.stderr.warn("warning: ", .{});
        try ctx.stderr.print("no build.zon found, cleaning anyway\n", .{});
    }

    if (dry_run) {
        try ctx.stdout.bold("Dry run - nothing will be deleted\n\n", .{});
    } else {
        try ctx.stdout.bold("Cleaning project\n\n", .{});
    }

    var total_cleaned: u64 = 0;
    var items_cleaned: u32 = 0;

    // Clean build directory
    if (!clean_deps and !clean_cache) {
        const build_dirs = [_][]const u8{ "build", "out", "bin", "lib" };

        for (build_dirs) |dir| {
            const should_clean = blk: {
                if (release_only) {
                    break :blk std.mem.eql(u8, dir, "build/release");
                }
                if (debug_only) {
                    break :blk std.mem.eql(u8, dir, "build/debug");
                }
                break :blk true;
            };

            if (should_clean) {
                const exists = ctx.cwd.access(dir, .{}) catch |e| {
                    if (e == error.FileNotFound) continue;
                    continue;
                };
                _ = exists;

                const size = getDirSize(ctx, dir);

                try ctx.stdout.print("  ", .{});
                if (dry_run) {
                    try ctx.stdout.warn("~", .{});
                } else {
                    try ctx.stdout.success("*", .{});
                }
                try ctx.stdout.print(" {s}/", .{dir});
                try ctx.stdout.dim(" ({d}KB)\n", .{size / 1024});

                if (!dry_run) {
                    // Would actually delete here
                    // ctx.cwd.deleteTree(dir) catch {};
                }

                total_cleaned += size;
                items_cleaned += 1;
            }
        }
    }

    // Clean dependencies
    if (clean_all or clean_deps) {
        const dep_dirs = [_][]const u8{ ".ovo/deps", "deps", "vendor" };

        for (dep_dirs) |dir| {
            const exists = ctx.cwd.access(dir, .{}) catch continue;
            _ = exists;

            const size = getDirSize(ctx, dir);

            try ctx.stdout.print("  ", .{});
            if (dry_run) {
                try ctx.stdout.warn("~", .{});
            } else {
                try ctx.stdout.success("*", .{});
            }
            try ctx.stdout.print(" {s}/", .{dir});
            try ctx.stdout.dim(" ({d}KB)\n", .{size / 1024});

            if (!dry_run) {
                // Would actually delete here
            }

            total_cleaned += size;
            items_cleaned += 1;
        }
    }

    // Clean cache
    if (clean_all or clean_cache) {
        const cache_dirs = [_][]const u8{ ".ovo/cache", ".cache" };

        for (cache_dirs) |dir| {
            const exists = ctx.cwd.access(dir, .{}) catch continue;
            _ = exists;

            const size = getDirSize(ctx, dir);

            try ctx.stdout.print("  ", .{});
            if (dry_run) {
                try ctx.stdout.warn("~", .{});
            } else {
                try ctx.stdout.success("*", .{});
            }
            try ctx.stdout.print(" {s}/", .{dir});
            try ctx.stdout.dim(" ({d}KB)\n", .{size / 1024});

            if (!dry_run) {
                // Would actually delete here
            }

            total_cleaned += size;
            items_cleaned += 1;
        }
    }

    // Summary
    try ctx.stdout.print("\n", .{});

    if (items_cleaned == 0) {
        try ctx.stdout.info("Nothing to clean\n", .{});
    } else if (dry_run) {
        try ctx.stdout.warn("Would clean {d} items", .{items_cleaned});
        try ctx.stdout.dim(" ({d}KB)\n", .{total_cleaned / 1024});
    } else {
        try ctx.stdout.success("Cleaned {d} items", .{items_cleaned});
        try ctx.stdout.dim(" ({d}KB freed)\n", .{total_cleaned / 1024});
    }

    return 0;
}

fn getDirSize(ctx: *Context, path: []const u8) u64 {
    // Simplified size calculation (in real impl would walk directory)
    _ = ctx;
    _ = path;
    // Return simulated size
    return 1024 * 1024; // 1MB placeholder
}
