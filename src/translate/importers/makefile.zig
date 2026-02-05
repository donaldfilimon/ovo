//! Makefile Importer - Makefile -> build.zon (Heuristic Analysis)
//!
//! Attempts to parse and understand Makefiles using heuristics:
//! - Variable assignments (CC, CXX, CFLAGS, LDFLAGS, etc.)
//! - Target definitions (executable, library patterns)
//! - Source file collections
//! - Include/library paths
//!
//! Note: Makefile parsing is inherently imprecise due to the language's
//! flexibility and shell integration. This importer uses best-effort heuristics.

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

/// Common Makefile variables we track
const TrackedVariables = struct {
    CC: ?[]const u8 = null,
    CXX: ?[]const u8 = null,
    CFLAGS: ?[]const u8 = null,
    CXXFLAGS: ?[]const u8 = null,
    CPPFLAGS: ?[]const u8 = null,
    LDFLAGS: ?[]const u8 = null,
    LDLIBS: ?[]const u8 = null,
    LIBS: ?[]const u8 = null,
    INCLUDES: ?[]const u8 = null,
    SRCS: ?[]const u8 = null,
    SOURCES: ?[]const u8 = null,
    OBJS: ?[]const u8 = null,
    OBJECTS: ?[]const u8 = null,
    TARGET: ?[]const u8 = null,
    NAME: ?[]const u8 = null,
    PROGRAM: ?[]const u8 = null,
    LIB: ?[]const u8 = null,
    LIBRARY: ?[]const u8 = null,
    PREFIX: ?[]const u8 = null,
    DESTDIR: ?[]const u8 = null,
};

/// Detected Makefile target
const MakeTarget = struct {
    name: []const u8,
    prerequisites: std.ArrayList([]const u8),
    recipe_lines: std.ArrayList([]const u8),
    is_phony: bool = false,

    fn init(allocator: Allocator, name: []const u8) MakeTarget {
        return .{
            .name = name,
            .prerequisites = std.ArrayList([]const u8).init(allocator),
            .recipe_lines = std.ArrayList([]const u8).init(allocator),
        };
    }

    fn deinit(self: *MakeTarget) void {
        self.prerequisites.deinit();
        self.recipe_lines.deinit();
    }
};

/// Parser state
const ParserState = struct {
    allocator: Allocator,
    content: []const u8,
    pos: usize = 0,
    line_num: usize = 1,
    variables: std.StringHashMap([]const u8),
    tracked: TrackedVariables = .{},
    make_targets: std.ArrayList(MakeTarget),
    phony_targets: std.StringHashMap(void),
    project: *Project,
    project_dir: []const u8,
    options: TranslationOptions,

    fn init(allocator: Allocator, content: []const u8, project: *Project, dir: []const u8, options: TranslationOptions) ParserState {
        return .{
            .allocator = allocator,
            .content = content,
            .variables = std.StringHashMap([]const u8).init(allocator),
            .make_targets = std.ArrayList(MakeTarget).init(allocator),
            .phony_targets = std.StringHashMap(void).init(allocator),
            .project = project,
            .project_dir = dir,
            .options = options,
        };
    }

    fn deinit(self: *ParserState) void {
        self.variables.deinit();
        for (self.make_targets.items) |*t| {
            t.deinit();
        }
        self.make_targets.deinit();
        self.phony_targets.deinit();
    }

    fn readLine(self: *ParserState) ?[]const u8 {
        if (self.pos >= self.content.len) return null;

        const start = self.pos;
        var end = start;

        // Handle line continuations with backslash
        while (self.pos < self.content.len) {
            if (self.content[self.pos] == '\n') {
                // Check for line continuation
                if (self.pos > 0 and self.content[self.pos - 1] == '\\') {
                    end = self.pos - 1;
                    self.pos += 1;
                    self.line_num += 1;
                    continue;
                }
                end = self.pos;
                self.pos += 1;
                self.line_num += 1;
                break;
            }
            self.pos += 1;
            end = self.pos;
        }

        return self.content[start..end];
    }

    fn expandVariable(self: *ParserState, name: []const u8) []const u8 {
        return self.variables.get(name) orelse "";
    }

    fn expandVariables(self: *ParserState, text: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var i: usize = 0;
        while (i < text.len) {
            if (i + 1 < text.len and text[i] == '$') {
                if (text[i + 1] == '(') {
                    // $(VAR) form
                    const start = i + 2;
                    var depth: usize = 1;
                    var end = start;
                    while (end < text.len and depth > 0) {
                        if (text[end] == '(') depth += 1;
                        if (text[end] == ')') depth -= 1;
                        if (depth > 0) end += 1;
                    }
                    const var_name = text[start..end];
                    const value = self.expandVariable(var_name);
                    try result.appendSlice(value);
                    i = end + 1;
                    continue;
                } else if (text[i + 1] == '{') {
                    // ${VAR} form
                    const start = i + 2;
                    var end = start;
                    while (end < text.len and text[end] != '}') {
                        end += 1;
                    }
                    const var_name = text[start..end];
                    const value = self.expandVariable(var_name);
                    try result.appendSlice(value);
                    i = if (end < text.len) end + 1 else end;
                    continue;
                } else if (std.ascii.isAlphanumeric(text[i + 1]) or text[i + 1] == '_') {
                    // $X single char variable
                    const var_name = text[i + 1 .. i + 2];
                    const value = self.expandVariable(var_name);
                    try result.appendSlice(value);
                    i += 2;
                    continue;
                }
            }
            try result.append(text[i]);
            i += 1;
        }

        return result.toOwnedSlice();
    }
};

