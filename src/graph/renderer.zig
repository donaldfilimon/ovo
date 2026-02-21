const std = @import("std");
const project_mod = @import("../core/project.zig");

pub const TreeFormat = enum {
    ascii,
    dot,
    json,
    mermaid,
};

pub fn parseTreeFormat(value: []const u8) ?TreeFormat {
    if (std.mem.eql(u8, value, "ascii")) return .ascii;
    if (std.mem.eql(u8, value, "dot")) return .dot;
    if (std.mem.eql(u8, value, "json")) return .json;
    if (std.mem.eql(u8, value, "mermaid")) return .mermaid;
    return null;
}

pub fn formatLabel(format: TreeFormat) []const u8 {
    return switch (format) {
        .ascii => "ascii",
        .dot => "dot",
        .json => "json",
        .mermaid => "mermaid",
    };
}

pub fn renderTree(
    allocator: std.mem.Allocator,
    project: project_mod.Project,
    format: TreeFormat,
    target_filter: ?[]const u8,
) ![]const u8 {
    return switch (format) {
        .ascii => renderAscii(allocator, project, target_filter),
        .dot => renderDot(allocator, project, target_filter),
        .json => renderJson(allocator, project, target_filter),
        .mermaid => renderMermaid(allocator, project, target_filter),
    };
}

// ── Internal helpers ────────────────────────────────────────────────

fn isInternalTarget(name: []const u8, targets: []const project_mod.Target) bool {
    for (targets) |t| {
        if (std.mem.eql(u8, t.name, name)) return true;
    }
    return false;
}

// ── ASCII renderer ──────────────────────────────────────────────────

fn renderAscii(
    allocator: std.mem.Allocator,
    project: project_mod.Project,
    target_filter: ?[]const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    // Header
    try out.print(allocator, "{s} v{s}\n", .{ project.name, project.version });
    try out.appendSlice(allocator, "|\n");

    // Collect visible targets
    var visible_count: usize = 0;
    for (project.targets) |target| {
        if (target_filter) |filter| {
            if (!std.mem.eql(u8, target.name, filter)) continue;
        }
        visible_count += 1;
    }

    // Count total items (visible targets + deps if no filter)
    const show_deps = target_filter == null;
    const total_items = visible_count + if (show_deps) project.dependencies.len else 0;

    var item_idx: usize = 0;
    for (project.targets) |target| {
        if (target_filter) |filter| {
            if (!std.mem.eql(u8, target.name, filter)) continue;
        }
        item_idx += 1;
        const is_last_item = item_idx == total_items;
        const prefix = if (is_last_item) "`-- " else "+-- ";
        const cont = if (is_last_item) "    " else "|   ";

        try out.print(allocator, "{s}[target] {s} ({s})\n", .{
            prefix, target.name, project_mod.targetTypeLabel(target.kind),
        });

        // Sources
        if (target.sources.len > 0) {
            try out.print(allocator, "{s}+-- sources:\n", .{cont});
            for (target.sources) |src| {
                try out.print(allocator, "{s}|   +-- {s}\n", .{ cont, src });
            }
        }

        // Include dirs
        if (target.include_dirs.len > 0) {
            try out.print(allocator, "{s}+-- include_dirs:\n", .{cont});
            for (target.include_dirs) |dir| {
                try out.print(allocator, "{s}|   +-- {s}\n", .{ cont, dir });
            }
        }

        // Link libraries (internal vs external)
        if (target.link_libraries.len > 0) {
            try out.print(allocator, "{s}+-- links:\n", .{cont});
            for (target.link_libraries) |lib| {
                if (isInternalTarget(lib, project.targets)) {
                    try out.print(allocator, "{s}|   +-- {s} -> [target]\n", .{ cont, lib });
                } else {
                    try out.print(allocator, "{s}|   +-- {s} (external)\n", .{ cont, lib });
                }
            }
        }

        // Defines
        if (target.defines.len > 0) {
            try out.print(allocator, "{s}+-- defines:\n", .{cont});
            for (target.defines) |def| {
                try out.print(allocator, "{s}|   +-- {s}\n", .{ cont, def });
            }
        }

        // Cflags
        if (target.cflags.len > 0) {
            try out.print(allocator, "{s}+-- cflags:\n", .{cont});
            for (target.cflags) |flag| {
                try out.print(allocator, "{s}|   +-- {s}\n", .{ cont, flag });
            }
        }

        try out.appendSlice(allocator, "|\n");
    }

    // Dependencies (only when no filter)
    if (show_deps) {
        for (project.dependencies, 0..) |dep, i| {
            item_idx += 1;
            const is_last = i == project.dependencies.len - 1;
            const prefix = if (is_last) "`-- " else "+-- ";
            try out.print(allocator, "{s}[dependency] {s}@{s}\n", .{ prefix, dep.name, dep.version });
        }
    }

    return out.items;
}

// ── DOT renderer ────────────────────────────────────────────────────

fn renderDot(
    allocator: std.mem.Allocator,
    project: project_mod.Project,
    target_filter: ?[]const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    try out.print(allocator, "digraph \"{s}\" {{\n", .{project.name});
    try out.appendSlice(allocator, "  rankdir=LR;\n");
    try out.appendSlice(allocator, "  node [shape=box];\n\n");

    // Target nodes
    for (project.targets) |target| {
        if (target_filter) |filter| {
            if (!std.mem.eql(u8, target.name, filter)) continue;
        }
        try out.print(allocator, "  \"{s}\" [label=\"{s}\\n({s})\"];\n", .{
            target.name, target.name, project_mod.targetTypeLabel(target.kind),
        });
    }

    // Internal link edges
    for (project.targets) |target| {
        if (target_filter) |filter| {
            if (!std.mem.eql(u8, target.name, filter)) continue;
        }
        for (target.link_libraries) |lib| {
            if (isInternalTarget(lib, project.targets)) {
                try out.print(allocator, "  \"{s}\" -> \"{s}\";\n", .{ target.name, lib });
            }
        }
    }

    // Dependency nodes (only when no filter)
    if (target_filter == null) {
        try out.appendSlice(allocator, "\n");
        for (project.dependencies) |dep| {
            try out.print(allocator, "  \"{s}\" [label=\"{s}@{s}\", style=dashed];\n", .{
                dep.name, dep.name, dep.version,
            });
        }
    }

    try out.appendSlice(allocator, "}\n");
    return out.items;
}

