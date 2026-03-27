const std = @import("std");
const testing = std.testing;

pub const CommandGroup = enum {
    basic,
    package,
    tooling,
    translation,
};

pub const CommandSpec = struct {
    name: []const u8,
    summary: []const u8,
    usage: []const u8,
    group: CommandGroup,
    examples: []const []const u8 = &.{},
};

pub const commands = [_]CommandSpec{
    .{
        .name = "version",
        .summary = "Show version information",
        .usage = "ovo version",
        .group = .basic,
        .examples = &.{"ovo version"},
    },
    .{
        .name = "new",
        .summary = "Create a new project",
        .usage = "ovo new <relative_path>",
        .group = .basic,
        .examples = &.{ "ovo new myapp", "ovo new apps/myapp" },
    },
    .{
        .name = "init",
        .summary = "Initialize OVO in current directory",
        .usage = "ovo init",
        .group = .basic,
        .examples = &.{"ovo init"},
    },
    .{
        .name = "build",
        .summary = "Build the project",
        .usage = "ovo build [--force] [-jN] [--jobs=N] [target]",
        .group = .basic,
        .examples = &.{ "ovo build", "ovo build -j8", "ovo build --jobs=4 mylib" },
    },
    .{
        .name = "run",
        .summary = "Build and run target",
        .usage = "ovo run [target] [-- args]",
        .group = .basic,
        .examples = &.{"ovo run app -- --port 8080"},
    },
    .{
        .name = "test",
        .summary = "Run tests",
        .usage = "ovo test [pattern]",
        .group = .basic,
        .examples = &.{"ovo test unit"},
    },
    .{
        .name = "clean",
        .summary = "Remove build artifacts",
        .usage = "ovo clean",
        .group = .basic,
        .examples = &.{"ovo clean"},
    },
    .{
        .name = "install",
        .summary = "Install project artifacts",
        .usage = "ovo install",
        .group = .basic,
        .examples = &.{"ovo install"},
    },
    .{
        .name = "add",
        .summary = "Add a dependency",
        .usage = "ovo add <package> [version] [--git <url>|--path <path>|--registry <version>]",
        .group = .package,
        .examples = &.{
            "ovo add zlib",
            "ovo add fmt 10.2.1",
            "ovo add fmt --git https://github.com/fmtlib/fmt.git",
            "ovo add fmt --path ../vendor/fmt",
            "ovo add fmt --registry latest",
        },
    },
    .{
        .name = "remove",
        .summary = "Remove a dependency",
        .usage = "ovo remove <package>",
        .group = .package,
        .examples = &.{"ovo remove zlib"},
    },
    .{
        .name = "fetch",
        .summary = "Download dependencies",
        .usage = "ovo fetch [--refresh]",
        .group = .package,
        .examples = &.{
            "ovo fetch",
            "ovo fetch --refresh",
        },
    },
    .{
        .name = "update",
        .summary = "Update dependencies",
        .usage = "ovo update [pkg]",
        .group = .package,
        .examples = &.{"ovo update"},
    },
    .{
        .name = "lock",
        .summary = "Generate lock file",
        .usage = "ovo lock",
        .group = .package,
        .examples = &.{"ovo lock"},
    },
    .{
        .name = "deps",
        .summary = "Show dependency tree",
        .usage = "ovo deps",
        .group = .package,
        .examples = &.{"ovo deps"},
    },
    .{
        .name = "doc",
        .summary = "Generate documentation",
        .usage = "ovo doc",
        .group = .tooling,
        .examples = &.{"ovo doc"},
    },
    .{
        .name = "doctor",
        .summary = "Diagnose environment",
        .usage = "ovo doctor",
        .group = .tooling,
        .examples = &.{"ovo doctor"},
    },
    .{
        .name = "fmt",
        .summary = "Format source code",
        .usage = "ovo fmt",
        .group = .tooling,
        .examples = &.{"ovo fmt"},
    },
    .{
        .name = "lint",
        .summary = "Run linter",
        .usage = "ovo lint",
        .group = .tooling,
        .examples = &.{"ovo lint"},
    },
    .{
        .name = "info",
        .summary = "Show project information",
        .usage = "ovo info",
        .group = .tooling,
        .examples = &.{"ovo info"},
    },
    .{
        .name = "tree",
        .summary = "Visualize the build graph",
        .usage = "ovo tree [--format=ascii|dot|json|mermaid] [--target=name]",
        .group = .tooling,
        .examples = &.{
            "ovo tree",
            "ovo tree --format=dot",
            "ovo tree --target=mylib",
        },
    },
    .{
        .name = "import",
        .summary = "Import from another project format",
        .usage = "ovo import <format> [path]",
        .group = .translation,
        .examples = &.{"ovo import cmake ."},
    },
    .{
        .name = "export",
        .summary = "Export to another project format",
        .usage = "ovo export <format> [output_path]",
        .group = .translation,
        .examples = &.{
            "ovo export cmake",
            "ovo export compile_commands.json build/compile_commands.json",
        },
    },
};

