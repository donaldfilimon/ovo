//! Configuration merging for ovo package manager.
//!
//! Handles merging of workspace + member configurations and profile overrides.
//! Follows precedence: member > workspace > defaults, with profile on top.
const std = @import("std");
const schema = @import("schema.zig");

/// Merge strategy for collections.
pub const MergeStrategy = enum {
    /// Replace entirely with override.
    replace,
    /// Append override items to base.
    append,
    /// Prepend override items to base.
    prepend,
    /// Merge by name, override matching items.
    merge_by_name,
};

/// Options for merge operations.
pub const MergeOptions = struct {
    /// Strategy for merging arrays.
    array_strategy: MergeStrategy = .append,
    /// Strategy for merging defines.
    defines_strategy: MergeStrategy = .merge_by_name,
    /// Strategy for merging flags.
    flags_strategy: MergeStrategy = .append,
    /// Allow override to have null values that clear base values.
    allow_null_override: bool = false,
    /// Deep copy all strings (needed if override may be freed).
    deep_copy: bool = true,
};

/// Merge two Projects, with override taking precedence.
/// Used for workspace + member merging.
pub fn mergeProjects(
    allocator: std.mem.Allocator,
    base: *const schema.Project,
    override: *const schema.Project,
    options: MergeOptions,
) !schema.Project {
    var result = schema.Project{
        .name = undefined,
        .version = undefined,
        .targets = undefined,
    };

    // Override always wins for identity fields
    result.name = try copyString(allocator, override.name, options);
    errdefer allocator.free(result.name);

    result.version = try copyVersion(allocator, &override.version, options);
    errdefer result.version.deinit(allocator);

    // Optional metadata: override wins if present
    result.description = try mergeOptionalString(allocator, base.description, override.description, options);
    result.license = try mergeOptionalString(allocator, base.license, override.license, options);
    result.repository = try mergeOptionalString(allocator, base.repository, override.repository, options);
    result.homepage = try mergeOptionalString(allocator, base.homepage, override.homepage, options);
    result.documentation = try mergeOptionalString(allocator, base.documentation, override.documentation, options);
    result.min_ovo_version = try mergeOptionalString(allocator, base.min_ovo_version, override.min_ovo_version, options);

    // Merge string arrays
    result.authors = try mergeStringArrays(allocator, base.authors, override.authors, options);
    result.keywords = try mergeStringArrays(allocator, base.keywords, override.keywords, options);
    result.workspace_members = try mergeStringArrays(allocator, base.workspace_members, override.workspace_members, options);

    // Merge defaults
    result.defaults = try mergeDefaults(allocator, base.defaults, override.defaults, options);

    // Targets: override replaces base entirely (member defines its own targets)
    result.targets = try copyTargets(allocator, override.targets, options);
    errdefer {
        for (result.targets) |*t| t.deinit(allocator);
        allocator.free(result.targets);
    }

    // Merge dependencies
    result.dependencies = try mergeDependencies(allocator, base.dependencies, override.dependencies, options);

    // Tests, benchmarks, examples: override replaces
    if (override.tests) |tests| {
        result.tests = try copyTests(allocator, tests, options);
    } else if (base.tests) |tests| {
        result.tests = try copyTests(allocator, tests, options);
    }

    if (override.benchmarks) |benchmarks| {
        result.benchmarks = try copyBenchmarks(allocator, benchmarks, options);
    } else if (base.benchmarks) |benchmarks| {
        result.benchmarks = try copyBenchmarks(allocator, benchmarks, options);
    }

    if (override.examples) |examples| {
        result.examples = try copyExamples(allocator, examples, options);
    } else if (base.examples) |examples| {
        result.examples = try copyExamples(allocator, examples, options);
    }

    // Scripts: merge by name
    result.scripts = try mergeScripts(allocator, base.scripts, override.scripts, options);

    // Profiles: merge by name
    result.profiles = try mergeProfiles(allocator, base.profiles, override.profiles, options);

    // Cross targets: merge by name
    result.cross_targets = try mergeCrossTargets(allocator, base.cross_targets, override.cross_targets, options);

    // Features: merge by name
    result.features = try mergeFeatures(allocator, base.features, override.features, options);

    // Module settings
    result.modules = try mergeModuleSettings(allocator, base.modules, override.modules, options);

    return result;
}