// ── JSON renderer ───────────────────────────────────────────────────

fn renderJson(
    allocator: std.mem.Allocator,
    project: project_mod.Project,
    target_filter: ?[]const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    try out.appendSlice(allocator, "{\n");
    try out.print(allocator, "  \"project\": \"{s}\",\n", .{project.name});
    try out.print(allocator, "  \"version\": \"{s}\",\n", .{project.version});

    // Targets array
    try out.appendSlice(allocator, "  \"targets\": [\n");
    var first_target = true;
    for (project.targets) |target| {
        if (target_filter) |filter| {
            if (!std.mem.eql(u8, target.name, filter)) continue;
        }
        if (!first_target) try out.appendSlice(allocator, ",\n");
        first_target = false;

        try out.appendSlice(allocator, "    {\n");
        try out.print(allocator, "      \"name\": \"{s}\",\n", .{target.name});
        try out.print(allocator, "      \"type\": \"{s}\",\n", .{project_mod.targetTypeLabel(target.kind)});

        // Sources
        try out.appendSlice(allocator, "      \"sources\": [");
        for (target.sources, 0..) |src, i| {
            if (i > 0) try out.appendSlice(allocator, ", ");
            try out.print(allocator, "\"{s}\"", .{src});
        }
        try out.appendSlice(allocator, "],\n");

        // Internal links
        try out.appendSlice(allocator, "      \"internal_links\": [");
        var first_internal = true;
        for (target.link_libraries) |lib| {
            if (isInternalTarget(lib, project.targets)) {
                if (!first_internal) try out.appendSlice(allocator, ", ");
                first_internal = false;
                try out.print(allocator, "\"{s}\"", .{lib});
            }
        }
        try out.appendSlice(allocator, "],\n");

        // External links
        try out.appendSlice(allocator, "      \"external_links\": [");
        var first_external = true;
        for (target.link_libraries) |lib| {
            if (!isInternalTarget(lib, project.targets)) {
                if (!first_external) try out.appendSlice(allocator, ", ");
                first_external = false;
                try out.print(allocator, "\"{s}\"", .{lib});
            }
        }
        try out.appendSlice(allocator, "],\n");

        // Include dirs
        try out.appendSlice(allocator, "      \"include_dirs\": [");
        for (target.include_dirs, 0..) |dir, i| {
            if (i > 0) try out.appendSlice(allocator, ", ");
            try out.print(allocator, "\"{s}\"", .{dir});
        }
        try out.appendSlice(allocator, "],\n");

        // Defines
        try out.appendSlice(allocator, "      \"defines\": [");
        for (target.defines, 0..) |def, i| {
            if (i > 0) try out.appendSlice(allocator, ", ");
            try out.print(allocator, "\"{s}\"", .{def});
        }
        try out.appendSlice(allocator, "],\n");

        // Cflags
        try out.appendSlice(allocator, "      \"cflags\": [");
        for (target.cflags, 0..) |flag, i| {
            if (i > 0) try out.appendSlice(allocator, ", ");
            try out.print(allocator, "\"{s}\"", .{flag});
        }
        try out.appendSlice(allocator, "]\n");
        try out.appendSlice(allocator, "    }");
    }
    try out.appendSlice(allocator, "\n  ],\n");

    // Dependencies
    try out.appendSlice(allocator, "  \"dependencies\": [");
    if (target_filter == null) {
        for (project.dependencies, 0..) |dep, i| {
            if (i > 0) try out.appendSlice(allocator, ", ");
            try out.print(allocator, "{{\"name\": \"{s}\", \"version\": \"{s}\"}}", .{ dep.name, dep.version });
        }
    }
    try out.appendSlice(allocator, "]\n");

    try out.appendSlice(allocator, "}\n");
    return out.items;
}

// ── Mermaid renderer ────────────────────────────────────────────────

fn renderMermaid(
    allocator: std.mem.Allocator,
    project: project_mod.Project,
    target_filter: ?[]const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    try out.appendSlice(allocator, "graph TD\n");

    // Target nodes
    for (project.targets) |target| {
        if (target_filter) |filter| {
            if (!std.mem.eql(u8, target.name, filter)) continue;
        }
        try out.print(allocator, "  {s}[\"{s} ({s})\"]\n", .{
            target.name, target.name, project_mod.targetTypeLabel(target.kind),
        });
    }

    // Internal link edges
    for (project.targets) |target| {
        if (target_filter) |filter| {
            if (!std.mem.eql(u8, target.name, filter)) continue;
        }
        for (target.link_libraries) |lib| {
            if (isInternalTarget(lib, project.targets)) {
                try out.print(allocator, "  {s} --> {s}\n", .{ target.name, lib });
            }
        }
    }

    // Dependency nodes (only when no filter)
    if (target_filter == null) {
        for (project.dependencies) |dep| {
            try out.print(allocator, "  {s}[\"{s}@{s}\"]\n", .{ dep.name, dep.name, dep.version });
            // Link from project root concept — use first target or just show as standalone
            try out.print(allocator, "  {s} -.-> {s}\n", .{ project.name, dep.name });
        }
    }

    return out.items;
}
