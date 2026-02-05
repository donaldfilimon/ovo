//! Conan Manifest Importer - conanfile.txt/conanfile.py -> dependencies
//!
//! Parses Conan package manager manifest files:
//! - conanfile.txt: INI-like format with [requires], [generators], etc.
//! - conanfile.py: Python class-based format (limited support)
//!
//! Extracts:
//! - Required packages with versions
//! - Build requirements
//! - Options and settings

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../engine.zig");
const Project = engine.Project;
const Dependency = engine.Dependency;
const TranslationWarning = engine.TranslationWarning;
const WarningSeverity = engine.WarningSeverity;
const TranslationOptions = engine.TranslationOptions;

/// Conanfile section types
const Section = enum {
    requires,
    tool_requires,
    build_requires,
    generators,
    options,
    imports,
    none,

    pub fn fromString(s: []const u8) Section {
        const map = std.StaticStringMap(Section).initComptime(.{
            .{ "requires", .requires },
            .{ "tool_requires", .tool_requires },
            .{ "build_requires", .build_requires },
            .{ "generators", .generators },
            .{ "options", .options },
            .{ "imports", .imports },
        });
        return map.get(s) orelse .none;
    }
};

/// Parse conanfile and return Project
pub fn parse(allocator: Allocator, path: []const u8, options: TranslationOptions) !Project {
    const dir = std.fs.path.dirname(path) orelse ".";
    const basename = std.fs.path.basename(path);

    var project = Project.init(allocator, "conan_project", dir);
    errdefer project.deinit();

    if (std.mem.eql(u8, basename, "conanfile.txt")) {
        try parseConanfileTxt(allocator, path, &project, options);
    } else if (std.mem.eql(u8, basename, "conanfile.py")) {
        try parseConanfilePy(allocator, path, &project, options);
    } else {
        try project.addWarning(.{
            .severity = .warning,
            .message = "Unknown Conan manifest format",
            .suggestion = "Expected conanfile.txt or conanfile.py",
        });
    }

    return project;
}

fn parseConanfileTxt(allocator: Allocator, path: []const u8, project: *Project, options: TranslationOptions) !void {
    _ = options;

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    var current_section: Section = .none;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");

        // Skip empty lines and comments
        if (line.len == 0 or line[0] == '#') continue;

        // Check for section header
        if (line[0] == '[' and line[line.len - 1] == ']') {
            const section_name = line[1 .. line.len - 1];
            current_section = Section.fromString(section_name);
            continue;
        }

        // Process line based on current section
        switch (current_section) {
            .requires => {
                const dep = try parseRequirement(allocator, line, .build);
                if (dep) |d| {
                    try project.addDependency(d);
                }
            },
            .tool_requires, .build_requires => {
                const dep = try parseRequirement(allocator, line, .dev);
                if (dep) |d| {
                    try project.addDependency(d);
                }
            },
            .options => {
                // Parse options like "pkg:option=value"
                // Store as project metadata
            },
            .generators => {
                // Note which generators are requested
                try project.addWarning(.{
                    .severity = .info,
                    .message = try std.fmt.allocPrint(allocator, "Conan generator requested: {s}", .{line}),
                });
            },
            else => {},
        }
    }
}

fn parseConanfilePy(allocator: Allocator, path: []const u8, project: *Project, options: TranslationOptions) !void {
    _ = options;

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    try project.addWarning(.{
        .severity = .info,
        .message = "conanfile.py parsing uses heuristics - complex recipes may not be fully captured",
    });

    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");

        // Look for class name (ConanFile subclass)
        if (std.mem.indexOf(u8, line, "class ") != null and std.mem.indexOf(u8, line, "ConanFile") != null) {
            // Extract class name as project name
            if (std.mem.indexOf(u8, line, "class ")) |class_pos| {
                const after_class = line[class_pos + 6 ..];
                if (std.mem.indexOf(u8, after_class, "(")) |paren_pos| {
                    const class_name = std.mem.trim(u8, after_class[0..paren_pos], " ");
                    if (class_name.len > 0) {
                        project.name = try allocator.dupe(u8, class_name);
                    }
                }
            }
        }

        // Look for name = "..."
        if (std.mem.indexOf(u8, line, "name")) |_| {
            if (extractPythonStringAssignment(line, "name")) |name| {
                project.name = try allocator.dupe(u8, name);
            }
        }

        // Look for version = "..."
        if (std.mem.indexOf(u8, line, "version")) |_| {
            if (extractPythonStringAssignment(line, "version")) |ver| {
                project.version = try allocator.dupe(u8, ver);
            }
        }

        // Look for description = "..."
        if (std.mem.indexOf(u8, line, "description")) |_| {
            if (extractPythonStringAssignment(line, "description")) |desc| {
                project.description = try allocator.dupe(u8, desc);
            }
        }

        // Look for url = "..."
        if (std.mem.indexOf(u8, line, "url")) |_| {
            if (extractPythonStringAssignment(line, "url")) |url| {
                project.homepage = try allocator.dupe(u8, url);
            }
        }

        // Look for license = "..."
        if (std.mem.indexOf(u8, line, "license")) |_| {
            if (extractPythonStringAssignment(line, "license")) |lic| {
                project.license = try allocator.dupe(u8, lic);
            }
        }

        // Look for requires = (...) or requires = "..."
        if (std.mem.indexOf(u8, line, "requires")) |_| {
            // Simple string requirement
            if (extractPythonStringAssignment(line, "requires")) |req| {
                const dep = try parseRequirement(allocator, req, .build);
                if (dep) |d| {
                    try project.addDependency(d);
                }
            }
        }

        // Look for self.requires("package/version")
        if (std.mem.indexOf(u8, line, "self.requires(")) |pos| {
            const after = line[pos + "self.requires(".len ..];
            if (extractQuotedString(after)) |req| {
                const dep = try parseRequirement(allocator, req, .build);
                if (dep) |d| {
                    try project.addDependency(d);
                }
            }
        }

        // Look for self.tool_requires("package/version")
        if (std.mem.indexOf(u8, line, "self.tool_requires(")) |pos| {
            const after = line[pos + "self.tool_requires(".len ..];
            if (extractQuotedString(after)) |req| {
                const dep = try parseRequirement(allocator, req, .dev);
                if (dep) |d| {
                    try project.addDependency(d);
                }
            }
        }
    }
}

