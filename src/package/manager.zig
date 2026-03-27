const std = @import("std");
const core = @import("../core/mod.zig");
const project_mod = @import("../core/project.zig");
const zon = @import("../zon/mod.zig");
const exec = @import("../core/exec.zig");
const source_spec = @import("source_spec.zig");
const registry_mod = @import("registry.zig");
const lockfile = @import("lockfile.zig");
const HttpClient = std.http.Client;
const Sha256 = std.crypto.hash.sha2.Sha256;

const cache_dir = ".ovo/cache";

pub const ResolvedDependency = struct {
    name: []const u8,
    requested: []const u8,
    origin: source_spec.DependencyOrigin,
    source: source_spec.SourceKind,
    url: []const u8 = "",
    ref: []const u8 = "",
    commit: []const u8 = "",
    sha256: []const u8 = "",
    path: []const u8 = "",
    cache_key: []const u8 = "",
    strip_prefix: []const u8 = "",
};

pub const PackageManager = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PackageManager {
        return .{ .allocator = allocator };
    }

    pub fn add(self: *PackageManager, name: []const u8, version: ?[]const u8) !void {
        try self.addWithSource(name, version, null);
    }

    pub fn addWithSource(
        self: *PackageManager,
        name: []const u8,
        requested: ?[]const u8,
        source: ?source_spec.SourceKind,
    ) !void {
        if (name.len == 0) return error.InvalidPackageName;

        const raw_value = requested orelse "latest";
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp = arena.allocator();

        const dep_value = if (source) |kind|
            try source_spec.canonicalSpec(kind, raw_value, temp)
        else
            try temp.dupe(u8, raw_value);

        var project = try loadProject(temp);
        var deps: std.ArrayList(project_mod.Dependency) = .empty;
        defer deps.deinit(temp);

        var found = false;
        for (project.dependencies) |dep| {
            if (std.mem.eql(u8, dep.name, name)) {
                try deps.append(temp, .{ .name = dep.name, .version = dep_value });
                found = true;
            } else {
                try deps.append(temp, dep);
            }
        }
        if (!found) {
            try deps.append(temp, .{ .name = name, .version = dep_value });
        }

        project.dependencies = try sortedUniqueDependencies(temp, deps.items);
        try saveProject(self.allocator, project);
    }

    pub fn remove(self: *PackageManager, name: []const u8) !void {
        if (name.len == 0) return error.InvalidPackageName;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp = arena.allocator();

        var project = try loadProject(temp);

        var deps: std.ArrayList(project_mod.Dependency) = .empty;
        defer deps.deinit(temp);
        for (project.dependencies) |dep| {
            if (!std.mem.eql(u8, dep.name, name)) {
                try deps.append(temp, dep);
            }
        }

        project.dependencies = try sortedUniqueDependencies(temp, deps.items);
        try saveProject(self.allocator, project);
    }

    pub fn fetch(self: *PackageManager, refresh: bool) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp = arena.allocator();

        const project = try loadProject(temp);
        const registry_entries = try registry_mod.loadManifest(temp);

        var resolved: std.ArrayList(ResolvedDependency) = .empty;
        defer resolved.deinit(temp);

        var lock_used = false;
        if (!refresh) {
            if (try maybeLoadValidLock(temp, project.dependencies, "ovo.lock.zon")) |from_lock| {
                resolved = from_lock;
                lock_used = true;
            }
        }

        if (!lock_used) {
            resolved = try resolveFromProject(temp, project.dependencies, registry_entries);
        }

        if (resolved.items.len == 0) {
            try core.fs.writeFile(".ovo/cache/fetch.log", "no dependencies declared\n");
            return;
        }

        try core.fs.ensureDir(cache_dir);
        var fetch_log: std.ArrayList(u8) = .empty;
        defer fetch_log.deinit(temp);

        for (resolved.items) |*dep| {
            switch (dep.source) {
                .git => {
                    const git_result = try fetchGitDependency(self.allocator, dep.*);
                    defer core.fs.removeTreeIfExists(git_result.source_dir) catch {};

                    dep.commit = try temp.dupe(u8, git_result.commit);
                    dep.cache_key = try cacheKeyForGit(temp, dep.url, dep.commit);
                    const target_dir = try cacheDir(temp, dep.cache_key);
                    try installDependencyContents(self.allocator, git_result.source_dir, target_dir);
                    try fetch_log.print(temp, "fetched {s} (git {s}) -> {s}\n", .{ dep.name, dep.commit, target_dir });
                },
                .tar => {
                    if (dep.sha256.len == 0) return error.MissingTarSha256;
                    dep.cache_key = try cacheKeyForTar(temp, dep.url, dep.sha256);
                    const target_dir = try cacheDir(temp, dep.cache_key);
                    try fetchTarDependency(self.allocator, dep.*, target_dir);
                    try fetch_log.print(temp, "fetched {s} (tar) -> {s}\n", .{ dep.name, target_dir });
                },
                .local => {
                    dep.cache_key = try cacheKeyForLocal(temp, dep.path);
                    const target_dir = try cacheDir(temp, dep.cache_key);
                    try fetchLocalDependency(self.allocator, dep.*, target_dir);
                    try fetch_log.print(temp, "fetched {s} (local) -> {s}\n", .{ dep.name, target_dir });
                },
                .registry => return error.InvalidDependencySource,
            }

            const manifest_path = try cacheManifestPath(temp, dep.cache_key);
            const manifest = try renderManifest(temp, dep.*);
            defer temp.free(manifest);
            try core.fs.writeFile(manifest_path, manifest);
        }

        if (refresh or !lock_used) {
            try writeLock(self.allocator, project, resolved.items);
        }

        if (refresh or !lock_used) {
            const msg = try std.fmt.allocPrint(temp, "{s} (lock updated)\n", .{fetch_log.items});
            defer temp.free(msg);
            try core.fs.writeFile(".ovo/cache/fetch.log", msg);
        } else {
            try core.fs.writeFile(".ovo/cache/fetch.log", fetch_log.items);
        }
    }

    pub fn update(self: *PackageManager, name: ?[]const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp = arena.allocator();

        const project = try loadProject(temp);
        const registry_entries = try registry_mod.loadManifest(temp);

        var deps: std.ArrayList(project_mod.Dependency) = .empty;
        defer deps.deinit(temp);

        if (name) |target| {
            var found = false;
            for (project.dependencies) |dep| {
                if (std.mem.eql(u8, dep.name, target)) {
                    found = true;
                    try deps.append(temp, .{ .name = dep.name, .version = try updatedVersion(temp, dep, registry_entries) });
                } else {
                    try deps.append(temp, dep);
                }
            }
            if (!found) return error.DependencyNotFound;
        } else {
            for (project.dependencies) |dep| {
                try deps.append(temp, .{ .name = dep.name, .version = try updatedVersion(temp, dep, registry_entries) });
            }
        }

        const final_deps = try sortedUniqueDependencies(temp, deps.items);
        var next = project;
        next.dependencies = final_deps;
        try saveProject(self.allocator, next);
    }

    pub fn lock(self: *PackageManager) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp = arena.allocator();

        const project = try loadProject(temp);
        const registry_entries = try registry_mod.loadManifest(temp);

        var resolved = try resolveFromProject(temp, project.dependencies, registry_entries);
        defer resolved.deinit(temp);

        const existing_lock = try parseExistingValidLock(temp, "ovo.lock.zon");

        for (resolved.items) |*dep| {
            if (dep.source == .git and dep.commit.len == 0) {
                if (existing_lock) |previous| {
                    if (lockfile.findDependency(previous, dep.name)) |locked| {
                        const identity_matches = locked.source == .git and
                            std.mem.eql(u8, locked.requested, dep.requested) and
                            std.mem.eql(u8, locked.url, dep.url) and
                            std.mem.eql(u8, locked.ref, dep.ref);
                        if (identity_matches) {
                            if (locked.commit.len > 0) dep.commit = locked.commit;
                            if (locked.cache_key.len > 0) dep.cache_key = locked.cache_key;
                        }
                    }
                }
            }

            if (dep.cache_key.len == 0) {
                dep.cache_key = switch (dep.source) {
                    .git => if (dep.commit.len > 0) try cacheKeyForGit(temp, dep.url, dep.commit) else "",
                    .tar => try cacheKeyForTar(temp, dep.url, dep.sha256),
                    .local => try cacheKeyForLocal(temp, dep.path),
                    .registry => "",
                };
            }
        }

        try writeLock(self.allocator, project, resolved.items);
    }

    pub fn dependencySummary(self: *PackageManager) ![]const u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp = arena.allocator();

        const project = try loadProject(temp);
        if (project.dependencies.len == 0) return "no dependencies";

        const sorted = try sortedUniqueDependencies(temp, project.dependencies);
        var output: std.ArrayList(u8) = .empty;
        for (sorted) |dep| {
            try output.print(self.allocator, "- {s}@{s}\n", .{ dep.name, dep.version });
        }
        return try output.toOwnedSlice(self.allocator);
    }
};

