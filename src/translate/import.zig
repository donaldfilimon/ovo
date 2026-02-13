const std = @import("std");
const core = @import("../core/mod.zig");
const project_mod = @import("../core/project.zig");
const zon = @import("../zon/mod.zig");

const CMakeParseError = anyerror;

pub const ImportFormat = enum {
    cmake,
    xcode,
    msbuild,
    meson,
    makefile,
    vcpkg,
    conan,
};

pub fn parseImportFormat(value: []const u8) ?ImportFormat {
    if (std.ascii.eqlIgnoreCase(value, "cmake")) return .cmake;
    if (std.ascii.eqlIgnoreCase(value, "xcode")) return .xcode;
    if (std.ascii.eqlIgnoreCase(value, "msbuild")) return .msbuild;
    if (std.ascii.eqlIgnoreCase(value, "meson")) return .meson;
    if (std.ascii.eqlIgnoreCase(value, "makefile")) return .makefile;
    if (std.ascii.eqlIgnoreCase(value, "vcpkg")) return .vcpkg;
    if (std.ascii.eqlIgnoreCase(value, "conan")) return .conan;
    return null;
}

pub fn label(format: ImportFormat) []const u8 {
    return switch (format) {
        .cmake => "cmake",
        .xcode => "xcode",
        .msbuild => "msbuild",
        .meson => "meson",
        .makefile => "makefile",
        .vcpkg => "vcpkg",
        .conan => "conan",
    };
}

pub fn importIntoBuildZon(
    allocator: std.mem.Allocator,
    format: ImportFormat,
    source_path: []const u8,
) !project_mod.Project {
    return switch (format) {
        .cmake => try importCMake(allocator, source_path),
        .makefile => try importMakefile(allocator, source_path),
        .meson => try importMeson(allocator, source_path),
        .xcode => try importXcode(allocator, source_path),
        .msbuild => try importMSBuild(allocator, source_path),
        .vcpkg => try importVcpkg(allocator, source_path),
        .conan => try importConan(allocator, source_path),
    };
}

pub fn writeImportedProject(allocator: std.mem.Allocator, project: project_mod.Project) !void {
    const bytes = try zon.writer.renderBuildZon(allocator, project);
    try core.fs.writeFile("build.zon", bytes);
}

const CMakeCommand = struct {
    name: []const u8,
    args: []const u8,
};

const CMakeVariable = struct {
    name: []const u8,
    values: []const []const u8,
};

const CMakeTarget = struct {
    name: []const u8,
    kind: project_mod.TargetType,
    sources: std.ArrayList([]const u8),
    include_dirs: std.ArrayList([]const u8),
    link_libraries: std.ArrayList([]const u8),
};

const CMakeParseContext = struct {
    allocator: std.mem.Allocator,
    target_data: *std.ArrayList(CMakeTarget),
    global_include_dirs: *std.ArrayList([]const u8),
    variable_values: *std.ArrayList(CMakeVariable),
    parsed_project_name: *[]const u8,
    cpp_standard: *project_mod.CppStandard,
    visited_paths: *std.ArrayList([]const u8),
};

fn importCMake(allocator: std.mem.Allocator, source_path: []const u8) !project_mod.Project {
    var target_data: std.ArrayList(CMakeTarget) = .empty;
    var global_include_dirs: std.ArrayList([]const u8) = .empty;
    var variable_values: std.ArrayList(CMakeVariable) = .empty;
    var parsed_project_name = project_mod.guessProjectNameFromPath(source_path);
    var cpp_standard = project_mod.CppStandard.cpp20;
    var visited_paths: std.ArrayList([]const u8) = .empty;

    const root_path = if (std.mem.eql(u8, source_path, "."))
        try allocator.dupe(u8, "CMakeLists.txt")
    else
        try std.fmt.allocPrint(allocator, "{s}/CMakeLists.txt", .{source_path});
    defer allocator.free(root_path);

    if (!core.fs.fileExists(root_path)) return error.CMakeFileNotFound;

    try setVariable(allocator, &variable_values, "PROJECT_NAME", &.{parsed_project_name});
    try setVariable(allocator, &variable_values, "CMAKE_SOURCE_DIR", &.{source_path});
    try setVariable(allocator, &variable_values, "CMAKE_CURRENT_SOURCE_DIR", &.{source_path});
    try setVariable(allocator, &variable_values, "CMAKE_CURRENT_LIST_DIR", &.{source_path});
    try setVariable(allocator, &variable_values, "PROJECT_SOURCE_DIR", &.{source_path});

    var context = CMakeParseContext{
        .allocator = allocator,
        .target_data = &target_data,
        .global_include_dirs = &global_include_dirs,
        .variable_values = &variable_values,
        .parsed_project_name = &parsed_project_name,
        .cpp_standard = &cpp_standard,
        .visited_paths = &visited_paths,
    };

    try importCMakeFromPath(allocator, source_path, true, &context);

    if (target_data.items.len == 0) {
        var sources: std.ArrayList([]const u8) = .empty;
        var includes: std.ArrayList([]const u8) = .empty;
        try sources.append(allocator, "src/main.cpp");
        try includes.append(allocator, "include");
        try target_data.append(allocator, .{
            .name = parsed_project_name,
            .kind = .executable,
            .sources = sources,
            .include_dirs = includes,
            .link_libraries = .empty,
        });
    }

    const rendered_targets = try allocator.alloc(project_mod.Target, target_data.items.len);
    for (target_data.items, 0..) |_, target_index| {
        var target = &target_data.items[target_index];
        const target_sources = if (target.sources.items.len > 0)
            try target.sources.toOwnedSlice(allocator)
        else
            try allocator.dupe([]const u8, &[_][]const u8{});
        const merged_includes = try mergeIncludeDirs(
            allocator,
            global_include_dirs.items,
            target.include_dirs.items,
        );
        const links = try target.link_libraries.toOwnedSlice(allocator);
        rendered_targets[target_index] = .{
            .name = target.name,
            .kind = target.kind,
            .sources = target_sources,
            .include_dirs = merged_includes,
            .link_libraries = links,
        };
    }

    return .{
        .name = parsed_project_name,
        .version = "0.1.0",
        .license = "MIT",
        .defaults = .{ .cpp_standard = cpp_standard },
        .targets = rendered_targets,
    };
}

fn importCMakeFromPath(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    is_root: bool,
    context: *CMakeParseContext,
) CMakeParseError!void {
    const path = if (std.mem.eql(u8, source_path, "."))
        try allocator.dupe(u8, "CMakeLists.txt")
    else
        try std.fmt.allocPrint(allocator, "{s}/CMakeLists.txt", .{source_path});
    defer allocator.free(path);

    if (!core.fs.fileExists(path)) return;
    if (isVisited(context.visited_paths, path)) return;
    const visited_path = try allocator.dupe(u8, path);
    try context.visited_paths.append(allocator, visited_path);

    const cmake = core.fs.readFileAlloc(allocator, path) catch |err| {
        return if (err == error.OutOfMemory) err else {};
    };
    defer allocator.free(cmake);

    try parseCMakeBuffer(allocator, source_path, cmake, context, is_root);
}

