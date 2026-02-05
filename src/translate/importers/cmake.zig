//! CMake Importer - CMakeLists.txt -> build.zon
//!
//! Parses CMake build files and translates to Zig build representation.
//! Supports:
//! - add_executable, add_library targets
//! - find_package dependency mapping
//! - target_link_libraries, target_include_directories
//! - CMake variables and generator expressions (partial)

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../engine.zig");
const Project = engine.Project;
const Target = engine.Target;
const TargetKind = engine.TargetKind;
const Dependency = engine.Dependency;
const TranslationWarning = engine.TranslationWarning;
const WarningSeverity = engine.WarningSeverity;
const TranslationOptions = engine.TranslationOptions;

/// CMake command types we recognize
const CmakeCommand = enum {
    project,
    cmake_minimum_required,
    add_executable,
    add_library,
    target_sources,
    target_link_libraries,
    target_include_directories,
    target_compile_definitions,
    target_compile_options,
    find_package,
    pkg_check_modules,
    include_directories,
    link_directories,
    link_libraries,
    add_definitions,
    add_compile_options,
    set,
    option,
    if_cmd,
    elseif_cmd,
    else_cmd,
    endif_cmd,
    foreach_cmd,
    endforeach_cmd,
    function_cmd,
    endfunction_cmd,
    macro_cmd,
    endmacro_cmd,
    include,
    add_subdirectory,
    install,
    file,
    message,
    unknown,
};

/// CMake variable storage
const Variables = std.StringHashMap([]const u8);

/// CMake parser state
const ParserState = struct {
    allocator: Allocator,
    content: []const u8,
    pos: usize = 0,
    line: usize = 1,
    column: usize = 1,
    variables: Variables,
    project: *Project,
    current_dir: []const u8,
    options: TranslationOptions,

    fn init(allocator: Allocator, content: []const u8, project: *Project, dir: []const u8, options: TranslationOptions) ParserState {
        return .{
            .allocator = allocator,
            .content = content,
            .variables = Variables.init(allocator),
            .project = project,
            .current_dir = dir,
            .options = options,
        };
    }

    fn deinit(self: *ParserState) void {
        self.variables.deinit();
    }

    fn peek(self: *ParserState) ?u8 {
        if (self.pos >= self.content.len) return null;
        return self.content[self.pos];
    }

    fn advance(self: *ParserState) ?u8 {
        if (self.pos >= self.content.len) return null;
        const c = self.content[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return c;
    }

    fn skipWhitespace(self: *ParserState) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                _ = self.advance();
            } else if (c == '#') {
                // Skip comment
                while (self.peek()) |cc| {
                    if (cc == '\n') break;
                    _ = self.advance();
                }
            } else {
                break;
            }
        }
    }

    fn readIdentifier(self: *ParserState) ?[]const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                _ = self.advance();
            } else {
                break;
            }
        }
        if (self.pos == start) return null;
        return self.content[start..self.pos];
    }

    fn readArgument(self: *ParserState) !?[]const u8 {
        self.skipWhitespace();

        const c = self.peek() orelse return null;

        if (c == ')') return null;

        // Quoted string
        if (c == '"') {
            _ = self.advance();
            const start = self.pos;
            while (self.peek()) |ch| {
                if (ch == '"') {
                    const result = self.content[start..self.pos];
                    _ = self.advance();
                    return try self.expandVariables(result);
                }
                if (ch == '\\' and self.pos + 1 < self.content.len) {
                    _ = self.advance();
                }
                _ = self.advance();
            }
            return error.UnterminatedString;
        }

        // Unquoted argument
        const start = self.pos;
        while (self.peek()) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == ')' or ch == '(') {
                break;
            }
            _ = self.advance();
        }

        if (self.pos == start) return null;
        return try self.expandVariables(self.content[start..self.pos]);
    }

    fn expandVariables(self: *ParserState, text: []const u8) ![]const u8 {
        // Simple variable expansion: ${VAR} -> value
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var i: usize = 0;
        while (i < text.len) {
            if (i + 1 < text.len and text[i] == '$' and text[i + 1] == '{') {
                // Find closing brace
                const start = i + 2;
                var end = start;
                while (end < text.len and text[end] != '}') {
                    end += 1;
                }
                if (end < text.len) {
                    const var_name = text[start..end];
                    if (self.variables.get(var_name)) |value| {
                        try result.appendSlice(value);
                    } else {
                        // Keep unresolved variable
                        try result.appendSlice(text[i .. end + 1]);
                    }
                    i = end + 1;
                    continue;
                }
            }
            try result.append(text[i]);
            i += 1;
        }

        return result.toOwnedSlice();
    }

    fn location(self: *ParserState) []const u8 {
        var buf: [64]u8 = undefined;
        const loc = std.fmt.bufPrint(&buf, "line {d}, column {d}", .{ self.line, self.column }) catch "unknown";
        return self.allocator.dupe(u8, loc) catch "unknown";
    }
};