fn updatedVersion(
    allocator: std.mem.Allocator,
    dep: project_mod.Dependency,
    registry_entries: []const registry_mod.RegistryEntry,
) ![]const u8 {
    const spec = source_spec.classify(dep.version);
    if (spec.kind != .registry) return dep.version;
    if (registry_mod.resolveEntry(registry_entries, dep.name, dep.version)) |_| {
        return allocator.dupe(u8, "latest");
    }
    return allocator.dupe(u8, dep.version);
}

fn maybeLoadValidLock(
    allocator: std.mem.Allocator,
    project_deps: []const project_mod.Dependency,
    path: []const u8,
) !?std.ArrayList(ResolvedDependency) {
    if (!core.fs.fileExists(path)) return null;

    const bytes = try core.fs.readFileAlloc(allocator, path);
    defer allocator.free(bytes);
    const parsed = try lockfile.parseLockFile(allocator, bytes);
    defer if (parsed.dependencies.len > 0) allocator.free(parsed.dependencies);
    if (!lockfile.isValidSchema(parsed)) return null;
    if (parsed.dependencies.len != project_deps.len) return null;

    var locked: std.ArrayList(ResolvedDependency) = .empty;
    errdefer locked.deinit(allocator);

    for (project_deps) |dep| {
        const found = lockfile.findDependency(parsed, dep.name) orelse return null;
        if (!std.mem.eql(u8, found.requested, dep.version)) return null;
        if (found.source == .local) {
            if (found.path.len == 0) return null;
            if (!core.fs.fileExists(found.path)) return null;
        }

        try locked.append(allocator, .{
            .name = try allocator.dupe(u8, dep.name),
            .requested = try allocator.dupe(u8, found.requested),
            .origin = if (found.origin == .registry) .registry else .direct,
            .source = found.source,
            .url = try allocator.dupe(u8, found.url),
            .ref = try allocator.dupe(u8, found.ref),
            .commit = try allocator.dupe(u8, found.commit),
            .sha256 = try allocator.dupe(u8, found.sha256),
            .path = try allocator.dupe(u8, found.path),
            .cache_key = try allocator.dupe(u8, found.cache_key),
            .strip_prefix = try allocator.dupe(u8, found.strip_prefix),
        });
    }

    return locked;
}