/// Apply a profile to a project.
pub fn applyProfile(
    allocator: std.mem.Allocator,
    project: *schema.Project,
    profile_name: []const u8,
) !void {
    const profiles = project.profiles orelse return error.ProfileNotFound;

    // Find the profile
    var profile: ?*const schema.Profile = null;
    for (profiles) |*p| {
        if (std.mem.eql(u8, p.name, profile_name)) {
            profile = p;
            break;
        }
    }

    if (profile == null) return error.ProfileNotFound;
    const p = profile.?;

    // Handle inheritance
    if (p.inherits) |parent_name| {
        try applyProfile(allocator, project, parent_name);
    }

    // Apply profile settings to defaults
    if (project.defaults == null) {
        project.defaults = schema.Defaults{};
    }
    var defaults = &project.defaults.?;

    if (p.optimization) |opt| {
        defaults.optimization = opt;
    }
    if (p.cpp_standard) |cpp| {
        defaults.cpp_standard = cpp;
    }
    if (p.c_standard) |c| {
        defaults.c_standard = c;
    }

    // Merge profile defines into defaults
    if (p.defines) |profile_defs| {
        defaults.defines = try mergeDefineSpecs(
            allocator,
            defaults.defines,
            profile_defs,
            .{ .defines_strategy = .merge_by_name },
        );
    }

    // Merge profile flags into defaults
    if (p.flags) |profile_flags| {
        defaults.flags = try mergeFlagSpecs(
            allocator,
            defaults.flags,
            profile_flags,
            .{ .flags_strategy = .append },
        );
    }

    // Apply to all targets
    for (project.targets) |*target| {
        if (p.optimization) |opt| {
            if (target.optimization == null) {
                target.optimization = opt;
            }
        }
        if (p.cpp_standard) |cpp| {
            if (target.cpp_standard == null) {
                target.cpp_standard = cpp;
            }
        }
        if (p.c_standard) |c| {
            if (target.c_standard == null) {
                target.c_standard = c;
            }
        }

        // Merge defines
        if (p.defines) |profile_defs| {
            target.defines = try mergeDefineSpecs(
                allocator,
                target.defines,
                profile_defs,
                .{ .defines_strategy = .append },
            );
        }

        // Merge flags
        if (p.flags) |profile_flags| {
            target.flags = try mergeFlagSpecs(
                allocator,
                target.flags,
                profile_flags,
                .{ .flags_strategy = .append },
            );
        }
    }
}

/// Apply defaults to all targets that don't have explicit values.
pub fn applyDefaults(project: *schema.Project) void {
    const defaults = project.defaults orelse return;

    for (project.targets) |*target| {
        if (target.cpp_standard == null) {
            target.cpp_standard = defaults.cpp_standard;
        }
        if (target.c_standard == null) {
            target.c_standard = defaults.c_standard;
        }
        if (target.optimization == null) {
            target.optimization = defaults.optimization;
        }
    }
}

/// Resolve enabled features and apply their effects.
pub fn resolveFeatures(
    allocator: std.mem.Allocator,
    project: *schema.Project,
    enabled_features: []const []const u8,
) !void {
    const features = project.features orelse return;

    // Build set of enabled features (including defaults and implied)
    var enabled = std.StringHashMap(void).init(allocator);
    defer enabled.deinit();

    // Add defaults
    for (features) |*f| {
        if (f.default) {
            try enabled.put(f.name, {});
        }
    }

    // Add explicitly enabled
    for (enabled_features) |name| {
        try enabled.put(name, {});
    }

    // Resolve implies (iterate until stable)
    var changed = true;
    while (changed) {
        changed = false;
        for (features) |*f| {
            if (enabled.contains(f.name)) {
                if (f.implies) |implies| {
                    for (implies) |imp| {
                        if (!enabled.contains(imp)) {
                            try enabled.put(imp, {});
                            changed = true;
                        }
                    }
                }
            }
        }
    }

    // Check for conflicts
    for (features) |*f| {
        if (enabled.contains(f.name)) {
            if (f.conflicts) |conflicts| {
                for (conflicts) |conf| {
                    if (enabled.contains(conf)) {
                        return error.FeatureConflict;
                    }
                }
            }
        }
    }

    // Apply feature effects
    for (features) |*f| {
        if (!enabled.contains(f.name)) continue;

        // Add feature dependencies to project dependencies
        if (f.dependencies) |deps| {
            for (deps) |dep_name| {
                // Mark dependency as enabled (actual resolution happens later)
                _ = dep_name;
            }
        }

        // Add feature defines to defaults
        if (f.defines) |defs| {
            if (project.defaults == null) {
                project.defaults = schema.Defaults{};
            }
            project.defaults.?.defines = try mergeDefineSpecs(
                allocator,
                project.defaults.?.defines,
                defs,
                .{ .defines_strategy = .append },
            );
        }
    }

    // Filter targets by required features
    var valid_targets = std.ArrayList(schema.Target).init(allocator);
    errdefer valid_targets.deinit();

    for (project.targets) |target| {
        var keep = true;
        if (target.required_features) |required| {
            for (required) |req| {
                if (!enabled.contains(req)) {
                    keep = false;
                    break;
                }
            }
        }
        if (keep) {
            try valid_targets.append(target);
        }
    }

    // Replace targets (note: we don't free removed targets here,
    // that would need careful handling)
    if (valid_targets.items.len != project.targets.len) {
        allocator.free(project.targets);
        project.targets = try valid_targets.toOwnedSlice();
    }
}

