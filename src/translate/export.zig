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
        .xcode => exportXcode(allocator, project),
        .msbuild => exportMSBuild(allocator, project),
        .ninja => exportNinja(allocator, project),
        .compile_commands => exportCompileCommands(allocator, project),
        .makefile => exportMakefile(allocator, project),
        .pkg_config => exportPkgConfig(allocator, project),
    };
}

pub fn defaultPathForFormat(allocator: std.mem.Allocator, project: project_mod.Project, format: ExportFormat) ![]const u8 {
    return switch (format) {
        .cmake => "CMakeLists.txt",
        .xcode => try std.fmt.allocPrint(allocator, "{s}.xcodeproj/project.pbxproj", .{project.name}),
        .msbuild => try std.fmt.allocPrint(allocator, "{s}.vcxproj", .{project.name}),
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

fn exportMSBuild(allocator: std.mem.Allocator, project: project_mod.Project) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const target = primaryTarget(project);
    const config_type = if (target) |t| msbuildConfigurationType(t.kind) else "Application";
    const lang_std = msbuildLanguageStandard(project.defaults.cpp_standard);
    const proj_guid = deterministicGuid(project.name);

    try out.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    try out.appendSlice(allocator, "<Project DefaultTargets=\"Build\" xmlns=\"http://schemas.microsoft.com/developer/msbuild/2003\">\n");

    // Project configurations
    try out.appendSlice(allocator, "  <ItemGroup Label=\"ProjectConfigurations\">\n");
    for ([_][]const u8{ "Debug", "Release" }) |cfg| {
        try out.print(allocator, "    <ProjectConfiguration Include=\"{s}|x64\">\n", .{cfg});
        try out.print(allocator, "      <Configuration>{s}</Configuration>\n", .{cfg});
        try out.appendSlice(allocator, "      <Platform>x64</Platform>\n");
        try out.appendSlice(allocator, "    </ProjectConfiguration>\n");
    }
    try out.appendSlice(allocator, "  </ItemGroup>\n");

    // Globals
    try out.appendSlice(allocator, "  <PropertyGroup Label=\"Globals\">\n");
    try out.print(allocator, "    <ProjectGuid>{s}</ProjectGuid>\n", .{&proj_guid});
    try out.print(allocator, "    <RootNamespace>{s}</RootNamespace>\n", .{project.name});
    try out.print(allocator, "    <ProjectName>{s}</ProjectName>\n", .{project.name});
    try out.appendSlice(allocator, "  </PropertyGroup>\n");

    try out.appendSlice(allocator, "  <Import Project=\"$(VCTargetsPath)\\Microsoft.Cpp.Default.props\" />\n");

    // Configuration properties for Debug and Release
    for ([_][]const u8{ "Debug", "Release" }) |cfg| {
        try out.print(allocator, "  <PropertyGroup Condition=\"'$(Configuration)|$(Platform)'=='{s}|x64'\" Label=\"Configuration\">\n", .{cfg});
        try out.print(allocator, "    <ConfigurationType>{s}</ConfigurationType>\n", .{config_type});
        try out.appendSlice(allocator, "    <PlatformToolset>v143</PlatformToolset>\n");
        try out.print(allocator, "    <LanguageStandard>{s}</LanguageStandard>\n", .{lang_std});
        try out.appendSlice(allocator, "  </PropertyGroup>\n");
    }

    try out.appendSlice(allocator, "  <Import Project=\"$(VCTargetsPath)\\Microsoft.Cpp.props\" />\n");

    // Source files
    try out.appendSlice(allocator, "  <ItemGroup>\n");
    if (target) |t| {
        for (t.sources) |source| {
            try out.print(allocator, "    <ClCompile Include=\"{s}\" />\n", .{source});
        }
    }
    try out.appendSlice(allocator, "  </ItemGroup>\n");

    // Include directories
    if (target) |t| {
        if (t.include_dirs.len > 0) {
            try out.appendSlice(allocator, "  <ItemDefinitionGroup>\n");
            try out.appendSlice(allocator, "    <ClCompile>\n");
            try out.appendSlice(allocator, "      <AdditionalIncludeDirectories>");
            for (t.include_dirs, 0..) |dir, i| {
                if (i > 0) try out.appendSlice(allocator, ";");
                try out.appendSlice(allocator, dir);
            }
            try out.appendSlice(allocator, "</AdditionalIncludeDirectories>\n");
            try out.appendSlice(allocator, "    </ClCompile>\n");
            try out.appendSlice(allocator, "  </ItemDefinitionGroup>\n");
        }
    }

    // Additional targets as comments
    if (project.targets.len > 1) {
        try out.appendSlice(allocator, "  <!-- Additional OVO targets not included in this .vcxproj:\n");
        for (project.targets[1..]) |extra| {
            try out.print(allocator, "       - {s} ({s})\n", .{ extra.name, project_mod.targetTypeLabel(extra.kind) });
        }
        try out.appendSlice(allocator, "  -->\n");
    }

    try out.appendSlice(allocator, "  <Import Project=\"$(VCTargetsPath)\\Microsoft.Cpp.targets\" />\n");
    try out.appendSlice(allocator, "</Project>\n");
    return try out.toOwnedSlice(allocator);
}

fn exportXcode(allocator: std.mem.Allocator, project: project_mod.Project) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const cxx_std = xcodeLanguageStandard(project.defaults.cpp_standard);
    var counter: u32 = 0;

    // Pre-generate UUIDs for project-level objects
    const project_uuid = pbxUuid(project.name, &counter);
    const main_group_uuid = pbxUuid(project.name, &counter);
    const sources_group_uuid = pbxUuid(project.name, &counter);
    const products_group_uuid = pbxUuid(project.name, &counter);
    const project_config_list_uuid = pbxUuid(project.name, &counter);
    const project_debug_config_uuid = pbxUuid(project.name, &counter);
    const project_release_config_uuid = pbxUuid(project.name, &counter);

    try out.appendSlice(allocator, "// !$*UTF8*$!\n{\n");
    try out.appendSlice(allocator, "\tarchiveVersion = 1;\n");
    try out.appendSlice(allocator, "\tclasses = {\n\t};\n");
    try out.appendSlice(allocator, "\tobjectVersion = 56;\n");
    try out.appendSlice(allocator, "\tobjects = {\n");

    // Collect per-target data for multi-pass generation
    const TargetInfo = struct {
        target_uuid: [24]u8,
        sources_phase_uuid: [24]u8,
        frameworks_phase_uuid: [24]u8,
        config_list_uuid: [24]u8,
        debug_config_uuid: [24]u8,
        release_config_uuid: [24]u8,
        product_ref_uuid: [24]u8,
        file_ref_uuids: []const [24]u8,
        build_file_uuids: []const [24]u8,
        target: project_mod.Target,
    };

    var targets_info: std.ArrayList(TargetInfo) = .empty;
    defer targets_info.deinit(allocator);

    for (project.targets) |target| {
        var file_refs: std.ArrayList([24]u8) = .empty;
        defer file_refs.deinit(allocator);
        var build_files: std.ArrayList([24]u8) = .empty;
        defer build_files.deinit(allocator);

        for (target.sources) |_| {
            try file_refs.append(allocator, pbxUuid(target.name, &counter));
            try build_files.append(allocator, pbxUuid(target.name, &counter));
        }

        try targets_info.append(allocator, .{
            .target_uuid = pbxUuid(target.name, &counter),
            .sources_phase_uuid = pbxUuid(target.name, &counter),
            .frameworks_phase_uuid = pbxUuid(target.name, &counter),
            .config_list_uuid = pbxUuid(target.name, &counter),
            .debug_config_uuid = pbxUuid(target.name, &counter),
            .release_config_uuid = pbxUuid(target.name, &counter),
            .product_ref_uuid = pbxUuid(target.name, &counter),
            .file_ref_uuids = try file_refs.toOwnedSlice(allocator),
            .build_file_uuids = try build_files.toOwnedSlice(allocator),
            .target = target,
        });
    }

    // PBXBuildFile section
    try out.appendSlice(allocator, "\n/* Begin PBXBuildFile section */\n");
    for (targets_info.items) |info| {
        for (info.build_file_uuids, 0..) |bf_uuid, si| {
            const source = info.target.sources[si];
            try out.print(allocator, "\t\t{s} /* {s} */ = {{isa = PBXBuildFile; fileRef = {s}; }};\n", .{ &bf_uuid, source, &info.file_ref_uuids[si] });
        }
    }
    try out.appendSlice(allocator, "/* End PBXBuildFile section */\n");

    // PBXFileReference section
    try out.appendSlice(allocator, "\n/* Begin PBXFileReference section */\n");
    for (targets_info.items) |info| {
        for (info.file_ref_uuids, 0..) |fr_uuid, si| {
            const source = info.target.sources[si];
            const ext = std.fs.path.extension(source);
            const file_type = if (std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".cxx") or std.mem.eql(u8, ext, ".cc"))
                "sourcecode.cpp.cpp"
            else if (std.mem.eql(u8, ext, ".c"))
                "sourcecode.c.c"
            else if (std.mem.eql(u8, ext, ".h") or std.mem.eql(u8, ext, ".hpp"))
                "sourcecode.c.h"
            else
                "text";
            const basename = std.fs.path.basename(source);
            try out.print(allocator, "\t\t{s} /* {s} */ = {{isa = PBXFileReference; lastKnownFileType = {s}; path = \"{s}\"; sourceTree = \"<group>\"; }};\n", .{ &fr_uuid, basename, file_type, source });
        }
        // Product reference
        const product_type_ext = xcodeProductExtension(info.target.kind);
        try out.print(allocator, "\t\t{s} /* {s}{s} */ = {{isa = PBXFileReference; explicitFileType = \"{s}\"; path = \"{s}{s}\"; sourceTree = BUILT_PRODUCTS_DIR; }};\n", .{ &info.product_ref_uuid, info.target.name, product_type_ext, xcodeExplicitFileType(info.target.kind), info.target.name, product_type_ext });
    }
    try out.appendSlice(allocator, "/* End PBXFileReference section */\n");

    // PBXGroup section
    try out.appendSlice(allocator, "\n/* Begin PBXGroup section */\n");
    // Main group
    try out.print(allocator, "\t\t{s} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n", .{&main_group_uuid});
    try out.print(allocator, "\t\t\t\t{s} /* Sources */,\n", .{&sources_group_uuid});
    try out.print(allocator, "\t\t\t\t{s} /* Products */,\n", .{&products_group_uuid});
    try out.appendSlice(allocator, "\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t};\n");
    // Sources group
    try out.print(allocator, "\t\t{s} /* Sources */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n", .{&sources_group_uuid});
    for (targets_info.items) |info| {
        for (info.file_ref_uuids, 0..) |fr_uuid, si| {
            const basename = std.fs.path.basename(info.target.sources[si]);
            try out.print(allocator, "\t\t\t\t{s} /* {s} */,\n", .{ &fr_uuid, basename });
        }
    }
    try out.appendSlice(allocator, "\t\t\t);\n\t\t\tname = Sources;\n\t\t\tsourceTree = \"<group>\";\n\t\t};\n");
    // Products group
    try out.print(allocator, "\t\t{s} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n", .{&products_group_uuid});
    for (targets_info.items) |info| {
        try out.print(allocator, "\t\t\t\t{s} /* {s} */,\n", .{ &info.product_ref_uuid, info.target.name });
    }
    try out.appendSlice(allocator, "\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t};\n");
    try out.appendSlice(allocator, "/* End PBXGroup section */\n");

    // PBXNativeTarget section
    try out.appendSlice(allocator, "\n/* Begin PBXNativeTarget section */\n");
    for (targets_info.items) |info| {
        try out.print(allocator, "\t\t{s} /* {s} */ = {{\n", .{ &info.target_uuid, info.target.name });
        try out.appendSlice(allocator, "\t\t\tisa = PBXNativeTarget;\n");
        try out.print(allocator, "\t\t\tbuildConfigurationList = {s};\n", .{&info.config_list_uuid});
        try out.appendSlice(allocator, "\t\t\tbuildPhases = (\n");
        try out.print(allocator, "\t\t\t\t{s} /* Sources */,\n", .{&info.sources_phase_uuid});
        try out.print(allocator, "\t\t\t\t{s} /* Frameworks */,\n", .{&info.frameworks_phase_uuid});
        try out.appendSlice(allocator, "\t\t\t);\n");
        try out.print(allocator, "\t\t\tname = \"{s}\";\n", .{info.target.name});
        try out.print(allocator, "\t\t\tproductReference = {s};\n", .{&info.product_ref_uuid});
        try out.print(allocator, "\t\t\tproductType = \"{s}\";\n", .{xcodeProductType(info.target.kind)});
        try out.appendSlice(allocator, "\t\t};\n");
    }
    try out.appendSlice(allocator, "/* End PBXNativeTarget section */\n");

    // PBXProject section
    try out.appendSlice(allocator, "\n/* Begin PBXProject section */\n");
    try out.print(allocator, "\t\t{s} /* Project object */ = {{\n", .{&project_uuid});
    try out.appendSlice(allocator, "\t\t\tisa = PBXProject;\n");
    try out.print(allocator, "\t\t\tbuildConfigurationList = {s};\n", .{&project_config_list_uuid});
    try out.print(allocator, "\t\t\tmainGroup = {s};\n", .{&main_group_uuid});
    try out.print(allocator, "\t\t\tproductRefGroup = {s} /* Products */;\n", .{&products_group_uuid});
    try out.appendSlice(allocator, "\t\t\ttargets = (\n");
    for (targets_info.items) |info| {
        try out.print(allocator, "\t\t\t\t{s} /* {s} */,\n", .{ &info.target_uuid, info.target.name });
    }
    try out.appendSlice(allocator, "\t\t\t);\n\t\t};\n");
    try out.appendSlice(allocator, "/* End PBXProject section */\n");

    // PBXSourcesBuildPhase section
    try out.appendSlice(allocator, "\n/* Begin PBXSourcesBuildPhase section */\n");
    for (targets_info.items) |info| {
        try out.print(allocator, "\t\t{s} /* Sources */ = {{\n", .{&info.sources_phase_uuid});
        try out.appendSlice(allocator, "\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tfiles = (\n");
        for (info.build_file_uuids, 0..) |bf_uuid, si| {
            const basename = std.fs.path.basename(info.target.sources[si]);
            try out.print(allocator, "\t\t\t\t{s} /* {s} */,\n", .{ &bf_uuid, basename });
        }
        try out.appendSlice(allocator, "\t\t\t);\n\t\t};\n");
    }
    try out.appendSlice(allocator, "/* End PBXSourcesBuildPhase section */\n");

    // PBXFrameworksBuildPhase section
    try out.appendSlice(allocator, "\n/* Begin PBXFrameworksBuildPhase section */\n");
    for (targets_info.items) |info| {
        try out.print(allocator, "\t\t{s} /* Frameworks */ = {{\n", .{&info.frameworks_phase_uuid});
        try out.appendSlice(allocator, "\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tfiles = (\n");
        try out.appendSlice(allocator, "\t\t\t);\n\t\t};\n");
    }
    try out.appendSlice(allocator, "/* End PBXFrameworksBuildPhase section */\n");

    // XCBuildConfiguration section
    try out.appendSlice(allocator, "\n/* Begin XCBuildConfiguration section */\n");
    // Project-level configs
    try out.print(allocator, "\t\t{s} /* Debug */ = {{\n", .{&project_debug_config_uuid});
    try out.appendSlice(allocator, "\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n");
    try out.print(allocator, "\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = \"{s}\";\n", .{cxx_std});
    try out.appendSlice(allocator, "\t\t\t\tCOPY_PHASE_STRIP = NO;\n");
    try out.appendSlice(allocator, "\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;\n");
    try out.appendSlice(allocator, "\t\t\t};\n\t\t\tname = Debug;\n\t\t};\n");

    try out.print(allocator, "\t\t{s} /* Release */ = {{\n", .{&project_release_config_uuid});
    try out.appendSlice(allocator, "\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n");
    try out.print(allocator, "\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = \"{s}\";\n", .{cxx_std});
    try out.appendSlice(allocator, "\t\t\t\tCOPY_PHASE_STRIP = YES;\n");
    try out.appendSlice(allocator, "\t\t\t\tGCC_OPTIMIZATION_LEVEL = s;\n");
    try out.appendSlice(allocator, "\t\t\t};\n\t\t\tname = Release;\n\t\t};\n");

    // Per-target configs
    for (targets_info.items) |info| {
        for ([_]struct { uuid: [24]u8, name: []const u8, opt: []const u8 }{
            .{ .uuid = info.debug_config_uuid, .name = "Debug", .opt = "0" },
            .{ .uuid = info.release_config_uuid, .name = "Release", .opt = "s" },
        }) |cfg| {
            try out.print(allocator, "\t\t{s} /* {s} */ = {{\n", .{ &cfg.uuid, cfg.name });
            try out.appendSlice(allocator, "\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n");
            try out.print(allocator, "\t\t\t\tGCC_OPTIMIZATION_LEVEL = {s};\n", .{cfg.opt});
            try out.print(allocator, "\t\t\t\tPRODUCT_NAME = \"{s}\";\n", .{info.target.name});
            if (info.target.include_dirs.len > 0) {
                try out.appendSlice(allocator, "\t\t\t\tHEADER_SEARCH_PATHS = (\n");
                for (info.target.include_dirs) |dir| {
                    try out.print(allocator, "\t\t\t\t\t\"{s}\",\n", .{dir});
                }
                try out.appendSlice(allocator, "\t\t\t\t);\n");
            }
            try out.appendSlice(allocator, "\t\t\t};\n");
            try out.print(allocator, "\t\t\tname = {s};\n\t\t}};\n", .{cfg.name});
        }
    }
    try out.appendSlice(allocator, "/* End XCBuildConfiguration section */\n");

    // XCConfigurationList section
    try out.appendSlice(allocator, "\n/* Begin XCConfigurationList section */\n");
    // Project config list
    try out.print(allocator, "\t\t{s} /* Build configuration list for PBXProject */ = {{\n", .{&project_config_list_uuid});
    try out.appendSlice(allocator, "\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n");
    try out.print(allocator, "\t\t\t\t{s} /* Debug */,\n", .{&project_debug_config_uuid});
    try out.print(allocator, "\t\t\t\t{s} /* Release */,\n", .{&project_release_config_uuid});
    try out.appendSlice(allocator, "\t\t\t);\n\t\t\tdefaultConfigurationName = Release;\n\t\t};\n");
    // Per-target config lists
    for (targets_info.items) |info| {
        try out.print(allocator, "\t\t{s} /* Build configuration list for PBXNativeTarget \"{s}\" */ = {{\n", .{ &info.config_list_uuid, info.target.name });
        try out.appendSlice(allocator, "\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n");
        try out.print(allocator, "\t\t\t\t{s} /* Debug */,\n", .{&info.debug_config_uuid});
        try out.print(allocator, "\t\t\t\t{s} /* Release */,\n", .{&info.release_config_uuid});
        try out.appendSlice(allocator, "\t\t\t);\n\t\t\tdefaultConfigurationName = Release;\n\t\t};\n");
    }
    try out.appendSlice(allocator, "/* End XCConfigurationList section */\n");

    try out.appendSlice(allocator, "\t};\n");
    try out.print(allocator, "\trootObject = {s} /* Project object */;\n", .{&project_uuid});
    try out.appendSlice(allocator, "}\n");
    return try out.toOwnedSlice(allocator);
}