fn parseExistingValidLock(
    allocator: std.mem.Allocator,
    path: []const u8,
) !?lockfile.LockFile {
    if (!core.fs.fileExists(path)) return null;

    const bytes = try core.fs.readFileAlloc(allocator, path);
    const parsed = try lockfile.parseLockFile(allocator, bytes);
    if (!lockfile.isValidSchema(parsed)) return null;
    return parsed;
}

fn resolveFromProject(
    allocator: std.mem.Allocator,
    deps: []const project_mod.Dependency,
    registry_entries: []const registry_mod.RegistryEntry,
) !std.ArrayList(ResolvedDependency) {
    var list: std.ArrayList(ResolvedDependency) = .empty;
    errdefer list.deinit(allocator);
    for (deps) |dep| {
        try list.append(allocator, try resolveSingle(allocator, dep, registry_entries));
    }
    return list;
}

fn resolveSingle(
    allocator: std.mem.Allocator,
    dep: project_mod.Dependency,
    registry_entries: []const registry_mod.RegistryEntry,
) !ResolvedDependency {
    const spec = source_spec.classify(dep.version);

    switch (spec.kind) {
        .registry => {
            const entry = registry_mod.resolveEntry(registry_entries, dep.name, dep.version) orelse return error.RegistryEntryNotFound;
            return switch (entry.source) {
                .git => .{
                    .name = try allocator.dupe(u8, dep.name),
                    .requested = try allocator.dupe(u8, dep.version),
                    .origin = .registry,
                    .source = .git,
                    .url = try allocator.dupe(u8, entry.url),
                    .ref = if (entry.ref.len > 0) try allocator.dupe(u8, entry.ref) else try allocator.dupe(u8, "HEAD"),
                    .strip_prefix = try allocator.dupe(u8, entry.strip_prefix),
                },
                .tar => .{
                    .name = try allocator.dupe(u8, dep.name),
                    .requested = try allocator.dupe(u8, dep.version),
                    .origin = .registry,
                    .source = .tar,
                    .url = try allocator.dupe(u8, entry.url),
                    .sha256 = try allocator.dupe(u8, entry.sha256),
                    .strip_prefix = try allocator.dupe(u8, entry.strip_prefix),
                },
                .local => .{
                    .name = try allocator.dupe(u8, dep.name),
                    .requested = try allocator.dupe(u8, dep.version),
                    .origin = .registry,
                    .source = .local,
                    .path = try allocator.dupe(u8, entry.path),
                },
                .registry => return error.InvalidDependencySource,
            };
        },
        .git => {
            const split = source_spec.splitGitRef(spec.request);
            return .{
                .name = try allocator.dupe(u8, dep.name),
                .requested = try allocator.dupe(u8, dep.version),
                .origin = .direct,
                .source = .git,
                .url = try allocator.dupe(u8, split.url),
                .ref = if (split.ref.len > 0) try allocator.dupe(u8, split.ref) else try allocator.dupe(u8, "HEAD"),
            };
        },
        .tar => return .{
            .name = try allocator.dupe(u8, dep.name),
            .requested = try allocator.dupe(u8, dep.version),
            .origin = .direct,
            .source = .tar,
            .url = try allocator.dupe(u8, spec.request),
        },
        .local => {
            const cwd = try core.fs.currentPathAlloc(allocator);
            defer allocator.free(cwd);
            const abs = try resolveAbsolutePath(allocator, cwd, spec.request);
            return .{
                .name = try allocator.dupe(u8, dep.name),
                .requested = try allocator.dupe(u8, dep.version),
                .origin = .direct,
                .source = .local,
                .path = abs,
            };
        },
    }
}