const group_order = [_]CommandGroup{ .basic, .package, .tooling, .translation };

const GlobalOption = struct {
    option: []const u8,
    description: []const u8,
};

const global_options = [_]GlobalOption{
    .{ .option = "--help, -h", .description = "Show help" },
    .{ .option = "--version, -V", .description = "Show version" },
    .{ .option = "--verbose", .description = "Enable verbose output" },
    .{ .option = "--quiet", .description = "Minimize output" },
    .{ .option = "--cwd <path>", .description = "Override working directory" },
    .{ .option = "--profile <name>", .description = "Build profile override" },
};

pub fn find(name: []const u8) ?CommandSpec {
    for (commands) |spec| {
        if (std.mem.eql(u8, spec.name, name)) {
            return spec;
        }
    }
    return null;
}

pub fn groupLabel(group: CommandGroup) []const u8 {
    return switch (group) {
        .basic => "Basic",
        .package => "Package Management",
        .tooling => "Tooling",
        .translation => "Project Translation",
    };
}

pub fn renderCommandReferenceMarkdown(allocator: std.mem.Allocator) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    try output.appendSlice(allocator, "# Command Reference\n");
    for (group_order) |group| {
        try appendGroupSection(allocator, &output, group);
    }
    try appendSelectedExamples(allocator, &output);
    try appendGlobalOptions(allocator, &output);
    return try output.toOwnedSlice(allocator);
}

fn appendGroupSection(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    group: CommandGroup,
) !void {
    try output.print(allocator, "\n## {s}\n\n", .{groupSectionHeading(group)});
    try output.appendSlice(allocator, "| Command | Description | Usage |\n");
    try output.appendSlice(allocator, "|---------|-------------|-------|\n");

    for (commands) |command| {
        if (command.group != group) continue;

        try output.appendSlice(allocator, "| `");
        try output.appendSlice(allocator, command.name);
        try output.appendSlice(allocator, "` | ");
        try appendEscapedTableCell(allocator, output, command.summary);
        try output.appendSlice(allocator, " | `");
        try appendEscapedTableCell(allocator, output, command.usage);
        try output.appendSlice(allocator, "` |\n");
    }
}

fn appendSelectedExamples(allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
    var wrote_header = false;
    for (commands) |command| {
        if (command.examples.len <= 1) continue;
        if (!wrote_header) {
            try output.appendSlice(allocator, "\n## Selected Examples\n");
            wrote_header = true;
        }

        try output.print(allocator, "\n### `{s}`\n\n```bash\n", .{command.name});
        for (command.examples) |example| {
            try output.print(allocator, "{s}\n", .{example});
        }
        try output.appendSlice(allocator, "```\n");
    }
}

fn appendGlobalOptions(allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
    try output.appendSlice(allocator, "\n## Global Options\n\n");
    try output.appendSlice(allocator, "| Option | Description |\n");
    try output.appendSlice(allocator, "|--------|-------------|\n");

    for (global_options) |option| {
        try output.appendSlice(allocator, "| `");
        try output.appendSlice(allocator, option.option);
        try output.appendSlice(allocator, "` | ");
        try appendEscapedTableCell(allocator, output, option.description);
        try output.appendSlice(allocator, " |\n");
    }
}

fn appendEscapedTableCell(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: []const u8,
) !void {
    for (value) |char| {
        if (char == '|') {
            try output.appendSlice(allocator, "\\|");
        } else {
            try output.append(allocator, char);
        }
    }
}

fn groupSectionHeading(group: CommandGroup) []const u8 {
    return switch (group) {
        .basic => "Basic Commands",
        .package => "Package Management",
        .tooling => "Tooling",
        .translation => "Translation",
    };
}

test "renderCommandReferenceMarkdown includes escaped usage and global options" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const markdown = try renderCommandReferenceMarkdown(arena.allocator());
    try testing.expect(std.mem.indexOf(u8, markdown, "# Command Reference") != null);
    try testing.expect(std.mem.indexOf(u8, markdown, "ovo version") != null);
    try testing.expect(std.mem.indexOf(u8, markdown, "ovo add <package> [version] [--git <url>\\|--path <path>\\|--registry <version>]") != null);
    try testing.expect(std.mem.indexOf(u8, markdown, "ovo tree [--format=ascii\\|dot\\|json\\|mermaid] [--target=name]") != null);
    try testing.expect(std.mem.indexOf(u8, markdown, "## Global Options") != null);
    try testing.expect(std.mem.indexOf(u8, markdown, "## Selected Examples") != null);
}
