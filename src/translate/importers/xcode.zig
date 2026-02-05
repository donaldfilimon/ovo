//! Xcode Project Importer - .xcodeproj -> build.zon
//!
//! Parses Xcode project files (project.pbxproj) and extracts:
//! - Native targets (executables, libraries, frameworks)
//! - Source files and resources
//! - Build settings and configurations
//! - Dependencies and linked frameworks

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

/// Xcode object types
const ObjectType = enum {
    PBXProject,
    PBXNativeTarget,
    PBXAggregateTarget,
    PBXLegacyTarget,
    PBXGroup,
    PBXFileReference,
    PBXBuildFile,
    PBXSourcesBuildPhase,
    PBXHeadersBuildPhase,
    PBXFrameworksBuildPhase,
    PBXResourcesBuildPhase,
    PBXCopyFilesBuildPhase,
    PBXShellScriptBuildPhase,
    XCBuildConfiguration,
    XCConfigurationList,
    PBXTargetDependency,
    PBXContainerItemProxy,
    PBXVariantGroup,
    unknown,

    pub fn fromString(s: []const u8) ObjectType {
        const map = std.StaticStringMap(ObjectType).initComptime(.{
            .{ "PBXProject", .PBXProject },
            .{ "PBXNativeTarget", .PBXNativeTarget },
            .{ "PBXAggregateTarget", .PBXAggregateTarget },
            .{ "PBXLegacyTarget", .PBXLegacyTarget },
            .{ "PBXGroup", .PBXGroup },
            .{ "PBXFileReference", .PBXFileReference },
            .{ "PBXBuildFile", .PBXBuildFile },
            .{ "PBXSourcesBuildPhase", .PBXSourcesBuildPhase },
            .{ "PBXHeadersBuildPhase", .PBXHeadersBuildPhase },
            .{ "PBXFrameworksBuildPhase", .PBXFrameworksBuildPhase },
            .{ "PBXResourcesBuildPhase", .PBXResourcesBuildPhase },
            .{ "PBXCopyFilesBuildPhase", .PBXCopyFilesBuildPhase },
            .{ "PBXShellScriptBuildPhase", .PBXShellScriptBuildPhase },
            .{ "XCBuildConfiguration", .XCBuildConfiguration },
            .{ "XCConfigurationList", .XCConfigurationList },
            .{ "PBXTargetDependency", .PBXTargetDependency },
            .{ "PBXContainerItemProxy", .PBXContainerItemProxy },
            .{ "PBXVariantGroup", .PBXVariantGroup },
        });
        return map.get(s) orelse .unknown;
    }
};

/// Xcode product type to target kind mapping
fn productTypeToTargetKind(product_type: []const u8) TargetKind {
    if (std.mem.indexOf(u8, product_type, "application")) |_| return .executable;
    if (std.mem.indexOf(u8, product_type, "tool")) |_| return .executable;
    if (std.mem.indexOf(u8, product_type, "library.static")) |_| return .static_library;
    if (std.mem.indexOf(u8, product_type, "library.dynamic")) |_| return .shared_library;
    if (std.mem.indexOf(u8, product_type, "framework")) |_| return .shared_library;
    if (std.mem.indexOf(u8, product_type, "bundle")) |_| return .shared_library;
    return .executable;
}

/// Parsed pbxproj object
const PbxObject = struct {
    isa: ObjectType,
    properties: std.StringHashMap(PbxValue),

    fn init(allocator: Allocator) PbxObject {
        return .{
            .isa = .unknown,
            .properties = std.StringHashMap(PbxValue).init(allocator),
        };
    }

    fn deinit(self: *PbxObject) void {
        self.properties.deinit();
    }

    fn get(self: *const PbxObject, key: []const u8) ?PbxValue {
        return self.properties.get(key);
    }

    fn getString(self: *const PbxObject, key: []const u8) ?[]const u8 {
        if (self.properties.get(key)) |val| {
            return switch (val) {
                .string => |s| s,
                else => null,
            };
        }
        return null;
    }

    fn getArray(self: *const PbxObject, key: []const u8) ?[]const PbxValue {
        if (self.properties.get(key)) |val| {
            return switch (val) {
                .array => |arr| arr,
                else => null,
            };
        }
        return null;
    }
};