fn cacheKey(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var hasher = Sha256.init(.{});
    hasher.update(input);

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    var hex: [64]u8 = undefined;
    var i: usize = 0;
    var j: usize = 0;
    while (i < digest.len) : (i += 1) {
        _ = try std.fmt.bufPrint(hex[j .. j + 2], "{x:0>2}", .{digest[i]});
        j += 2;
    }
    return allocator.dupe(u8, hex[0..16]);
}

fn cacheKeyForGit(allocator: std.mem.Allocator, url: []const u8, commit: []const u8) ![]const u8 {
    const identity = try std.fmt.allocPrint(allocator, "git|{s}|{s}", .{ url, commit });
    defer allocator.free(identity);
    return cacheKey(allocator, identity);
}

fn cacheKeyForTar(allocator: std.mem.Allocator, url: []const u8, sha256: []const u8) ![]const u8 {
    const identity = try std.fmt.allocPrint(allocator, "tar|{s}|{s}", .{ url, sha256 });
    defer allocator.free(identity);
    return cacheKey(allocator, identity);
}

fn cacheKeyForLocal(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const identity = try std.fmt.allocPrint(allocator, "local|{s}", .{path});
    defer allocator.free(identity);
    return cacheKey(allocator, identity);
}

fn cacheDir(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    if (key.len == 0) return error.MissingCacheKey;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_dir, key });
}