fn parseCMakeBuffer(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    cmake: []const u8,
    context: *CMakeParseContext,
    parse_project_name: bool,
) CMakeParseError!void {
    const commands = try extractCMakeCommands(allocator, cmake);
    defer allocator.free(commands);

    for (commands) |command| {
        var raw_args = try tokenizeCMakeArguments(allocator, command.args);
        defer raw_args.deinit(allocator);
        if (raw_args.items.len == 0) continue;

        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(allocator);
        try expandVariables(allocator, raw_args.items, context.variable_values, &args);

        if (std.ascii.eqlIgnoreCase(command.name, "project") and parse_project_name) {
            if (parseProjectNameFromTokens(args.items)) |name| {
                context.parsed_project_name.* = name;
                try setVariable(allocator, context.variable_values, "PROJECT_NAME", &.{name});
            }
            continue;
        }

        if (std.ascii.eqlIgnoreCase(command.name, "set")) {
            try parseSetCommand(allocator, args.items, context.variable_values, context.cpp_standard);
            continue;
        }

        if (std.ascii.eqlIgnoreCase(command.name, "set_property")) {
            parseSetPropertyCommand(args.items, context.cpp_standard);
            continue;
        }

        if (std.ascii.eqlIgnoreCase(command.name, "set_target_properties")) {
            parseSetTargetPropertiesCommand(args.items, context.cpp_standard);
            continue;
        }

        if (std.ascii.eqlIgnoreCase(command.name, "target_compile_features")) {
            parseTargetCompileFeatures(args.items, context.cpp_standard);
            continue;
        }

        if (std.ascii.eqlIgnoreCase(command.name, "add_executable")) {
            try parseTargetCommand(allocator, args.items, .executable, context.target_data);
            continue;
        }

        if (std.ascii.eqlIgnoreCase(command.name, "add_library")) {
            try parseAddLibraryCommand(allocator, args.items, context.target_data);
            continue;
        }

        if (std.ascii.eqlIgnoreCase(command.name, "add_subdirectory")) {
            try parseAddSubdirectoryCommand(allocator, args.items, source_path, context);
            continue;
        }

        if (std.ascii.eqlIgnoreCase(command.name, "include")) {
            try parseIncludeCommand(allocator, args.items, source_path, context);
            continue;
        }

        if (std.ascii.eqlIgnoreCase(command.name, "target_sources")) {
            try parseTargetSourcesCommand(allocator, args.items, context.target_data);
            continue;
        }

        if (std.ascii.eqlIgnoreCase(command.name, "include_directories") or
            std.ascii.eqlIgnoreCase(command.name, "include_directory"))
        {
            try appendDirectoryList(allocator, context.global_include_dirs, args.items, &.{ "BEFORE", "AFTER", "SYSTEM" });
            continue;
        }

        if (std.ascii.eqlIgnoreCase(command.name, "target_include_directories")) {
            try parseTargetIncludeDirectoriesCommand(allocator, args.items, context.target_data);
            continue;
        }

        if (std.ascii.eqlIgnoreCase(command.name, "target_link_libraries")) {
            try parseTargetLinkLibrariesCommand(allocator, args.items, context.target_data);
            continue;
        }
    }
}

fn parseAddSubdirectoryCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    source_path: []const u8,
    context: *CMakeParseContext,
) CMakeParseError!void {
    if (args.len == 0) return;
    const sub_dir = args[0];
    if (sub_dir.len == 0) return;
    if (sub_dir[0] == '$') return;

    const resolved = try resolveRelativePath(allocator, source_path, sub_dir);
    defer allocator.free(resolved);

    try importCMakeFromPath(allocator, resolved, false, context);
}

fn parseIncludeCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    source_path: []const u8,
    context: *CMakeParseContext,
) CMakeParseError!void {
    if (args.len == 0) return;
    const include_path = args[0];
    if (include_path.len == 0 or include_path[0] == '$') return;
    const resolved = try resolveRelativePath(allocator, source_path, include_path);
    defer allocator.free(resolved);
    try parseCMakeFile(allocator, resolved, context);
    if (!std.mem.endsWith(u8, resolved, ".cmake")) {
        const with_ext = try std.fmt.allocPrint(allocator, "{s}.cmake", .{resolved});
        defer allocator.free(with_ext);
        try parseCMakeFile(allocator, with_ext, context);
    }
}

fn parseCMakeFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    context: *CMakeParseContext,
) CMakeParseError!void {
    if (!std.mem.endsWith(u8, file_path, ".cmake")) {
        return;
    }
    if (!core.fs.fileExists(file_path)) return;
    if (isVisited(context.visited_paths, file_path)) return;
    const visited_path = try allocator.dupe(u8, file_path);
    try context.visited_paths.append(allocator, visited_path);

    const bytes = core.fs.readFileAlloc(allocator, file_path) catch |err| {
        return if (err == error.OutOfMemory) err else {};
    };
    defer allocator.free(bytes);

    const source_dir = if (std.fs.path.dirname(file_path)) |dir| dir else ".";
    const source_buffer: []const u8 = bytes;
    try parseCMakeBuffer(allocator, source_dir, source_buffer, context, false);
}

fn isVisited(visited: *std.ArrayList([]const u8), candidate: []const u8) bool {
    for (visited.items) |path| {
        if (std.mem.eql(u8, path, candidate)) return true;
    }
    return false;
}

fn resolveRelativePath(allocator: std.mem.Allocator, base: []const u8, candidate: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(candidate)) return try allocator.dupe(u8, candidate);
    if (std.mem.eql(u8, base, ".")) return try allocator.dupe(u8, candidate);
    return try std.fs.path.join(allocator, &.{ base, candidate });
}

fn importMakefile(allocator: std.mem.Allocator, source_path: []const u8) !project_mod.Project {
    const path = if (std.mem.eql(u8, source_path, "."))
        "Makefile"
    else
        try std.fmt.allocPrint(allocator, "{s}/Makefile", .{source_path});
    if (!core.fs.fileExists(path)) return error.MakefileNotFound;
    const makefile = try core.fs.readFileAlloc(allocator, path);

    var source_list: std.ArrayList([]const u8) = .empty;
    errdefer source_list.deinit(allocator);
    var lines = std.mem.tokenizeAny(u8, makefile, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, ".cpp")) |idx| {
            const start = backwardTokenBoundary(line, idx);
            const end = forwardTokenBoundary(line, idx + 4);
            const candidate = std.mem.trim(u8, line[start..end], " \t\\");
            if (candidate.len > 0) try source_list.append(allocator, candidate);
        }
    }
    if (source_list.items.len == 0) try source_list.append(allocator, "src/main.cpp");

    const inferred_name = project_mod.guessProjectNameFromPath(source_path);
    const targets = try allocator.alloc(project_mod.Target, 1);
    targets[0] = .{
        .name = inferred_name,
        .kind = .executable,
        .sources = try source_list.toOwnedSlice(allocator),
        .include_dirs = &.{"include"},
    };

    return .{
        .name = inferred_name,
        .version = "0.1.0",
        .license = "MIT",
        .targets = targets,
    };
}

fn importMeson(allocator: std.mem.Allocator, source_path: []const u8) !project_mod.Project {
    const inferred_name = project_mod.guessProjectNameFromPath(source_path);
    var targets = try allocator.alloc(project_mod.Target, 1);
    targets[0] = .{
        .name = inferred_name,
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
        .include_dirs = &.{"include"},
    };
    return .{
        .name = inferred_name,
        .version = "0.1.0",
        .license = "MIT",
        .targets = targets,
    };
}

fn importMSBuild(allocator: std.mem.Allocator, source_path: []const u8) !project_mod.Project {
    const vcxproj_path = findFileWithExtension(source_path, ".vcxproj");
    if (vcxproj_path == null) return importFromDirectoryName(allocator, source_path);

    const bytes = core.fs.readFileAlloc(allocator, vcxproj_path.?) catch {
        return importFromDirectoryName(allocator, source_path);
    };

    const proj_name = extractXmlTagContent(bytes, "RootNamespace") orelse
        extractXmlTagContent(bytes, "ProjectName") orelse
        project_mod.guessProjectNameFromPath(source_path);

    const config_type_str = extractXmlTagContent(bytes, "ConfigurationType") orelse "Application";
    const kind: project_mod.TargetType = if (std.ascii.eqlIgnoreCase(config_type_str, "StaticLibrary"))
        .library_static
    else if (std.ascii.eqlIgnoreCase(config_type_str, "DynamicLibrary"))
        .library_shared
    else
        .executable;

    var sources: std.ArrayList([]const u8) = .empty;
    errdefer sources.deinit(allocator);
    try collectXmlAttribute(allocator, bytes, "ClCompile", "Include", &sources);
    if (sources.items.len == 0) try sources.append(allocator, "src/main.cpp");

    var include_dirs: std.ArrayList([]const u8) = .empty;
    errdefer include_dirs.deinit(allocator);
    if (extractXmlTagContent(bytes, "AdditionalIncludeDirectories")) |dirs_str| {
        var parts = std.mem.splitScalar(u8, dirs_str, ';');
        while (parts.next()) |part| {
            const dir = std.mem.trim(u8, part, " \t\r\n");
            if (dir.len > 0 and !std.mem.startsWith(u8, dir, "%("))
                try include_dirs.append(allocator, dir);
        }
    }

    var cpp_standard: project_mod.CppStandard = .cpp20;
    if (extractXmlTagContent(bytes, "LanguageStandard")) |lang_std| {
        if (std.mem.eql(u8, lang_std, "stdcpp11")) {
            cpp_standard = .cpp11;
        } else if (std.mem.eql(u8, lang_std, "stdcpp14")) {
            cpp_standard = .cpp14;
        } else if (std.mem.eql(u8, lang_std, "stdcpp17")) {
            cpp_standard = .cpp17;
        } else if (std.mem.eql(u8, lang_std, "stdcpp20")) {
            cpp_standard = .cpp20;
        } else if (std.mem.eql(u8, lang_std, "stdcpplatest")) {
            cpp_standard = .cpp23;
        }
    }

    const targets = try allocator.alloc(project_mod.Target, 1);
    targets[0] = .{
        .name = proj_name,
        .kind = kind,
        .sources = try sources.toOwnedSlice(allocator),
        .include_dirs = if (include_dirs.items.len > 0)
            try include_dirs.toOwnedSlice(allocator)
        else
            &.{},
    };

    return .{
        .name = proj_name,
        .version = "0.1.0",
        .license = "MIT",
        .defaults = .{ .cpp_standard = cpp_standard },
        .targets = targets,
    };
}