/// pbxproj value types
const PbxValue = union(enum) {
    string: []const u8,
    array: []const PbxValue,
    dict: std.StringHashMap(PbxValue),
};

/// Parser state
const ParserState = struct {
    allocator: Allocator,
    content: []const u8,
    pos: usize = 0,
    objects: std.StringHashMap(PbxObject),
    project_dir: []const u8,

    fn init(allocator: Allocator, content: []const u8, project_dir: []const u8) ParserState {
        return .{
            .allocator = allocator,
            .content = content,
            .objects = std.StringHashMap(PbxObject).init(allocator),
            .project_dir = project_dir,
        };
    }

    fn deinit(self: *ParserState) void {
        var iter = self.objects.valueIterator();
        while (iter.next()) |obj| {
            obj.deinit();
        }
        self.objects.deinit();
    }

    fn peek(self: *ParserState) ?u8 {
        if (self.pos >= self.content.len) return null;
        return self.content[self.pos];
    }

    fn advance(self: *ParserState) ?u8 {
        if (self.pos >= self.content.len) return null;
        const c = self.content[self.pos];
        self.pos += 1;
        return c;
    }

    fn skipWhitespaceAndComments(self: *ParserState) void {
        while (self.pos < self.content.len) {
            const c = self.content[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else if (self.pos + 1 < self.content.len and c == '/' and self.content[self.pos + 1] == '*') {
                // Block comment
                self.pos += 2;
                while (self.pos + 1 < self.content.len) {
                    if (self.content[self.pos] == '*' and self.content[self.pos + 1] == '/') {
                        self.pos += 2;
                        break;
                    }
                    self.pos += 1;
                }
            } else if (self.pos + 1 < self.content.len and c == '/' and self.content[self.pos + 1] == '/') {
                // Line comment
                while (self.pos < self.content.len and self.content[self.pos] != '\n') {
                    self.pos += 1;
                }
            } else {
                break;
            }
        }
    }

    fn readString(self: *ParserState) !?[]const u8 {
        self.skipWhitespaceAndComments();
        if (self.peek() == null) return null;

        if (self.peek() == '"') {
            // Quoted string
            _ = self.advance();
            const start = self.pos;
            while (self.peek()) |c| {
                if (c == '"') {
                    const result = self.content[start..self.pos];
                    _ = self.advance();
                    return result;
                }
                if (c == '\\' and self.pos + 1 < self.content.len) {
                    _ = self.advance();
                }
                _ = self.advance();
            }
            return error.UnterminatedString;
        }

        // Unquoted string (identifier or UUID)
        const start = self.pos;
        while (self.peek()) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-' or c == '/') {
                _ = self.advance();
            } else {
                break;
            }
        }

        if (self.pos == start) return null;
        return self.content[start..self.pos];
    }

    fn expect(self: *ParserState, expected: u8) !void {
        self.skipWhitespaceAndComments();
        if (self.peek() != expected) {
            return error.UnexpectedToken;
        }
        _ = self.advance();
    }
};

/// Parse Xcode project and return Project
pub fn parse(allocator: Allocator, path: []const u8, options: TranslationOptions) !Project {
    _ = options;

    // Path should be .xcodeproj directory
    const pbxproj_path = try std.fs.path.join(allocator, &.{ path, "project.pbxproj" });
    defer allocator.free(pbxproj_path);

    const project_dir = std.fs.path.dirname(path) orelse ".";

    const file = try std.fs.cwd().openFile(pbxproj_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 50 * 1024 * 1024);
    defer allocator.free(content);

    var project = Project.init(allocator, "xcode_project", project_dir);
    errdefer project.deinit();

    var state = ParserState.init(allocator, content, project_dir);
    defer state.deinit();

    // Parse the pbxproj file
    try parsePbxproj(&state);

    // Extract project information
    try extractProject(&state, &project);

    return project;
}