/// Parse Makefile and return Project
pub fn parse(allocator: Allocator, path: []const u8, options: TranslationOptions) !Project {
    const dir = std.fs.path.dirname(path) orelse ".";

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    var project = Project.init(allocator, "makefile_project", dir);
    errdefer project.deinit();

    var state = ParserState.init(allocator, content, &project, dir, options);
    defer state.deinit();

    try project.addWarning(.{
        .severity = .info,
        .message = "Makefile parsing uses heuristics and may not capture all build details",
        .suggestion = "Review generated build.zon and adjust as needed",
    });

    // First pass: collect variables and targets
    try parseFirstPass(&state);

    // Second pass: analyze and create project structure
    try analyzeAndCreateTargets(&state);

    return project;
}

fn parseFirstPass(state: *ParserState) !void {
    while (state.readLine()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");

        // Skip empty lines and comments
        if (line.len == 0 or line[0] == '#') continue;

        // Check for variable assignment
        if (try parseVariableAssignment(state, line)) continue;

        // Check for target definition
        if (try parseTargetDefinition(state, line)) continue;

        // Check for include directive
        if (std.mem.startsWith(u8, line, "include ") or std.mem.startsWith(u8, line, "-include ")) {
            // Note: we don't recursively parse includes for simplicity
            continue;
        }

        // Check for recipe line (starts with tab)
        if (raw_line.len > 0 and raw_line[0] == '\t') {
            // Add to most recent target
            if (state.make_targets.items.len > 0) {
                try state.make_targets.items[state.make_targets.items.len - 1].recipe_lines.append(line);
            }
        }
    }
}

fn parseVariableAssignment(state: *ParserState, line: []const u8) !bool {
    // Look for = := ?= +=
    var eq_pos: ?usize = null;
    var op_len: usize = 1;

    for (line, 0..) |c, i| {
        if (c == '=' and i > 0) {
            eq_pos = i;
            // Check for := ?= +=
            if (line[i - 1] == ':' or line[i - 1] == '?' or line[i - 1] == '+') {
                eq_pos = i - 1;
                op_len = 2;
            }
            break;
        }
        // Stop if we hit a colon (target definition)
        if (c == ':' and i + 1 < line.len and line[i + 1] != '=') {
            return false;
        }
    }

    if (eq_pos) |pos| {
        const var_name = std.mem.trim(u8, line[0..pos], " \t");
        const value = std.mem.trim(u8, line[pos + op_len ..], " \t");

        // Store in variables map
        try state.variables.put(var_name, value);

        // Update tracked variables
        inline for (std.meta.fields(TrackedVariables)) |field| {
            if (std.mem.eql(u8, var_name, field.name)) {
                @field(state.tracked, field.name) = value;
                break;
            }
        }

        return true;
    }

    return false;
}

