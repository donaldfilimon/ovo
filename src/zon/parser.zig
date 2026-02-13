const std = @import("std");
const project_mod = @import("../core/project.zig");

pub fn parseBuildZon(allocator: std.mem.Allocator, bytes: []const u8) !project_mod.Project {
    var project = project_mod.Project{
        .ovo_schema = extractStringField(bytes, ".ovo_schema") orelse "0",
        .name = extractStringField(bytes, ".name") orelse return error.MissingName,
        .version = extractStringField(bytes, ".version") orelse return error.MissingVersion,
        .license = extractStringField(bytes, ".license"),
    };

    if (findObjectBlock(bytes, ".defaults")) |defaults_block| {
        if (extractEnumField(defaults_block, ".cpp_standard")) |cpp| {
            project.defaults.cpp_standard = project_mod.parseCppStandard(cpp) orelse project.defaults.cpp_standard;
        }
        if (extractStringField(defaults_block, ".optimize")) |optimize| {
            project.defaults.optimize = optimize;
        }
        if (extractStringField(defaults_block, ".backend")) |backend| {
            project.defaults.backend = backend;
        }
        if (extractStringField(defaults_block, ".output_dir")) |out_dir| {
            project.defaults.output_dir = out_dir;
        }
    }

    project.targets = try parseTargets(allocator, bytes);
    project.dependencies = try parseDependencies(allocator, bytes);
    return project;
}

fn parseTargets(allocator: std.mem.Allocator, bytes: []const u8) ![]const project_mod.Target {
    const block = findObjectBlock(bytes, ".targets") orelse return &.{};
    var targets: std.ArrayList(project_mod.Target) = .empty;
    errdefer targets.deinit(allocator);

    var cursor: usize = 0;
    while (findTopLevelEntryObject(block, &cursor)) |entry| {
        var target = project_mod.Target{
            .name = entry.name,
            .kind = .executable,
        };
        if (extractEnumField(entry.body, ".type")) |kind| {
            target.kind = project_mod.parseTargetType(kind) orelse .executable;
        }
        target.sources = try parseStringArray(allocator, entry.body, ".sources");
        target.include_dirs = try parseStringArray(allocator, entry.body, ".include_dirs");
        target.link_libraries = try parseStringArray(allocator, entry.body, ".link");
        try targets.append(allocator, target);
    }

    return try targets.toOwnedSlice(allocator);
}

fn parseDependencies(allocator: std.mem.Allocator, bytes: []const u8) ![]const project_mod.Dependency {
    const block = findObjectBlock(bytes, ".dependencies") orelse return &.{};
    var deps: std.ArrayList(project_mod.Dependency) = .empty;
    errdefer deps.deinit(allocator);

    var i: usize = 0;
    var depth: usize = 0;
    while (i < block.len) : (i += 1) {
        const c = block[i];
        if (c == '"') {
            i = skipQuoted(block, i);
            continue;
        }
        if (c == '{') {
            depth += 1;
            continue;
        }
        if (c == '}') {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (c != '.' or depth != 0) continue;

        const name_start = i + 1;
        var eq = std.mem.indexOfPos(u8, block, name_start, "=") orelse continue;
        const raw_name = std.mem.trim(u8, block[name_start..eq], " \t\r\n");
        eq += 1;
        while (eq < block.len and (block[eq] == ' ' or block[eq] == '\t')) : (eq += 1) {}
        if (eq >= block.len or block[eq] != '"') continue;
        const end = findNextQuote(block, eq + 1) orelse continue;
        const version = block[eq + 1 .. end];

        try deps.append(allocator, .{
            .name = raw_name,
            .version = version,
        });
        i = end;
    }

    return try deps.toOwnedSlice(allocator);
}

fn parseStringArray(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    field_name: []const u8,
) ![]const []const u8 {
    const block = findObjectBlock(bytes, field_name) orelse return &.{};
    var values: std.ArrayList([]const u8) = .empty;
    errdefer values.deinit(allocator);

    var i: usize = 0;
    while (i < block.len) : (i += 1) {
        if (block[i] != '"') continue;
        const end = findNextQuote(block, i + 1) orelse break;
        try values.append(allocator, block[i + 1 .. end]);
        i = end;
    }
    return try values.toOwnedSlice(allocator);
}

const EntryObject = struct {
    name: []const u8,
    body: []const u8,
};

fn findTopLevelEntryObject(bytes: []const u8, cursor: *usize) ?EntryObject {
    var i = cursor.*;
    var depth: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c == '"') {
            i = skipQuoted(bytes, i);
            continue;
        }
        if (c == '{') {
            depth += 1;
            continue;
        }
        if (c == '}') {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (c != '.' or depth != 0) continue;

        const name_start = i + 1;
        const eq_index = std.mem.indexOfPos(u8, bytes, name_start, "=") orelse continue;
        const name = std.mem.trim(u8, bytes[name_start..eq_index], " \t\r\n");
        var after_eq = eq_index + 1;
        while (after_eq < bytes.len and (bytes[after_eq] == ' ' or bytes[after_eq] == '\t')) : (after_eq += 1) {}
        if (after_eq >= bytes.len or bytes[after_eq] != '.') continue;
        after_eq += 1;
        while (after_eq < bytes.len and (bytes[after_eq] == ' ' or bytes[after_eq] == '\t')) : (after_eq += 1) {}
        if (after_eq >= bytes.len or bytes[after_eq] != '{') continue;
        const close = findMatchingBrace(bytes, after_eq) orelse continue;
        cursor.* = close + 1;
        return .{
            .name = name,
            .body = bytes[after_eq + 1 .. close],
        };
    }
    cursor.* = i;
    return null;
}

