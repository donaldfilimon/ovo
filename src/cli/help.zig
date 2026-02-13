const Context = @import("context.zig").Context;
const registry = @import("command_registry.zig");
const version = @import("../version.zig");

const ordered_groups = [_]registry.CommandGroup{
    .basic,
    .package,
    .tooling,
    .translation,
};

pub fn printGlobalHelp(ctx: *Context) !void {
    try ctx.print("OVO {s}\n", .{version.string});
    try ctx.print("ZON-based package manager and build system for C/C++.\n\n", .{});
    try ctx.print("Usage:\n  ovo <command> [options]\n\n", .{});

    try ctx.print("Global Options:\n", .{});
    try ctx.print("  --help, -h            Show help\n", .{});
    try ctx.print("  --version, -V         Show version\n", .{});
    try ctx.print("  --verbose             Enable verbose output\n", .{});
    try ctx.print("  --quiet               Minimize output\n", .{});
    try ctx.print("  --cwd <path>          Override working directory\n", .{});
    try ctx.print("  --profile <name>      Build profile override\n", .{});

    for (ordered_groups) |group| {
        try ctx.print("\n{s}:\n", .{registry.groupLabel(group)});
        for (registry.commands) |spec| {
            if (spec.group == group) {
                try ctx.print("  {s}\t{s}\n", .{ spec.name, spec.summary });
            }
        }
    }
}

pub fn printCommandHelp(ctx: *Context, spec: registry.CommandSpec) !void {
    try ctx.print("{s}\n", .{spec.summary});
    try ctx.print("Usage:\n  {s}\n", .{spec.usage});

    if (spec.examples.len > 0) {
        try ctx.print("\nExamples:\n", .{});
        for (spec.examples) |example| {
            try ctx.print("  {s}\n", .{example});
        }
    }
}
