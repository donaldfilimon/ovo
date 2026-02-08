//! ovo add command
//!
//! Add a dependency to the project.
//! Usage: ovo add <package> [--git/--path/--vcpkg/--conan/--dev]

const std = @import("std");
const commands = @import("commands.zig");
const manifest = @import("manifest.zig");
const zon_parser = @import("zon").parser;
const zon_schema = @import("zon").schema;
const zon_writer = @import("zon").writer;

const Context = commands.Context;
const TermWriter = commands.TermWriter;

/// Dependency source type
pub const SourceType = enum {
    registry,
    git,
    path,
    vcpkg,
    conan,

    pub fn toString(self: SourceType) []const u8 {
        return switch (self) {
            .registry => "registry",
            .git => "git",
            .path => "path",
            .vcpkg => "vcpkg",
            .conan => "conan",
        };
    }
};

/// Print help for add command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo add", .{});
    try writer.print(" - Add a dependency\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo add <package> [options]\n\n", .{});

    try writer.bold("ARGUMENTS:\n", .{});
    try writer.print("    <package>        Package name or URL\n\n", .{});

    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    --version <ver>  Specify version requirement\n", .{});
    try writer.print("    --git <url>      Add from git repository\n", .{});
    try writer.print("    --branch <name>  Git branch (with --git)\n", .{});
    try writer.print("    --tag <name>     Git tag (with --git)\n", .{});
    try writer.print("    --rev <sha>      Git revision (with --git)\n", .{});
    try writer.print("    --path <dir>     Add from local path\n", .{});
    try writer.print("    --vcpkg          Install via vcpkg\n", .{});
    try writer.print("    --conan          Install via conan\n", .{});
    try writer.print("    --dev            Add as dev dependency\n", .{});
    try writer.print("    --optional       Mark as optional dependency\n", .{});
    try writer.print("    --features <f>   Enable specific features\n", .{});
    try writer.print("    -h, --help       Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo add fmt                              # Add from registry\n", .{});
    try writer.dim("    ovo add fmt --version \">=8.0\"            # Specific version\n", .{});
    try writer.dim("    ovo add --git https://github.com/org/lib # From git\n", .{});
    try writer.dim("    ovo add --path ../mylib                  # Local path\n", .{});
    try writer.dim("    ovo add boost --vcpkg                    # Via vcpkg\n", .{});
    try writer.dim("    ovo add catch2 --dev                     # Dev dependency\n", .{});
}

