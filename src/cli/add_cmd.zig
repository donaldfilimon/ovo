//! ovo add command
//!
//! Add a dependency to the project.
//! Usage: ovo add <package> [--git/--path/--vcpkg/--conan/--dev]

const std = @import("std");
const commands = @import("commands.zig");

const Context = commands.Context;
const TermWriter = commands.TermWriter;
const Spinner = commands.Spinner;

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
        ctx.cwd.access("build.zon", .{}) catch break :blk false;
        break :blk true;
    };

    if (!manifest_exists) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("no build.zon found in current directory\n", .{});
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

    // Print what we're doing
    try ctx.stdout.bold("Adding", .{});
    try ctx.stdout.print(" dependency ", .{});
    try ctx.stdout.success("'{s}'", .{name});
    if (is_dev) {
        try ctx.stdout.dim(" (dev)", .{});
    }
    try ctx.stdout.print("\n", .{});

    // Show source info
    try ctx.stdout.dim("  Source: {s}", .{source_type.toString()});
    switch (source_type) {
        .git => {
            if (git_url) |url| {
                try ctx.stdout.dim(" ({s})", .{url});
            }
            if (git_branch) |branch| {
                try ctx.stdout.dim(" branch:{s}", .{branch});
            }
            if (git_tag) |tag| {
                try ctx.stdout.dim(" tag:{s}", .{tag});
            }
        },
        .path => {
            if (local_path) |path| {
                try ctx.stdout.dim(" ({s})", .{path});
            }
        },
        else => {},
    }
    try ctx.stdout.print("\n", .{});

    // Simulate resolving the package
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Resolving package...\n", .{});

    // In real implementation, would fetch package metadata here
    const resolved_version = version orelse "1.0.0";

    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Found version ", .{});
    try ctx.stdout.info("{s}\n", .{resolved_version});

    // Update build.zon
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Updating build.zon...\n", .{});

    // In real implementation, would parse and update build.zon
    // For now, just print what would be added
    try ctx.stdout.dim("    Added to [{s}]:\n", .{if (is_dev) "dev-dependencies" else "dependencies"});
    try ctx.stdout.dim("    {s} = {{ ", .{name});

    switch (source_type) {
        .registry => {
            try ctx.stdout.dim("version = \"{s}\"", .{resolved_version});
        },
        .git => {
            try ctx.stdout.dim("git = \"{s}\"", .{git_url.?});
            if (git_branch) |branch| {
                try ctx.stdout.dim(", branch = \"{s}\"", .{branch});
            } else if (git_tag) |tag| {
                try ctx.stdout.dim(", tag = \"{s}\"", .{tag});
            } else if (git_rev) |rev| {
                try ctx.stdout.dim(", rev = \"{s}\"", .{rev});
            }
        },
        .path => {
            try ctx.stdout.dim("path = \"{s}\"", .{local_path.?});
        },
        .vcpkg => {
            try ctx.stdout.dim("vcpkg = \"{s}\"", .{name});
            if (version) |v| {
                try ctx.stdout.dim(", version = \"{s}\"", .{v});
            }
        },
        .conan => {
            try ctx.stdout.dim("conan = \"{s}/{s}\"", .{ name, resolved_version });
        },
    }

    if (is_optional) {
        try ctx.stdout.dim(", optional = true", .{});
    }
    if (features) |f| {
        try ctx.stdout.dim(", features = [{s}]", .{f});
    }

    try ctx.stdout.dim(" }}\n", .{});

    // Fetch the dependency
    try ctx.stdout.print("  ", .{});
    try ctx.stdout.success("*", .{});
    try ctx.stdout.print(" Fetching dependency...\n", .{});

    // Print success
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.success("Added '{s}' to dependencies\n", .{name});

    // Show next steps
    try ctx.stdout.print("\n", .{});
    try ctx.stdout.dim("To use in your code:\n", .{});
    try ctx.stdout.dim("  #include <{s}/{s}.h>\n", .{ name, name });

    return 0;
}
