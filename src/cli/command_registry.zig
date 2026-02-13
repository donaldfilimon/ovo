const std = @import("std");

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
        .name = "new",
        .summary = "Create a new project",
        .usage = "ovo new <name>",
        .group = .basic,
        .examples = &.{"ovo new myapp"},
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
        .usage = "ovo build [target]",
        .group = .basic,
        .examples = &.{"ovo build"},
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
        .usage = "ovo add <package> [version]",
        .group = .package,
        .examples = &.{
            "ovo add zlib",
            "ovo add fmt 10.2.1",
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
        .usage = "ovo fetch",
        .group = .package,
        .examples = &.{"ovo fetch"},
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