/// Execute the add command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    // Check for help flag
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    // Parse options
    var package_name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var source_type: SourceType = .registry;
    var git_url: ?[]const u8 = null;
    var git_branch: ?[]const u8 = null;
    var git_tag: ?[]const u8 = null;
    var git_rev: ?[]const u8 = null;
    var local_path: ?[]const u8 = null;
    var is_dev = false;
    var is_optional = false;
    var features: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--version") and i + 1 < args.len) {
            i += 1;
            version = args[i];
        } else if (std.mem.startsWith(u8, arg, "--version=")) {
            version = arg["--version=".len..];
        } else if (std.mem.eql(u8, arg, "--git") and i + 1 < args.len) {
            i += 1;
            git_url = args[i];
            source_type = .git;
        } else if (std.mem.startsWith(u8, arg, "--git=")) {
            git_url = arg["--git=".len..];
            source_type = .git;
        } else if (std.mem.eql(u8, arg, "--branch") and i + 1 < args.len) {
            i += 1;
            git_branch = args[i];
        } else if (std.mem.eql(u8, arg, "--tag") and i + 1 < args.len) {
            i += 1;
            git_tag = args[i];
        } else if (std.mem.eql(u8, arg, "--rev") and i + 1 < args.len) {
            i += 1;
            git_rev = args[i];
        } else if (std.mem.eql(u8, arg, "--path") and i + 1 < args.len) {
            i += 1;
            local_path = args[i];
            source_type = .path;
        } else if (std.mem.startsWith(u8, arg, "--path=")) {
            local_path = arg["--path=".len..];
            source_type = .path;
        } else if (std.mem.eql(u8, arg, "--vcpkg")) {
            source_type = .vcpkg;
        } else if (std.mem.eql(u8, arg, "--conan")) {
            source_type = .conan;
        } else if (std.mem.eql(u8, arg, "--dev")) {
            is_dev = true;
        } else if (std.mem.eql(u8, arg, "--optional")) {
            is_optional = true;
        } else if (std.mem.eql(u8, arg, "--features") and i + 1 < args.len) {
            i += 1;
            features = args[i];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            package_name = arg;
        }
    }

    // Check for build.zon
    const manifest_exists = blk: {
        ctx.cwd.access(manifest.manifest_filename, .{}) catch break :blk false;
        break :blk true;
    };

    if (!manifest_exists) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("no {s} found in current directory\n", .{manifest.manifest_filename});
        try ctx.stderr.dim("Run 'ovo init' to create a new project.\n", .{});
        return 1;
    }

    // Validate arguments
    if (package_name == null and git_url == null and local_path == null) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("missing package name\n", .{});
        try ctx.stderr.dim("Usage: ovo add <package>\n", .{});
        return 1;
    }

    // Derive package name from git URL if needed
    const name = package_name orelse blk: {
        if (git_url) |url| {
            // Extract name from URL (e.g., "https://github.com/org/repo.git" -> "repo")
            var clean_url = url;
            if (std.mem.endsWith(u8, clean_url, ".git")) {
                clean_url = clean_url[0 .. clean_url.len - 4];
            }
            if (std.mem.lastIndexOf(u8, clean_url, "/")) |idx| {
                break :blk clean_url[idx + 1 ..];
            }
        }
        if (local_path) |path| {
            break :blk std.fs.path.basename(path);
        }
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("could not determine package name\n", .{});
        return 1;
    };

    // Parse existing build.zon
    var project = zon_parser.parseFile(ctx.allocator, manifest.manifest_filename) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to parse {s}: {}\n", .{ manifest.manifest_filename, err });
        return 1;
    };
    defer project.deinit(ctx.allocator);

    // Check if dependency already exists
    if (project.dependencies) |deps| {
        for (deps) |dep| {
            if (std.mem.eql(u8, dep.name, name)) {
                try ctx.stderr.warn("warning: ", .{});
                try ctx.stderr.print("'{s}' is already a dependency\n", .{name});
                return 1;
            }
        }
    }

    // Build new dependency source based on parsed flags
    const dep_source: zon_schema.DependencySource = switch (source_type) {
        .git => .{ .git = .{
            .url = try ctx.allocator.dupe(u8, git_url orelse ""),
            .branch = if (git_branch) |b| try ctx.allocator.dupe(u8, b) else null,
            .tag = if (git_tag) |t| try ctx.allocator.dupe(u8, t) else null,
            .commit = if (git_rev) |r| try ctx.allocator.dupe(u8, r) else null,
        } },
        .path => .{ .path = try ctx.allocator.dupe(u8, local_path orelse ".") },
        .vcpkg => .{ .vcpkg = .{
            .name = try ctx.allocator.dupe(u8, name),
            .version = if (version) |v| try ctx.allocator.dupe(u8, v) else null,
        } },
        .conan => .{ .conan = .{
            .name = try ctx.allocator.dupe(u8, name),
            .version = try ctx.allocator.dupe(u8, version orelse "1.0.0"),
        } },
        .registry => .{ .system = .{
            .name = try ctx.allocator.dupe(u8, name),
        } },
    };

    const new_dep = zon_schema.Dependency{
        .name = try ctx.allocator.dupe(u8, name),
        .source = dep_source,
    };

    // Grow the dependencies array: allocate new slice, copy old entries, append new
    const old_deps = project.dependencies orelse &[_]zon_schema.Dependency{};
    const new_deps = try ctx.allocator.alloc(zon_schema.Dependency, old_deps.len + 1);
    @memcpy(new_deps[0..old_deps.len], old_deps);
    new_deps[old_deps.len] = new_dep;

    // Free the old dependencies slice (but not the individual entries, they are still referenced)
    if (project.dependencies) |deps| {
        ctx.allocator.free(deps);
    }
    project.dependencies = new_deps;

    // Write back to build.zon
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Updating {s}...\n", .{manifest.manifest_filename});

    const content = zon_writer.writeProject(ctx.allocator, &project, .{}) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to serialize {s}: {}\n", .{ manifest.manifest_filename, err });
        return 1;
    };
    defer ctx.allocator.free(content);

    const file = ctx.cwd.createFile(manifest.manifest_filename, .{}) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to write {s}: {}\n", .{ manifest.manifest_filename, err });
        return 1;
    };
    defer file.close();
    file.writeAll(content) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to write {s}: {}\n", .{ manifest.manifest_filename, err });
        return 1;
    };

    // Print success
    try ctx.stdout.print("\n", .{});
    const dep_kind = if (is_dev) "dev-dependencies" else "dependencies";
    try ctx.stdout.success("Added '{s}' to {s}\n", .{ name, dep_kind });

    // Show source info
    try ctx.stdout.dim("  Source: {s}\n", .{source_type.toString()});
    if (is_optional) {
        try ctx.stdout.dim("  Optional: yes\n", .{});
    }
    if (features) |f| {
        try ctx.stdout.dim("  Features: {s}\n", .{f});
    }

    return 0;
}