/// Well-known find_package to Zig dependency mapping
const PackageMapping = struct {
    cmake_name: []const u8,
    zig_name: []const u8,
    url: ?[]const u8 = null,
};

const known_packages = [_]PackageMapping{
    .{ .cmake_name = "ZLIB", .zig_name = "zlib", .url = "https://github.com/madler/zlib" },
    .{ .cmake_name = "PNG", .zig_name = "libpng" },
    .{ .cmake_name = "JPEG", .zig_name = "libjpeg" },
    .{ .cmake_name = "OpenSSL", .zig_name = "openssl" },
    .{ .cmake_name = "Threads", .zig_name = "pthread" },
    .{ .cmake_name = "CURL", .zig_name = "curl" },
    .{ .cmake_name = "SQLite3", .zig_name = "sqlite" },
    .{ .cmake_name = "Boost", .zig_name = "boost" },
    .{ .cmake_name = "GTest", .zig_name = "googletest" },
    .{ .cmake_name = "fmt", .zig_name = "fmt" },
    .{ .cmake_name = "spdlog", .zig_name = "spdlog" },
    .{ .cmake_name = "nlohmann_json", .zig_name = "json" },
};

fn mapPackage(cmake_name: []const u8) ?PackageMapping {
    for (known_packages) |pkg| {
        if (std.ascii.eqlIgnoreCase(pkg.cmake_name, cmake_name)) {
            return pkg;
        }
    }
    return null;
}

/// Parse CMakeLists.txt and return Project
pub fn parse(allocator: Allocator, path: []const u8, options: TranslationOptions) !Project {
    const dir = std.fs.path.dirname(path) orelse ".";
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    var project = Project.init(allocator, "cmake_project", dir);
    errdefer project.deinit();

    var state = ParserState.init(allocator, content, &project, dir, options);
    defer state.deinit();

    // Set some default variables
    try state.variables.put("CMAKE_SOURCE_DIR", dir);
    try state.variables.put("CMAKE_CURRENT_SOURCE_DIR", dir);
    try state.variables.put("PROJECT_SOURCE_DIR", dir);

    try parseCommands(&state);

    return project;
}

fn parseCommands(state: *ParserState) !void {
    while (true) {
        state.skipWhitespace();
        if (state.peek() == null) break;

        const cmd_name = state.readIdentifier() orelse continue;
        const cmd = classifyCommand(cmd_name);

        state.skipWhitespace();
        if (state.peek() != '(') {
            try state.project.addWarning(.{
                .severity = .warning,
                .message = "Expected '(' after command",
                .source_location = state.location(),
            });
            continue;
        }
        _ = state.advance(); // consume '('

        try handleCommand(state, cmd, cmd_name);

        state.skipWhitespace();
        if (state.peek() == ')') {
            _ = state.advance();
        }
    }
}

