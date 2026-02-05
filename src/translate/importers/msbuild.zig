//! MSBuild Importer - .vcxproj/.sln -> build.zon
//!
//! Parses Visual Studio project files and extracts:
//! - Project configurations (Debug/Release, Win32/x64)
//! - Source files and headers
//! - Preprocessor definitions
//! - Include directories
//! - Library dependencies

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../engine.zig");
const Project = engine.Project;
const Target = engine.Target;
const TargetKind = engine.TargetKind;
const Dependency = engine.Dependency;
const BuildConfig = engine.BuildConfig;
const TranslationWarning = engine.TranslationWarning;
const WarningSeverity = engine.WarningSeverity;
const TranslationOptions = engine.TranslationOptions;

/// MSBuild configuration type to TargetKind mapping
fn configTypeToTargetKind(config_type: []const u8) TargetKind {
    if (std.mem.eql(u8, config_type, "Application")) return .executable;
    if (std.mem.eql(u8, config_type, "StaticLibrary")) return .static_library;
    if (std.mem.eql(u8, config_type, "DynamicLibrary")) return .shared_library;
    return .executable;
}

/// XML element representation
const XmlElement = struct {
    name: []const u8,
    attributes: std.StringHashMap([]const u8),
    children: std.ArrayList(XmlNode),
    text: ?[]const u8 = null,

    fn init(allocator: Allocator, name: []const u8) XmlElement {
        return .{
            .name = name,
            .attributes = std.StringHashMap([]const u8).init(allocator),
            .children = std.ArrayList(XmlNode).init(allocator),
        };
    }

    fn deinit(self: *XmlElement, allocator: Allocator) void {
        self.attributes.deinit();
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit();
    }

    fn getAttribute(self: *const XmlElement, name: []const u8) ?[]const u8 {
        return self.attributes.get(name);
    }

    fn findChild(self: *const XmlElement, name: []const u8) ?*const XmlElement {
        for (self.children.items) |*child| {
            if (child.* == .element) {
                if (std.mem.eql(u8, child.element.name, name)) {
                    return &child.element;
                }
            }
        }
        return null;
    }

    fn findChildren(self: *const XmlElement, allocator: Allocator, name: []const u8) !std.ArrayList(*const XmlElement) {
        var result = std.ArrayList(*const XmlElement).init(allocator);
        for (self.children.items) |*child| {
            if (child.* == .element) {
                if (std.mem.eql(u8, child.element.name, name)) {
                    try result.append(&child.element);
                }
            }
        }
        return result;
    }
};

const XmlNode = union(enum) {
    element: XmlElement,
    text: []const u8,

    fn deinit(self: *XmlNode, allocator: Allocator) void {
        switch (self.*) {
            .element => |*e| e.deinit(allocator),
            .text => {},
        }
    }
};

