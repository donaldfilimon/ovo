//! vcpkg Manifest Importer - vcpkg.json -> dependencies
//!
//! Parses vcpkg manifest files to extract:
//! - Project name and version
//! - Dependencies with version constraints
//! - Features and default features
//! - Platform-specific dependencies

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../engine.zig");
const Project = engine.Project;
const Dependency = engine.Dependency;
const TranslationWarning = engine.TranslationWarning;
const WarningSeverity = engine.WarningSeverity;
const TranslationOptions = engine.TranslationOptions;

/// JSON value wrapper for parsing
const JsonValue = std.json.Value;

/// Parse vcpkg.json and return Project
pub fn parse(allocator: Allocator, path: []const u8, options: TranslationOptions) !Project {
    const dir = std.fs.path.dirname(path) orelse ".";

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    var project = Project.init(allocator, "vcpkg_project", dir);
    errdefer project.deinit();

    // Parse JSON
    const parsed = std.json.parseFromSlice(JsonValue, allocator, content, .{}) catch |err| {
        try project.addWarning(.{
            .severity = .@"error",
            .message = try std.fmt.allocPrint(allocator, "Failed to parse vcpkg.json: {}", .{err}),
        });
        return project;
    };
    defer parsed.deinit();

    const root = parsed.value;

    if (root != .object) {
        try project.addWarning(.{
            .severity = .@"error",
            .message = "vcpkg.json root must be an object",
        });
        return project;
    }

    const obj = root.object;

    // Extract project name
    if (obj.get("name")) |name_val| {
        if (name_val == .string) {
            project.name = try allocator.dupe(u8, name_val.string);
        }
    }

    // Extract version
    if (obj.get("version") orelse obj.get("version-string") orelse obj.get("version-semver")) |ver_val| {
        if (ver_val == .string) {
            project.version = try allocator.dupe(u8, ver_val.string);
        }
    }

    // Extract description
    if (obj.get("description")) |desc_val| {
        if (desc_val == .string) {
            project.description = try allocator.dupe(u8, desc_val.string);
        } else if (desc_val == .array) {
            // Join array of strings
            var desc_parts = std.ArrayList(u8).init(allocator);
            defer desc_parts.deinit();
            for (desc_val.array.items, 0..) |item, i| {
                if (item == .string) {
                    if (i > 0) try desc_parts.appendSlice(" ");
                    try desc_parts.appendSlice(item.string);
                }
            }
            if (desc_parts.items.len > 0) {
                project.description = try desc_parts.toOwnedSlice();
            }
        }
    }

    // Extract homepage
    if (obj.get("homepage")) |hp_val| {
        if (hp_val == .string) {
            project.homepage = try allocator.dupe(u8, hp_val.string);
        }
    }

    // Extract license
    if (obj.get("license")) |lic_val| {
        if (lic_val == .string) {
            project.license = try allocator.dupe(u8, lic_val.string);
        }
    }

    // Extract dependencies
    if (obj.get("dependencies")) |deps_val| {
        if (deps_val == .array) {
            for (deps_val.array.items) |dep_item| {
                const dep = try parseDependency(allocator, dep_item, options);
                if (dep) |d| {
                    try project.addDependency(d);
                }
            }
        }
    }

    // Extract dev-dependencies
    if (obj.get("dev-dependencies")) |deps_val| {
        if (deps_val == .array) {
            for (deps_val.array.items) |dep_item| {
                var dep = try parseDependency(allocator, dep_item, options);
                if (dep) |*d| {
                    d.kind = .dev;
                    try project.addDependency(d.*);
                }
            }
        }
    }

    // Extract features for optional dependencies
    if (obj.get("features")) |features_val| {
        if (features_val == .object) {
            var iter = features_val.object.iterator();
            while (iter.next()) |entry| {
                const feature_name = entry.key_ptr.*;
                const feature_obj = entry.value_ptr.*;

                if (feature_obj == .object) {
                    if (feature_obj.object.get("dependencies")) |feat_deps| {
                        if (feat_deps == .array) {
                            for (feat_deps.array.items) |dep_item| {
                                var dep = try parseDependency(allocator, dep_item, options);
                                if (dep) |*d| {
                                    d.kind = .optional;
                                    // Note the feature this dependency belongs to
                                    try project.addWarning(.{
                                        .severity = .info,
                                        .message = try std.fmt.allocPrint(allocator, "Dependency '{s}' is part of feature '{s}'", .{ d.name, feature_name }),
                                    });
                                    try project.addDependency(d.*);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Note about default-features
    if (obj.get("default-features")) |df_val| {
        if (df_val == .array and df_val.array.items.len > 0) {
            var features_list = std.ArrayList(u8).init(allocator);
            defer features_list.deinit();

            for (df_val.array.items, 0..) |item, i| {
                if (item == .string) {
                    if (i > 0) try features_list.appendSlice(", ");
                    try features_list.appendSlice(item.string);
                }
            }

            if (features_list.items.len > 0) {
                try project.addWarning(.{
                    .severity = .info,
                    .message = try std.fmt.allocPrint(allocator, "Default features: {s}", .{features_list.items}),
                });
            }
        }
    }

    return project;
}

fn parseDependency(allocator: Allocator, value: JsonValue, options: TranslationOptions) !?Dependency {
    _ = options;

    switch (value) {
        .string => |name| {
            return Dependency{
                .name = try allocator.dupe(u8, name),
                .kind = .build,
            };
        },
        .object => |obj| {
            const name = if (obj.get("name")) |n| switch (n) {
                .string => |s| try allocator.dupe(u8, s),
                else => return null,
            } else return null;

            var dep = Dependency{
                .name = name,
                .kind = .build,
            };

            // Version constraints
            if (obj.get("version>=")) |ver| {
                if (ver == .string) {
                    dep.version = try std.fmt.allocPrint(allocator, ">={s}", .{ver.string});
                }
            } else if (obj.get("version>")) |ver| {
                if (ver == .string) {
                    dep.version = try std.fmt.allocPrint(allocator, ">{s}", .{ver.string});
                }
            }

            // Check host dependency
            if (obj.get("host")) |host| {
                if (host == .bool and host.bool) {
                    dep.kind = .dev;
                }
            }

            // Platform filter - note but don't filter
            // Platform info could be used for conditional deps in the future
            _ = obj.get("platform");

            return dep;
        },
        else => return null,
    }
}

/// Well-known vcpkg package to Zig dependency mapping
const PackageMapping = struct {
    vcpkg_name: []const u8,
    zig_name: []const u8,
    url: ?[]const u8 = null,
};

const known_packages = [_]PackageMapping{
    .{ .vcpkg_name = "zlib", .zig_name = "zlib" },
    .{ .vcpkg_name = "libpng", .zig_name = "libpng" },
    .{ .vcpkg_name = "libjpeg-turbo", .zig_name = "libjpeg" },
    .{ .vcpkg_name = "openssl", .zig_name = "openssl" },
    .{ .vcpkg_name = "curl", .zig_name = "curl" },
    .{ .vcpkg_name = "sqlite3", .zig_name = "sqlite" },
    .{ .vcpkg_name = "boost", .zig_name = "boost" },
    .{ .vcpkg_name = "gtest", .zig_name = "googletest" },
    .{ .vcpkg_name = "fmt", .zig_name = "fmt" },
    .{ .vcpkg_name = "spdlog", .zig_name = "spdlog" },
    .{ .vcpkg_name = "nlohmann-json", .zig_name = "json" },
    .{ .vcpkg_name = "sdl2", .zig_name = "sdl2" },
    .{ .vcpkg_name = "glfw3", .zig_name = "glfw" },
    .{ .vcpkg_name = "imgui", .zig_name = "imgui" },
    .{ .vcpkg_name = "freetype", .zig_name = "freetype" },
};

pub fn mapPackageName(vcpkg_name: []const u8) ?[]const u8 {
    for (known_packages) |pkg| {
        if (std.mem.eql(u8, pkg.vcpkg_name, vcpkg_name)) {
            return pkg.zig_name;
        }
    }
    return null;
}

// Tests
test "parseDependency string" {
    const allocator = std.testing.allocator;
    const value = JsonValue{ .string = "zlib" };

    const dep = try parseDependency(allocator, value, .{});
    try std.testing.expect(dep != null);
    try std.testing.expectEqualStrings("zlib", dep.?.name);
    allocator.free(dep.?.name);
}

test "mapPackageName" {
    try std.testing.expectEqualStrings("zlib", mapPackageName("zlib").?);
    try std.testing.expectEqualStrings("sdl2", mapPackageName("sdl2").?);
    try std.testing.expect(mapPackageName("unknown-package") == null);
}