// --- Helpers ---

fn primaryTarget(project: project_mod.Project) ?project_mod.Target {
    if (project.targets.len == 0) return null;
    for (project.targets) |t| {
        if (t.kind == .executable) return t;
    }
    return project.targets[0];
}

fn msbuildConfigurationType(kind: project_mod.TargetType) []const u8 {
    return switch (kind) {
        .executable, .test_target => "Application",
        .library_static => "StaticLibrary",
        .library_shared => "DynamicLibrary",
    };
}

fn msbuildLanguageStandard(standard: project_mod.CppStandard) []const u8 {
    return switch (standard) {
        .c89, .c99, .c11, .c17 => "Default",
        .cpp11 => "stdcpp11",
        .cpp14 => "stdcpp14",
        .cpp17 => "stdcpp17",
        .cpp20 => "stdcpp20",
        .cpp23 => "stdcpplatest",
    };
}

fn deterministicGuid(name: []const u8) [38]u8 {
    var hash: u128 = 0x6F766F_70726F6A;
    for (name) |c| {
        hash = hash *% 31 +% c;
    }
    var buf: [38]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{{{X:0>8}-{X:0>4}-{X:0>4}-{X:0>4}-{X:0>12}}}", .{
        @as(u32, @truncate(hash >> 96)),
        @as(u16, @truncate(hash >> 80)),
        @as(u16, @truncate(hash >> 64)),
        @as(u16, @truncate(hash >> 48)),
        @as(u48, @truncate(hash)),
    }) catch unreachable;
    return buf;
}