/// Simple XML parser state
const XmlParser = struct {
    allocator: Allocator,
    content: []const u8,
    pos: usize = 0,

    fn init(allocator: Allocator, content: []const u8) XmlParser {
        return .{
            .allocator = allocator,
            .content = content,
        };
    }

    fn peek(self: *XmlParser) ?u8 {
        if (self.pos >= self.content.len) return null;
        return self.content[self.pos];
    }

    fn advance(self: *XmlParser) ?u8 {
        if (self.pos >= self.content.len) return null;
        const c = self.content[self.pos];
        self.pos += 1;
        return c;
    }

    fn skipWhitespace(self: *XmlParser) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                _ = self.advance();
            } else {
                break;
            }
        }
    }

    fn readUntil(self: *XmlParser, delimiter: u8) []const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (c == delimiter) break;
            _ = self.advance();
        }
        return self.content[start..self.pos];
    }

    fn readName(self: *XmlParser) []const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == ':' or c == '.') {
                _ = self.advance();
            } else {
                break;
            }
        }
        return self.content[start..self.pos];
    }

    fn parseDocument(self: *XmlParser) !?XmlElement {
        // Skip XML declaration and comments
        while (self.pos < self.content.len) {
            self.skipWhitespace();
            if (self.peek() != '<') break;

            if (self.pos + 1 < self.content.len) {
                if (self.content[self.pos + 1] == '?') {
                    // XML declaration
                    while (self.peek()) |c| {
                        if (c == '>') {
                            _ = self.advance();
                            break;
                        }
                        _ = self.advance();
                    }
                    continue;
                }
                if (self.content[self.pos + 1] == '!') {
                    // Comment or DOCTYPE
                    while (self.peek()) |c| {
                        if (c == '>') {
                            _ = self.advance();
                            break;
                        }
                        _ = self.advance();
                    }
                    continue;
                }
            }

            return try self.parseElement();
        }
        return null;
    }

    fn parseElement(self: *XmlParser) !XmlElement {
        self.skipWhitespace();

        if (self.peek() != '<') return error.ExpectedOpenBracket;
        _ = self.advance();

        const name = self.readName();
        var element = XmlElement.init(self.allocator, name);
        errdefer element.deinit(self.allocator);

        // Parse attributes
        while (true) {
            self.skipWhitespace();
            const c = self.peek() orelse break;

            if (c == '/' and self.pos + 1 < self.content.len and self.content[self.pos + 1] == '>') {
                // Self-closing tag
                self.pos += 2;
                return element;
            }
            if (c == '>') {
                _ = self.advance();
                break;
            }

            // Parse attribute
            const attr_name = self.readName();
            if (attr_name.len == 0) {
                _ = self.advance();
                continue;
            }

            self.skipWhitespace();
            if (self.peek() == '=') {
                _ = self.advance();
                self.skipWhitespace();
                if (self.peek() == '"' or self.peek() == '\'') {
                    const quote = self.advance().?;
                    const value = self.readUntil(quote);
                    _ = self.advance();
                    try element.attributes.put(attr_name, value);
                }
            }
        }

        // Parse children
        while (true) {
            self.skipWhitespace();
            if (self.peek() == null) break;

            if (self.peek() == '<') {
                if (self.pos + 1 < self.content.len and self.content[self.pos + 1] == '/') {
                    // Closing tag
                    while (self.peek()) |c| {
                        if (c == '>') {
                            _ = self.advance();
                            break;
                        }
                        _ = self.advance();
                    }
                    break;
                }

                if (self.pos + 3 < self.content.len and
                    self.content[self.pos + 1] == '!' and
                    self.content[self.pos + 2] == '-' and
                    self.content[self.pos + 3] == '-')
                {
                    // Comment
                    while (self.pos + 2 < self.content.len) {
                        if (self.content[self.pos] == '-' and
                            self.content[self.pos + 1] == '-' and
                            self.content[self.pos + 2] == '>')
                        {
                            self.pos += 3;
                            break;
                        }
                        _ = self.advance();
                    }
                    continue;
                }

                const child = try self.parseElement();
                try element.children.append(.{ .element = child });
            } else {
                // Text content
                const text_start = self.pos;
                while (self.peek()) |c| {
                    if (c == '<') break;
                    _ = self.advance();
                }
                const text = std.mem.trim(u8, self.content[text_start..self.pos], " \t\n\r");
                if (text.len > 0) {
                    element.text = text;
                }
            }
        }

        return element;
    }
};

/// Parse .vcxproj file and return Project
pub fn parse(allocator: Allocator, path: []const u8, options: TranslationOptions) !Project {
    const dir = std.fs.path.dirname(path) orelse ".";

    // Check if it's a solution file
    if (std.mem.endsWith(u8, path, ".sln")) {
        return parseSolution(allocator, path, dir, options);
    }

    return parseVcxproj(allocator, path, dir, options);
}