fn cacheManifestPath(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const dir = try cacheDir(allocator, key);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/manifest.txt", .{dir});
}

const GitResult = struct {
    source_dir: []const u8,
    commit: []const u8,
};

fn fetchGitDependency(allocator: std.mem.Allocator, dep: ResolvedDependency) !GitResult {
    if (!exec.commandExists("git")) return error.MissingGit;

    const tmp_key = try cacheKeyForGit(allocator, dep.url, if (dep.ref.len > 0) dep.ref else "HEAD");
    const source_dir = try std.fmt.allocPrint(allocator, "{s}/.git-{s}", .{ cache_dir, tmp_key });
    try core.fs.removeTreeIfExists(source_dir);

    if (dep.ref.len > 0 and !std.mem.eql(u8, dep.ref, "HEAD")) {
        const branch_code = try exec.runQuiet(&.{ "git", "clone", "--depth", "1", "--branch", dep.ref, dep.url, source_dir });
        if (branch_code != 0) {
            const code = try exec.runQuiet(&.{ "git", "clone", "--depth", "1", dep.url, source_dir });
            if (code != 0) return error.GitCloneFailed;
            const checkout_code = try exec.runQuiet(&.{ "git", "-C", source_dir, "checkout", dep.ref });
            if (checkout_code != 0) return error.GitCheckoutFailed;
        }
    } else {
        const code = try exec.runQuiet(&.{ "git", "clone", "--depth", "1", dep.url, source_dir });
        if (code != 0) return error.GitCloneFailed;
    }

    const raw_commit = try runAndReadStdout(allocator, &.{ "git", "-C", source_dir, "rev-parse", "HEAD" });
    const commit = std.mem.trim(u8, raw_commit, " \t\r\n");
    if (commit.len == 0) return error.InvalidGitCommit;
    return .{ .source_dir = source_dir, .commit = commit };
}

fn fetchTarDependency(allocator: std.mem.Allocator, dep: ResolvedDependency, target_dir: []const u8) !void {
    if (dep.url.len == 0) return error.InvalidDependencySource;
    if (dep.sha256.len == 0) return error.MissingTarSha256;

    const tmp_key = try cacheKeyForTar(allocator, dep.url, dep.sha256);
    defer allocator.free(tmp_key);
    const download_path = try std.fmt.allocPrint(allocator, "{s}/.download-{s}", .{ cache_dir, tmp_key });
    defer core.fs.deleteFileIfExists(download_path) catch {};

    const extract_root = try std.fmt.allocPrint(allocator, "{s}/.extract-{s}", .{ cache_dir, tmp_key });
    defer core.fs.removeTreeIfExists(extract_root) catch {};

    try downloadToFile(allocator, dep.url, download_path);
    try verifySha256(allocator, download_path, dep.sha256);

    if (!std.mem.endsWith(u8, dep.url, ".zip")) {
        const code = try exec.runQuiet(&.{ "tar", "xzf", download_path, "-C", extract_root });
        if (code != 0) return error.TarExtractFailed;
    } else {
        const code = try exec.runQuiet(&.{ "unzip", "-q", download_path, "-d", extract_root });
        if (code != 0) return error.TarExtractFailed;
    }

    const source_root = if (dep.strip_prefix.len > 0)
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ extract_root, dep.strip_prefix })
    else
        try allocator.dupe(u8, extract_root);
    defer allocator.free(source_root);

    try installDependencyContents(allocator, source_root, target_dir);
}