fn classifyCommand(name: []const u8) CmakeCommand {
    const lower = std.ascii.lowerString(undefined[0..name.len], name);
    const cmd_map = std.StaticStringMap(CmakeCommand).initComptime(.{
        .{ "project", .project },
        .{ "cmake_minimum_required", .cmake_minimum_required },
        .{ "add_executable", .add_executable },
        .{ "add_library", .add_library },
        .{ "target_sources", .target_sources },
        .{ "target_link_libraries", .target_link_libraries },
        .{ "target_include_directories", .target_include_directories },
        .{ "target_compile_definitions", .target_compile_definitions },
        .{ "target_compile_options", .target_compile_options },
        .{ "find_package", .find_package },
        .{ "pkg_check_modules", .pkg_check_modules },
        .{ "include_directories", .include_directories },
        .{ "link_directories", .link_directories },
        .{ "link_libraries", .link_libraries },
        .{ "add_definitions", .add_definitions },
        .{ "add_compile_options", .add_compile_options },
        .{ "set", .set },
        .{ "option", .option },
        .{ "if", .if_cmd },
        .{ "elseif", .elseif_cmd },
        .{ "else", .else_cmd },
        .{ "endif", .endif_cmd },
        .{ "foreach", .foreach_cmd },
        .{ "endforeach", .endforeach_cmd },
        .{ "function", .function_cmd },
        .{ "endfunction", .endfunction_cmd },
        .{ "macro", .macro_cmd },
        .{ "endmacro", .endmacro_cmd },
        .{ "include", .include },
        .{ "add_subdirectory", .add_subdirectory },
        .{ "install", .install },
        .{ "file", .file },
        .{ "message", .message },
    });

    return cmd_map.get(lower) orelse .unknown;
}

fn handleCommand(state: *ParserState, cmd: CmakeCommand, cmd_name: []const u8) !void {
    switch (cmd) {
        .project => try handleProject(state),
        .cmake_minimum_required => try handleMinimumRequired(state),
        .add_executable => try handleAddExecutable(state),
        .add_library => try handleAddLibrary(state),
        .target_sources => try handleTargetSources(state),
        .target_link_libraries => try handleTargetLinkLibraries(state),
        .target_include_directories => try handleTargetIncludeDirectories(state),
        .target_compile_definitions => try handleTargetCompileDefinitions(state),
        .find_package => try handleFindPackage(state),
        .set => try handleSet(state),
        .add_subdirectory => try handleAddSubdirectory(state),
        .include => try handleInclude(state),
        .unknown => {
            if (state.options.verbose) {
                try state.project.addWarning(.{
                    .severity = .info,
                    .message = try std.fmt.allocPrint(state.allocator, "Unknown CMake command: {s}", .{cmd_name}),
                    .source_location = state.location(),
                });
            }
            // Skip arguments
            try skipArguments(state);
        },
        else => try skipArguments(state),
    }
}

fn handleProject(state: *ParserState) !void {
    if (try state.readArgument()) |name| {
        state.project.name = name;
        try state.variables.put("PROJECT_NAME", name);

        // Parse optional VERSION, LANGUAGES, etc.
        while (try state.readArgument()) |arg| {
            if (std.mem.eql(u8, arg, "VERSION")) {
                if (try state.readArgument()) |ver| {
                    state.project.version = ver;
                    try state.variables.put("PROJECT_VERSION", ver);
                }
            } else if (std.mem.eql(u8, arg, "DESCRIPTION")) {
                if (try state.readArgument()) |desc| {
                    state.project.description = desc;
                }
            } else if (std.mem.eql(u8, arg, "HOMEPAGE_URL")) {
                if (try state.readArgument()) |url| {
                    state.project.homepage = url;
                }
            }
        }
    }
}

fn handleMinimumRequired(state: *ParserState) !void {
    while (try state.readArgument()) |arg| {
        if (std.mem.eql(u8, arg, "VERSION")) {
            if (try state.readArgument()) |ver| {
                try state.variables.put("CMAKE_MINIMUM_REQUIRED_VERSION", ver);
            }
        }
    }
}