fn importXcode(allocator: std.mem.Allocator, source_path: []const u8) !project_mod.Project {
    const pbxproj_path = findPbxprojFile(allocator, source_path) catch null;
    if (pbxproj_path == null) return importFromDirectoryName(allocator, source_path);

    const bytes = core.fs.readFileAlloc(allocator, pbxproj_path.?) catch {
        return importFromDirectoryName(allocator, source_path);
    };

    const objects_block = findPlistBlock(bytes, "objects") orelse
        return importFromDirectoryName(allocator, source_path);

    var targets_list: std.ArrayList(project_mod.Target) = .empty;
    errdefer targets_list.deinit(allocator);
    var cpp_standard: project_mod.CppStandard = .cpp20;

    // Extract build configurations for C++ standard
    if (extractPlistFieldValue(objects_block, "CLANG_CXX_LANGUAGE_STANDARD")) |cxx_std| {
        if (std.mem.eql(u8, cxx_std, "c++11")) {
            cpp_standard = .cpp11;
        } else if (std.mem.eql(u8, cxx_std, "c++14")) {
            cpp_standard = .cpp14;
        } else if (std.mem.eql(u8, cxx_std, "c++17")) {
            cpp_standard = .cpp17;
        } else if (std.mem.eql(u8, cxx_std, "c++20")) {
            cpp_standard = .cpp20;
        } else if (std.mem.eql(u8, cxx_std, "c++23")) {
            cpp_standard = .cpp23;
        }
    }

    // Find PBXNativeTarget entries
    var cursor: usize = 0;
    while (findPlistIsaBlock(objects_block, "PBXNativeTarget", &cursor)) |target_block| {
        const name = extractPlistFieldValue(target_block, "name") orelse continue;
        const product_type = extractPlistFieldValue(target_block, "productType") orelse "com.apple.product-type.tool";

        const kind: project_mod.TargetType = if (std.mem.eql(u8, product_type, "com.apple.product-type.library.static"))
            .library_static
        else if (std.mem.eql(u8, product_type, "com.apple.product-type.library.dynamic"))
            .library_shared
        else if (std.mem.eql(u8, product_type, "com.apple.product-type.bundle.unit-test"))
            .test_target
        else
            .executable;

        // Resolve source files through build phases -> build files -> file references
        var sources: std.ArrayList([]const u8) = .empty;
        errdefer sources.deinit(allocator);

        // Get source files from PBXSourcesBuildPhase entries referenced by this target
        if (findPlistArray(target_block, "buildPhases")) |phases_str| {
            var phases_iter = std.mem.tokenizeAny(u8, phases_str, " ,\t\r\n");
            while (phases_iter.next()) |phase_uuid| {
                const phase_id = std.mem.trim(u8, phase_uuid, " \t/*");
                if (phase_id.len == 0) continue;
                if (findPbxObjectByUuid(objects_block, phase_id)) |phase_block| {
                    if (extractPlistFieldValue(phase_block, "isa")) |isa| {
                        if (!std.mem.eql(u8, isa, "PBXSourcesBuildPhase")) continue;
                    }
                    // Get files array from the build phase
                    if (findPlistArray(phase_block, "files")) |files_str| {
                        var files_iter = std.mem.tokenizeAny(u8, files_str, " ,\t\r\n");
                        while (files_iter.next()) |bf_uuid| {
                            const bf_id = std.mem.trim(u8, bf_uuid, " \t/*");
                            if (bf_id.len == 0) continue;
                            // Look up PBXBuildFile -> fileRef -> PBXFileReference -> path
                            if (findPbxObjectByUuid(objects_block, bf_id)) |bf_block| {
                                if (extractPlistFieldValue(bf_block, "fileRef")) |file_ref| {
                                    if (findPbxObjectByUuid(objects_block, file_ref)) |fr_block| {
                                        if (extractPlistQuotedField(fr_block, "path")) |path| {
                                            try sources.append(allocator, path);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if (sources.items.len == 0) try sources.append(allocator, "src/main.cpp");

        // Extract include dirs from HEADER_SEARCH_PATHS in build configurations
        var include_dirs: std.ArrayList([]const u8) = .empty;
        errdefer include_dirs.deinit(allocator);
        if (extractPlistFieldValue(target_block, "buildConfigurationList")) |config_list_uuid| {
            if (findPbxObjectByUuid(objects_block, config_list_uuid)) |config_list_block| {
                if (findPlistArray(config_list_block, "buildConfigurations")) |configs_str| {
                    var config_iter = std.mem.tokenizeAny(u8, configs_str, " ,\t\r\n");
                    if (config_iter.next()) |first_config_uuid| {
                        const cfg_id = std.mem.trim(u8, first_config_uuid, " \t/*");
                        if (findPbxObjectByUuid(objects_block, cfg_id)) |cfg_block| {
                            if (findPlistArray(cfg_block, "HEADER_SEARCH_PATHS")) |paths_str| {
                                var paths_iter = std.mem.tokenizeAny(u8, paths_str, ",\r\n");
                                while (paths_iter.next()) |path_raw| {
                                    const path = std.mem.trim(u8, path_raw, " \t\"");
                                    if (path.len > 0) try include_dirs.append(allocator, path);
                                }
                            }
                        }
                    }
                }
            }
        }

        try targets_list.append(allocator, .{
            .name = name,
            .kind = kind,
            .sources = try sources.toOwnedSlice(allocator),
            .include_dirs = if (include_dirs.items.len > 0)
                try include_dirs.toOwnedSlice(allocator)
            else
                &.{},
        });
    }

    if (targets_list.items.len == 0) return importFromDirectoryName(allocator, source_path);

    const proj_name = targets_list.items[0].name;
    return .{
        .name = proj_name,
        .version = "0.1.0",
        .license = "MIT",
        .defaults = .{ .cpp_standard = cpp_standard },
        .targets = try targets_list.toOwnedSlice(allocator),
    };
}

// --- Xcode/MSBuild helper functions ---

fn extractXmlTagContent(bytes: []const u8, tag_name: []const u8) ?[]const u8 {
    // Find <tag_name>...</tag_name>
    var search_pos: usize = 0;
    while (search_pos < bytes.len) {
        const open_start = std.mem.indexOfPos(u8, bytes, search_pos, "<") orelse return null;
        const open_end = std.mem.indexOfPos(u8, bytes, open_start + 1, ">") orelse return null;
        const tag_content = bytes[open_start + 1 .. open_end];
        // Check if this tag matches (ignoring attributes)
        const tag_end = std.mem.indexOfScalar(u8, tag_content, ' ') orelse tag_content.len;
        if (std.mem.eql(u8, tag_content[0..tag_end], tag_name)) {
            const value_start = open_end + 1;
            // Find closing tag
            var close_tag_buf: [128]u8 = undefined;
            const close_tag = std.fmt.bufPrint(&close_tag_buf, "</{s}>", .{tag_name}) catch return null;
            const close_pos = std.mem.indexOfPos(u8, bytes, value_start, close_tag) orelse return null;
            return std.mem.trim(u8, bytes[value_start..close_pos], " \t\r\n");
        }
        search_pos = open_end + 1;
    }
    return null;
}

fn collectXmlAttribute(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    tag_name: []const u8,
    attr_name: []const u8,
    results: *std.ArrayList([]const u8),
) !void {
    var search_pos: usize = 0;
    while (search_pos < bytes.len) {
        const tag_start = std.mem.indexOfPos(u8, bytes, search_pos, "<") orelse return;
        const tag_end = std.mem.indexOfPos(u8, bytes, tag_start + 1, ">") orelse return;
        const tag_content = bytes[tag_start + 1 .. tag_end];

        // Check if tag name matches
        const name_end = std.mem.indexOfScalar(u8, tag_content, ' ') orelse tag_content.len;
        const actual_name = tag_content[0..name_end];
        if (std.mem.eql(u8, actual_name, tag_name)) {
            // Look for attribute
            if (extractAttributeValue(tag_content, attr_name)) |value| {
                try results.append(allocator, value);
            }
        }
        search_pos = tag_end + 1;
    }
}

fn extractAttributeValue(tag_content: []const u8, attr_name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag_content.len) {
        const attr_start = std.mem.indexOfPos(u8, tag_content, i, attr_name) orelse return null;
        const after_name = attr_start + attr_name.len;
        if (after_name >= tag_content.len) return null;
        // Skip whitespace and =
        var pos = after_name;
        while (pos < tag_content.len and (tag_content[pos] == ' ' or tag_content[pos] == '=')) : (pos += 1) {}
        if (pos >= tag_content.len) return null;
        if (tag_content[pos] == '"') {
            pos += 1;
            const end = std.mem.indexOfScalarPos(u8, tag_content, pos, '"') orelse return null;
            return tag_content[pos..end];
        }
        i = pos;
    }
    return null;
}

fn findFileWithExtension(source_path: []const u8, ext: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, source_path, ext)) return source_path;
    return null;
}

fn findPbxprojFile(allocator: std.mem.Allocator, source_path: []const u8) ![]const u8 {
    // Check if source_path itself ends with .xcodeproj
    if (std.mem.endsWith(u8, source_path, ".xcodeproj")) {
        return try std.fmt.allocPrint(allocator, "{s}/project.pbxproj", .{source_path});
    }
    // Check for *.xcodeproj/project.pbxproj inside directory
    // Try common pattern: source_path/ProjectName.xcodeproj/project.pbxproj
    const basename = std.fs.path.basename(source_path);
    const attempt = try std.fmt.allocPrint(allocator, "{s}/{s}.xcodeproj/project.pbxproj", .{ source_path, basename });
    if (core.fs.fileExists(attempt)) return attempt;
    return error.XcodeProjectNotFound;
}

fn findPlistBlock(bytes: []const u8, key: []const u8) ?[]const u8 {
    // Find "key = {" in plist format
    const needle_eq = std.mem.indexOf(u8, bytes, key) orelse return null;
    const after_key = bytes[needle_eq + key.len ..];
    const open_brace = std.mem.indexOfScalar(u8, after_key, '{') orelse return null;
    const abs_open = needle_eq + key.len + open_brace;
    const close = findMatchingPlistBrace(bytes, abs_open) orelse return null;
    return bytes[abs_open + 1 .. close];
}

fn findMatchingPlistBrace(bytes: []const u8, open_idx: usize) ?usize {
    var depth: usize = 0;
    var i = open_idx;
    var in_quote = false;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (in_quote) {
            if (c == '\\' and i + 1 < bytes.len) {
                i += 1;
                continue;
            }
            if (c == '"') in_quote = false;
            continue;
        }
        if (c == '"') {
            in_quote = true;
            continue;
        }
        if (c == '/' and i + 1 < bytes.len and bytes[i + 1] == '*') {
            i += 2;
            while (i + 1 < bytes.len) : (i += 1) {
                if (bytes[i] == '*' and bytes[i + 1] == '/') {
                    i += 1;
                    break;
                }
            }
            continue;
        }
        if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn extractPlistFieldValue(block: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, block, key) orelse return null;
    const after = block[key_pos + key.len ..];
    // Skip whitespace and = and whitespace
    var pos: usize = 0;
    while (pos < after.len and (after[pos] == ' ' or after[pos] == '\t' or after[pos] == '=')) : (pos += 1) {}
    if (pos >= after.len) return null;
    if (after[pos] == '"') {
        pos += 1;
        const end = std.mem.indexOfScalarPos(u8, after, pos, '"') orelse return null;
        return after[pos..end];
    }
    // Bare value — read until semicolon or whitespace
    const start = pos;
    while (pos < after.len and after[pos] != ';' and after[pos] != '\n' and after[pos] != ' ' and after[pos] != '\t') : (pos += 1) {}
    if (pos > start) return std.mem.trim(u8, after[start..pos], " \t");
    return null;
}

fn extractPlistQuotedField(block: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, block, key) orelse return null;
    const after = block[key_pos + key.len ..];
    var pos: usize = 0;
    while (pos < after.len and (after[pos] == ' ' or after[pos] == '\t' or after[pos] == '=')) : (pos += 1) {}
    if (pos >= after.len) return null;
    if (after[pos] == '"') {
        pos += 1;
        const end = std.mem.indexOfScalarPos(u8, after, pos, '"') orelse return null;
        return after[pos..end];
    }
    // Bare value
    const start = pos;
    while (pos < after.len and after[pos] != ';' and after[pos] != '\n') : (pos += 1) {}
    return std.mem.trim(u8, after[start..pos], " \t");
}

fn findPlistArray(block: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, block, key) orelse return null;
    const after = block[key_pos + key.len ..];
    const open_paren = std.mem.indexOfScalar(u8, after, '(') orelse return null;
    const abs_open = key_pos + key.len + open_paren;
    // Find matching )
    var i = abs_open + 1;
    var depth: usize = 1;
    while (i < block.len and depth > 0) : (i += 1) {
        if (block[i] == '(') depth += 1;
        if (block[i] == ')') depth -= 1;
    }
    if (depth != 0) return null;
    return block[abs_open + 1 .. i - 1];
}

fn findPlistIsaBlock(block: []const u8, isa_type: []const u8, cursor: *usize) ?[]const u8 {
    var pos = cursor.*;
    while (pos < block.len) {
        // Find next "isa = TYPE"
        const isa_pos = std.mem.indexOfPos(u8, block, pos, "isa = ") orelse {
            cursor.* = block.len;
            return null;
        };
        const type_start = isa_pos + 6;
        const type_end_semi = std.mem.indexOfScalarPos(u8, block, type_start, ';') orelse {
            pos = type_start;
            continue;
        };
        const found_type = std.mem.trim(u8, block[type_start..type_end_semi], " \t");
        if (!std.mem.eql(u8, found_type, isa_type)) {
            pos = type_end_semi + 1;
            continue;
        }

        // Walk backwards to find the opening { of this object
        var obj_start = isa_pos;
        while (obj_start > 0 and block[obj_start] != '{') : (obj_start -= 1) {}
        // Find the matching }
        const obj_end = findMatchingPlistBrace(block, obj_start) orelse {
            pos = type_end_semi + 1;
            continue;
        };

        cursor.* = obj_end + 1;
        return block[obj_start + 1 .. obj_end];
    }
    cursor.* = block.len;
    return null;
}

fn findPbxObjectByUuid(objects_block: []const u8, uuid: []const u8) ?[]const u8 {
    // Find "UUID = {" or "UUID /* comment */ = {"
    var search_pos: usize = 0;
    while (search_pos < objects_block.len) {
        const uuid_pos = std.mem.indexOfPos(u8, objects_block, search_pos, uuid) orelse return null;
        // Make sure this is an object definition (followed by = {)
        const after_uuid = objects_block[uuid_pos + uuid.len ..];
        var skip: usize = 0;
        // Skip whitespace, comments, and =
        while (skip < after_uuid.len and (after_uuid[skip] == ' ' or after_uuid[skip] == '\t')) : (skip += 1) {}
        if (skip < after_uuid.len and after_uuid[skip] == '/') {
            // Skip /* comment */
            if (skip + 1 < after_uuid.len and after_uuid[skip + 1] == '*') {
                const comment_end = std.mem.indexOfPos(u8, after_uuid, skip + 2, "*/") orelse {
                    search_pos = uuid_pos + uuid.len;
                    continue;
                };
                skip = comment_end + 2;
                while (skip < after_uuid.len and (after_uuid[skip] == ' ' or after_uuid[skip] == '\t')) : (skip += 1) {}
            }
        }
        if (skip < after_uuid.len and after_uuid[skip] == '=') {
            skip += 1;
            while (skip < after_uuid.len and (after_uuid[skip] == ' ' or after_uuid[skip] == '\t')) : (skip += 1) {}
            if (skip < after_uuid.len and after_uuid[skip] == '{') {
                const abs_open = uuid_pos + uuid.len + skip;
                const close = findMatchingPlistBrace(objects_block, abs_open) orelse {
                    search_pos = uuid_pos + uuid.len;
                    continue;
                };
                return objects_block[abs_open + 1 .. close];
            }
        }
        search_pos = uuid_pos + uuid.len;
    }
    return null;
}

fn importFromDirectoryName(allocator: std.mem.Allocator, source_path: []const u8) !project_mod.Project {
    const inferred_name = project_mod.guessProjectNameFromPath(source_path);
    const targets = try allocator.alloc(project_mod.Target, 1);
    targets[0] = .{
        .name = inferred_name,
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
        .include_dirs = &.{"include"},
    };
    return .{
        .name = inferred_name,
        .version = "0.1.0",
        .license = "MIT",
        .targets = targets,
    };
}

fn importVcpkg(allocator: std.mem.Allocator, source_path: []const u8) !project_mod.Project {
    const path = if (std.mem.eql(u8, source_path, "."))
        "vcpkg.json"
    else
        try std.fmt.allocPrint(allocator, "{s}/vcpkg.json", .{source_path});

    if (!core.fs.fileExists(path)) {
        return importFromDirectoryName(allocator, source_path);
    }

    const bytes = try core.fs.readFileAlloc(allocator, path);
    const inferred_name = extractJsonStringField(bytes, "\"name\"") orelse project_mod.guessProjectNameFromPath(source_path);

    var deps: std.ArrayList(project_mod.Dependency) = .empty;
    errdefer deps.deinit(allocator);
    if (extractJsonArray(bytes, "\"dependencies\"")) |deps_array| {
        var i: usize = 0;
        while (i < deps_array.len) : (i += 1) {
            if (deps_array[i] != '"') continue;
            const end = std.mem.indexOfScalarPos(u8, deps_array, i + 1, '"') orelse break;
            const dep_name = deps_array[i + 1 .. end];
            if (dep_name.len > 0) {
                try deps.append(allocator, .{ .name = dep_name, .version = "latest" });
            }
            i = end;
        }
    }

    var project = try importFromDirectoryName(allocator, source_path);
    project.name = inferred_name;
    project.dependencies = try deps.toOwnedSlice(allocator);
    return project;
}

fn importConan(allocator: std.mem.Allocator, source_path: []const u8) !project_mod.Project {
    const txt_path = if (std.mem.eql(u8, source_path, "."))
        "conanfile.txt"
    else
        try std.fmt.allocPrint(allocator, "{s}/conanfile.txt", .{source_path});

    var deps: std.ArrayList(project_mod.Dependency) = .empty;
    errdefer deps.deinit(allocator);

    if (core.fs.fileExists(txt_path)) {
        const bytes = try core.fs.readFileAlloc(allocator, txt_path);
        var in_requires = false;
        var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t");
            if (line.len == 0 or line[0] == '#') continue;
            if (std.mem.eql(u8, line, "[requires]")) {
                in_requires = true;
                continue;
            }
            if (line[0] == '[' and line[line.len - 1] == ']') {
                in_requires = false;
                continue;
            }
            if (!in_requires) continue;

            const slash = std.mem.indexOfScalar(u8, line, '/') orelse continue;
            const dep_name = std.mem.trim(u8, line[0..slash], " \t");
            const dep_version = std.mem.trim(u8, line[slash + 1 ..], " \t");
            if (dep_name.len == 0) continue;
            try deps.append(allocator, .{
                .name = dep_name,
                .version = if (dep_version.len == 0) "latest" else dep_version,
            });
        }
    } else {
        // Fallback: scan conanfile.py for requires patterns
        const py_path = if (std.mem.eql(u8, source_path, "."))
            "conanfile.py"
        else
            try std.fmt.allocPrint(allocator, "{s}/conanfile.py", .{source_path});

        if (core.fs.fileExists(py_path)) {
            const py_bytes = try core.fs.readFileAlloc(allocator, py_path);
            try parseConanPyRequires(allocator, py_bytes, &deps);
        }
    }

    if (deps.items.len == 0) return importFromDirectoryName(allocator, source_path);

    var project = try importFromDirectoryName(allocator, source_path);
    project.dependencies = try deps.toOwnedSlice(allocator);
    return project;
}

fn parseConanPyRequires(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    deps: *std.ArrayList(project_mod.Dependency),
) !void {
    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t");
        // Match: requires = "lib/version"  or  self.requires("lib/version")
        const pattern_strs = [_][]const u8{ "requires", "self.requires" };
        for (pattern_strs) |pattern| {
            if (std.mem.indexOf(u8, line, pattern) == null) continue;
            // Find quoted strings containing /
            var i: usize = 0;
            while (i < line.len) : (i += 1) {
                if (line[i] != '"' and line[i] != '\'') continue;
                const quote = line[i];
                i += 1;
                const start = i;
                while (i < line.len and line[i] != quote) : (i += 1) {}
                if (i > start) {
                    const value = line[start..i];
                    const slash = std.mem.indexOfScalar(u8, value, '/') orelse continue;
                    const dep_name = value[0..slash];
                    const dep_version = value[slash + 1 ..];
                    if (dep_name.len > 0) {
                        try deps.append(allocator, .{
                            .name = dep_name,
                            .version = if (dep_version.len == 0) "latest" else dep_version,
                        });
                    }
                }
            }
        }
    }
}

fn extractCMakeCommands(allocator: std.mem.Allocator, bytes: []const u8) ![]CMakeCommand {
    var commands: std.ArrayList(CMakeCommand) = .empty;

    var i: usize = 0;
    while (i < bytes.len) {
        while (i < bytes.len and isWhitespace(bytes[i])) : (i += 1) {}
        if (i >= bytes.len) break;

        if (bytes[i] == '#') {
            while (i < bytes.len and bytes[i] != '\n') : (i += 1) {}
            continue;
        }

        if (!isCommandStart(bytes[i])) {
            i += 1;
            continue;
        }

        const name_start = i;
        while (i < bytes.len and isCommandChar(bytes[i])) : (i += 1) {}
        const name = trim(bytes[name_start..i]);
        if (name.len == 0) continue;

        while (i < bytes.len and isWhitespace(bytes[i])) : (i += 1) {}
        if (i >= bytes.len or bytes[i] != '(') continue;
        i += 1;

        const args_start = i;
        var depth: usize = 1;
        var in_quote = false;
        var escaped = false;
        while (i < bytes.len and depth > 0) {
            const current = bytes[i];
            if (escaped) {
                escaped = false;
                i += 1;
                continue;
            }
            if (in_quote) {
                if (current == '\\') {
                    escaped = true;
                } else if (current == '"') {
                    in_quote = false;
                }
                i += 1;
                continue;
            }
            if (current == '"') {
                in_quote = true;
                i += 1;
                continue;
            }
            if (current == '#') {
                while (i < bytes.len and bytes[i] != '\n') : (i += 1) {}
                continue;
            }
            if (current == '(') depth += 1;
            if (current == ')') depth -= 1;
            i += 1;
        }
        if (depth != 0) break;

        const args_end = i - 1;
        try commands.append(allocator, .{ .name = name, .args = trim(bytes[args_start..args_end]) });
    }

    return try commands.toOwnedSlice(allocator);
}

fn tokenizeCMakeArguments(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList([]const u8) {
    var tokens: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;

    while (i < input.len) {
        while (i < input.len and isWhitespace(input[i])) : (i += 1) {}
        if (i >= input.len) break;
        if (input[i] == '#') {
            while (i < input.len and input[i] != '\n') : (i += 1) {}
            continue;
        }

        if (input[i] == '"') {
            i += 1;
            const start = i;
            var escaped = false;
            while (i < input.len) {
                const c = input[i];
                if (escaped) {
                    escaped = false;
                    i += 1;
                    continue;
                }
                if (c == '\\') {
                    escaped = true;
                    i += 1;
                    continue;
                }
                if (c == '"') break;
                i += 1;
            }
            const end = i;
            if (start < end) try tokens.append(allocator, trim(input[start..end]));
            if (i < input.len and input[i] == '"') i += 1;
            continue;
        }

        const start = i;
        while (i < input.len) : (i += 1) {
            const c = input[i];
            if (isWhitespace(c) or c == '#') break;
        }
        if (start < i) try tokens.append(allocator, trim(input[start..i]));
        if (i < input.len and input[i] == '#') {
            while (i < input.len and input[i] != '\n') : (i += 1) {}
        }
    }

    return tokens;
}

fn parseProjectNameFromTokens(tokens: []const []const u8) ?[]const u8 {
    if (tokens.len == 0) return null;
    return if (tokens[0].len == 0) null else tokens[0];
}

fn parseSetCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    variables: *std.ArrayList(CMakeVariable),
    cpp_standard: *project_mod.CppStandard,
) !void {
    if (args.len < 2) return;

    if (std.ascii.eqlIgnoreCase(args[0], "CMAKE_CXX_STANDARD")) {
        if (parseCppStandardFromToken(args[1])) |standard| cpp_standard.* = standard;
        return;
    }

    if (std.ascii.eqlIgnoreCase(args[0], "CMAKE_C_STANDARD")) return;

    try setVariable(allocator, variables, args[0], args[1..]);
}

fn parseSetPropertyCommand(args: []const []const u8, cpp_standard: *project_mod.CppStandard) void {
    var i: usize = 0;
    while (i < args.len) {
        if (std.ascii.eqlIgnoreCase(args[i], "CXX_STANDARD") and i + 1 < args.len) {
            if (parseCppStandardFromToken(args[i + 1])) |standard| {
                cpp_standard.* = standard;
            }
            i += 1;
        }
        i += 1;
    }
}

fn parseSetTargetPropertiesCommand(args: []const []const u8, cpp_standard: *project_mod.CppStandard) void {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(args[i], "PROPERTIES")) {
            i += 1;
            while (i + 1 < args.len) {
                if (std.ascii.eqlIgnoreCase(args[i], "CXX_STANDARD")) {
                    if (parseCppStandardFromToken(args[i + 1])) |standard| {
                        cpp_standard.* = standard;
                    }
                }
                i += 2;
            }
            return;
        }
    }
}

