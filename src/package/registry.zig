const std = @import("std");
const source_spec = @import("source_spec.zig");
const core = @import("../core/mod.zig");

pub const RegistryEntry = struct {
    name: []const u8,
    version: []const u8,
    source: source_spec.SourceKind,
    url: []const u8 = "",
    ref: []const u8 = "",
    sha256: []const u8 = "",
    strip_prefix: []const u8 = "",
    path: []const u8 = "",
};

pub fn parseManifest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    manifest_path: []const u8,
) ![]const RegistryEntry {
    const schema = extractStringField(bytes, ".registry_schema");
    if (schema) |value| {
        if (!std.mem.eql(u8, value, "1")) {
            return &.{};
        }
    }

    const entries_block = findObjectBlock(bytes, ".entries") orelse return &.{};
    const base_dir = dirnameFromPath(manifest_path);

    var entries: std.ArrayList(RegistryEntry) = .empty;
    errdefer entries.deinit(allocator);

    var cursor: usize = 0;
    while (cursor < entries_block.len) : (cursor += 1) {
        const c = entries_block[cursor];
        if (c != '.' and c != '{') continue;
        if (c == '.') {
            if (cursor + 1 >= entries_block.len or entries_block[cursor + 1] != '{') continue;

            const next = cursor + 1;
            const close = findMatchingBrace(entries_block, next) orelse continue;
            const body = entries_block[next + 1 .. close];
            const entry = parseRegistryEntry(allocator, body, base_dir) catch continue;
            try entries.append(allocator, entry);
            cursor = close;
        }
    }

    return try entries.toOwnedSlice(allocator);
}

pub fn parseProjectManifest(allocator: std.mem.Allocator) ![]const RegistryEntry {
    const file_path = "ovo.registry.zon";
    if (!core.fs.fileExists(file_path)) return &.{};

    const bytes = try core.fs.readFileAlloc(allocator, file_path);
    defer allocator.free(bytes);
    return parseManifest(allocator, bytes, file_path);
}

pub fn parseUserManifest(allocator: std.mem.Allocator) ![]const RegistryEntry {
    const home = std.c.getenv("HOME") orelse return &.{};
    const dir = try std.fmt.allocPrint(allocator, "{s}/.ovo", .{home});
    defer allocator.free(dir);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/registry.zon", .{dir});
    defer allocator.free(file_path);

    if (!core.fs.fileExists(file_path)) return &.{};
    const bytes = try core.fs.readFileAlloc(allocator, file_path);
    defer allocator.free(bytes);
    return parseManifest(allocator, bytes, file_path);
}

pub fn loadManifest(allocator: std.mem.Allocator) ![]const RegistryEntry {
    var all: std.ArrayList(RegistryEntry) = .empty;
    errdefer all.deinit(allocator);

    const project_entries = try parseProjectManifest(allocator);
    for (project_entries) |entry| try all.append(allocator, entry);

    const user_entries = try parseUserManifest(allocator);
    for (user_entries) |entry| try all.append(allocator, entry);

    return try all.toOwnedSlice(allocator);
}

pub fn resolveEntry(entries: []const RegistryEntry, name: []const u8, requested: []const u8) ?RegistryEntry {
    if (requested.len == 0) return null;

    if (std.mem.eql(u8, requested, "latest")) {
        for (entries) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            if (std.mem.eql(u8, entry.version, "latest")) return entry;
        }
        return null;
    }

    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name) and std.mem.eql(u8, entry.version, requested)) {
            return entry;
        }
    }
    return null;
}

fn parseRegistryEntry(
    allocator: std.mem.Allocator,
    body: []const u8,
    base_dir: []const u8,
) !RegistryEntry {
    const name = extractStringField(body, ".name") orelse return error.MissingName;
    const version = extractStringField(body, ".version") orelse return error.MissingVersion;
    const source_label = extractEnumField(body, ".source") orelse return error.MissingSource;
    const source = sourceFromString(source_label);

    const raw_path = extractStringField(body, ".path") orelse "";
    const resolved_path = if (raw_path.len == 0)
        ""
    else if (std.fs.path.isAbsolute(raw_path))
        try allocator.dupe(u8, raw_path)
    else
        try std.fs.path.join(allocator, &.{ base_dir, raw_path });

    return RegistryEntry{
        .name = try allocator.dupe(u8, name),
        .version = try allocator.dupe(u8, version),
        .source = source,
        .url = try allocator.dupe(u8, extractStringField(body, ".url") orelse ""),
        .ref = try allocator.dupe(u8, extractStringField(body, ".ref") orelse ""),
        .sha256 = try allocator.dupe(u8, extractStringField(body, ".sha256") orelse ""),
        .strip_prefix = try allocator.dupe(u8, extractStringField(body, ".strip_prefix") orelse ""),
        .path = resolved_path,
    };
}

fn sourceFromString(value: []const u8) source_spec.SourceKind {
    if (std.mem.eql(u8, value, "git")) return .git;
    if (std.mem.eql(u8, value, "tar")) return .tar;
    if (std.mem.eql(u8, value, "local")) return .local;
    return .registry;
}

fn dirnameFromPath(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
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

fn skipQuoted(bytes: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\\' and i + 1 < bytes.len) {
            i += 1;
            continue;
        }
        if (bytes[i] == '"') return i;
    }
    return bytes.len - 1;
}

fn extractStringField(bytes: []const u8, field_name: []const u8) ?[]const u8 {
    const field_start = std.mem.indexOf(u8, bytes, field_name) orelse return null;
    const rest = bytes[field_start + field_name.len ..];
    const first_quote = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const quoted = rest[first_quote + 1 ..];
    const second_quote = std.mem.indexOfScalar(u8, quoted, '"') orelse return null;
    return quoted[0..second_quote];
}

fn extractEnumField(bytes: []const u8, field_name: []const u8) ?[]const u8 {
    const field_start = std.mem.indexOf(u8, bytes, field_name) orelse return null;
    const rest = bytes[field_start + field_name.len ..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    const value_start = dot + 1;
    var end = value_start;
    while (end < rest.len) : (end += 1) {
        const c = rest[end];
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) break;
    }
    if (end <= value_start) return null;
    return rest[value_start..end];
}
