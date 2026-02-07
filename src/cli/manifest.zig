//! Helpers for build.zon manifest handling in the CLI.

const std = @import("std");

pub const manifest_filename = "build.zon";
pub const lock_filename = "ovo.lock";

pub const TemplateKind = enum {
    cpp_exe,
    cpp_lib,
    cpp_header_only,
    c_exe,
    c_lib,
    c_header_only,
};

// Inline templates for Zig 0.16 module compatibility
const template_cpp_exe =
    \\.{
    \\    .name = "{{PROJECT_NAME}}",
    \\    .version = .{ .major = 0, .minor = 1, .patch = 0 },
    \\    .authors = .{"{{AUTHOR_NAME}} <{{AUTHOR_EMAIL}}>"},
    \\    .license = "MIT",
    \\    .targets = .{
    \\        .{
    \\            .name = "{{PROJECT_NAME}}",
    \\            .target_type = .executable,
    \\            .sources = .{.{ .pattern = "src/**/*.cpp" }},
    \\        },
    \\    },
    \\    .defaults = .{
    \\        .cpp_standard = .cpp20,
    \\    },
    \\}
;
const template_cpp_lib =
    \\.{
    \\    .name = "{{PROJECT_NAME}}",
    \\    .version = .{ .major = 0, .minor = 1, .patch = 0 },
    \\    .authors = .{"{{AUTHOR_NAME}} <{{AUTHOR_EMAIL}}>"},
    \\    .license = "MIT",
    \\    .targets = .{
    \\        .{
    \\            .name = "{{PROJECT_NAME}}",
    \\            .target_type = .static_library,
    \\            .sources = .{.{ .pattern = "src/**/*.cpp" }},
    \\        },
    \\    },
    \\    .defaults = .{
    \\        .cpp_standard = .cpp20,
    \\    },
    \\}
;
const template_c_exe =
    \\.{
    \\    .name = "{{PROJECT_NAME}}",
    \\    .version = .{ .major = 0, .minor = 1, .patch = 0 },
    \\    .authors = .{"{{AUTHOR_NAME}} <{{AUTHOR_EMAIL}}>"},
    \\    .license = "MIT",
    \\    .targets = .{
    \\        .{
    \\            .name = "{{PROJECT_NAME}}",
    \\            .target_type = .executable,
    \\            .sources = .{.{ .pattern = "src/**/*.c" }},
    \\        },
    \\    },
    \\    .defaults = .{
    \\        .c_standard = .c17,
    \\    },
    \\}
;
const template_cpp_header_only =
    \\.{
    \\    .name = "{{PROJECT_NAME}}",
    \\    .version = .{ .major = 0, .minor = 1, .patch = 0 },
    \\    .authors = .{"{{AUTHOR_NAME}} <{{AUTHOR_EMAIL}}>"},
    \\    .license = "MIT",
    \\    .targets = .{
    \\        .{
    \\            .name = "{{PROJECT_NAME}}",
    \\            .target_type = .header_only,
    \\            .includes = .{.{ .path = "include" }},
    \\        },
    \\    },
    \\}
;
const template_c_lib =
    \\.{
    \\    .name = "{{PROJECT_NAME}}",
    \\    .version = .{ .major = 0, .minor = 1, .patch = 0 },
    \\    .authors = .{"{{AUTHOR_NAME}} <{{AUTHOR_EMAIL}}>"},
    \\    .license = "MIT",
    \\    .targets = .{
    \\        .{
    \\            .name = "{{PROJECT_NAME}}",
    \\            .target_type = .static_library,
    \\            .sources = .{.{ .pattern = "src/**/*.c" }},
    \\        },
    \\    },
    \\    .defaults = .{
    \\        .c_standard = .c17,
    \\    },
    \\}
;
const template_c_header_only =
    \\.{
    \\    .name = "{{PROJECT_NAME}}",
    \\    .version = .{ .major = 0, .minor = 1, .patch = 0 },
    \\    .authors = .{"{{AUTHOR_NAME}} <{{AUTHOR_EMAIL}}>"},
    \\    .license = "MIT",
    \\    .targets = .{
    \\        .{
    \\            .name = "{{PROJECT_NAME}}",
    \\            .target_type = .header_only,
    \\            .includes = .{.{ .path = "include" }},
    \\        },
    \\    },
    \\}
;