fn parseTargetCompileFeatures(args: []const []const u8, cpp_standard: *project_mod.CppStandard) void {
    for (args) |token| {
        if (std.ascii.eqlIgnoreCase(token, "PUBLIC") or
            std.ascii.eqlIgnoreCase(token, "PRIVATE") or
            std.ascii.eqlIgnoreCase(token, "INTERFACE"))
        {
            continue;
        }
        if (parseCppStandardFromToken(token)) |standard| cpp_standard.* = standard;
    }
}

fn parseTargetCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    default_kind: project_mod.TargetType,
    targets: *std.ArrayList(CMakeTarget),
) !void {
    if (args.len == 0) return;

    const target_name = args[0];
    const target_index = try findOrCreateTarget(allocator, targets, target_name, default_kind);
    const target = &targets.items[target_index];

    var i: usize = 1;
    if (default_kind == .library_static or default_kind == .library_shared) {
        if (i < args.len) {
            if (parseTargetLibraryType(args[i])) |kind| {
                target.kind = kind;
                i += 1;
            }
        }
    }

    while (i < args.len) {
        const token = args[i];
        if (isIgnoredTargetToken(token)) {
            i += 1;
            continue;
        }
        if (isLikelySourceToken(token)) {
            try appendSplitTokenValues(allocator, &target.sources, token);
        }
        i += 1;
    }

    if (target.sources.items.len == 0 and
        (target.kind == .executable or target.kind == .test_target))
    {
        try appendUnique(allocator, &target.sources, "src/main.cpp");
    }
}