/// Apply cross-compilation target settings.
pub fn applyCrossTarget(
    allocator: std.mem.Allocator,
    project: *schema.Project,
    target_name: []const u8,
) !void {
    const cross_targets = project.cross_targets orelse return error.CrossTargetNotFound;

    var cross: ?*const schema.CrossTarget = null;
    for (cross_targets) |*ct| {
        if (std.mem.eql(u8, ct.name, target_name)) {
            cross = ct;
            break;
        }
    }

    if (cross == null) return error.CrossTargetNotFound;
    const ct = cross.?;

    // Apply cross-target defines and flags to defaults
    if (project.defaults == null) {
        project.defaults = schema.Defaults{};
    }

    if (ct.defines) |defs| {
        project.defaults.?.defines = try mergeDefineSpecs(
            allocator,
            project.defaults.?.defines,
            defs,
            .{ .defines_strategy = .append },
        );
    }

    if (ct.flags) |flags| {
        project.defaults.?.flags = try mergeFlagSpecs(
            allocator,
            project.defaults.?.flags,
            flags,
            .{ .flags_strategy = .append },
        );
    }
}

// ============================================================================
// Internal merge helpers
// ============================================================================

fn copyString(allocator: std.mem.Allocator, str: []const u8, options: MergeOptions) ![]u8 {
    if (options.deep_copy) {
        return allocator.dupe(u8, str);
    }
    // Shallow copy not safe for owned strings
    return allocator.dupe(u8, str);
}

fn copyVersion(allocator: std.mem.Allocator, version: *const schema.Version, options: MergeOptions) !schema.Version {
    _ = options;
    var result = schema.Version{
        .major = version.major,
        .minor = version.minor,
        .patch = version.patch,
    };
    if (version.prerelease) |pre| {
        result.prerelease = try allocator.dupe(u8, pre);
    }
    if (version.build_metadata) |meta| {
        result.build_metadata = try allocator.dupe(u8, meta);
    }
    return result;
}

fn mergeOptionalString(
    allocator: std.mem.Allocator,
    base: ?[]const u8,
    override: ?[]const u8,
    options: MergeOptions,
) !?[]const u8 {
    if (override) |o| {
        return try copyString(allocator, o, options);
    }
    if (base) |b| {
        return try copyString(allocator, b, options);
    }
    return null;
}

fn mergeStringArrays(
    allocator: std.mem.Allocator,
    base: ?[]const []const u8,
    override: ?[]const []const u8,
    options: MergeOptions,
) !?[]const []const u8 {
    const base_arr = base orelse &[_][]const u8{};
    const override_arr = override orelse &[_][]const u8{};

    if (base_arr.len == 0 and override_arr.len == 0) return null;

    switch (options.array_strategy) {
        .replace => {
            if (override_arr.len == 0) {
                return try copyStringArray(allocator, base_arr);
            }
            return try copyStringArray(allocator, override_arr);
        },
        .append => {
            var result = std.ArrayList([]const u8).init(allocator);
            errdefer {
                for (result.items) |s| allocator.free(s);
                result.deinit();
            }
            for (base_arr) |s| {
                try result.append(try allocator.dupe(u8, s));
            }
            for (override_arr) |s| {
                try result.append(try allocator.dupe(u8, s));
            }
            return result.toOwnedSlice();
        },
        .prepend => {
            var result = std.ArrayList([]const u8).init(allocator);
            errdefer {
                for (result.items) |s| allocator.free(s);
                result.deinit();
            }
            for (override_arr) |s| {
                try result.append(try allocator.dupe(u8, s));
            }
            for (base_arr) |s| {
                try result.append(try allocator.dupe(u8, s));
            }
            return result.toOwnedSlice();
        },
        .merge_by_name => {
            // For string arrays, this is same as append with dedup
            var seen = std.StringHashMap(void).init(allocator);
            defer seen.deinit();

            var result = std.ArrayList([]const u8).init(allocator);
            errdefer {
                for (result.items) |s| allocator.free(s);
                result.deinit();
            }

            for (base_arr) |s| {
                if (!seen.contains(s)) {
                    try seen.put(s, {});
                    try result.append(try allocator.dupe(u8, s));
                }
            }
            for (override_arr) |s| {
                if (!seen.contains(s)) {
                    try seen.put(s, {});
                    try result.append(try allocator.dupe(u8, s));
                }
            }
            return result.toOwnedSlice();
        },
    }
}

fn copyStringArray(allocator: std.mem.Allocator, arr: []const []const u8) ![]const []const u8 {
    var result = try allocator.alloc([]const u8, arr.len);
    errdefer allocator.free(result);

    for (arr, 0..) |s, i| {
        result[i] = try allocator.dupe(u8, s);
    }
    return result;
}