fn fetchLocalDependency(allocator: std.mem.Allocator, dep: ResolvedDependency, target_dir: []const u8) !void {
    if (dep.path.len == 0 or !core.fs.fileExists(dep.path)) return error.MissingLocalPath;
    try installDependencyContents(allocator, dep.path, target_dir);
}

fn installDependencyContents(allocator: std.mem.Allocator, source: []const u8, target_dir: []const u8) !void {
    try core.fs.removeTreeIfExists(target_dir);
    const copy_source = try std.fmt.allocPrint(allocator, "{s}/.", .{source});
    defer allocator.free(copy_source);
    const code = try exec.runQuiet(&.{ "cp", "-R", copy_source, target_dir });
    if (code != 0) return error.DependencyCopyFailed;
}

fn writeLock(
    allocator: std.mem.Allocator,
    project: project_mod.Project,
    deps: []const ResolvedDependency,
) !void {
    var locked: std.ArrayList(lockfile.LockedDependency) = .empty;
    defer locked.deinit(allocator);

    for (deps) |dep| {
        var cache_key = dep.cache_key;
        if (cache_key.len == 0) {
            cache_key = switch (dep.source) {
                .git => if (dep.commit.len > 0) try cacheKeyForGit(allocator, dep.url, dep.commit) else "",
                .tar => if (dep.sha256.len > 0) try cacheKeyForTar(allocator, dep.url, dep.sha256) else "",
                .local => if (dep.path.len > 0) try cacheKeyForLocal(allocator, dep.path) else "",
                .registry => "",
            };
        }

        try locked.append(allocator, .{
            .name = dep.name,
            .requested = dep.requested,
            .origin = if (dep.origin == .registry) .registry else .direct,
            .source = dep.source,
            .url = dep.url,
            .ref = dep.ref,
            .commit = dep.commit,
            .sha256 = dep.sha256,
            .path = dep.path,
            .cache_key = cache_key,
            .strip_prefix = dep.strip_prefix,
        });
    }

    const rendered = try lockfile.renderLockFile(allocator, project.name, project.version, locked.items);
    defer allocator.free(rendered);
    try core.fs.writeFile("ovo.lock.zon", rendered);
}

fn renderManifest(allocator: std.mem.Allocator, dep: ResolvedDependency) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.print(allocator, "name={s}\n", .{dep.name});
    try out.print(allocator, "requested={s}\n", .{dep.requested});
    try out.print(allocator, "origin={s}\n", .{if (dep.origin == .registry) "registry" else "direct"});
    try out.print(allocator, "source={s}\n", .{source_spec.sourceLabel(dep.source)});
    try out.print(allocator, "url={s}\n", .{dep.url});
    try out.print(allocator, "ref={s}\n", .{dep.ref});
    try out.print(allocator, "commit={s}\n", .{dep.commit});
    try out.print(allocator, "sha256={s}\n", .{dep.sha256});
    try out.print(allocator, "path={s}\n", .{dep.path});
    try out.print(allocator, "cache_key={s}\n", .{dep.cache_key});
    if (dep.strip_prefix.len > 0) {
        try out.print(allocator, "strip_prefix={s}\n", .{dep.strip_prefix});
    }
    return try out.toOwnedSlice(allocator);
}

fn runAndReadStdout(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const captured = try exec.runCapture(allocator, argv);
    if (captured.code != 0) return error.CommandFailed;
    return captured.stdout;
}

