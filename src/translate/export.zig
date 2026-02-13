const std = @import("std");
const core = @import("../core/mod.zig");
const project_mod = @import("../core/project.zig");
const orchestrator = @import("../build/orchestrator.zig");

pub const ExportFormat = enum {
    cmake,
    xcode,
    msbuild,
    ninja,
    compile_commands,
    makefile,
    pkg_config,
};

pub fn parseExportFormat(value: []const u8) ?ExportFormat {
    if (std.mem.eql(u8, value, "cmake")) return .cmake;
    if (std.mem.eql(u8, value, "xcode")) return .xcode;
    if (std.mem.eql(u8, value, "msbuild")) return .msbuild;
    if (std.mem.eql(u8, value, "ninja")) return .ninja;
    if (std.mem.eql(u8, value, "compile_commands.json")) return .compile_commands;
    if (std.mem.eql(u8, value, "compile_commands")) return .compile_commands;
    if (std.mem.eql(u8, value, "makefile")) return .makefile;
    if (std.mem.eql(u8, value, "pkg-config")) return .pkg_config;
    if (std.mem.eql(u8, value, "pkg_config")) return .pkg_config;
    return null;
}

pub fn label(format: ExportFormat) []const u8 {
    return switch (format) {
        .cmake => "cmake",
        .xcode => "xcode",
        .msbuild => "msbuild",
        .ninja => "ninja",
        .compile_commands => "compile_commands.json",
        .makefile => "makefile",
        .pkg_config => "pkg-config",
    };
}

pub fn exportProject(allocator: std.mem.Allocator, project: project_mod.Project, format: ExportFormat) ![]const u8 {
    return switch (format) {
        .cmake => exportCMake(allocator, project),
        .xcode => exportPlaceholder(allocator, "xcode"),
        .msbuild => exportPlaceholder(allocator, "msbuild"),
        .ninja => exportNinja(allocator, project),
        .compile_commands => exportCompileCommands(allocator, project),
        .makefile => exportMakefile(allocator, project),
        .pkg_config => exportPkgConfig(allocator, project),
    };
}

pub fn defaultPathForFormat(allocator: std.mem.Allocator, project: project_mod.Project, format: ExportFormat) ![]const u8 {
    return switch (format) {
        .cmake => "CMakeLists.txt",
        .xcode => "OVOExport.xcodeproj/README.txt",
        .msbuild => "OVOExport.msbuild/README.txt",
        .ninja => "build.ninja",
        .compile_commands => "compile_commands.json",
        .makefile => "Makefile",
        .pkg_config => try std.fmt.allocPrint(allocator, "{s}.pc", .{project.name}),
    };
}

pub fn writeExport(path: []const u8, content: []const u8) !void {
    try core.fs.writeFile(path, content);
}

fn exportCMake(allocator: std.mem.Allocator, project: project_mod.Project) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "cmake_minimum_required(VERSION 3.16)\n");
    try out.print(allocator, "project({s} LANGUAGES C CXX)\n\n", .{project.name});
    for (project.targets) |target| {
        switch (target.kind) {
            .executable, .test_target => try out.print(allocator, "add_executable({s}\n", .{target.name}),
            .library_static => try out.print(allocator, "add_library({s} STATIC\n", .{target.name}),
            .library_shared => try out.print(allocator, "add_library({s} SHARED\n", .{target.name}),
        }
        for (target.sources) |source| {
            try out.print(allocator, "    {s}\n", .{source});
        }
        try out.appendSlice(allocator, ")\n");
        if (target.include_dirs.len > 0) {
            try out.print(allocator, "target_include_directories({s} PRIVATE\n", .{target.name});
            for (target.include_dirs) |include_dir| {
                try out.print(allocator, "    {s}\n", .{include_dir});
            }
            try out.appendSlice(allocator, ")\n");
        }
        if (target.link_libraries.len > 0) {
            try out.print(allocator, "target_link_libraries({s} PRIVATE\n", .{target.name});
            for (target.link_libraries) |lib| {
                try out.print(allocator, "    {s}\n", .{lib});
            }
            try out.appendSlice(allocator, ")\n");
        }
        try out.appendSlice(allocator, "\n");
    }
    return try out.toOwnedSlice(allocator);
}

fn exportNinja(allocator: std.mem.Allocator, project: project_mod.Project) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "rule cxx\n");
    try out.appendSlice(allocator, "  command = c++ -std=c++20 -O2 $in -o $out\n\n");
    for (project.targets) |target| {
        if (target.sources.len == 0) continue;
        const first_source = target.sources[0];
        try out.print(allocator, "build {s}: cxx {s}\n", .{ target.name, first_source });
    }
    return try out.toOwnedSlice(allocator);
}

fn exportCompileCommands(allocator: std.mem.Allocator, project: project_mod.Project) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "[\n");

    var first = true;
    for (project.targets) |target| {
        for (target.sources) |pattern| {
            const sources = orchestrator.resolveSourcePattern(allocator, pattern) catch blk: {
                const single = try allocator.alloc([]const u8, 1);
                single[0] = pattern;
                break :blk single;
            };
            for (sources) |source| {
                if (!first) try out.appendSlice(allocator, ",\n");
                first = false;
                var include_flags: std.ArrayList(u8) = .empty;
                defer include_flags.deinit(allocator);
                for (target.include_dirs) |include_dir| {
                    try include_flags.print(allocator, " -I{s}", .{include_dir});
                }
                try out.print(
                    allocator,
                    "  {{\"directory\":\".\",\"command\":\"c++ -std=c++20{s} -c {s}\",\"file\":\"{s}\"}}",
                    .{ include_flags.items, source, source },
                );
            }
        }
    }
    try out.appendSlice(allocator, "\n]\n");
    return try out.toOwnedSlice(allocator);
}

fn exportMakefile(allocator: std.mem.Allocator, project: project_mod.Project) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "CXX := c++\n");
    try out.appendSlice(allocator, "CXXFLAGS := -std=c++20 -O2\n\n");
    for (project.targets) |target| {
        if (target.sources.len == 0) continue;
        const first_source = target.sources[0];
        try out.print(allocator, "{s}: {s}\n", .{ target.name, first_source });
        try out.print(allocator, "\t$(CXX) $(CXXFLAGS) {s} -o {s}\n\n", .{ first_source, target.name });
    }
    return try out.toOwnedSlice(allocator);
}

fn exportPkgConfig(allocator: std.mem.Allocator, project: project_mod.Project) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "prefix=/usr/local\n");
    try out.appendSlice(allocator, "exec_prefix=${prefix}\n");
    try out.appendSlice(allocator, "libdir=${exec_prefix}/lib\n");
    try out.appendSlice(allocator, "includedir=${prefix}/include\n\n");
    try out.print(allocator, "Name: {s}\n", .{project.name});
    try out.appendSlice(allocator, "Description: Export from OVO\n");
    try out.print(allocator, "Version: {s}\n", .{project.version});
    try out.appendSlice(allocator, "Libs: -L${libdir}\n");
    try out.appendSlice(allocator, "Cflags: -I${includedir}\n");
    return try out.toOwnedSlice(allocator);
}

fn exportPlaceholder(allocator: std.mem.Allocator, format_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "OVO generated a placeholder for {s}. Native project emission can be expanded in a future revision.\n",
        .{format_name},
    );
}