fn parseRequirement(allocator: Allocator, spec: []const u8, kind: Dependency.Kind) !?Dependency {
    // Conan requirement format: name/version[@user/channel]
    // e.g., "zlib/1.2.11", "boost/1.76.0@conan/stable"

    const trimmed = std.mem.trim(u8, spec, " \t\"'");
    if (trimmed.len == 0) return null;

    // Split by /
    var parts = std.mem.splitScalar(u8, trimmed, '/');
    const name = parts.next() orelse return null;

    var version: ?[]const u8 = null;
    if (parts.next()) |ver_part| {
        // Remove @user/channel if present
        if (std.mem.indexOf(u8, ver_part, "@")) |at_pos| {
            version = try allocator.dupe(u8, ver_part[0..at_pos]);
        } else {
            version = try allocator.dupe(u8, ver_part);
        }
    }

    return Dependency{
        .name = try allocator.dupe(u8, name),
        .version = version,
        .kind = kind,
    };
}

fn extractPythonStringAssignment(line: []const u8, var_name: []const u8) ?[]const u8 {
    // Look for: var_name = "value" or var_name = 'value'
    if (std.mem.indexOf(u8, line, var_name)) |var_pos| {
        const after_var = line[var_pos + var_name.len ..];
        const trimmed = std.mem.trimLeft(u8, after_var, " \t");
        if (trimmed.len > 0 and trimmed[0] == '=') {
            const after_eq = std.mem.trimLeft(u8, trimmed[1..], " \t");
            return extractQuotedString(after_eq);
        }
    }
    return null;
}

fn extractQuotedString(text: []const u8) ?[]const u8 {
    if (text.len < 2) return null;

    const quote = text[0];
    if (quote != '"' and quote != '\'') return null;

    // Find closing quote
    for (text[1..], 1..) |c, i| {
        if (c == quote) {
            return text[1..i];
        }
    }
    return null;
}

/// Well-known Conan package to Zig dependency mapping
const PackageMapping = struct {
    conan_name: []const u8,
    zig_name: []const u8,
    url: ?[]const u8 = null,
};

const known_packages = [_]PackageMapping{
    .{ .conan_name = "zlib", .zig_name = "zlib" },
    .{ .conan_name = "libpng", .zig_name = "libpng" },
    .{ .conan_name = "libjpeg", .zig_name = "libjpeg" },
    .{ .conan_name = "openssl", .zig_name = "openssl" },
    .{ .conan_name = "libcurl", .zig_name = "curl" },
    .{ .conan_name = "sqlite3", .zig_name = "sqlite" },
    .{ .conan_name = "boost", .zig_name = "boost" },
    .{ .conan_name = "gtest", .zig_name = "googletest" },
    .{ .conan_name = "fmt", .zig_name = "fmt" },
    .{ .conan_name = "spdlog", .zig_name = "spdlog" },
    .{ .conan_name = "nlohmann_json", .zig_name = "json" },
    .{ .conan_name = "sdl", .zig_name = "sdl2" },
    .{ .conan_name = "glfw", .zig_name = "glfw" },
    .{ .conan_name = "imgui", .zig_name = "imgui" },
    .{ .conan_name = "freetype", .zig_name = "freetype" },
};

pub fn mapPackageName(conan_name: []const u8) ?[]const u8 {
    for (known_packages) |pkg| {
        if (std.mem.eql(u8, pkg.conan_name, conan_name)) {
            return pkg.zig_name;
        }
    }
    return null;
}

// Tests
test "parseRequirement" {
    const allocator = std.testing.allocator;

    // Simple requirement
    {
        const dep = try parseRequirement(allocator, "zlib/1.2.11", .build);
        try std.testing.expect(dep != null);
        try std.testing.expectEqualStrings("zlib", dep.?.name);
        try std.testing.expectEqualStrings("1.2.11", dep.?.version.?);
        allocator.free(dep.?.name);
        allocator.free(dep.?.version.?);
    }

    // With channel
    {
        const dep = try parseRequirement(allocator, "boost/1.76.0@conan/stable", .build);
        try std.testing.expect(dep != null);
        try std.testing.expectEqualStrings("boost", dep.?.name);
        try std.testing.expectEqualStrings("1.76.0", dep.?.version.?);
        allocator.free(dep.?.name);
        allocator.free(dep.?.version.?);
    }
}

test "extractQuotedString" {
    try std.testing.expectEqualStrings("hello", extractQuotedString("\"hello\"").?);
    try std.testing.expectEqualStrings("world", extractQuotedString("'world'").?);
    try std.testing.expect(extractQuotedString("noquotes") == null);
}
