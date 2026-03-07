const std = @import("std");
const source_spec = @import("source_spec.zig");

pub const LockOrigin = enum {
    registry,
    direct,
};

pub const LockedDependency = struct {
    name: []const u8,
    requested: []const u8,
    origin: LockOrigin,
    source: source_spec.SourceKind,
    url: []const u8 = "",
    ref: []const u8 = "",
    commit: []const u8 = "",
    sha256: []const u8 = "",
    path: []const u8 = "",
    cache_key: []const u8 = "",
    strip_prefix: []const u8 = "",
};

pub const LockFile = struct {
    schema: ?[]const u8 = null,
    project: ?[]const u8 = null,
    version: ?[]const u8 = null,
    dependencies: []const LockedDependency,
    legacy: bool = false,
};

pub fn parseLockFile(allocator: std.mem.Allocator, bytes: []const u8) !LockFile {
    const schema = extractStringField(bytes, ".lock_schema");
    if (schema == null) {
        // Compatibility path: legacy lockfiles are accepted on read and rewritten
        // to schema v1 by lock/fetch operations.
        const legacy = try parseLegacyDependencies(allocator, bytes);
        return .{ .dependencies = legacy, .legacy = true };
    }

    if (!std.mem.eql(u8, schema.?, "1")) {
        // Unknown schema also falls back to legacy read for migration safety.
        const legacy = try parseLegacyDependencies(allocator, bytes);
        return .{
            .schema = schema,
            .dependencies = legacy,
            .legacy = true,
        };
    }

    const deps_block = findObjectBlock(bytes, ".dependencies") orelse
        return .{ .schema = schema, .project = extractStringField(bytes, ".project"), .version = extractStringField(bytes, ".version"), .dependencies = &.{} };

    var deps: std.ArrayList(LockedDependency) = .empty;
    errdefer deps.deinit(allocator);

    var i: usize = 0;
    while (i < deps_block.len) : (i += 1) {
        if (deps_block[i] != '.') continue;

        const name_start = i + 1;
        const eq = std.mem.indexOfScalarPos(u8, deps_block, name_start, '=') orelse continue;
        const name = std.mem.trim(u8, deps_block[name_start..eq], " \t\r\n");
        if (name.len == 0) continue;

        var v = eq + 1;
        while (v < deps_block.len and std.ascii.isWhitespace(deps_block[v])) : (v += 1) {}
        if (v >= deps_block.len) continue;
        if (deps_block[v] != '.') continue;

        const close = findMatchingBrace(deps_block, v) orelse continue;
        if (close <= v) continue;

        const body = deps_block[v + 1 .. close];
        const dep = parseDependencyObject(name, body);
        try deps.append(allocator, dep);
        i = close;
    }

    return .{
        .schema = schema,
        .project = extractStringField(bytes, ".project"),
        .version = extractStringField(bytes, ".version"),
        .dependencies = try deps.toOwnedSlice(allocator),
    };
}

pub fn isValidSchema(file: LockFile) bool {
    return file.schema != null and std.mem.eql(u8, file.schema.?, "1") and !file.legacy;
}

pub fn findDependency(file: LockFile, name: []const u8) ?LockedDependency {
    for (file.dependencies) |dep| {
        if (std.mem.eql(u8, dep.name, name)) return dep;
    }
    return null;
}

pub fn renderLockFile(
    allocator: std.mem.Allocator,
    project: []const u8,
    project_version: []const u8,
    dependencies: []const LockedDependency,
) ![]u8 {
    const sorted = try allocator.alloc(LockedDependency, dependencies.len);
    defer allocator.free(sorted);
    @memcpy(sorted, dependencies);
    sortLockedDependencies(sorted);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, ".{\n");
    try out.print(allocator, "    .lock_schema = \"1\",\n", .{});
    if (project.len > 0) {
        try out.print(allocator, "    .project = \"{s}\",\n", .{project});
    }
    if (project_version.len > 0) {
        try out.print(allocator, "    .version = \"{s}\",\n", .{project_version});
    }
    try out.appendSlice(allocator, "    .dependencies = .{\n");

    for (sorted) |dep| {
        try out.print(allocator, "        .{s} = .{{\n", .{dep.name});
        try out.print(allocator, "            .requested = \"{s}\",\n", .{dep.requested});
        try out.print(allocator, "            .origin = .{s},\n", .{lockOriginLabel(dep.origin)});
        try out.print(allocator, "            .source = .{s},\n", .{sourceKindLabel(dep.source)});
        try out.print(allocator, "            .url = \"{s}\",\n", .{dep.url});
        try out.print(allocator, "            .ref = \"{s}\",\n", .{dep.ref});
        try out.print(allocator, "            .commit = \"{s}\",\n", .{dep.commit});
        try out.print(allocator, "            .sha256 = \"{s}\",\n", .{dep.sha256});
        try out.print(allocator, "            .path = \"{s}\",\n", .{dep.path});
        if (dep.strip_prefix.len > 0) {
            try out.print(allocator, "            .strip_prefix = \"{s}\",\n", .{dep.strip_prefix});
        }
        try out.print(allocator, "            .cache_key = \"{s}\",\n", .{dep.cache_key});
        try out.appendSlice(allocator, "        },\n");
    }

    try out.appendSlice(allocator, "    },\n");
    try out.appendSlice(allocator, "}\n");

    return try out.toOwnedSlice(allocator);
}