fn parseTargetDefinition(state: *ParserState, line: []const u8) !bool {
    // Look for target: prerequisites
    const colon_pos = std.mem.indexOf(u8, line, ":") orelse return false;

    // Make sure it's not a variable assignment
    if (colon_pos + 1 < line.len and line[colon_pos + 1] == '=') {
        return false;
    }

    const target_part = std.mem.trim(u8, line[0..colon_pos], " \t");
    const prereq_part = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");

    // Handle multiple targets
    var target_iter = std.mem.tokenizeAny(u8, target_part, " \t");
    while (target_iter.next()) |target_name| {
        // Check for .PHONY
        if (std.mem.eql(u8, target_name, ".PHONY")) {
            var prereq_iter = std.mem.tokenizeAny(u8, prereq_part, " \t");
            while (prereq_iter.next()) |phony| {
                try state.phony_targets.put(phony, {});
            }
            return true;
        }

        var make_target = MakeTarget.init(state.allocator, target_name);
        errdefer make_target.deinit();

        // Parse prerequisites
        var prereq_iter = std.mem.tokenizeAny(u8, prereq_part, " \t");
        while (prereq_iter.next()) |prereq| {
            try make_target.prerequisites.append(prereq);
        }

        make_target.is_phony = state.phony_targets.contains(target_name);
        try state.make_targets.append(make_target);
    }

    return true;
}

fn analyzeAndCreateTargets(state: *ParserState) !void {
    // Determine project name from TARGET, NAME, PROGRAM, or first non-phony target
    var project_name: ?[]const u8 = null;

    if (state.tracked.TARGET) |t| project_name = t;
    if (project_name == null and state.tracked.NAME != null) project_name = state.tracked.NAME;
    if (project_name == null and state.tracked.PROGRAM != null) project_name = state.tracked.PROGRAM;

    // Find first non-phony, non-pattern target
    if (project_name == null) {
        for (state.make_targets.items) |mt| {
            if (!mt.is_phony and
                std.mem.indexOf(u8, mt.name, "%") == null and
                !std.mem.eql(u8, mt.name, "all") and
                !std.mem.eql(u8, mt.name, "clean") and
                !std.mem.eql(u8, mt.name, "install"))
            {
                project_name = mt.name;
                break;
            }
        }
    }

    if (project_name) |name| {
        state.project.name = name;
    }

    // Collect source files from SRCS/SOURCES or by analyzing targets
    var sources = std.ArrayList([]const u8).init(state.allocator);
    defer sources.deinit();

    if (state.tracked.SRCS orelse state.tracked.SOURCES) |src_var| {
        const expanded = try state.expandVariables(src_var);
        var iter = std.mem.tokenizeAny(u8, expanded, " \t");
        while (iter.next()) |src| {
            if (isSourceFile(src)) {
                const path = try std.fs.path.join(state.allocator, &.{ state.project_dir, src });
                try sources.append(path);
            }
        }
    }

    // If no SRCS, look at target prerequisites for .c/.cpp files
    if (sources.items.len == 0) {
        for (state.make_targets.items) |mt| {
            for (mt.prerequisites.items) |prereq| {
                if (isSourceFile(prereq)) {
                    const path = try std.fs.path.join(state.allocator, &.{ state.project_dir, prereq });
                    try sources.append(path);
                } else if (isObjectFile(prereq)) {
                    // Try to find corresponding source
                    const base = std.fs.path.stem(prereq);
                    for ([_][]const u8{ ".c", ".cpp", ".cc", ".cxx" }) |ext| {
                        const src_name = try std.fmt.allocPrint(state.allocator, "{s}{s}", .{ base, ext });
                        defer state.allocator.free(src_name);

                        const path = try std.fs.path.join(state.allocator, &.{ state.project_dir, src_name });
                        if (std.fs.cwd().access(path, .{})) {
                            try sources.append(path);
                            break;
                        } else |_| {}
                    }
                }
            }
        }
    }

    // Determine target kind
    var kind: TargetKind = .executable;
    if (state.tracked.LIB != null or state.tracked.LIBRARY != null) {
        // Check if shared or static
        if (state.tracked.LDFLAGS) |flags| {
            if (std.mem.indexOf(u8, flags, "-shared") != null) {
                kind = .shared_library;
            } else {
                kind = .static_library;
            }
        } else {
            kind = .static_library;
        }
    }

    // Analyze recipe lines for more hints
    for (state.make_targets.items) |mt| {
        for (mt.recipe_lines.items) |recipe| {
            if (std.mem.indexOf(u8, recipe, "ar ") != null or std.mem.indexOf(u8, recipe, "$(AR)") != null) {
                kind = .static_library;
            }
            if (std.mem.indexOf(u8, recipe, "-shared") != null) {
                kind = .shared_library;
            }
        }
    }

    // Create target
    var target = Target.init(state.allocator, state.project.name, kind);
    errdefer target.deinit();

    // Add sources
    for (sources.items) |src| {
        try target.sources.append(src);
    }

    // Parse CFLAGS/CXXFLAGS for defines and includes
    const flag_vars = [_]?[]const u8{
        state.tracked.CFLAGS,
        state.tracked.CXXFLAGS,
        state.tracked.CPPFLAGS,
    };

    for (flag_vars) |maybe_flags| {
        if (maybe_flags) |flags| {
            var iter = std.mem.tokenizeAny(u8, flags, " \t");
            while (iter.next()) |flag| {
                if (std.mem.startsWith(u8, flag, "-D")) {
                    try target.flags.defines.append(flag[2..]);
                } else if (std.mem.startsWith(u8, flag, "-I")) {
                    const inc = if (flag.len > 2) flag[2..] else iter.next() orelse continue;
                    const path = try std.fs.path.join(state.allocator, &.{ state.project_dir, inc });
                    try target.flags.include_paths.append(path);
                } else if (!std.mem.startsWith(u8, flag, "-O") and
                    !std.mem.startsWith(u8, flag, "-g") and
                    !std.mem.startsWith(u8, flag, "-W"))
                {
                    try target.flags.compile_flags.append(flag);
                }
            }
        }
    }

    // Parse LDFLAGS/LDLIBS for libraries
    const link_vars = [_]?[]const u8{
        state.tracked.LDFLAGS,
        state.tracked.LDLIBS,
        state.tracked.LIBS,
    };

    for (link_vars) |maybe_flags| {
        if (maybe_flags) |flags| {
            var iter = std.mem.tokenizeAny(u8, flags, " \t");
            while (iter.next()) |flag| {
                if (std.mem.startsWith(u8, flag, "-l")) {
                    try target.flags.link_libraries.append(flag[2..]);
                } else if (std.mem.startsWith(u8, flag, "-L")) {
                    // Library path
                    try target.flags.link_flags.append(flag);
                } else if (std.mem.startsWith(u8, flag, "-framework")) {
                    if (iter.next()) |fw| {
                        try target.flags.frameworks.append(fw);
                    }
                }
            }
        }
    }

    try state.project.addTarget(target);
}