fn handleAddExecutable(state: *ParserState) !void {
    const name = try state.readArgument() orelse return;
    var target = Target.init(state.allocator, name, .executable);

    // Parse sources
    while (try state.readArgument()) |arg| {
        // Skip keywords
        if (std.mem.eql(u8, arg, "WIN32") or
            std.mem.eql(u8, arg, "MACOSX_BUNDLE") or
            std.mem.eql(u8, arg, "EXCLUDE_FROM_ALL"))
        {
            continue;
        }

        // Source file
        const source_path = try std.fs.path.join(state.allocator, &.{ state.current_dir, arg });
        try target.sources.append(source_path);
    }

    try state.project.addTarget(target);
}

fn handleAddLibrary(state: *ParserState) !void {
    const name = try state.readArgument() orelse return;

    var kind: TargetKind = .static_library;
    var is_interface = false;

    // Check library type
    if (try state.readArgument()) |arg| {
        if (std.mem.eql(u8, arg, "STATIC")) {
            kind = .static_library;
        } else if (std.mem.eql(u8, arg, "SHARED")) {
            kind = .shared_library;
        } else if (std.mem.eql(u8, arg, "INTERFACE")) {
            kind = .interface;
            is_interface = true;
        } else if (std.mem.eql(u8, arg, "OBJECT")) {
            kind = .object_library;
        } else if (std.mem.eql(u8, arg, "MODULE")) {
            kind = .shared_library;
            try state.project.addWarning(.{
                .severity = .warning,
                .message = "MODULE libraries translated as SHARED",
                .source_location = state.location(),
            });
        } else {
            // It's a source file
            var target = Target.init(state.allocator, name, kind);
            const source_path = try std.fs.path.join(state.allocator, &.{ state.current_dir, arg });
            try target.sources.append(source_path);

            while (try state.readArgument()) |src| {
                const path = try std.fs.path.join(state.allocator, &.{ state.current_dir, src });
                try target.sources.append(path);
            }

            try state.project.addTarget(target);
            return;
        }
    }

    var target = Target.init(state.allocator, name, kind);

    if (!is_interface) {
        // Parse sources
        while (try state.readArgument()) |arg| {
            if (std.mem.eql(u8, arg, "EXCLUDE_FROM_ALL")) continue;
            const source_path = try std.fs.path.join(state.allocator, &.{ state.current_dir, arg });
            try target.sources.append(source_path);
        }
    }

    try state.project.addTarget(target);
}

fn handleTargetSources(state: *ParserState) !void {
    const target_name = try state.readArgument() orelse return;

    // Find target
    for (state.project.targets.items) |*target| {
        if (std.mem.eql(u8, target.name, target_name)) {
            var visibility_mode: enum { public, private, interface } = .private;

            while (try state.readArgument()) |arg| {
                if (std.mem.eql(u8, arg, "PUBLIC")) {
                    visibility_mode = .public;
                } else if (std.mem.eql(u8, arg, "PRIVATE")) {
                    visibility_mode = .private;
                } else if (std.mem.eql(u8, arg, "INTERFACE")) {
                    visibility_mode = .interface;
                } else {
                    // visibility_mode is tracked but sources are added regardless
                    const source_path = try std.fs.path.join(state.allocator, &.{ state.current_dir, arg });
                    try target.sources.append(source_path);
                }
            }
            return;
        }
    }

    try state.project.addWarning(.{
        .severity = .warning,
        .message = try std.fmt.allocPrint(state.allocator, "target_sources: unknown target '{s}'", .{target_name}),
        .source_location = state.location(),
    });
    try skipArguments(state);
}