fn mergeDefaults(
    allocator: std.mem.Allocator,
    base: ?schema.Defaults,
    override: ?schema.Defaults,
    options: MergeOptions,
) !?schema.Defaults {
    const b = base orelse schema.Defaults{};
    const o = override orelse schema.Defaults{};

    var result = schema.Defaults{
        .cpp_standard = o.cpp_standard orelse b.cpp_standard,
        .c_standard = o.c_standard orelse b.c_standard,
        .compiler = o.compiler orelse b.compiler,
        .optimization = o.optimization orelse b.optimization,
    };

    result.includes = try mergeIncludeSpecs(allocator, b.includes, o.includes, options);
    result.defines = try mergeDefineSpecs(allocator, b.defines, o.defines, options);
    result.flags = try mergeFlagSpecs(allocator, b.flags, o.flags, options);

    // Check if result is all empty
    if (result.cpp_standard == null and
        result.c_standard == null and
        result.compiler == null and
        result.optimization == null and
        result.includes == null and
        result.defines == null and
        result.flags == null)
    {
        return null;
    }

    return result;
}

fn mergeIncludeSpecs(
    allocator: std.mem.Allocator,
    base: ?[]schema.IncludeSpec,
    override: ?[]schema.IncludeSpec,
    options: MergeOptions,
) !?[]schema.IncludeSpec {
    _ = options;
    const base_arr = base orelse &[_]schema.IncludeSpec{};
    const override_arr = override orelse &[_]schema.IncludeSpec{};

    if (base_arr.len == 0 and override_arr.len == 0) return null;

    var result = std.ArrayList(schema.IncludeSpec).init(allocator);
    errdefer {
        for (result.items) |*i| i.deinit(allocator);
        result.deinit();
    }

    for (base_arr) |*inc| {
        try result.append(schema.IncludeSpec{
            .path = try allocator.dupe(u8, inc.path),
            .system = inc.system,
            .platform = inc.platform,
        });
    }
    for (override_arr) |*inc| {
        try result.append(schema.IncludeSpec{
            .path = try allocator.dupe(u8, inc.path),
            .system = inc.system,
            .platform = inc.platform,
        });
    }

    return result.toOwnedSlice();
}

fn mergeDefineSpecs(
    allocator: std.mem.Allocator,
    base: ?[]schema.DefineSpec,
    override: ?[]schema.DefineSpec,
    options: MergeOptions,
) !?[]schema.DefineSpec {
    const base_arr = base orelse &[_]schema.DefineSpec{};
    const override_arr = override orelse &[_]schema.DefineSpec{};

    if (base_arr.len == 0 and override_arr.len == 0) return null;

    switch (options.defines_strategy) {
        .replace => {
            if (override_arr.len > 0) {
                return try copyDefineSpecs(allocator, override_arr);
            }
            return try copyDefineSpecs(allocator, base_arr);
        },
        .merge_by_name => {
            var by_name = std.StringHashMap(schema.DefineSpec).init(allocator);
            defer by_name.deinit();

            // Add base
            for (base_arr) |*def| {
                try by_name.put(def.name, schema.DefineSpec{
                    .name = try allocator.dupe(u8, def.name),
                    .value = if (def.value) |v| try allocator.dupe(u8, v) else null,
                    .platform = def.platform,
                });
            }

            // Override with new values
            for (override_arr) |*def| {
                if (by_name.getPtr(def.name)) |existing| {
                    allocator.free(existing.name);
                    if (existing.value) |v| allocator.free(v);
                }
                try by_name.put(def.name, schema.DefineSpec{
                    .name = try allocator.dupe(u8, def.name),
                    .value = if (def.value) |v| try allocator.dupe(u8, v) else null,
                    .platform = def.platform,
                });
            }

            var result = std.ArrayList(schema.DefineSpec).init(allocator);
            var iter = by_name.valueIterator();
            while (iter.next()) |def| {
                try result.append(def.*);
            }

            return result.toOwnedSlice();
        },
        else => {
            // append/prepend
            var result = std.ArrayList(schema.DefineSpec).init(allocator);
            errdefer {
                for (result.items) |*d| d.deinit(allocator);
                result.deinit();
            }

            const first = if (options.defines_strategy == .prepend) override_arr else base_arr;
            const second = if (options.defines_strategy == .prepend) base_arr else override_arr;

            for (first) |*def| {
                try result.append(schema.DefineSpec{
                    .name = try allocator.dupe(u8, def.name),
                    .value = if (def.value) |v| try allocator.dupe(u8, v) else null,
                    .platform = def.platform,
                });
            }
            for (second) |*def| {
                try result.append(schema.DefineSpec{
                    .name = try allocator.dupe(u8, def.name),
                    .value = if (def.value) |v| try allocator.dupe(u8, v) else null,
                    .platform = def.platform,
                });
            }

            return result.toOwnedSlice();
        },
    }
}

