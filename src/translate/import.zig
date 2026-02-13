const std = @import("std");
const core = @import("../core/mod.zig");
const project_mod = @import("../core/project.zig");
const zon = @import("../zon/mod.zig");

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
    if (std.mem.eql(u8, value, "cmake")) return .cmake;
    if (std.mem.eql(u8, value, "xcode")) return .xcode;
    if (std.mem.eql(u8, value, "msbuild")) return .msbuild;
    if (std.mem.eql(u8, value, "meson")) return .meson;
    if (std.mem.eql(u8, value, "makefile")) return .makefile;
    if (std.mem.eql(u8, value, "vcpkg")) return .vcpkg;
    if (std.mem.eql(u8, value, "conan")) return .conan;
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
        .xcode => try importFromDirectoryName(allocator, source_path),
        .msbuild => try importFromDirectoryName(allocator, source_path),
        .vcpkg => try importVcpkg(allocator, source_path),
        .conan => try importConan(allocator, source_path),
    };
}

pub fn writeImportedProject(allocator: std.mem.Allocator, project: project_mod.Project) !void {
    const bytes = try zon.writer.renderBuildZon(allocator, project);
    try core.fs.writeFile("build.zon", bytes);
}

fn importCMake(allocator: std.mem.Allocator, source_path: []const u8) !project_mod.Project {
    const path = if (std.mem.eql(u8, source_path, "."))
        "CMakeLists.txt"
    else
        try std.fmt.allocPrint(allocator, "{s}/CMakeLists.txt", .{source_path});

    if (!core.fs.fileExists(path)) return error.CMakeFileNotFound;
    const cmake = try core.fs.readFileAlloc(allocator, path);

    const project_name = parseProjectName(cmake) orelse project_mod.guessProjectNameFromPath(source_path);
    const target_name = parseAddExecutableName(cmake) orelse project_name;
    const sources = try parseCMakeSources(allocator, cmake);

    const target = project_mod.Target{
        .name = target_name,
        .kind = .executable,
        .sources = sources,
        .include_dirs = &.{"include"},
    };

    const targets = try allocator.alloc(project_mod.Target, 1);
    targets[0] = target;

    return .{
        .name = project_name,
        .version = "0.1.0",
        .license = "MIT",
        .targets = targets,
    };
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
    const path = if (std.mem.eql(u8, source_path, "."))
        "conanfile.txt"
    else
        try std.fmt.allocPrint(allocator, "{s}/conanfile.txt", .{source_path});

    if (!core.fs.fileExists(path)) {
        return importFromDirectoryName(allocator, source_path);
    }

    const bytes = try core.fs.readFileAlloc(allocator, path);
    var deps: std.ArrayList(project_mod.Dependency) = .empty;
    errdefer deps.deinit(allocator);

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

    var project = try importFromDirectoryName(allocator, source_path);
    project.dependencies = try deps.toOwnedSlice(allocator);
    return project;
}

fn extractJsonStringField(bytes: []const u8, field_name: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, bytes, field_name) orelse return null;
    const rest = bytes[start + field_name.len ..];
    const first_quote = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const tail = rest[first_quote + 1 ..];
    const second_quote = std.mem.indexOfScalar(u8, tail, '"') orelse return null;
    return tail[0..second_quote];
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

fn parseProjectName(cmake: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, cmake, "project(") orelse return null;
    const tail = cmake[start + "project(".len ..];
    const end = std.mem.indexOfScalar(u8, tail, ')') orelse return null;
    const inside = std.mem.trim(u8, tail[0..end], " \t\r\n");
    if (inside.len == 0) return null;
    return inside;
}

fn parseAddExecutableName(cmake: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, cmake, "add_executable(") orelse return null;
    const tail = cmake[start + "add_executable(".len ..];
    const end = std.mem.indexOfScalar(u8, tail, ')') orelse return null;
    const inside = std.mem.trim(u8, tail[0..end], " \t\r\n");
    if (inside.len == 0) return null;
    const first_space = std.mem.indexOfAny(u8, inside, " \t\r\n") orelse inside.len;
    return inside[0..first_space];
}

fn parseCMakeSources(allocator: std.mem.Allocator, cmake: []const u8) ![]const []const u8 {
    const start = std.mem.indexOf(u8, cmake, "add_executable(") orelse {
        return &.{"src/main.cpp"};
    };
    const tail = cmake[start + "add_executable(".len ..];
    const end = std.mem.indexOfScalar(u8, tail, ')') orelse return &.{"src/main.cpp"};
    const inside = std.mem.trim(u8, tail[0..end], " \t\r\n");

    var tokens = std.mem.tokenizeAny(u8, inside, " \t\r\n");
    _ = tokens.next();

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    while (tokens.next()) |token| {
        if (std.mem.endsWith(u8, token, ".cpp") or
            std.mem.endsWith(u8, token, ".cc") or
            std.mem.endsWith(u8, token, ".c"))
        {
            try out.append(allocator, token);
        }
    }
    if (out.items.len == 0) try out.append(allocator, "src/main.cpp");
    return try out.toOwnedSlice(allocator);
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