fn parseDependencyObject(name: []const u8, body: []const u8) LockedDependency {
    return .{
        .name = name,
        .requested = extractStringField(body, ".requested") orelse "",
        .origin = originFromLabel(extractEnumField(body, ".origin") orelse "direct"),
        .source = sourceFromLabel(extractEnumField(body, ".source") orelse "registry"),
        .url = extractStringField(body, ".url") orelse "",
        .ref = extractStringField(body, ".ref") orelse "",
        .commit = extractStringField(body, ".commit") orelse "",
        .sha256 = extractStringField(body, ".sha256") orelse "",
        .path = extractStringField(body, ".path") orelse "",
        .cache_key = extractStringField(body, ".cache_key") orelse "",
        .strip_prefix = extractStringField(body, ".strip_prefix") orelse "",
    };
}

fn parseLegacyDependencies(allocator: std.mem.Allocator, bytes: []const u8) ![]const LockedDependency {
    const block = findObjectBlock(bytes, ".dependencies") orelse return &.{};
    var deps: std.ArrayList(LockedDependency) = .empty;
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
        const eq = std.mem.indexOfScalarPos(u8, block, name_start, '=') orelse continue;
        const name = std.mem.trim(u8, block[name_start..eq], " \t\r\n");
        if (name.len == 0) continue;

        var v = eq + 1;
        while (v < block.len and std.ascii.isWhitespace(block[v])) : (v += 1) {}
        if (v >= block.len or block[v] != '"') continue;
        const end = findNextQuote(block, v + 1) orelse continue;

        try deps.append(allocator, .{
            .name = name,
            .requested = block[v + 1 .. end],
            .origin = .direct,
            .source = .registry,
        });
        i = end;
    }

    return try deps.toOwnedSlice(allocator);
}

fn sortLockedDependencies(dependencies: []LockedDependency) void {
    if (dependencies.len < 2) return;
    var i: usize = 1;
    while (i < dependencies.len) : (i += 1) {
        const key = dependencies[i];
        var j = i;
        while (j > 0 and std.mem.order(u8, dependencies[j - 1].name, key.name) == .gt) : (j -= 1) {
            dependencies[j] = dependencies[j - 1];
        }
        dependencies[j] = key;
    }
}

fn lockOriginLabel(origin: LockOrigin) []const u8 {
    return switch (origin) {
        .registry => "registry",
        .direct => "direct",
    };
}

fn sourceKindLabel(kind: source_spec.SourceKind) []const u8 {
    return switch (kind) {
        .registry => "registry",
        .git => "git",
        .tar => "tar",
        .local => "local",
    };
}

fn sourceFromLabel(value: []const u8) source_spec.SourceKind {
    if (std.mem.eql(u8, value, "git")) return .git;
    if (std.mem.eql(u8, value, "tar")) return .tar;
    if (std.mem.eql(u8, value, "local")) return .local;
    if (std.mem.eql(u8, value, "registry")) return .registry;
    return .registry;
}

fn originFromLabel(value: []const u8) LockOrigin {
    if (std.mem.eql(u8, value, "registry")) return .registry;
    return .direct;
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

fn extractStringField(bytes: []const u8, field_name: []const u8) ?[]const u8 {
    const field_start = std.mem.indexOf(u8, bytes, field_name) orelse return null;
    const rest = bytes[field_start + field_name.len ..];
    const q0 = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const tail = rest[q0 + 1 ..];
    const q1 = std.mem.indexOfScalar(u8, tail, '"') orelse return null;
    return tail[0..q1];
}

fn extractEnumField(bytes: []const u8, field_name: []const u8) ?[]const u8 {
    const field_start = std.mem.indexOf(u8, bytes, field_name) orelse return null;
    const rest = bytes[field_start + field_name.len ..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    const start = dot + 1;
    var end = start;
    while (end < rest.len) : (end += 1) {
        const c = rest[end];
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) break;
    }
    if (end <= start) return null;
    return rest[start..end];
}