fn copyDefineSpecs(allocator: std.mem.Allocator, specs: []const schema.DefineSpec) ![]schema.DefineSpec {
    var result = try allocator.alloc(schema.DefineSpec, specs.len);
    errdefer allocator.free(result);

    for (specs, 0..) |*spec, i| {
        result[i] = schema.DefineSpec{
            .name = try allocator.dupe(u8, spec.name),
            .value = if (spec.value) |v| try allocator.dupe(u8, v) else null,
            .platform = spec.platform,
        };
    }
    return result;
}

fn mergeFlagSpecs(
    allocator: std.mem.Allocator,
    base: ?[]schema.FlagSpec,
    override: ?[]schema.FlagSpec,
    options: MergeOptions,
) !?[]schema.FlagSpec {
    _ = options;
    const base_arr = base orelse &[_]schema.FlagSpec{};
    const override_arr = override orelse &[_]schema.FlagSpec{};

    if (base_arr.len == 0 and override_arr.len == 0) return null;

    var result = std.ArrayList(schema.FlagSpec).init(allocator);
    errdefer {
        for (result.items) |*f| f.deinit(allocator);
        result.deinit();
    }

    for (base_arr) |*flag| {
        try result.append(schema.FlagSpec{
            .flag = try allocator.dupe(u8, flag.flag),
            .platform = flag.platform,
            .compile_only = flag.compile_only,
            .link_only = flag.link_only,
        });
    }
    for (override_arr) |*flag| {
        try result.append(schema.FlagSpec{
            .flag = try allocator.dupe(u8, flag.flag),
            .platform = flag.platform,
            .compile_only = flag.compile_only,
            .link_only = flag.link_only,
        });
    }

    return result.toOwnedSlice();
}

fn copyTargets(allocator: std.mem.Allocator, targets: []const schema.Target, options: MergeOptions) ![]schema.Target {
    _ = options;
    var result = try allocator.alloc(schema.Target, targets.len);
    errdefer allocator.free(result);

    for (targets, 0..) |*target, i| {
        result[i] = try copyTarget(allocator, target);
    }
    return result;
}

fn copyTarget(allocator: std.mem.Allocator, target: *const schema.Target) !schema.Target {
    var result = schema.Target{
        .name = try allocator.dupe(u8, target.name),
        .target_type = target.target_type,
        .sources = undefined,
    };
    errdefer allocator.free(result.name);

    // Copy sources
    result.sources = try copySourceSpecs(allocator, target.sources);

    // Copy optional fields
    if (target.includes) |incs| {
        result.includes = try copyIncludeSpecs(allocator, incs);
    }
    if (target.defines) |defs| {
        result.defines = try copyDefineSpecs(allocator, defs);
    }
    if (target.flags) |flags| {
        result.flags = try copyFlagSpecs(allocator, flags);
    }
    if (target.link_libraries) |libs| {
        result.link_libraries = try copyStringArray(allocator, libs);
    }
    if (target.dependencies) |deps| {
        result.dependencies = try copyStringArray(allocator, deps);
    }
    if (target.output_name) |name| {
        result.output_name = try allocator.dupe(u8, name);
    }
    if (target.install_dir) |dir| {
        result.install_dir = try allocator.dupe(u8, dir);
    }
    if (target.required_features) |feats| {
        result.required_features = try copyStringArray(allocator, feats);
    }

    result.cpp_standard = target.cpp_standard;
    result.c_standard = target.c_standard;
    result.optimization = target.optimization;
    result.platform = target.platform;

    return result;
}

fn copySourceSpecs(allocator: std.mem.Allocator, specs: []const schema.SourceSpec) ![]schema.SourceSpec {
    var result = try allocator.alloc(schema.SourceSpec, specs.len);
    errdefer allocator.free(result);

    for (specs, 0..) |*spec, i| {
        result[i] = schema.SourceSpec{
            .pattern = try allocator.dupe(u8, spec.pattern),
            .platform = spec.platform,
        };
        if (spec.exclude) |excl| {
            result[i].exclude = try copyStringArray(allocator, excl);
        }
    }
    return result;
}

fn copyIncludeSpecs(allocator: std.mem.Allocator, specs: []const schema.IncludeSpec) ![]schema.IncludeSpec {
    var result = try allocator.alloc(schema.IncludeSpec, specs.len);
    errdefer allocator.free(result);

    for (specs, 0..) |*spec, i| {
        result[i] = schema.IncludeSpec{
            .path = try allocator.dupe(u8, spec.path),
            .system = spec.system,
            .platform = spec.platform,
        };
    }
    return result;
}