fn parseAddLibraryCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    targets: *std.ArrayList(CMakeTarget),
) !void {
    if (args.len < 2) return;
    const name = args[0];

    const kind = parseTargetLibraryType(args[1]) orelse project_mod.TargetType.library_static;
    var start_index: usize = 1;
    if (parseTargetLibraryType(args[1]) != null) {
        start_index = 2;
    }
    if (start_index == 1 and std.ascii.eqlIgnoreCase(args[1], "ALIAS")) return;

    const target_index = try findOrCreateTarget(allocator, targets, name, kind);
    const target = &targets.items[target_index];
    target.kind = kind;

    var i = start_index;
    while (i < args.len) {
        const token = args[i];
        if (isIgnoredTargetToken(token)) {
            i += 1;
            continue;
        }
        if (isLikelySourceToken(token)) {
            try appendSplitTokenValues(allocator, &target.sources, token);
        }
        i += 1;
    }
}

fn parseTargetSourcesCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    targets: *std.ArrayList(CMakeTarget),
) !void {
    if (args.len < 1) return;
    const target_name = args[0];
    const target_index = try findOrCreateTarget(allocator, targets, target_name, .executable);
    const target = &targets.items[target_index];

    var i: usize = 1;
    if (i < args.len and isScopeToken(args[i])) i += 1;
    while (i < args.len) {
        const token = args[i];
        if (isIgnoredTargetToken(token)) {
            i += 1;
            continue;
        }
        if (isLikelySourceToken(token)) {
            try appendSplitTokenValues(allocator, &target.sources, token);
        }
        i += 1;
    }
}

fn parseTargetIncludeDirectoriesCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    targets: *std.ArrayList(CMakeTarget),
) !void {
    if (args.len < 1) return;
    const target_name = args[0];
    const target_index = try findOrCreateTarget(allocator, targets, target_name, .executable);
    const target = &targets.items[target_index];

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const token = args[i];
        if (isScopeToken(token)) continue;
        if (isLikelyIncludeToken(token)) {
            try appendSplitTokenValues(allocator, &target.include_dirs, token);
        }
    }
}

fn parseTargetLinkLibrariesCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    targets: *std.ArrayList(CMakeTarget),
) !void {
    if (args.len < 1) return;
    const target_name = args[0];
    const target_index = try findOrCreateTarget(allocator, targets, target_name, .executable);
    const target = &targets.items[target_index];

    var i: usize = 1;
    if (i < args.len and isScopeToken(args[i])) i += 1;
    while (i < args.len) : (i += 1) {
        const token = args[i];
        if (isIgnoredTargetToken(token)) continue;
        if (token.len > 0) try appendSplitTokenValues(allocator, &target.link_libraries, token);
    }
}

fn appendDirectoryList(
    allocator: std.mem.Allocator,
    target: *std.ArrayList([]const u8),
    args: []const []const u8,
    skip: []const []const u8,
) !void {
    for (args) |token| {
        if (isKeyword(skip, token)) continue;
        if (isLikelyIncludeToken(token)) try appendSplitTokenValues(allocator, target, token);
    }
}

fn appendSplitTokenValues(
    allocator: std.mem.Allocator,
    target: *std.ArrayList([]const u8),
    token: []const u8,
) !void {
    var parts = std.mem.splitScalar(u8, token, ';');
    while (parts.next()) |part| {
        const value = trim(part);
        if (value.len == 0) continue;
        try appendUnique(allocator, target, value);
    }
}

fn findOrCreateTarget(
    allocator: std.mem.Allocator,
    targets: *std.ArrayList(CMakeTarget),
    name: []const u8,
    kind: project_mod.TargetType,
) !usize {
    if (findTargetIndex(targets, name)) |index| {
        return index;
    }

    try targets.append(allocator, .{
        .name = name,
        .kind = kind,
        .sources = .empty,
        .include_dirs = .empty,
        .link_libraries = .empty,
    });

    return targets.items.len - 1;
}

fn findTargetIndex(targets: *std.ArrayList(CMakeTarget), name: []const u8) ?usize {
    for (targets.items, 0..) |target, index| {
        if (std.mem.eql(u8, target.name, name)) return index;
    }
    return null;
}