pub fn templateForKind(kind: TemplateKind) []const u8 {
    return switch (kind) {
        .cpp_exe => template_cpp_exe,
        .cpp_lib => template_cpp_lib,
        .cpp_header_only => template_cpp_header_only,
        .c_exe => template_c_exe,
        .c_lib => template_c_lib,
        .c_header_only => template_c_header_only,
    };
}

/// Return base template directory (OVO_TEMPLATES env or "templates").
pub fn getTemplateDir(allocator: std.mem.Allocator) ![]const u8 {
    const key = "OVO_TEMPLATES";
    var key_buf: [32]u8 = undefined;
    if (key.len >= key_buf.len) return allocator.dupe(u8, "templates");
    @memcpy(key_buf[0..key.len], key);
    key_buf[key.len] = 0;
    if (std.c.getenv(@ptrCast(&key_buf))) |ptr| {
        const val = std.mem.span(ptr);
        if (val.len > 0) return allocator.dupe(u8, val);
    }
    return allocator.dupe(u8, "templates");
}

/// Return relative path for build.zon template (e.g. "cpp_exe/build.zon").
pub fn getBuildZonTemplatePath(kind: TemplateKind, lang: []const u8) []const u8 {
    return switch (kind) {
        .cpp_exe => if (std.mem.eql(u8, lang, "cpp")) "cpp_exe/build.zon" else "c_project/build.zon",
        .cpp_lib => if (std.mem.eql(u8, lang, "cpp")) "cpp_lib/build.zon" else "c_lib/build.zon",
        .cpp_header_only => if (std.mem.eql(u8, lang, "cpp")) "cpp_header_only/build.zon" else "c_header_only/build.zon",
        .c_exe => "c_project/build.zon",
        .c_lib => "c_lib/build.zon",
        .c_header_only => "c_header_only/build.zon",
    };
}

pub fn renderTemplate(allocator: std.mem.Allocator, kind: TemplateKind, project_name: []const u8) ![]u8 {
    const author_name = try getEnvOwned(allocator, &.{ "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME", "USER" }, "Unknown");
    defer allocator.free(author_name);
    const author_email = try getEnvOwned(allocator, &.{ "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL", "EMAIL" }, "unknown@example.com");
    defer allocator.free(author_email);
    const project_name_upper = try toUpperSnake(allocator, project_name);
    defer allocator.free(project_name_upper);

    const base = templateForKind(kind);
    var output = try replaceAll(allocator, base, "{{PROJECT_NAME}}", project_name);
    output = try replaceAllOwned(allocator, output, "{{PROJECT_NAME_UPPER}}", project_name_upper);
    output = try replaceAllOwned(allocator, output, "{{AUTHOR_NAME}}", author_name);
    output = try replaceAllOwned(allocator, output, "{{AUTHOR_EMAIL}}", author_email);
    return output;
}

pub fn applyStandardOverride(
    allocator: std.mem.Allocator,
    input: []const u8,
    lang: []const u8,
    std_version: []const u8,
) ![]u8 {
    const parsed = try parseStandard(allocator, std_version) orelse return allocator.dupe(u8, input);
    defer allocator.free(parsed.value);

    if (parsed.is_cpp and std.mem.eql(u8, lang, "cpp")) {
        return replaceStandardField(allocator, input, "cpp_standard", parsed.value);
    }
    if (!parsed.is_cpp and std.mem.eql(u8, lang, "c")) {
        return replaceStandardField(allocator, input, "c_standard", parsed.value);
    }

    return allocator.dupe(u8, input);
}

const ParsedStandard = struct {
    is_cpp: bool,
    value: []u8,
};

fn parseStandard(allocator: std.mem.Allocator, std_version: []const u8) !?ParsedStandard {
    if (std_version.len == 0) return null;
    var lowered = try allocator.alloc(u8, std_version.len);
    defer allocator.free(lowered);
    for (std_version, 0..) |c, i| lowered[i] = std.ascii.toLower(c);

    if (std.mem.startsWith(u8, lowered, "c++") or std.mem.startsWith(u8, lowered, "cpp") or std.mem.startsWith(u8, lowered, "cxx")) {
        const digits = extractDigits(lowered);
        if (digits.len == 0) return null;
        const value = try std.fmt.allocPrint(allocator, "cpp{s}", .{digits});
        return .{ .is_cpp = true, .value = value };
    }

    if (lowered[0] == 'c') {
        const digits = extractDigits(lowered);
        if (digits.len == 0) return null;
        const value = try std.fmt.allocPrint(allocator, "c{s}", .{digits});
        return .{ .is_cpp = false, .value = value };
    }

    return null;
}