fn copyFlagSpecs(allocator: std.mem.Allocator, specs: []const schema.FlagSpec) ![]schema.FlagSpec {
    var result = try allocator.alloc(schema.FlagSpec, specs.len);
    errdefer allocator.free(result);

    for (specs, 0..) |*spec, i| {
        result[i] = schema.FlagSpec{
            .flag = try allocator.dupe(u8, spec.flag),
            .platform = spec.platform,
            .compile_only = spec.compile_only,
            .link_only = spec.link_only,
        };
    }
    return result;
}

fn mergeDependencies(
    allocator: std.mem.Allocator,
    base: ?[]schema.Dependency,
    override: ?[]schema.Dependency,
    options: MergeOptions,
) !?[]schema.Dependency {
    _ = options;
    const base_arr = base orelse &[_]schema.Dependency{};
    const override_arr = override orelse &[_]schema.Dependency{};

    if (base_arr.len == 0 and override_arr.len == 0) return null;

    // Merge by name
    var by_name = std.StringHashMap(*const schema.Dependency).init(allocator);
    defer by_name.deinit();

    for (base_arr) |*dep| {
        try by_name.put(dep.name, dep);
    }
    for (override_arr) |*dep| {
        try by_name.put(dep.name, dep);
    }

    var result = std.ArrayList(schema.Dependency).init(allocator);
    errdefer {
        for (result.items) |*d| d.deinit(allocator);
        result.deinit();
    }

    var iter = by_name.valueIterator();
    while (iter.next()) |dep_ptr| {
        try result.append(try copyDependency(allocator, dep_ptr.*));
    }

    return result.toOwnedSlice();
}

fn copyDependency(allocator: std.mem.Allocator, dep: *const schema.Dependency) !schema.Dependency {
    var result = schema.Dependency{
        .name = try allocator.dupe(u8, dep.name),
        .source = undefined,
    };

    // Copy source
    result.source = switch (dep.source) {
        .git => |git| .{
            .git = .{
                .url = try allocator.dupe(u8, git.url),
                .tag = if (git.tag) |t| try allocator.dupe(u8, t) else null,
                .branch = if (git.branch) |b| try allocator.dupe(u8, b) else null,
                .commit = if (git.commit) |c| try allocator.dupe(u8, c) else null,
            },
        },
        .url => |url| .{
            .url = .{
                .location = try allocator.dupe(u8, url.location),
                .hash = if (url.hash) |h| try allocator.dupe(u8, h) else null,
            },
        },
        .path => |path| .{ .path = try allocator.dupe(u8, path) },
        .vcpkg => |vcpkg| .{
            .vcpkg = .{
                .name = try allocator.dupe(u8, vcpkg.name),
                .version = if (vcpkg.version) |v| try allocator.dupe(u8, v) else null,
                .features = if (vcpkg.features) |f| try copyStringArray(allocator, f) else null,
            },
        },
        .conan => |conan| .{
            .conan = .{
                .name = try allocator.dupe(u8, conan.name),
                .version = try allocator.dupe(u8, conan.version),
                .options = if (conan.options) |o| try copyStringArray(allocator, o) else null,
            },
        },
        .system => |sys| .{
            .system = .{
                .name = try allocator.dupe(u8, sys.name),
                .fallback = null, // TODO: deep copy fallback
            },
        },
    };

    if (dep.feature) |f| result.feature = try allocator.dupe(u8, f);
    if (dep.build_options) |o| result.build_options = try copyStringArray(allocator, o);
    if (dep.components) |c| result.components = try copyStringArray(allocator, c);
    result.link_static = dep.link_static;

    return result;
}

fn copyTests(allocator: std.mem.Allocator, tests: []const schema.TestSpec, options: MergeOptions) ![]schema.TestSpec {
    _ = options;
    var result = try allocator.alloc(schema.TestSpec, tests.len);
    errdefer allocator.free(result);

    for (tests, 0..) |*t, i| {
        result[i] = schema.TestSpec{
            .name = try allocator.dupe(u8, t.name),
            .sources = try copySourceSpecs(allocator, t.sources),
        };
        if (t.dependencies) |d| result[i].dependencies = try copyStringArray(allocator, d);
        if (t.framework) |f| result[i].framework = try allocator.dupe(u8, f);
        if (t.args) |a| result[i].args = try copyStringArray(allocator, a);
        if (t.env) |e| result[i].env = try copyStringArray(allocator, e);
        if (t.working_dir) |w| result[i].working_dir = try allocator.dupe(u8, w);
        result[i].timeout = t.timeout;
    }
    return result;
}

fn copyBenchmarks(allocator: std.mem.Allocator, benchmarks: []const schema.BenchmarkSpec, options: MergeOptions) ![]schema.BenchmarkSpec {
    _ = options;
    var result = try allocator.alloc(schema.BenchmarkSpec, benchmarks.len);
    errdefer allocator.free(result);

    for (benchmarks, 0..) |*b, i| {
        result[i] = schema.BenchmarkSpec{
            .name = try allocator.dupe(u8, b.name),
            .sources = try copySourceSpecs(allocator, b.sources),
        };
        if (b.dependencies) |d| result[i].dependencies = try copyStringArray(allocator, d);
        if (b.framework) |f| result[i].framework = try allocator.dupe(u8, f);
        result[i].iterations = b.iterations;
        result[i].warmup = b.warmup;
    }
    return result;
}