fn parsePbxproj(state: *ParserState) !void {
    // Skip to objects section
    // Format: // !$*UTF8*$! { archiveVersion = ...; objects = { ... }; ... }

    while (state.pos < state.content.len) {
        if (std.mem.indexOf(u8, state.content[state.pos..], "objects = {")) |idx| {
            state.pos += idx + "objects = {".len;
            break;
        }
        state.pos += 1;
    }

    // Parse objects
    try parseObjects(state);
}

fn parseObjects(state: *ParserState) !void {
    state.skipWhitespaceAndComments();

    while (state.peek()) |c| {
        if (c == '}') {
            _ = state.advance();
            return;
        }

        // Read object ID
        const obj_id = try state.readString() orelse break;

        state.skipWhitespaceAndComments();
        try state.expect('=');
        state.skipWhitespaceAndComments();
        try state.expect('{');

        // Parse object properties
        var obj = PbxObject.init(state.allocator);
        errdefer obj.deinit();

        try parseObjectProperties(state, &obj);

        try state.objects.put(obj_id, obj);

        state.skipWhitespaceAndComments();
        if (state.peek() == ';') {
            _ = state.advance();
        }
    }
}

fn parseObjectProperties(state: *ParserState, obj: *PbxObject) !void {
    while (true) {
        state.skipWhitespaceAndComments();

        if (state.peek() == '}') {
            _ = state.advance();
            return;
        }

        const key = try state.readString() orelse return;

        state.skipWhitespaceAndComments();
        try state.expect('=');

        const value = try parseValue(state);

        if (std.mem.eql(u8, key, "isa")) {
            if (value == .string) {
                obj.isa = ObjectType.fromString(value.string);
            }
        }

        try obj.properties.put(key, value);

        state.skipWhitespaceAndComments();
        if (state.peek() == ';') {
            _ = state.advance();
        }
    }
}

fn parseValue(state: *ParserState) !PbxValue {
    state.skipWhitespaceAndComments();

    if (state.peek() == '(') {
        // Array
        _ = state.advance();
        var items = std.ArrayList(PbxValue).init(state.allocator);
        errdefer items.deinit();

        while (true) {
            state.skipWhitespaceAndComments();
            if (state.peek() == ')') {
                _ = state.advance();
                break;
            }

            const item = try parseValue(state);
            try items.append(item);

            state.skipWhitespaceAndComments();
            if (state.peek() == ',') {
                _ = state.advance();
            }
        }

        return .{ .array = try items.toOwnedSlice() };
    }

    if (state.peek() == '{') {
        // Dictionary
        _ = state.advance();
        var dict = std.StringHashMap(PbxValue).init(state.allocator);
        errdefer dict.deinit();

        while (true) {
            state.skipWhitespaceAndComments();
            if (state.peek() == '}') {
                _ = state.advance();
                break;
            }

            const key = try state.readString() orelse break;
            state.skipWhitespaceAndComments();
            try state.expect('=');
            const val = try parseValue(state);
            try dict.put(key, val);

            state.skipWhitespaceAndComments();
            if (state.peek() == ';') {
                _ = state.advance();
            }
        }

        return .{ .dict = dict };
    }

    // String
    const str = try state.readString() orelse return .{ .string = "" };
    return .{ .string = str };
}

fn extractProject(state: *ParserState, project: *Project) !void {
    // Find PBXProject object
    var iter = state.objects.iterator();
    while (iter.next()) |entry| {
        const obj = entry.value_ptr;

        if (obj.isa == .PBXProject) {
            // Get project name from build settings or use default
            if (obj.getString("projectDirPath")) |dir| {
                if (dir.len > 0) {
                    project.name = std.fs.path.basename(dir);
                }
            }
        }

        if (obj.isa == .PBXNativeTarget) {
            try extractTarget(state, obj, project);
        }
    }
}