fn extractDigits(input: []const u8) []const u8 {
    var start: ?usize = null;
    var end: usize = 0;
    for (input, 0..) |c, i| {
        if (c >= '0' and c <= '9') {
            if (start == null) start = i;
            end = i + 1;
        } else if (start != null) {
            break;
        }
    }
    if (start) |s| return input[s..end];
    return "";
}

fn replaceStandardField(allocator: std.mem.Allocator, input: []const u8, field: []const u8, value: []const u8) ![]u8 {
    const prefix = try std.fmt.allocPrint(allocator, ".{s} = .", .{field});
    defer allocator.free(prefix);
    if (std.mem.indexOf(u8, input, prefix)) |idx| {
        var end_idx = idx + prefix.len;
        while (end_idx < input.len) : (end_idx += 1) {
            const c = input[end_idx];
            if (c == ',' or c == '\n' or c == ' ' or c == '\t') break;
        }
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ input[0 .. idx + prefix.len], value, input[end_idx..] });
    }
    return allocator.dupe(u8, input);
}

fn replaceAllOwned(allocator: std.mem.Allocator, input: []u8, needle: []const u8, replacement: []const u8) ![]u8 {
    const output = try replaceAll(allocator, input, needle, replacement);
    allocator.free(input);
    return output;
}

fn replaceAll(allocator: std.mem.Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    if (needle.len == 0) return allocator.dupe(u8, input);
    // Use unmanaged ArrayList for Zig 0.16 compatibility
    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(allocator);

    var start: usize = 0;
    while (std.mem.indexOfPos(u8, input, start, needle)) |idx| {
        try buffer.appendSlice(allocator, input[start..idx]);
        try buffer.appendSlice(allocator, replacement);
        start = idx + needle.len;
    }
    try buffer.appendSlice(allocator, input[start..]);
    return buffer.toOwnedSlice(allocator);
}

pub fn toUpperSnake(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = if (c == '-') '_' else std.ascii.toUpper(c);
    }
    return result;
}

fn toSnake(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = if (c == '-') '_' else std.ascii.toLower(c);
    }
    return result;
}

/// Substitute template placeholders in content.
/// Placeholders: {{PROJECT_NAME}}, {{PROJECT_NAME_UPPER}}, {{PROJECT_NAME_SNAKE}}, {{AUTHOR_NAME}}, {{AUTHOR_EMAIL}}
pub fn substituteInContent(allocator: std.mem.Allocator, content: []const u8, project_name: []const u8) ![]u8 {
    const project_name_upper = try toUpperSnake(allocator, project_name);
    defer allocator.free(project_name_upper);
    const project_name_snake = try toSnake(allocator, project_name);
    defer allocator.free(project_name_snake);
    const author_name = try getEnvOwned(allocator, &.{ "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME", "USER" }, "Unknown");
    defer allocator.free(author_name);
    const author_email = try getEnvOwned(allocator, &.{ "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL", "EMAIL" }, "unknown@example.com");
    defer allocator.free(author_email);

    var result = try replaceAll(allocator, content, "{{PROJECT_NAME}}", project_name);
    result = try replaceAllOwned(allocator, result, "{{PROJECT_NAME_UPPER}}", project_name_upper);
    result = try replaceAllOwned(allocator, result, "{{PROJECT_NAME_SNAKE}}", project_name_snake);
    result = try replaceAllOwned(allocator, result, "{{AUTHOR_NAME}}", author_name);
    result = try replaceAllOwned(allocator, result, "{{AUTHOR_EMAIL}}", author_email);
    return result;
}

fn getEnvOwned(allocator: std.mem.Allocator, keys: []const []const u8, default_value: []const u8) ![]u8 {
    for (keys) |key| {
        // Use C library getenv for Zig 0.16 compatibility
        var key_buf: [256]u8 = undefined;
        if (key.len >= key_buf.len) continue;
        @memcpy(key_buf[0..key.len], key);
        key_buf[key.len] = 0;
        const c_result = std.c.getenv(@ptrCast(&key_buf));
        if (c_result) |ptr| {
            const val = std.mem.span(ptr);
            if (val.len > 0) return allocator.dupe(u8, val);
        }
    }
    return allocator.dupe(u8, default_value);
}