fn isSourceFile(name: []const u8) bool {
    const extensions = [_][]const u8{ ".c", ".cpp", ".cc", ".cxx", ".c++", ".C", ".m", ".mm" };
    for (extensions) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

fn isObjectFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".o") or std.mem.endsWith(u8, name, ".obj");
}

// Tests
test "parseVariableAssignment" {
    const allocator = std.testing.allocator;
    var project = Project.init(allocator, "test", ".");
    defer project.deinit();

    var state = ParserState.init(allocator, "", &project, ".", .{});
    defer state.deinit();

    try std.testing.expect(try parseVariableAssignment(&state, "CC = gcc"));
    try std.testing.expectEqualStrings("gcc", state.variables.get("CC").?);

    try std.testing.expect(try parseVariableAssignment(&state, "CFLAGS := -Wall -O2"));
    try std.testing.expectEqualStrings("-Wall -O2", state.variables.get("CFLAGS").?);

    // Not a variable assignment
    try std.testing.expect(!try parseVariableAssignment(&state, "target: prereq"));
}

test "isSourceFile" {
    try std.testing.expect(isSourceFile("main.c"));
    try std.testing.expect(isSourceFile("utils.cpp"));
    try std.testing.expect(isSourceFile("app.mm"));
    try std.testing.expect(!isSourceFile("header.h"));
    try std.testing.expect(!isSourceFile("main.o"));
}