fn extractTarget(state: *ParserState, obj: *const PbxObject, project: *Project) !void {
    const name = obj.getString("name") orelse return;

    // Determine target kind from product type
    var kind: TargetKind = .executable;
    if (obj.getString("productType")) |product_type| {
        kind = productTypeToTargetKind(product_type);
    }

    var target = Target.init(state.allocator, name, kind);
    errdefer target.deinit();

    // Extract build phases
    if (obj.getArray("buildPhases")) |phases| {
        for (phases) |phase_ref| {
            if (phase_ref == .string) {
                if (state.objects.get(phase_ref.string)) |phase_obj| {
                    try extractBuildPhase(state, &phase_obj, &target);
                }
            }
        }
    }

    // Extract dependencies
    if (obj.getArray("dependencies")) |deps| {
        for (deps) |dep_ref| {
            if (dep_ref == .string) {
                if (state.objects.get(dep_ref.string)) |dep_obj| {
                    if (dep_obj.getString("name")) |dep_name| {
                        try target.dependencies.append(dep_name);
                    }
                }
            }
        }
    }

    // Extract linked frameworks
    if (obj.getArray("buildPhases")) |phases| {
        for (phases) |phase_ref| {
            if (phase_ref == .string) {
                if (state.objects.get(phase_ref.string)) |phase_obj| {
                    if (phase_obj.isa == .PBXFrameworksBuildPhase) {
                        try extractFrameworks(state, &phase_obj, &target);
                    }
                }
            }
        }
    }

    try project.addTarget(target);
}

fn extractBuildPhase(state: *ParserState, phase_obj: *const PbxObject, target: *Target) !void {
    if (phase_obj.isa != .PBXSourcesBuildPhase and phase_obj.isa != .PBXHeadersBuildPhase) {
        return;
    }

    if (phase_obj.getArray("files")) |files| {
        for (files) |file_ref| {
            if (file_ref == .string) {
                if (state.objects.get(file_ref.string)) |build_file| {
                    if (build_file.getString("fileRef")) |ref| {
                        if (state.objects.get(ref)) |file_obj| {
                            if (file_obj.getString("path")) |path| {
                                const full_path = try std.fs.path.join(state.allocator, &.{ state.project_dir, path });

                                if (phase_obj.isa == .PBXSourcesBuildPhase) {
                                    try target.sources.append(full_path);
                                } else {
                                    try target.headers.append(full_path);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

fn extractFrameworks(state: *ParserState, phase_obj: *const PbxObject, target: *Target) !void {
    if (phase_obj.getArray("files")) |files| {
        for (files) |file_ref| {
            if (file_ref == .string) {
                if (state.objects.get(file_ref.string)) |build_file| {
                    if (build_file.getString("fileRef")) |ref| {
                        if (state.objects.get(ref)) |file_obj| {
                            if (file_obj.getString("name") orelse file_obj.getString("path")) |name| {
                                // Extract framework name
                                if (std.mem.endsWith(u8, name, ".framework")) {
                                    const fw_name = name[0 .. name.len - ".framework".len];
                                    try target.flags.frameworks.append(fw_name);
                                } else if (std.mem.endsWith(u8, name, ".dylib") or std.mem.endsWith(u8, name, ".a")) {
                                    try target.flags.link_libraries.append(name);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// Tests
test "ObjectType.fromString" {
    try std.testing.expectEqual(ObjectType.PBXProject, ObjectType.fromString("PBXProject"));
    try std.testing.expectEqual(ObjectType.PBXNativeTarget, ObjectType.fromString("PBXNativeTarget"));
    try std.testing.expectEqual(ObjectType.unknown, ObjectType.fromString("InvalidType"));
}

test "productTypeToTargetKind" {
    try std.testing.expectEqual(TargetKind.executable, productTypeToTargetKind("com.apple.product-type.application"));
    try std.testing.expectEqual(TargetKind.executable, productTypeToTargetKind("com.apple.product-type.tool"));
    try std.testing.expectEqual(TargetKind.static_library, productTypeToTargetKind("com.apple.product-type.library.static"));
    try std.testing.expectEqual(TargetKind.shared_library, productTypeToTargetKind("com.apple.product-type.framework"));
}
