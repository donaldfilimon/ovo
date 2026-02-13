const std = @import("std");
const project_mod = @import("../core/project.zig");

pub fn renderBuildZon(allocator: std.mem.Allocator, project: project_mod.Project) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    try output.appendSlice(allocator, ".{\n");
    try output.print(allocator, "    .ovo_schema = \"{s}\",\n", .{project.ovo_schema});
    try output.print(allocator, "    .name = \"{s}\",\n", .{project.name});
    try output.print(allocator, "    .version = \"{s}\",\n", .{project.version});
    if (project.license) |license| {
        try output.print(allocator, "    .license = \"{s}\",\n", .{license});
    }

    try output.appendSlice(allocator, "    .defaults = .{\n");
    try output.print(allocator, "        .cpp_standard = .{s},\n", .{project_mod.cppStandardLabel(project.defaults.cpp_standard)});
    try output.print(allocator, "        .optimize = \"{s}\",\n", .{project.defaults.optimize});
    try output.print(allocator, "        .backend = \"{s}\",\n", .{project.defaults.backend});
    try output.print(allocator, "        .output_dir = \"{s}\",\n", .{project.defaults.output_dir});
    try output.appendSlice(allocator, "    },\n");

    try output.appendSlice(allocator, "    .targets = .{\n");
    for (project.targets) |target| {
        try output.print(allocator, "        .{s} = .{{\n", .{target.name});
        try output.print(allocator, "            .type = .{s},\n", .{project_mod.targetTypeLabel(target.kind)});
        try output.appendSlice(allocator, "            .sources = .{\n");
        for (target.sources) |source| {
            try output.print(allocator, "                \"{s}\",\n", .{source});
        }
        try output.appendSlice(allocator, "            },\n");
        try output.appendSlice(allocator, "            .include_dirs = .{\n");
        for (target.include_dirs) |include_dir| {
            try output.print(allocator, "                \"{s}\",\n", .{include_dir});
        }
        try output.appendSlice(allocator, "            },\n");
        try output.appendSlice(allocator, "            .link = .{\n");
        for (target.link_libraries) |lib| {
            try output.print(allocator, "                \"{s}\",\n", .{lib});
        }
        try output.appendSlice(allocator, "            },\n");
        try output.appendSlice(allocator, "        },\n");
    }
    try output.appendSlice(allocator, "    },\n");

    try output.appendSlice(allocator, "    .dependencies = .{\n");
    for (project.dependencies) |dep| {
        try output.print(allocator, "        .{s} = \"{s}\",\n", .{ dep.name, dep.version });
    }
    try output.appendSlice(allocator, "    },\n");
    try output.appendSlice(allocator, "}\n");

    return try output.toOwnedSlice(allocator);
}
