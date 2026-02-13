const std = @import("std");
const core = @import("../core/mod.zig");
const project_mod = @import("../core/project.zig");
const zon = @import("../zon/mod.zig");

pub fn createProjectSkeleton(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    project_name: []const u8,
) !void {
    if (root_path.len > 0 and !std.mem.eql(u8, root_path, ".")) {
        try core.fs.ensureDir(root_path);
    }

    const src_dir = if (std.mem.eql(u8, root_path, ".")) "src" else try std.fmt.allocPrint(allocator, "{s}/src", .{root_path});
    const tests_dir = if (std.mem.eql(u8, root_path, ".")) "tests" else try std.fmt.allocPrint(allocator, "{s}/tests", .{root_path});
    const include_dir = if (std.mem.eql(u8, root_path, ".")) "include" else try std.fmt.allocPrint(allocator, "{s}/include", .{root_path});
    try core.fs.ensureDir(src_dir);
    try core.fs.ensureDir(tests_dir);
    try core.fs.ensureDir(include_dir);

    const main_cpp_path = if (std.mem.eql(u8, root_path, "."))
        "src/main.cpp"
    else
        try std.fmt.allocPrint(allocator, "{s}/src/main.cpp", .{root_path});

    if (!core.fs.fileExists(main_cpp_path)) {
        try core.fs.writeFile(
            main_cpp_path,
            \\#include <iostream>
            \\
            \\int main() {
            \\    std::cout << "Hello from OVO!" << std::endl;
            \\    return 0;
            \\}
            \\
        );
    }

    const test_cpp_path = if (std.mem.eql(u8, root_path, "."))
        "tests/main_test.cpp"
    else
        try std.fmt.allocPrint(allocator, "{s}/tests/main_test.cpp", .{root_path});
    if (!core.fs.fileExists(test_cpp_path)) {
        try core.fs.writeFile(
            test_cpp_path,
            \\#include <cassert>
            \\
            \\int main() {
            \\    assert(1 + 1 == 2);
            \\    return 0;
            \\}
            \\
        );
    }

    const app_target = project_mod.Target{
        .name = project_name,
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
        .include_dirs = &.{"include"},
    };
    const test_target = project_mod.Target{
        .name = try std.fmt.allocPrint(allocator, "{s}_test", .{project_name}),
        .kind = .test_target,
        .sources = &.{"tests/main_test.cpp"},
        .include_dirs = &.{"include"},
    };
    const targets = try allocator.alloc(project_mod.Target, 2);
    targets[0] = app_target;
    targets[1] = test_target;

    const project = project_mod.Project{
        .ovo_schema = "0",
        .name = project_name,
        .version = "0.1.0",
        .license = "MIT",
        .targets = targets,
    };

    const build_zon = try zon.writer.renderBuildZon(allocator, project);
    const build_zon_path = if (std.mem.eql(u8, root_path, "."))
        "build.zon"
    else
        try std.fmt.allocPrint(allocator, "{s}/build.zon", .{root_path});
    if (!core.fs.fileExists(build_zon_path)) {
        try core.fs.writeFile(build_zon_path, build_zon);
    }
}