fn extractStringField(bytes: []const u8, field_name: []const u8) ?[]const u8 {
    const field_start = std.mem.indexOf(u8, bytes, field_name) orelse return null;
    const rest = bytes[field_start + field_name.len ..];
    const first_quote_rel = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const quoted_tail = rest[first_quote_rel + 1 ..];
    const second_quote_rel = std.mem.indexOfScalar(u8, quoted_tail, '"') orelse return null;
    return quoted_tail[0..second_quote_rel];
}

fn extractEnumField(bytes: []const u8, field_name: []const u8) ?[]const u8 {
    const field_start = std.mem.indexOf(u8, bytes, field_name) orelse return null;
    const rest = bytes[field_start + field_name.len ..];
    const dot_rel = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    const enum_start = dot_rel + 1;
    var end = enum_start;
    while (end < rest.len) : (end += 1) {
        const c = rest[end];
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) break;
    }
    if (end <= enum_start) return null;
    return rest[enum_start..end];
}

fn findObjectBlock(bytes: []const u8, field_name: []const u8) ?[]const u8 {
    const field_start = std.mem.indexOf(u8, bytes, field_name) orelse return null;
    const rest = bytes[field_start + field_name.len ..];
    const open_rel = std.mem.indexOfScalar(u8, rest, '{') orelse return null;
    const open_idx = field_start + field_name.len + open_rel;
    const close_idx = findMatchingBrace(bytes, open_idx) orelse return null;
    if (close_idx <= open_idx) return null;
    return bytes[open_idx + 1 .. close_idx];
}

fn findMatchingBrace(bytes: []const u8, open_idx: usize) ?usize {
    var depth: usize = 0;
    var i = open_idx;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c == '"') {
            i = skipQuoted(bytes, i);
            continue;
        }
        if (c == '{') {
            depth += 1;
            continue;
        }
        if (c == '}') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn skipQuoted(bytes: []const u8, quote_index: usize) usize {
    if (bytes.len == 0) return 0;
    var i = quote_index + 1;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\\' and i + 1 < bytes.len) {
            i += 1;
            continue;
        }
        if (bytes[i] == '"') return i;
    }
    return bytes.len - 1;
}

fn findNextQuote(bytes: []const u8, start: usize) ?usize {
    var i = start;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\\' and i + 1 < bytes.len) {
            i += 1;
            continue;
        }
        if (bytes[i] == '"') return i;
    }
    return null;
}