fn appendUnique(
    allocator: std.mem.Allocator,
    target: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    const owned = try allocator.dupe(u8, value);
    for (target.items) |item| {
        if (std.mem.eql(u8, item, value)) {
            allocator.free(owned);
            return;
        }
    }
    try target.append(allocator, owned);
}

fn mergeIncludeDirs(allocator: std.mem.Allocator, global_includes: []const []const u8, target_includes: []const []const u8) ![]const []const u8 {
    var merged: std.ArrayList([]const u8) = .empty;
    for (global_includes) |include_dir| {
        try appendUnique(allocator, &merged, include_dir);
    }
    for (target_includes) |include_dir| {
        try appendUnique(allocator, &merged, include_dir);
    }
    return try merged.toOwnedSlice(allocator);
}

fn parseCppStandardFromToken(value: []const u8) ?project_mod.CppStandard {
    const token = trim(value);

    if (std.mem.eql(u8, token, "11") or std.ascii.eqlIgnoreCase(token, "cpp11") or std.ascii.eqlIgnoreCase(token, "cxx11")) return .cpp11;
    if (std.mem.eql(u8, token, "14") or std.ascii.eqlIgnoreCase(token, "cpp14") or std.ascii.eqlIgnoreCase(token, "cxx14")) return .cpp14;
    if (std.mem.eql(u8, token, "17") or std.ascii.eqlIgnoreCase(token, "cpp17") or std.ascii.eqlIgnoreCase(token, "cxx17")) return .cpp17;
    if (std.mem.eql(u8, token, "20") or std.ascii.eqlIgnoreCase(token, "cpp20") or std.ascii.eqlIgnoreCase(token, "cxx20")) return .cpp20;
    if (std.mem.eql(u8, token, "23") or std.ascii.eqlIgnoreCase(token, "cpp23") or std.ascii.eqlIgnoreCase(token, "cxx23")) return .cpp23;

    if (std.mem.startsWith(u8, token, "c++")) {
        if (std.fmt.parseInt(u8, token["c++".len..], 10) catch null) |numeric| {
            return switch (numeric) {
                11 => .cpp11,
                14 => .cpp14,
                17 => .cpp17,
                20 => .cpp20,
                23 => .cpp23,
                else => null,
            };
        }
    }

    if (std.mem.startsWith(u8, token, "cxx_std_")) {
        if (std.fmt.parseInt(u8, token["cxx_std_".len..], 10) catch null) |numeric| {
            return switch (numeric) {
                11 => .cpp11,
                14 => .cpp14,
                17 => .cpp17,
                20 => .cpp20,
                23 => .cpp23,
                else => null,
            };
        }
    }
    return null;
}

fn parseTargetLibraryType(token: []const u8) ?project_mod.TargetType {
    if (std.ascii.eqlIgnoreCase(token, "STATIC")) return .library_static;
    if (std.ascii.eqlIgnoreCase(token, "SHARED")) return .library_shared;
    if (std.ascii.eqlIgnoreCase(token, "MODULE")) return .library_shared;
    if (std.ascii.eqlIgnoreCase(token, "OBJECT")) return .library_static;
    if (std.ascii.eqlIgnoreCase(token, "INTERFACE")) return .library_static;
    return null;
}

fn setVariable(
    allocator: std.mem.Allocator,
    variables: *std.ArrayList(CMakeVariable),
    key: []const u8,
    values: []const []const u8,
) !void {
    for (variables.items, 0..) |*entry, index| {
        if (std.mem.eql(u8, entry.name, key)) {
            var stored_values: std.ArrayList([]const u8) = .empty;
            for (values) |value| {
                try stored_values.append(allocator, try allocator.dupe(u8, value));
            }
            variables.items[index].values = try stored_values.toOwnedSlice(allocator);
            return;
        }
    }
    var stored_values: std.ArrayList([]const u8) = .empty;
    for (values) |value| {
        try stored_values.append(allocator, try allocator.dupe(u8, value));
    }
    try variables.append(allocator, .{
        .name = try allocator.dupe(u8, key),
        .values = try stored_values.toOwnedSlice(allocator),
    });
}

fn findVariable(variables: *std.ArrayList(CMakeVariable), key: []const u8) ?CMakeVariable {
    for (variables.items) |entry| {
        if (std.mem.eql(u8, entry.name, key)) return entry;
    }
    return null;
}

fn expandVariables(
    allocator: std.mem.Allocator,
    input: []const []const u8,
    variables: *std.ArrayList(CMakeVariable),
    output: *std.ArrayList([]const u8),
) !void {
    for (input) |token| {
        if (extractVariableName(token)) |name| {
            if (findVariable(variables, name)) |entry| {
                for (entry.values) |value| {
                    try output.append(allocator, try allocator.dupe(u8, value));
                }
                continue;
            }
        }
        if (token.len > 0) {
            if (std.mem.indexOf(u8, token, "${") == null) {
                try output.append(allocator, try allocator.dupe(u8, token));
            } else {
                try interpolateVariableToken(allocator, token, variables, output);
            }
        }
    }
}

fn interpolateVariableToken(
    allocator: std.mem.Allocator,
    token: []const u8,
    variables: *std.ArrayList(CMakeVariable),
    output: *std.ArrayList([]const u8),
) !void {
    var expanded: std.ArrayList(u8) = .empty;
    defer expanded.deinit(allocator);

    var i: usize = 0;
    var found_any = false;
    while (i < token.len) {
        const start = std.mem.indexOf(u8, token[i..], "${") orelse {
            if (i < token.len) try expanded.appendSlice(allocator, token[i..]);
            break;
        };
        const abs_start = i + start;
        if (abs_start > i) {
            try expanded.appendSlice(allocator, token[i..abs_start]);
        }

        const search = token[abs_start + 2 ..];
        const close = std.mem.indexOfScalar(u8, search, '}') orelse {
            try expanded.appendSlice(allocator, token[abs_start..]);
            break;
        };
        const name = token[abs_start + 2 .. abs_start + 2 + close];
        if (findVariable(variables, name)) |entry| {
            if (entry.values.len > 0) {
                found_any = true;
                if (entry.values.len == 1) {
                    try expanded.appendSlice(allocator, entry.values[0]);
                } else {
                    for (entry.values, 0..) |value, index| {
                        if (index > 0) try expanded.append(allocator, ' ');
                        try expanded.appendSlice(allocator, value);
                    }
                }
            }
        } else {
            const missing = token[abs_start .. abs_start + 2 + close + 1];
            try expanded.appendSlice(allocator, missing);
        }
        i = abs_start + 2 + close + 1;
    }

    const expanded_token = try expanded.toOwnedSlice(allocator);
    if (expanded_token.len == 0) return;
    if (found_any) {
        try output.append(allocator, expanded_token);
    } else {
        try output.append(allocator, try allocator.dupe(u8, token));
    }

    return;
}

fn extractVariableName(token: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, token, "${")) return null;
    if (!std.mem.endsWith(u8, token, "}")) return null;
    if (token.len < 4) return null;
    return token[2 .. token.len - 1];
}

fn isLikelySourceToken(token: []const u8) bool {
    if (token.len == 0) return false;
    return token[0] != '$' and token[token.len - 1] != ';' and !isScopeToken(token);
}

fn isLikelyIncludeToken(token: []const u8) bool {
    if (token.len == 0) return false;
    return token[0] != '$' and !isIgnoredTargetToken(token);
}

fn isScopeToken(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "PUBLIC") or
        std.ascii.eqlIgnoreCase(token, "PRIVATE") or
        std.ascii.eqlIgnoreCase(token, "INTERFACE");
}