fn parseVcxproj(allocator: Allocator, path: []const u8, dir: []const u8, options: TranslationOptions) !Project {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 50 * 1024 * 1024);
    defer allocator.free(content);

    var project = Project.init(allocator, "msbuild_project", dir);
    errdefer project.deinit();

    var parser = XmlParser.init(allocator, content);
    var root = try parser.parseDocument() orelse return error.InvalidXml;
    defer root.deinit(allocator);

    // Extract project name from filename
    const basename = std.fs.path.basename(path);
    if (std.mem.lastIndexOf(u8, basename, ".")) |dot| {
        project.name = basename[0..dot];
    }

    // Parse PropertyGroups for configurations
    var prop_groups = try root.findChildren(allocator, "PropertyGroup");
    defer prop_groups.deinit();

    var target_kind: TargetKind = .executable;

    for (prop_groups.items) |pg| {
        // Check ConfigurationType
        if (pg.findChild("ConfigurationType")) |ct| {
            if (ct.text) |text| {
                target_kind = configTypeToTargetKind(text);
            }
        }

        // Check RootNamespace
        if (pg.findChild("RootNamespace")) |ns| {
            if (ns.text) |text| {
                project.name = text;
            }
        }

        // Check ProjectName
        if (pg.findChild("ProjectName")) |pn| {
            if (pn.text) |text| {
                project.name = text;
            }
        }
    }

    var target = Target.init(allocator, project.name, target_kind);
    errdefer target.deinit();

    // Parse ItemGroups for source files
    var item_groups = try root.findChildren(allocator, "ItemGroup");
    defer item_groups.deinit();

    for (item_groups.items) |ig| {
        // ClCompile items (source files)
        var compiles = try ig.findChildren(allocator, "ClCompile");
        defer compiles.deinit();

        for (compiles.items) |compile| {
            if (compile.getAttribute("Include")) |include| {
                const source_path = try std.fs.path.join(allocator, &.{ dir, normalizePathSeparators(include) });
                try target.sources.append(source_path);
            }
        }

        // ClInclude items (header files)
        var includes = try ig.findChildren(allocator, "ClInclude");
        defer includes.deinit();

        for (includes.items) |include_elem| {
            if (include_elem.getAttribute("Include")) |include| {
                const header_path = try std.fs.path.join(allocator, &.{ dir, normalizePathSeparators(include) });
                try target.headers.append(header_path);
            }
        }

        // ProjectReference items (dependencies)
        var refs = try ig.findChildren(allocator, "ProjectReference");
        defer refs.deinit();

        for (refs.items) |ref| {
            if (ref.getAttribute("Include")) |include| {
                // Extract project name from path
                const ref_basename = std.fs.path.basename(normalizePathSeparators(include));
                if (std.mem.lastIndexOf(u8, ref_basename, ".")) |dot| {
                    try target.dependencies.append(ref_basename[0..dot]);
                }
            }
        }
    }

    // Parse ItemDefinitionGroups for compiler/linker settings
    var def_groups = try root.findChildren(allocator, "ItemDefinitionGroup");
    defer def_groups.deinit();

    for (def_groups.items) |dg| {
        // Get condition for this definition group
        const condition = dg.getAttribute("Condition");

        if (condition) |cond| {
            // Parse condition like "'$(Configuration)|$(Platform)'=='Debug|Win32'"
            if (std.mem.indexOf(u8, cond, "==")) |eq| {
                const right = cond[eq + 2 ..];
                if (std.mem.indexOf(u8, right, "'")) |start| {
                    if (std.mem.indexOf(u8, right[start + 1 ..], "'")) |end| {
                        // Extract configuration name for potential future use
                        _ = right[start + 1 .. start + 1 + end];
                    }
                }
            }
        }

        // ClCompile settings
        if (dg.findChild("ClCompile")) |cl| {
            // Preprocessor definitions
            if (cl.findChild("PreprocessorDefinitions")) |defs| {
                if (defs.text) |text| {
                    var iter = std.mem.splitScalar(u8, text, ';');
                    while (iter.next()) |def| {
                        const trimmed = std.mem.trim(u8, def, " ");
                        if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "%(PreprocessorDefinitions)")) {
                            try target.flags.defines.append(trimmed);
                        }
                    }
                }
            }

            // Additional include directories
            if (cl.findChild("AdditionalIncludeDirectories")) |inc| {
                if (inc.text) |text| {
                    var iter = std.mem.splitScalar(u8, text, ';');
                    while (iter.next()) |inc_dir| {
                        const trimmed = std.mem.trim(u8, inc_dir, " ");
                        if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "%(AdditionalIncludeDirectories)")) {
                            const inc_path = try std.fs.path.join(allocator, &.{ dir, normalizePathSeparators(trimmed) });
                            try target.flags.include_paths.append(inc_path);
                        }
                    }
                }
            }
        }

        // Link settings
        if (dg.findChild("Link")) |link| {
            // Additional dependencies
            if (link.findChild("AdditionalDependencies")) |deps| {
                if (deps.text) |text| {
                    var iter = std.mem.splitScalar(u8, text, ';');
                    while (iter.next()) |dep| {
                        const trimmed = std.mem.trim(u8, dep, " ");
                        if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "%(AdditionalDependencies)")) {
                            try target.flags.link_libraries.append(trimmed);
                        }
                    }
                }
            }
        }
    }

    try project.addTarget(target);

    if (options.verbose) {
        try project.addWarning(.{
            .severity = .info,
            .message = try std.fmt.allocPrint(allocator, "Parsed MSBuild project: {s}", .{project.name}),
        });
    }

    return project;
}