fn handleTargetLinkLibraries(state: *ParserState) !void {
    const target_name = try state.readArgument() orelse return;

    for (state.project.targets.items) |*target| {
        if (std.mem.eql(u8, target.name, target_name)) {
            while (try state.readArgument()) |arg| {
                // Skip visibility keywords
                if (std.mem.eql(u8, arg, "PUBLIC") or
                    std.mem.eql(u8, arg, "PRIVATE") or
                    std.mem.eql(u8, arg, "INTERFACE"))
                {
                    continue;
                }

                // Handle generator expressions (partial support)
                if (std.mem.startsWith(u8, arg, "$<")) {
                    try state.project.addWarning(.{
                        .severity = .warning,
                        .message = "Generator expression in target_link_libraries not fully supported",
                        .source_location = state.location(),
                    });
                    continue;
                }

                try target.flags.link_libraries.append(arg);
                try target.dependencies.append(arg);
            }
            return;
        }
    }
    try skipArguments(state);
}

fn handleTargetIncludeDirectories(state: *ParserState) !void {
    const target_name = try state.readArgument() orelse return;

    for (state.project.targets.items) |*target| {
        if (std.mem.eql(u8, target.name, target_name)) {
            var is_system = false;

            while (try state.readArgument()) |arg| {
                if (std.mem.eql(u8, arg, "PUBLIC") or
                    std.mem.eql(u8, arg, "PRIVATE") or
                    std.mem.eql(u8, arg, "INTERFACE"))
                {
                    continue;
                }
                if (std.mem.eql(u8, arg, "SYSTEM")) {
                    is_system = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "BEFORE") or std.mem.eql(u8, arg, "AFTER")) {
                    continue;
                }

                const include_path = try std.fs.path.join(state.allocator, &.{ state.current_dir, arg });
                if (is_system) {
                    try target.flags.system_include_paths.append(include_path);
                } else {
                    try target.flags.include_paths.append(include_path);
                }
            }
            return;
        }
    }
    try skipArguments(state);
}

fn handleTargetCompileDefinitions(state: *ParserState) !void {
    const target_name = try state.readArgument() orelse return;

    for (state.project.targets.items) |*target| {
        if (std.mem.eql(u8, target.name, target_name)) {
            while (try state.readArgument()) |arg| {
                if (std.mem.eql(u8, arg, "PUBLIC") or
                    std.mem.eql(u8, arg, "PRIVATE") or
                    std.mem.eql(u8, arg, "INTERFACE"))
                {
                    continue;
                }
                try target.flags.defines.append(arg);
            }
            return;
        }
    }
    try skipArguments(state);
}

fn handleFindPackage(state: *ParserState) !void {
    const package_name = try state.readArgument() orelse return;

    var is_required = false;
    var components = std.ArrayList([]const u8).init(state.allocator);
    defer components.deinit();

    while (try state.readArgument()) |arg| {
        if (std.mem.eql(u8, arg, "REQUIRED")) {
            is_required = true;
        } else if (std.mem.eql(u8, arg, "COMPONENTS") or std.mem.eql(u8, arg, "OPTIONAL_COMPONENTS")) {
            // Following args are component names until next keyword
            continue;
        } else if (std.mem.eql(u8, arg, "CONFIG") or
            std.mem.eql(u8, arg, "MODULE") or
            std.mem.eql(u8, arg, "QUIET"))
        {
            continue;
        } else {
            try components.append(arg);
        }
    }

    // Map to Zig dependency
    if (mapPackage(package_name)) |mapping| {
        try state.project.addDependency(.{
            .name = mapping.zig_name,
            .url = mapping.url,
            .kind = if (is_required) .build else .optional,
        });
    } else {
        // Unknown package
        try state.project.addDependency(.{
            .name = package_name,
            .kind = if (is_required) .build else .optional,
        });
        try state.project.addWarning(.{
            .severity = .info,
            .message = try std.fmt.allocPrint(state.allocator, "Unknown package '{s}' - manual configuration may be needed", .{package_name}),
            .source_location = state.location(),
            .suggestion = "Add dependency URL and hash to build.zig.zon",
        });
    }
}