fn isIgnoredTargetToken(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "STATIC") or
        std.ascii.eqlIgnoreCase(token, "SHARED") or
        std.ascii.eqlIgnoreCase(token, "MODULE") or
        std.ascii.eqlIgnoreCase(token, "OBJECT") or
        std.ascii.eqlIgnoreCase(token, "INTERFACE") or
        std.ascii.eqlIgnoreCase(token, "EXCLUDE_FROM_ALL") or
        std.ascii.eqlIgnoreCase(token, "WIN32") or
        std.ascii.eqlIgnoreCase(token, "MACOSX_BUNDLE") or
        std.ascii.eqlIgnoreCase(token, "BEFORE") or
        std.ascii.eqlIgnoreCase(token, "AFTER") or
        std.ascii.eqlIgnoreCase(token, "SYSTEM") or
        std.ascii.eqlIgnoreCase(token, "IMPORTED") or
        std.ascii.eqlIgnoreCase(token, "OUTPUT_NAME") or
        std.ascii.eqlIgnoreCase(token, "UNICODE") or
        std.ascii.eqlIgnoreCase(token, "COMMAND") or
        std.ascii.eqlIgnoreCase(token, "SOURCES") or
        std.ascii.eqlIgnoreCase(token, "PROPERTIES") or
        std.ascii.eqlIgnoreCase(token, "GENERAL") or
        std.ascii.eqlIgnoreCase(token, "DEBUG") or
        std.ascii.eqlIgnoreCase(token, "OPTIMIZED") or
        std.ascii.eqlIgnoreCase(token, "ON") or
        std.ascii.eqlIgnoreCase(token, "OFF") or
        std.ascii.eqlIgnoreCase(token, "TRUE") or
        std.ascii.eqlIgnoreCase(token, "FALSE") or
        token.len == 0 or
        token[0] == '$';
}

fn isKeyword(list: []const []const u8, token: []const u8) bool {
    for (list) |entry| {
        if (std.ascii.eqlIgnoreCase(entry, token)) return true;
    }
    return false;
}

fn isCommandStart(char: u8) bool {
    return std.ascii.isAlphabetic(char) or char == '_';
}

fn isCommandChar(char: u8) bool {
    return isCommandStart(char) or std.ascii.isDigit(char);
}

fn isWhitespace(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\r' or char == '\n';
}

fn trim(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r\n");
}

fn extractJsonStringField(bytes: []const u8, field_name: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, bytes, field_name) orelse return null;
    const rest = bytes[start + field_name.len ..];
    const first_quote = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const quoted_tail = rest[first_quote + 1 ..];
    const second_quote = std.mem.indexOfScalar(u8, quoted_tail, '"') orelse return null;
    return quoted_tail[0..second_quote];
}

fn extractJsonArray(bytes: []const u8, field_name: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, bytes, field_name) orelse return null;
    const rest = bytes[start + field_name.len ..];
    const open_rel = std.mem.indexOfScalar(u8, rest, '[') orelse return null;
    const open_index = start + field_name.len + open_rel;
    const close = findMatchingSquare(bytes, open_index) orelse return null;
    if (close <= open_index) return null;
    return bytes[open_index + 1 .. close];
}

fn findMatchingSquare(bytes: []const u8, open_index: usize) ?usize {
    var depth: usize = 0;
    var i = open_index;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c == '"') {
            i += 1;
            while (i < bytes.len and bytes[i] != '"') : (i += 1) {
                if (bytes[i] == '\\' and i + 1 < bytes.len) i += 1;
            }
            continue;
        }
        if (c == '[') {
            depth += 1;
            continue;
        }
        if (c == ']') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn backwardTokenBoundary(line: []const u8, idx: usize) usize {
    var i = idx;
    while (i > 0) : (i -= 1) {
        const c = line[i - 1];
        if (c == ' ' or c == '\t' or c == ':' or c == '=') break;
    }
    return i;
}

fn forwardTokenBoundary(line: []const u8, idx: usize) usize {
    var i = idx;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == ' ' or c == '\t' or c == '\\') break;
    }
    return i;
}

test "import format parsing is case-insensitive" {
    try std.testing.expectEqual(ImportFormat.cmake, (parseImportFormat("CMAKE") orelse return error.TestExpectedEqual));
    try std.testing.expectEqual(ImportFormat.vcpkg, (parseImportFormat("VcPkG") orelse return error.TestExpectedEqual));
    try std.testing.expectEqual(ImportFormat.meson, parseImportFormat("meson"));
}

test "cmake tokenization handles quoted args and inline comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = "A \"hello world\" B  # comment";
    var tokens = try tokenizeCMakeArguments(alloc, source);
    defer tokens.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);
    try std.testing.expectEqualStrings("A", tokens.items[0]);
    try std.testing.expectEqualStrings("hello world", tokens.items[1]);
    try std.testing.expectEqualStrings("B", tokens.items[2]);
}

test "variable expansion replaces defined variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vars = std.ArrayList(CMakeVariable).empty;
    defer vars.deinit(alloc);
    try setVariable(alloc, &vars, "FOO", &.{ "one", "two" });

    var input = [_][]const u8{ "${FOO}", "keep", "${MISSING}" };
    var output = std.ArrayList([]const u8).empty;
    defer output.deinit(alloc);
    try expandVariables(alloc, &input, &vars, &output);

    try std.testing.expectEqual(@as(usize, 4), output.items.len);
    try std.testing.expectEqualStrings("one", output.items[0]);
    try std.testing.expectEqualStrings("two", output.items[1]);
    try std.testing.expectEqualStrings("keep", output.items[2]);
    try std.testing.expectEqualStrings("${MISSING}", output.items[3]);
}

test "cmake import handles add_subdirectory recursion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const fixture = try std.fmt.allocPrint(alloc, "build/.tmp-ovo-cmake-import-recursive-{d}", .{std.time.milliTimestamp()});
    defer core.fs.removeTreeIfExists(fixture) catch {};

    try core.fs.writeFile(try std.fmt.allocPrint(alloc, "{s}/CMakeLists.txt", .{fixture}),
        \\project(ImportRoot)
        \\add_subdirectory(modules)
    );
    try core.fs.writeFile(try std.fmt.allocPrint(alloc, "{s}/modules/CMakeLists.txt", .{fixture}),
        \\add_library(core STATIC modules/core.cpp)
    );

    const project = try importCMake(alloc, fixture);
    try std.testing.expectEqualStrings("ImportRoot", project.name);
    try std.testing.expectEqual(@as(usize, 1), project.targets.len);
    const target = project.targets[0];
    try std.testing.expectEqualStrings("core", target.name);
    try std.testing.expectEqual(project_mod.TargetType.library_static, target.kind);
    try std.testing.expectEqual(@as(usize, 1), target.sources.len);
    try std.testing.expectEqualStrings("modules/core.cpp", target.sources[0]);
}

test "cmake variable expansion supports embedded values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const fixture = try std.fmt.allocPrint(alloc, "build/.tmp-ovo-cmake-import-var-{d}", .{std.time.milliTimestamp()});
    defer core.fs.removeTreeIfExists(fixture) catch {};

    try core.fs.writeFile(try std.fmt.allocPrint(alloc, "{s}/CMakeLists.txt", .{fixture}),
        \\project(Embed)
        \\set(ROOT src)
        \\set(INCLUDES include)
        \\include_directories(${ROOT}/${INCLUDES})
        \\add_executable(app ${ROOT}/main.cpp)
    );

    const project = try importCMake(alloc, fixture);
    try std.testing.expectEqualStrings("Embed", project.name);
    try std.testing.expectEqual(@as(usize, 1), project.targets.len);
    const target = project.targets[0];
    try std.testing.expectEqualStrings("app", target.name);
    try std.testing.expectEqual(@as(usize, 1), target.sources.len);
    try std.testing.expectEqualStrings("src/main.cpp", target.sources[0]);
    try std.testing.expectEqual(@as(usize, 1), target.include_dirs.len);
    try std.testing.expectEqualStrings("src/include", target.include_dirs[0]);
}

test "cmake variable list values split on semicolon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const fixture = try std.fmt.allocPrint(alloc, "build/.tmp-ovo-cmake-import-list-{d}", .{std.time.milliTimestamp()});
    defer core.fs.removeTreeIfExists(fixture) catch {};

    try core.fs.writeFile(try std.fmt.allocPrint(alloc, "{s}/CMakeLists.txt", .{fixture}),
        \\project(ListProject)
        \\set(SOURCES src/a.cpp;src/b.cpp)
        \\add_library(parts STATIC ${SOURCES})
    );

    const project = try importCMake(alloc, fixture);
    try std.testing.expectEqual(@as(usize, 1), project.targets.len);
    try std.testing.expectEqual(@as(usize, 2), project.targets[0].sources.len);
    try std.testing.expectEqualStrings("src/a.cpp", project.targets[0].sources[0]);
    try std.testing.expectEqualStrings("src/b.cpp", project.targets[0].sources[1]);
}