fn parseSolution(allocator: Allocator, path: []const u8, dir: []const u8, options: TranslationOptions) !Project {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    // Extract solution name
    const basename = std.fs.path.basename(path);
    const sln_name = if (std.mem.lastIndexOf(u8, basename, ".")) |dot|
        basename[0..dot]
    else
        basename;

    var project = Project.init(allocator, sln_name, dir);
    errdefer project.deinit();

    // Parse Project entries
    // Format: Project("{GUID}") = "Name", "Path.vcxproj", "{GUID}"
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "Project(")) {
            // Extract project path
            if (std.mem.indexOf(u8, trimmed, ".vcxproj")) |vcxproj_end| {
                // Find start of path (after second quote after =)
                if (std.mem.indexOf(u8, trimmed, "= \"")) |eq_pos| {
                    const after_name = trimmed[eq_pos + 3 ..];
                    if (std.mem.indexOf(u8, after_name, "\", \"")) |comma_pos| {
                        const path_start = eq_pos + 3 + comma_pos + 4;
                        const path_end = vcxproj_end + ".vcxproj".len;
                        if (path_end > path_start) {
                            const proj_path = trimmed[path_start..path_end];
                            const full_path = try std.fs.path.join(allocator, &.{ dir, normalizePathSeparators(proj_path) });
                            defer allocator.free(full_path);

                            // Try to parse the project
                            var sub_project = parseVcxproj(allocator, full_path, dir, options) catch |err| {
                                try project.addWarning(.{
                                    .severity = .warning,
                                    .message = try std.fmt.allocPrint(allocator, "Failed to parse {s}: {}", .{ proj_path, err }),
                                });
                                continue;
                            };

                            // Merge targets
                            for (sub_project.targets.items) |t| {
                                try project.addTarget(t);
                            }
                            sub_project.targets.clearRetainingCapacity();
                            sub_project.deinit();
                        }
                    }
                }
            }
        }
    }

    return project;
}

fn normalizePathSeparators(path: []const u8) []const u8 {
    // This is a view-only operation for comparison
    // Actual path normalization happens during join
    return path;
}

// Tests
test "configTypeToTargetKind" {
    try std.testing.expectEqual(TargetKind.executable, configTypeToTargetKind("Application"));
    try std.testing.expectEqual(TargetKind.static_library, configTypeToTargetKind("StaticLibrary"));
    try std.testing.expectEqual(TargetKind.shared_library, configTypeToTargetKind("DynamicLibrary"));
}

test "XmlParser basic" {
    const allocator = std.testing.allocator;
    const xml = "<root attr=\"value\"><child>text</child></root>";

    var parser = XmlParser.init(allocator, xml);
    var root = try parser.parseDocument() orelse return error.ParseFailed;
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings("root", root.name);
    try std.testing.expectEqualStrings("value", root.getAttribute("attr").?);
}