fn copyExamples(allocator: std.mem.Allocator, examples: []const schema.ExampleSpec, options: MergeOptions) ![]schema.ExampleSpec {
    _ = options;
    var result = try allocator.alloc(schema.ExampleSpec, examples.len);
    errdefer allocator.free(result);

    for (examples, 0..) |*e, i| {
        result[i] = schema.ExampleSpec{
            .name = try allocator.dupe(u8, e.name),
            .sources = try copySourceSpecs(allocator, e.sources),
        };
        if (e.dependencies) |d| result[i].dependencies = try copyStringArray(allocator, d);
        if (e.description) |desc| result[i].description = try allocator.dupe(u8, desc);
    }
    return result;
}

fn mergeScripts(
    allocator: std.mem.Allocator,
    base: ?[]schema.ScriptSpec,
    override: ?[]schema.ScriptSpec,
    options: MergeOptions,
) !?[]schema.ScriptSpec {
    _ = options;
    const base_arr = base orelse &[_]schema.ScriptSpec{};
    const override_arr = override orelse &[_]schema.ScriptSpec{};

    if (base_arr.len == 0 and override_arr.len == 0) return null;

    var by_name = std.StringHashMap(*const schema.ScriptSpec).init(allocator);
    defer by_name.deinit();

    for (base_arr) |*s| try by_name.put(s.name, s);
    for (override_arr) |*s| try by_name.put(s.name, s);

    var result = std.ArrayList(schema.ScriptSpec).init(allocator);
    var iter = by_name.valueIterator();
    while (iter.next()) |s_ptr| {
        const s = s_ptr.*;
        try result.append(schema.ScriptSpec{
            .name = try allocator.dupe(u8, s.name),
            .command = try allocator.dupe(u8, s.command),
            .args = if (s.args) |a| try copyStringArray(allocator, a) else null,
            .env = if (s.env) |e| try copyStringArray(allocator, e) else null,
            .working_dir = if (s.working_dir) |w| try allocator.dupe(u8, w) else null,
            .hook = s.hook,
        });
    }

    return result.toOwnedSlice();
}

fn mergeProfiles(
    allocator: std.mem.Allocator,
    base: ?[]schema.Profile,
    override: ?[]schema.Profile,
    options: MergeOptions,
) !?[]schema.Profile {
    _ = options;
    const base_arr = base orelse &[_]schema.Profile{};
    const override_arr = override orelse &[_]schema.Profile{};

    if (base_arr.len == 0 and override_arr.len == 0) return null;

    var by_name = std.StringHashMap(*const schema.Profile).init(allocator);
    defer by_name.deinit();

    for (base_arr) |*p| try by_name.put(p.name, p);
    for (override_arr) |*p| try by_name.put(p.name, p);

    var result = std.ArrayList(schema.Profile).init(allocator);
    var iter = by_name.valueIterator();
    while (iter.next()) |p_ptr| {
        const p = p_ptr.*;
        var profile = schema.Profile{
            .name = try allocator.dupe(u8, p.name),
        };
        if (p.inherits) |i| profile.inherits = try allocator.dupe(u8, i);
        profile.optimization = p.optimization;
        profile.cpp_standard = p.cpp_standard;
        profile.c_standard = p.c_standard;
        if (p.defines) |d| profile.defines = try copyDefineSpecs(allocator, d);
        if (p.flags) |f| profile.flags = try copyFlagSpecs(allocator, f);
        if (p.sanitizers) |s| profile.sanitizers = try copyStringArray(allocator, s);
        profile.debug_info = p.debug_info;
        profile.lto = p.lto;
        profile.pic = p.pic;
        try result.append(profile);
    }

    return result.toOwnedSlice();
}

