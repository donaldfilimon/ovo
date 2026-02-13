const std = @import("std");
const core = @import("../core/mod.zig");
const project_mod = @import("../core/project.zig");
const zon = @import("../zon/mod.zig");

pub const PackageManager = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PackageManager {
        return .{ .allocator = allocator };
    }

    pub fn add(self: *PackageManager, name: []const u8, version: ?[]const u8) !void {
        if (name.len == 0) return error.InvalidPackageName;

        var project = try loadProject(self.allocator);
        const dep_version = version orelse "latest";

        var deps: std.ArrayList(project_mod.Dependency) = .empty;
        errdefer deps.deinit(self.allocator);
        var found = false;
        for (project.dependencies) |dep| {
            if (std.mem.eql(u8, dep.name, name)) {
                try deps.append(self.allocator, .{ .name = name, .version = dep_version });
                found = true;
            } else {
                try deps.append(self.allocator, dep);
            }
        }
        if (!found) {
            try deps.append(self.allocator, .{ .name = name, .version = dep_version });
        }
        project.dependencies = try sortedUniqueDependencies(self.allocator, deps.items);
        try saveProject(self.allocator, project);
    }

    pub fn remove(self: *PackageManager, name: []const u8) !void {
        if (name.len == 0) return error.InvalidPackageName;
        var project = try loadProject(self.allocator);
        var deps: std.ArrayList(project_mod.Dependency) = .empty;
        errdefer deps.deinit(self.allocator);

        for (project.dependencies) |dep| {
            if (!std.mem.eql(u8, dep.name, name)) {
                try deps.append(self.allocator, dep);
            }
        }
        project.dependencies = try sortedUniqueDependencies(self.allocator, deps.items);
        try saveProject(self.allocator, project);
    }

    pub fn fetch(self: *PackageManager) !void {
        const project = try loadProject(self.allocator);
        try core.fs.ensureDir(".ovo/cache");

        var fetch_log: std.ArrayList(u8) = .empty;
        for (project.dependencies) |dep| {
            const dep_dir = try std.fmt.allocPrint(self.allocator, ".ovo/cache/{s}-{s}", .{ dep.name, dep.version });
            try core.fs.ensureDir(dep_dir);
            try core.fs.writeFile(
                try std.fmt.allocPrint(self.allocator, "{s}/manifest.txt", .{dep_dir}),
                try std.fmt.allocPrint(self.allocator, "name={s}\nversion={s}\nsource=registry\n", .{ dep.name, dep.version }),
            );
            try fetch_log.print(self.allocator, "fetched {s}@{s}\n", .{ dep.name, dep.version });
        }
        if (project.dependencies.len == 0) {
            try fetch_log.appendSlice(self.allocator, "no dependencies declared\n");
        }
        try core.fs.writeFile(".ovo/cache/fetch.log", fetch_log.items);
    }

    pub fn update(self: *PackageManager, name: ?[]const u8) !void {
        var project = try loadProject(self.allocator);
        if (name) |needle| {
            var changed = false;
            var deps: std.ArrayList(project_mod.Dependency) = .empty;
            errdefer deps.deinit(self.allocator);
            for (project.dependencies) |dep| {
                if (std.mem.eql(u8, dep.name, needle)) {
                    try deps.append(self.allocator, .{
                        .name = dep.name,
                        .version = "latest",
                    });
                    changed = true;
                } else {
                    try deps.append(self.allocator, dep);
                }
            }
            if (!changed) return error.DependencyNotFound;
            project.dependencies = try sortedUniqueDependencies(self.allocator, deps.items);
        } else {
            var deps: std.ArrayList(project_mod.Dependency) = .empty;
            errdefer deps.deinit(self.allocator);
            for (project.dependencies) |dep| {
                try deps.append(self.allocator, .{ .name = dep.name, .version = "latest" });
            }
            project.dependencies = try sortedUniqueDependencies(self.allocator, deps.items);
        }

        try saveProject(self.allocator, project);
    }

    pub fn lock(self: *PackageManager) !void {
        const project = try loadProject(self.allocator);
        var lock_data: std.ArrayList(u8) = .empty;
        defer lock_data.deinit(self.allocator);
        try lock_data.appendSlice(self.allocator, ".{\n");
        try lock_data.print(self.allocator, "    .project = \"{s}\",\n", .{project.name});
        try lock_data.print(self.allocator, "    .version = \"{s}\",\n", .{project.version});
        try lock_data.appendSlice(self.allocator, "    .dependencies = .{\n");
        for (project.dependencies) |dep| {
            try lock_data.print(self.allocator, "        .{s} = \"{s}\",\n", .{ dep.name, dep.version });
        }
        try lock_data.appendSlice(self.allocator, "    },\n");
        try lock_data.appendSlice(self.allocator, "}\n");
        try core.fs.writeFile("ovo.lock.zon", lock_data.items);
    }

    pub fn dependencySummary(self: *PackageManager) ![]const u8 {
        const project = try loadProject(self.allocator);
        if (project.dependencies.len == 0) return "no dependencies";

        const sorted = try sortedUniqueDependencies(self.allocator, project.dependencies);
        var output: std.ArrayList(u8) = .empty;
        for (sorted) |dep| {
            try output.print(self.allocator, "- {s}@{s}\n", .{ dep.name, dep.version });
        }
        return try output.toOwnedSlice(self.allocator);
    }
};

pub fn sortedUniqueDependencies(
    allocator: std.mem.Allocator,
    deps_input: []const project_mod.Dependency,
) ![]project_mod.Dependency {
    var deps: std.ArrayList(project_mod.Dependency) = .empty;
    errdefer deps.deinit(allocator);
    for (deps_input) |dep| {
        if (dep.name.len == 0) continue;
        try deps.append(allocator, dep);
    }
    insertionSortDependencies(deps.items);

    var unique: std.ArrayList(project_mod.Dependency) = .empty;
    errdefer unique.deinit(allocator);
    var i: usize = 0;
    while (i < deps.items.len) : (i += 1) {
        const dep = deps.items[i];
        if (i + 1 < deps.items.len and std.mem.eql(u8, dep.name, deps.items[i + 1].name)) {
            continue;
        }
        try unique.append(allocator, dep);
    }
    return try unique.toOwnedSlice(allocator);
}

pub fn insertionSortDependencies(items: []project_mod.Dependency) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j: usize = i;
        while (j > 0) {
            if (std.mem.order(u8, items[j - 1].name, key.name) == .gt) {
                items[j] = items[j - 1];
                j -= 1;
                continue;
            }
            break;
        }
        items[j] = key;
    }
}

fn loadProject(allocator: std.mem.Allocator) !project_mod.Project {
    const bytes = try core.fs.readFileAlloc(allocator, "build.zon");
    return zon.parser.parseBuildZon(allocator, bytes);
}

fn saveProject(allocator: std.mem.Allocator, project: project_mod.Project) !void {
    const rendered = try zon.writer.renderBuildZon(allocator, project);
    try core.fs.writeFile("build.zon", rendered);
}