fn handleSet(state: *ParserState) !void {
    const var_name = try state.readArgument() orelse return;

    // Collect all values (CMake lists are space-separated)
    var values = std.ArrayList(u8).init(state.allocator);
    defer values.deinit();

    var first = true;
    while (try state.readArgument()) |arg| {
        // Skip CACHE, PARENT_SCOPE, etc.
        if (std.mem.eql(u8, arg, "CACHE") or
            std.mem.eql(u8, arg, "PARENT_SCOPE") or
            std.mem.eql(u8, arg, "FORCE"))
        {
            break;
        }
        if (!first) try values.append(';');
        try values.appendSlice(arg);
        first = false;
    }

    if (values.items.len > 0) {
        const value = try values.toOwnedSlice();
        try state.variables.put(var_name, value);
    }
}

fn handleAddSubdirectory(state: *ParserState) !void {
    const subdir = try state.readArgument() orelse return;

    const subdir_path = try std.fs.path.join(state.allocator, &.{ state.current_dir, subdir, "CMakeLists.txt" });

    // Check if subdirectory CMakeLists.txt exists
    if (std.fs.cwd().access(subdir_path, .{})) {
        // Parse subdirectory (recursive)
        const file = std.fs.cwd().openFile(subdir_path, .{}) catch {
            try state.project.addWarning(.{
                .severity = .warning,
                .message = try std.fmt.allocPrint(state.allocator, "Could not open subdirectory: {s}", .{subdir}),
            });
            return;
        };
        defer file.close();

        const content = file.readToEndAlloc(state.allocator, 10 * 1024 * 1024) catch return;
        defer state.allocator.free(content);

        const old_dir = state.current_dir;
        state.current_dir = try std.fs.path.join(state.allocator, &.{ state.current_dir, subdir });
        defer state.current_dir = old_dir;

        const old_content = state.content;
        const old_pos = state.pos;
        state.content = content;
        state.pos = 0;

        parseCommands(state) catch |err| {
            try state.project.addWarning(.{
                .severity = .warning,
                .message = try std.fmt.allocPrint(state.allocator, "Error parsing subdirectory {s}: {}", .{ subdir, err }),
            });
        };

        state.content = old_content;
        state.pos = old_pos;
    } else |_| {
        try state.project.addWarning(.{
            .severity = .warning,
            .message = try std.fmt.allocPrint(state.allocator, "Subdirectory not found: {s}", .{subdir}),
        });
    }

    try skipArguments(state);
}

fn handleInclude(state: *ParserState) !void {
    const include_file = try state.readArgument() orelse return;

    // Check for well-known includes
    if (std.mem.eql(u8, include_file, "GNUInstallDirs") or
        std.mem.eql(u8, include_file, "CTest") or
        std.mem.eql(u8, include_file, "FetchContent"))
    {
        // These are CMake modules, note them but don't process
        if (state.options.verbose) {
            try state.project.addWarning(.{
                .severity = .info,
                .message = try std.fmt.allocPrint(state.allocator, "CMake module included: {s}", .{include_file}),
            });
        }
    }

    try skipArguments(state);
}

fn skipArguments(state: *ParserState) !void {
    var depth: usize = 0;
    while (state.peek()) |c| {
        if (c == '(') {
            depth += 1;
            _ = state.advance();
        } else if (c == ')') {
            if (depth == 0) break;
            depth -= 1;
            _ = state.advance();
        } else {
            _ = try state.readArgument();
        }
    }
}

// Tests
test "CMake parser basics" {
    const allocator = std.testing.allocator;

    const cmake_content =
        \\cmake_minimum_required(VERSION 3.20)
        \\project(TestProject VERSION 1.0.0)
        \\add_executable(myapp main.cpp utils.cpp)
    ;

    // Create temp file
    const tmp_path = "/tmp/test_cmake_CMakeLists.txt";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll(cmake_content);
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var project = try parse(allocator, tmp_path, .{});
    defer project.deinit();

    try std.testing.expectEqualStrings("TestProject", project.name);
    try std.testing.expectEqual(@as(usize, 1), project.targets.items.len);
    try std.testing.expectEqualStrings("myapp", project.targets.items[0].name);
}