fn downloadToFile(allocator: std.mem.Allocator, url: []const u8, destination: []const u8) !void {
    var client = HttpClient{ .allocator = allocator, .io = core.runtime.io() };
    defer client.deinit();

    const out_file = try std.Io.Dir.cwd().createFile(core.runtime.io(), destination, .{ .truncate = true });
    defer out_file.close(core.runtime.io());

    var out_buf: [4096]u8 = undefined;
    var out_writer = out_file.writer(core.runtime.io(), &out_buf);
    const result = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &out_writer.interface });
    if (result.status.class() != .success) return error.HttpDownloadFailed;
}

fn verifySha256(allocator: std.mem.Allocator, file_path: []const u8, expected_hex: []const u8) !void {
    if (expected_hex.len != 64) return error.ArchiveChecksumMismatch;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(core.runtime.io(), file_path, allocator, .unlimited);
    defer allocator.free(bytes);

    var hasher = Sha256.init(.{});
    hasher.update(bytes);

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    var computed: [64]u8 = undefined;
    var i: usize = 0;
    var j: usize = 0;
    while (i < digest.len) : (i += 1) {
        _ = try std.fmt.bufPrint(computed[j .. j + 2], "{x:0>2}", .{digest[i]});
        j += 2;
    }

    var normalized = try allocator.alloc(u8, expected_hex.len);
    defer allocator.free(normalized);
    for (expected_hex, 0..) |c, idx| {
        normalized[idx] = std.ascii.toLower(c);
    }

    if (!std.mem.eql(u8, computed[0..normalized.len], normalized)) return error.ArchiveChecksumMismatch;
}

fn resolveAbsolutePath(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    raw_path: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(raw_path)) return try allocator.dupe(u8, raw_path);
    return try std.fs.path.join(allocator, &.{ cwd, raw_path });
}

pub fn sortedUniqueDependencies(
    allocator: std.mem.Allocator,
    dependencies: []const project_mod.Dependency,
) ![]project_mod.Dependency {
    var list: std.ArrayList(project_mod.Dependency) = .empty;
    errdefer list.deinit(allocator);

    for (dependencies) |dep| {
        if (dep.name.len == 0) continue;
        try list.append(allocator, dep);
    }

    insertionSortDependencies(list.items);

    var unique: std.ArrayList(project_mod.Dependency) = .empty;
    defer unique.deinit(allocator);

    var i: usize = 0;
    while (i < list.items.len) : (i += 1) {
        const dep = list.items[i];
        if (i + 1 < list.items.len and std.mem.eql(u8, dep.name, list.items[i + 1].name)) continue;
        try unique.append(allocator, dep);
    }

    return try unique.toOwnedSlice(allocator);
}

pub fn computeCacheKeyForGit(
    allocator: std.mem.Allocator,
    url: []const u8,
    commit: []const u8,
) ![]const u8 {
    return cacheKeyForGit(allocator, url, commit);
}

pub fn computeCacheKeyForTar(
    allocator: std.mem.Allocator,
    url: []const u8,
    sha256: []const u8,
) ![]const u8 {
    return cacheKeyForTar(allocator, url, sha256);
}

pub fn computeCacheKeyForLocal(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]const u8 {
    return cacheKeyForLocal(allocator, path);
}

pub fn verifyArchiveSha256(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    expected_hex: []const u8,
) !void {
    return verifySha256(allocator, file_path, expected_hex);
}

pub fn insertionSortDependencies(items: []project_mod.Dependency) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const current = items[i];
        var j: usize = i;
        while (j > 0) {
            if (std.mem.order(u8, items[j - 1].name, current.name) == .gt) {
                items[j] = items[j - 1];
                j -= 1;
            } else {
                break;
            }
        }
        items[j] = current;
    }
}

fn loadProject(allocator: std.mem.Allocator) !project_mod.Project {
    const bytes = try core.fs.readFileAlloc(allocator, "build.zon");
    return zon.parser.parseBuildZon(allocator, bytes);
}

fn saveProject(allocator: std.mem.Allocator, project: project_mod.Project) !void {
    const rendered = try zon.writer.renderBuildZon(allocator, project);
    defer allocator.free(rendered);
    try core.fs.writeFile("build.zon", rendered);
}