fn mergeCrossTargets(
    allocator: std.mem.Allocator,
    base: ?[]schema.CrossTarget,
    override: ?[]schema.CrossTarget,
    options: MergeOptions,
) !?[]schema.CrossTarget {
    _ = options;
    const base_arr = base orelse &[_]schema.CrossTarget{};
    const override_arr = override orelse &[_]schema.CrossTarget{};

    if (base_arr.len == 0 and override_arr.len == 0) return null;

    var by_name = std.StringHashMap(*const schema.CrossTarget).init(allocator);
    defer by_name.deinit();

    for (base_arr) |*ct| try by_name.put(ct.name, ct);
    for (override_arr) |*ct| try by_name.put(ct.name, ct);

    var result = std.ArrayList(schema.CrossTarget).init(allocator);
    var iter = by_name.valueIterator();
    while (iter.next()) |ct_ptr| {
        const ct = ct_ptr.*;
        var cross = schema.CrossTarget{
            .name = try allocator.dupe(u8, ct.name),
            .os = ct.os,
            .arch = ct.arch,
        };
        if (ct.toolchain) |t| cross.toolchain = try allocator.dupe(u8, t);
        if (ct.sysroot) |s| cross.sysroot = try allocator.dupe(u8, s);
        if (ct.defines) |d| cross.defines = try copyDefineSpecs(allocator, d);
        if (ct.flags) |f| cross.flags = try copyFlagSpecs(allocator, f);
        try result.append(cross);
    }

    return result.toOwnedSlice();
}

fn mergeFeatures(
    allocator: std.mem.Allocator,
    base: ?[]schema.Feature,
    override: ?[]schema.Feature,
    options: MergeOptions,
) !?[]schema.Feature {
    _ = options;
    const base_arr = base orelse &[_]schema.Feature{};
    const override_arr = override orelse &[_]schema.Feature{};

    if (base_arr.len == 0 and override_arr.len == 0) return null;

    var by_name = std.StringHashMap(*const schema.Feature).init(allocator);
    defer by_name.deinit();

    for (base_arr) |*f| try by_name.put(f.name, f);
    for (override_arr) |*f| try by_name.put(f.name, f);

    var result = std.ArrayList(schema.Feature).init(allocator);
    var iter = by_name.valueIterator();
    while (iter.next()) |f_ptr| {
        const f = f_ptr.*;
        var feature = schema.Feature{
            .name = try allocator.dupe(u8, f.name),
        };
        if (f.description) |d| feature.description = try allocator.dupe(u8, d);
        if (f.dependencies) |d| feature.dependencies = try copyStringArray(allocator, d);
        if (f.defines) |d| feature.defines = try copyDefineSpecs(allocator, d);
        feature.default = f.default;
        if (f.implies) |i| feature.implies = try copyStringArray(allocator, i);
        if (f.conflicts) |c| feature.conflicts = try copyStringArray(allocator, c);
        try result.append(feature);
    }

    return result.toOwnedSlice();
}

fn mergeModuleSettings(
    allocator: std.mem.Allocator,
    base: ?schema.ModuleSettings,
    override: ?schema.ModuleSettings,
    options: MergeOptions,
) !?schema.ModuleSettings {
    _ = options;
    const b = base orelse schema.ModuleSettings{};
    const o = override orelse schema.ModuleSettings{};

    if (!b.enabled and !o.enabled and
        b.interfaces == null and o.interfaces == null and
        b.partitions == null and o.partitions == null and
        b.cache_dir == null and o.cache_dir == null)
    {
        return null;
    }

    var result = schema.ModuleSettings{
        .enabled = o.enabled or b.enabled,
    };

    if (o.cache_dir) |cd| {
        result.cache_dir = try allocator.dupe(u8, cd);
    } else if (b.cache_dir) |cd| {
        result.cache_dir = try allocator.dupe(u8, cd);
    }

    if (o.interfaces) |ifaces| {
        result.interfaces = try copySourceSpecs(allocator, ifaces);
    } else if (b.interfaces) |ifaces| {
        result.interfaces = try copySourceSpecs(allocator, ifaces);
    }

    if (o.partitions) |parts| {
        result.partitions = try copySourceSpecs(allocator, parts);
    } else if (b.partitions) |parts| {
        result.partitions = try copySourceSpecs(allocator, parts);
    }

    return result;
}

test "merge string arrays - append" {
    const allocator = std.testing.allocator;

    const base = [_][]const u8{ "a", "b" };
    const override = [_][]const u8{ "c", "d" };

    const result = try mergeStringArrays(allocator, &base, &override, .{ .array_strategy = .append });
    defer {
        if (result) |r| {
            for (r) |s| allocator.free(s);
            allocator.free(r);
        }
    }

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 4), result.?.len);
    try std.testing.expectEqualStrings("a", result.?[0]);
    try std.testing.expectEqualStrings("d", result.?[3]);
}

test "merge defines - by name" {
    const allocator = std.testing.allocator;

    var base = [_]schema.DefineSpec{
        .{ .name = "DEBUG", .value = "1" },
        .{ .name = "FOO", .value = "bar" },
    };
    var override = [_]schema.DefineSpec{
        .{ .name = "DEBUG", .value = "0" }, // Override
        .{ .name = "NEW", .value = "val" }, // New
    };

    const result = try mergeDefineSpecs(allocator, &base, &override, .{ .defines_strategy = .merge_by_name });
    defer {
        if (result) |r| {
            for (r) |*d| d.deinit(allocator);
            allocator.free(r);
        }
    }

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 3), result.?.len);
}
