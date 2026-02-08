//! ovo clean command
//!
//! Clean build artifacts and caches.
//! Usage: ovo clean

const std = @import("std");
const commands = @import("commands.zig");
const manifest = @import("manifest.zig");

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
        ctx.cwd.access(manifest.manifest_filename, .{}) catch break :blk false;
        break :blk true;
    };

    if (!manifest_exists) {
        try ctx.stderr.warn("warning: ", .{});
        try ctx.stderr.print("no {s} found, cleaning anyway\n", .{manifest.manifest_filename});
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
                    ctx.cwd.deleteTree(dir) catch {};
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
                ctx.cwd.deleteTree(dir) catch {};
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
                ctx.cwd.deleteTree(dir) catch {};
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

fn getDirSize(_: *Context, path: []const u8) u64 {
    return getDirSizeRecursive(path);
}

const SEEK_END: c_int = 2;
const SEEK_SET: c_int = 0;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

fn getFileSize(file_path: []const u8) u64 {
    var path_buf: [4096]u8 = undefined;
    if (file_path.len >= path_buf.len) return 0;
    @memcpy(path_buf[0..file_path.len], file_path);
    path_buf[file_path.len] = 0;
    const f = std.c.fopen(@ptrCast(&path_buf), "r") orelse return 0;
    defer _ = std.c.fclose(f);
    _ = fseek(f, 0, SEEK_END);
    const size = ftell(f);
    if (size < 0) return 0;
    return @intCast(size);
}

fn getDirentName(entry: *const std.c.dirent) [*:0]const u8 {
    return @ptrCast(&entry.name);
}

fn getDirSizeRecursive(path: []const u8) u64 {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return 0;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const dir = std.c.opendir(@ptrCast(&path_buf)) orelse return 0;
    defer _ = std.c.closedir(dir);

    var total: u64 = 0;
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
            total += getDirSizeRecursive(child_path);
        } else {
            total += getFileSize(child_path);
        }
    }
    return total;
}