fn pbxUuid(seed: []const u8, counter: *u32) [24]u8 {
    var hash: u96 = 0x4F564F_504258;
    for (seed) |c| {
        hash = hash *% 31 +% c;
    }
    hash = hash *% 65537 +% counter.*;
    counter.* += 1;
    var buf: [24]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{X:0>24}", .{hash}) catch unreachable;
    return buf;
}

fn xcodeProductType(kind: project_mod.TargetType) []const u8 {
    return switch (kind) {
        .executable => "com.apple.product-type.tool",
        .library_static => "com.apple.product-type.library.static",
        .library_shared => "com.apple.product-type.library.dynamic",
        .test_target => "com.apple.product-type.bundle.unit-test",
    };
}

fn xcodeExplicitFileType(kind: project_mod.TargetType) []const u8 {
    return switch (kind) {
        .executable, .test_target => "compiled.mach-o.executable",
        .library_static => "archive.ar",
        .library_shared => "compiled.mach-o.dylib",
    };
}

fn xcodeProductExtension(kind: project_mod.TargetType) []const u8 {
    return switch (kind) {
        .executable, .test_target => "",
        .library_static => ".a",
        .library_shared => ".dylib",
    };
}

fn xcodeLanguageStandard(standard: project_mod.CppStandard) []const u8 {
    return switch (standard) {
        .c89, .c99, .c11, .c17 => "c11",
        .cpp11 => "c++11",
        .cpp14 => "c++14",
        .cpp17 => "c++17",
        .cpp20 => "c++20",
        .cpp23 => "c++23",
    };
}
