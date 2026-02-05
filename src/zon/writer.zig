//! ZON writer for generating build.zon files.
//!
//! Generates properly formatted build.zon files from Project model.
//! Used for scaffolding new projects, adding dependencies, and modifying configs.
const std = @import("std");
const schema = @import("schema.zig");

/// Writer configuration options.
pub const WriterOptions = struct {
    /// Indentation string (default: 4 spaces).
    indent: []const u8 = "    ",
    /// Include comments in output.
    include_comments: bool = true,
    /// Include empty/null optional fields.
    include_empty_optionals: bool = false,
    /// Sort fields alphabetically.
    sort_fields: bool = false,
};

/// Write a Project to a build.zon formatted string.
pub fn writeProject(allocator: std.mem.Allocator, project: *const schema.Project, options: WriterOptions) ![]u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();

    var writer = ZonWriter.init(&buffer, options);
    try writer.writeProjectImpl(project);

    return buffer.toOwnedSlice();
}

/// Write a Project to a file.
pub fn writeProjectToFile(project: *const schema.Project, path: []const u8, options: WriterOptions) !void {
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var buffered = std.io.bufferedWriter(file.writer());
    var writer = ZonWriter.initFile(&buffered, options);
    try writer.writeProjectImpl(project);
    try buffered.flush();
}

/// Internal ZON writer with state management.
pub const ZonWriter = struct {
    writer: Writer,
    options: WriterOptions,
    depth: usize,

    const Writer = union(enum) {
        array_list: *std.ArrayList(u8),
        file: *std.io.BufferedWriter(4096, std.fs.File.Writer),
    };

    pub fn init(buffer: *std.ArrayList(u8), options: WriterOptions) ZonWriter {
        return .{
            .writer = .{ .array_list = buffer },
            .options = options,
            .depth = 0,
        };
    }

    pub fn initFile(buffered: *std.io.BufferedWriter(4096, std.fs.File.Writer), options: WriterOptions) ZonWriter {
        return .{
            .writer = .{ .file = buffered },
            .options = options,
            .depth = 0,
        };
    }

    fn write(self: *ZonWriter, bytes: []const u8) !void {
        switch (self.writer) {
            .array_list => |al| try al.appendSlice(bytes),
            .file => |f| _ = try f.write(bytes),
        }
    }

    fn writeByte(self: *ZonWriter, byte: u8) !void {
        switch (self.writer) {
            .array_list => |al| try al.append(byte),
            .file => |f| _ = try f.write(&[_]u8{byte}),
        }
    }

    fn writeIndent(self: *ZonWriter) !void {
        for (0..self.depth) |_| {
            try self.write(self.options.indent);
        }
    }

    fn writeString(self: *ZonWriter, str: []const u8) !void {
        try self.writeByte('"');
        for (str) |c| {
            switch (c) {
                '"' => try self.write("\\\""),
                '\\' => try self.write("\\\\"),
                '\n' => try self.write("\\n"),
                '\r' => try self.write("\\r"),
                '\t' => try self.write("\\t"),
                else => try self.writeByte(c),
            }
        }
        try self.writeByte('"');
    }

    fn writeComment(self: *ZonWriter, comment: []const u8) !void {
        if (self.options.include_comments) {
            try self.writeIndent();
            try self.write("// ");
            try self.write(comment);
            try self.writeByte('\n');
        }
    }

    fn writeProjectImpl(self: *ZonWriter, project: *const schema.Project) !void {
        try self.write(".{\n");
        self.depth += 1;

        // Package metadata
        try self.writeComment("Package metadata");
        try self.writeField("name", project.name);
        try self.writeVersionField("version", &project.version);

        if (project.description) |desc| {
            try self.writeField("description", desc);
        }
        if (project.license) |license| {
            try self.writeField("license", license);
        }
        if (project.authors) |authors| {
            try self.writeStringArrayField("authors", authors);
        }
        if (project.repository) |repo| {
            try self.writeField("repository", repo);
        }
        if (project.homepage) |home| {
            try self.writeField("homepage", home);
        }
        if (project.documentation) |docs| {
            try self.writeField("documentation", docs);
        }
        if (project.keywords) |keywords| {
            try self.writeStringArrayField("keywords", keywords);
        }
        if (project.min_ovo_version) |ver| {
            try self.writeField("min_ovo_version", ver);
        }

        try self.writeByte('\n');

        // Defaults
        if (project.defaults) |*defaults| {
            try self.writeComment("Build defaults");
            try self.writeDefaults(defaults);
            try self.writeByte('\n');
        }

        // Targets
        try self.writeComment("Build targets");
        try self.writeTargets(project.targets);
        try self.writeByte('\n');

        // Dependencies
        if (project.dependencies) |deps| {
            try self.writeComment("Dependencies");
            try self.writeDependencies(deps);
            try self.writeByte('\n');
        }

        // Tests
        if (project.tests) |tests| {
            try self.writeComment("Tests");
            try self.writeTests(tests);
            try self.writeByte('\n');
        }

        // Benchmarks
        if (project.benchmarks) |benchmarks| {
            try self.writeComment("Benchmarks");
            try self.writeBenchmarks(benchmarks);
            try self.writeByte('\n');
        }

        // Examples
        if (project.examples) |examples| {
            try self.writeComment("Examples");
            try self.writeExamples(examples);
            try self.writeByte('\n');
        }

        // Scripts
        if (project.scripts) |scripts| {
            try self.writeComment("Scripts and hooks");
            try self.writeScripts(scripts);
            try self.writeByte('\n');
        }

        // Profiles
        if (project.profiles) |profiles| {
            try self.writeComment("Build profiles");
            try self.writeProfiles(profiles);
            try self.writeByte('\n');
        }

        // Cross-compilation targets
        if (project.cross_targets) |cross| {
            try self.writeComment("Cross-compilation targets");
            try self.writeCrossTargets(cross);
            try self.writeByte('\n');
        }

        // Features
        if (project.features) |features| {
            try self.writeComment("Optional features");
            try self.writeFeatures(features);
            try self.writeByte('\n');
        }

        // Module settings
        if (project.modules) |*modules| {
            try self.writeComment("C++20 module settings");
            try self.writeModuleSettings(modules);
            try self.writeByte('\n');
        }

        // Workspace members
        if (project.workspace_members) |members| {
            try self.writeComment("Workspace members");
            try self.writeStringArrayField("workspace_members", members);
            try self.writeByte('\n');
        }

        self.depth -= 1;
        try self.write("}\n");
    }

    fn writeField(self: *ZonWriter, name: []const u8, value: []const u8) !void {
        try self.writeIndent();
        try self.write(".");
        try self.write(name);
        try self.write(" = ");
        try self.writeString(value);
        try self.write(",\n");
    }

    fn writeVersionField(self: *ZonWriter, name: []const u8, version: *const schema.Version) !void {
        try self.writeIndent();
        try self.write(".");
        try self.write(name);
        try self.write(" = \"");

        // Write version components
        var buf: [64]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{
            version.major,
            version.minor,
            version.patch,
        }) catch return;
        try self.write(buf[0..len]);

        if (version.prerelease) |pre| {
            try self.write("-");
            try self.write(pre);
        }
        if (version.build_metadata) |meta| {
            try self.write("+");
            try self.write(meta);
        }

        try self.write("\",\n");
    }

    fn writeBoolField(self: *ZonWriter, name: []const u8, value: bool) !void {
        try self.writeIndent();
        try self.write(".");
        try self.write(name);
        try self.write(" = ");
        try self.write(if (value) "true" else "false");
        try self.write(",\n");
    }

    fn writeU32Field(self: *ZonWriter, name: []const u8, value: u32) !void {
        try self.writeIndent();
        try self.write(".");
        try self.write(name);
        try self.write(" = ");
        var buf: [16]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
        try self.write(buf[0..len]);
        try self.write(",\n");
    }

    fn writeStringArrayField(self: *ZonWriter, name: []const u8, values: []const []const u8) !void {
        try self.writeIndent();
        try self.write(".");
        try self.write(name);
        try self.write(" = .{\n");
        self.depth += 1;

        for (values) |value| {
            try self.writeIndent();
            try self.writeString(value);
            try self.write(",\n");
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }

    fn writeDefaults(self: *ZonWriter, defaults: *const schema.Defaults) !void {
        try self.writeIndent();
        try self.write(".defaults = .{\n");
        self.depth += 1;

        if (defaults.cpp_standard) |cpp| {
            try self.writeField("cpp_standard", cpp.toString());
        }
        if (defaults.c_standard) |c| {
            try self.writeField("c_standard", c.toString());
        }
        if (defaults.compiler) |comp| {
            try self.writeField("compiler", comp.toString());
        }
        if (defaults.optimization) |opt| {
            try self.writeField("optimization", opt.toString());
        }
        if (defaults.includes) |incs| {
            try self.writeIncludeSpecs("includes", incs);
        }
        if (defaults.defines) |defs| {
            try self.writeDefineSpecs("defines", defs);
        }
        if (defaults.flags) |flags| {
            try self.writeFlagSpecs("flags", flags);
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }

    fn writeTargets(self: *ZonWriter, targets: []const schema.Target) !void {
        try self.writeIndent();
        try self.write(".targets = .{\n");
        self.depth += 1;

        for (targets) |*target| {
            try self.writeTarget(target);
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }

    fn writeTarget(self: *ZonWriter, target: *const schema.Target) !void {
        try self.writeIndent();
        try self.write(".{\n");
        self.depth += 1;

        try self.writeField("name", target.name);
        try self.writeField("type", target.target_type.toString());

        // Sources
        try self.writeSourceSpecs("sources", target.sources);

        // Optional fields
        if (target.includes) |incs| {
            try self.writeIncludeSpecs("includes", incs);
        }
        if (target.defines) |defs| {
            try self.writeDefineSpecs("defines", defs);
        }
        if (target.flags) |flags| {
            try self.writeFlagSpecs("flags", flags);
        }
        if (target.link_libraries) |libs| {
            try self.writeStringArrayField("link_libraries", libs);
        }
        if (target.dependencies) |deps| {
            try self.writeStringArrayField("dependencies", deps);
        }
        if (target.cpp_standard) |cpp| {
            try self.writeField("cpp_standard", cpp.toString());
        }
        if (target.c_standard) |c| {
            try self.writeField("c_standard", c.toString());
        }
        if (target.optimization) |opt| {
            try self.writeField("optimization", opt.toString());
        }
        if (target.output_name) |name| {
            try self.writeField("output_name", name);
        }
        if (target.install_dir) |dir| {
            try self.writeField("install_dir", dir);
        }
        if (target.required_features) |feats| {
            try self.writeStringArrayField("required_features", feats);
        }
        if (target.platform) |*plat| {
            try self.writePlatformFilter("platform", plat);
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }

    fn writeSourceSpecs(self: *ZonWriter, name: []const u8, sources: []const schema.SourceSpec) !void {
        try self.writeIndent();
        try self.write(".");
        try self.write(name);
        try self.write(" = .{\n");
        self.depth += 1;

        for (sources) |*source| {
            if (source.exclude == null and source.platform == null) {
                // Simple string form
                try self.writeIndent();
                try self.writeString(source.pattern);
                try self.write(",\n");
            } else {
                // Full struct form
                try self.writeIndent();
                try self.write(".{\n");
                self.depth += 1;

                try self.writeField("pattern", source.pattern);
                if (source.exclude) |excl| {
                    try self.writeStringArrayField("exclude", excl);
                }
                if (source.platform) |*plat| {
                    try self.writePlatformFilter("platform", plat);
                }

                self.depth -= 1;
                try self.writeIndent();
                try self.write("},\n");
            }
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }

    fn writeIncludeSpecs(self: *ZonWriter, name: []const u8, includes: []const schema.IncludeSpec) !void {
        try self.writeIndent();
        try self.write(".");
        try self.write(name);
        try self.write(" = .{\n");
        self.depth += 1;

        for (includes) |*inc| {
            if (!inc.system and inc.platform == null) {
                try self.writeIndent();
                try self.writeString(inc.path);
                try self.write(",\n");
            } else {
                try self.writeIndent();
                try self.write(".{\n");
                self.depth += 1;

                try self.writeField("path", inc.path);
                if (inc.system) {
                    try self.writeBoolField("system", true);
                }
                if (inc.platform) |*plat| {
                    try self.writePlatformFilter("platform", plat);
                }

                self.depth -= 1;
                try self.writeIndent();
                try self.write("},\n");
            }
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }

    fn writeDefineSpecs(self: *ZonWriter, name: []const u8, defines: []const schema.DefineSpec) !void {
        try self.writeIndent();
        try self.write(".");
        try self.write(name);
        try self.write(" = .{\n");
        self.depth += 1;

        for (defines) |*def| {
            if (def.platform == null) {
                try self.writeIndent();
                if (def.value) |val| {
                    try self.writeString(def.name);
                    // Actually we need to write "NAME=VALUE" as single string
                    // Let's write as struct instead for clarity
                    try self.write(",\n");
                    _ = val;
                } else {
                    try self.writeString(def.name);
                    try self.write(",\n");
                }
            } else {
                try self.writeIndent();
                try self.write(".{\n");
                self.depth += 1;

                try self.writeField("name", def.name);
                if (def.value) |val| {
                    try self.writeField("value", val);
                }
                if (def.platform) |*plat| {
                    try self.writePlatformFilter("platform", plat);
                }

                self.depth -= 1;
                try self.writeIndent();
                try self.write("},\n");
            }
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }

    fn writeFlagSpecs(self: *ZonWriter, name: []const u8, flags: []const schema.FlagSpec) !void {
        try self.writeIndent();
        try self.write(".");
        try self.write(name);
        try self.write(" = .{\n");
        self.depth += 1;

        for (flags) |*flag| {
            if (!flag.compile_only and !flag.link_only and flag.platform == null) {
                try self.writeIndent();
                try self.writeString(flag.flag);
                try self.write(",\n");
            } else {
                try self.writeIndent();
                try self.write(".{\n");
                self.depth += 1;

                try self.writeField("flag", flag.flag);
                if (flag.compile_only) {
                    try self.writeBoolField("compile_only", true);
                }
                if (flag.link_only) {
                    try self.writeBoolField("link_only", true);
                }
                if (flag.platform) |*plat| {
                    try self.writePlatformFilter("platform", plat);
                }

                self.depth -= 1;
                try self.writeIndent();
                try self.write("},\n");
            }
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }

    fn writePlatformFilter(self: *ZonWriter, name: []const u8, filter: *const schema.PlatformFilter) !void {
        try self.writeIndent();
        try self.write(".");
        try self.write(name);
        try self.write(" = .{\n");
        self.depth += 1;

        if (filter.os) |os| {
            try self.writeField("os", @tagName(os));
        }
        if (filter.arch) |arch| {
            try self.writeField("arch", @tagName(arch));
        }
        if (filter.compiler) |comp| {
            try self.writeField("compiler", comp.toString());
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }

    fn writeDependencies(self: *ZonWriter, deps: []const schema.Dependency) !void {
        try self.writeIndent();
        try self.write(".dependencies = .{\n");
        self.depth += 1;

        for (deps) |*dep| {
            try self.writeDependency(dep);
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }

    fn writeDependency(self: *ZonWriter, dep: *const schema.Dependency) !void {
        try self.writeIndent();
        try self.write(".{\n");
        self.depth += 1;

        try self.writeField("name", dep.name);

        switch (dep.source) {
            .git => |git| {
                try self.writeIndent();
                try self.write(".git = .{\n");
                self.depth += 1;

                try self.writeField("url", git.url);
                if (git.tag) |tag| {
                    try self.writeField("tag", tag);
                }
                if (git.branch) |branch| {
                    try self.writeField("branch", branch);
                }
                if (git.commit) |commit| {
                    try self.writeField("commit", commit);
                }

                self.depth -= 1;
                try self.writeIndent();
                try self.write("},\n");
            },
            .url => |url| {
                try self.writeIndent();
                try self.write(".url = .{\n");
                self.depth += 1;

                try self.writeField("location", url.location);
                if (url.hash) |hash| {
                    try self.writeField("hash", hash);
                }

                self.depth -= 1;
                try self.writeIndent();
                try self.write("},\n");
            },
            .path => |path| {
                try self.writeIndent();
                try self.write(".path = ");
                try self.writeString(path);
                try self.write(",\n");
            },
            .vcpkg => |vcpkg| {
                try self.writeIndent();
                try self.write(".vcpkg = .{\n");
                self.depth += 1;

                try self.writeField("name", vcpkg.name);
                if (vcpkg.version) |ver| {
                    try self.writeField("version", ver);
                }
                if (vcpkg.features) |feats| {
                    try self.writeStringArrayField("features", feats);
                }

                self.depth -= 1;
                try self.writeIndent();
                try self.write("},\n");
            },
            .conan => |conan| {
                try self.writeIndent();
                try self.write(".conan = .{\n");
                self.depth += 1;

                try self.writeField("name", conan.name);
                try self.writeField("version", conan.version);
                if (conan.options) |opts| {
                    try self.writeStringArrayField("options", opts);
                }

                self.depth -= 1;
                try self.writeIndent();
                try self.write("},\n");
            },
            .system => |sys| {
                try self.writeIndent();
                try self.write(".system = ");
                try self.writeString(sys.name);
                try self.write(",\n");
            },
        }

        if (dep.feature) |feat| {
            try self.writeField("feature", feat);
        }
        if (dep.build_options) |opts| {
            try self.writeStringArrayField("build_options", opts);
        }
        if (dep.components) |comps| {
            try self.writeStringArrayField("components", comps);
        }
        if (dep.link_static) |static| {
            try self.writeBoolField("link_static", static);
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }

    fn writeTests(self: *ZonWriter, tests: []const schema.TestSpec) !void {
        try self.writeIndent();
        try self.write(".tests = .{\n");
        self.depth += 1;

        for (tests) |*t| {
            try self.writeIndent();
            try self.write(".{\n");
            self.depth += 1;

            try self.writeField("name", t.name);
            try self.writeSourceSpecs("sources", t.sources);

            if (t.dependencies) |deps| {
                try self.writeStringArrayField("dependencies", deps);
            }
            if (t.framework) |fw| {
                try self.writeField("framework", fw);
            }
            if (t.args) |args| {
                try self.writeStringArrayField("args", args);
            }
            if (t.env) |env| {
                try self.writeStringArrayField("env", env);
            }
            if (t.working_dir) |wd| {
                try self.writeField("working_dir", wd);
            }
            if (t.timeout) |to| {
                try self.writeU32Field("timeout", to);
            }

            self.depth -= 1;
            try self.writeIndent();
            try self.write("},\n");
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }

    fn writeBenchmarks(self: *ZonWriter, benchmarks: []const schema.BenchmarkSpec) !void {
        try self.writeIndent();
        try self.write(".benchmarks = .{\n");
        self.depth += 1;

        for (benchmarks) |*b| {
            try self.writeIndent();
            try self.write(".{\n");
            self.depth += 1;

            try self.writeField("name", b.name);
            try self.writeSourceSpecs("sources", b.sources);

            if (b.dependencies) |deps| {
                try self.writeStringArrayField("dependencies", deps);
            }
            if (b.framework) |fw| {
                try self.writeField("framework", fw);
            }
            if (b.iterations) |iter| {
                try self.writeU32Field("iterations", iter);
            }
            if (b.warmup) |wu| {
                try self.writeU32Field("warmup", wu);
            }

            self.depth -= 1;
            try self.writeIndent();
            try self.write("},\n");
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }

    fn writeExamples(self: *ZonWriter, examples: []const schema.ExampleSpec) !void {
        try self.writeIndent();
        try self.write(".examples = .{\n");
        self.depth += 1;

        for (examples) |*e| {
            try self.writeIndent();
            try self.write(".{\n");
            self.depth += 1;

            try self.writeField("name", e.name);
            try self.writeSourceSpecs("sources", e.sources);

            if (e.dependencies) |deps| {
                try self.writeStringArrayField("dependencies", deps);
            }
            if (e.description) |desc| {
                try self.writeField("description", desc);
            }

            self.depth -= 1;
            try self.writeIndent();
            try self.write("},\n");
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }

    fn writeScripts(self: *ZonWriter, scripts: []const schema.ScriptSpec) !void {
        try self.writeIndent();
        try self.write(".scripts = .{\n");
        self.depth += 1;

        for (scripts) |*s| {
            try self.writeIndent();
            try self.write(".{\n");
            self.depth += 1;

            try self.writeField("name", s.name);
            try self.writeField("command", s.command);

            if (s.args) |args| {
                try self.writeStringArrayField("args", args);
            }
            if (s.env) |env| {
                try self.writeStringArrayField("env", env);
            }
            if (s.working_dir) |wd| {
                try self.writeField("working_dir", wd);
            }
            if (s.hook) |hook| {
                try self.writeField("hook", @tagName(hook));
            }

            self.depth -= 1;
            try self.writeIndent();
            try self.write("},\n");
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }

    fn writeProfiles(self: *ZonWriter, profiles: []const schema.Profile) !void {
        try self.writeIndent();
        try self.write(".profiles = .{\n");
        self.depth += 1;

        for (profiles) |*p| {
            try self.writeIndent();
            try self.write(".{\n");
            self.depth += 1;

            try self.writeField("name", p.name);

            if (p.inherits) |inh| {
                try self.writeField("inherits", inh);
            }
            if (p.optimization) |opt| {
                try self.writeField("optimization", opt.toString());
            }
            if (p.cpp_standard) |cpp| {
                try self.writeField("cpp_standard", cpp.toString());
            }
            if (p.c_standard) |c| {
                try self.writeField("c_standard", c.toString());
            }
            if (p.defines) |defs| {
                try self.writeDefineSpecs("defines", defs);
            }
            if (p.flags) |flags| {
                try self.writeFlagSpecs("flags", flags);
            }
            if (p.sanitizers) |sans| {
                try self.writeStringArrayField("sanitizers", sans);
            }
            if (p.debug_info) |di| {
                try self.writeBoolField("debug_info", di);
            }
            if (p.lto) |lto| {
                try self.writeBoolField("lto", lto);
            }
            if (p.pic) |pic| {
                try self.writeBoolField("pic", pic);
            }

            self.depth -= 1;
            try self.writeIndent();
            try self.write("},\n");
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }

    fn writeCrossTargets(self: *ZonWriter, targets: []const schema.CrossTarget) !void {
        try self.writeIndent();
        try self.write(".cross_targets = .{\n");
        self.depth += 1;

        for (targets) |*t| {
            try self.writeIndent();
            try self.write(".{\n");
            self.depth += 1;

            try self.writeField("name", t.name);
            try self.writeField("os", @tagName(t.os));
            try self.writeField("arch", @tagName(t.arch));

            if (t.toolchain) |tc| {
                try self.writeField("toolchain", tc);
            }
            if (t.sysroot) |sr| {
                try self.writeField("sysroot", sr);
            }
            if (t.defines) |defs| {
                try self.writeDefineSpecs("defines", defs);
            }
            if (t.flags) |flags| {
                try self.writeFlagSpecs("flags", flags);
            }

            self.depth -= 1;
            try self.writeIndent();
            try self.write("},\n");
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }

    fn writeFeatures(self: *ZonWriter, features: []const schema.Feature) !void {
        try self.writeIndent();
        try self.write(".features = .{\n");
        self.depth += 1;

        for (features) |*f| {
            try self.writeIndent();
            try self.write(".{\n");
            self.depth += 1;

            try self.writeField("name", f.name);

            if (f.description) |desc| {
                try self.writeField("description", desc);
            }
            if (f.dependencies) |deps| {
                try self.writeStringArrayField("dependencies", deps);
            }
            if (f.defines) |defs| {
                try self.writeDefineSpecs("defines", defs);
            }
            if (f.default) {
                try self.writeBoolField("default", true);
            }
            if (f.implies) |imp| {
                try self.writeStringArrayField("implies", imp);
            }
            if (f.conflicts) |conf| {
                try self.writeStringArrayField("conflicts", conf);
            }

            self.depth -= 1;
            try self.writeIndent();
            try self.write("},\n");
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }

    fn writeModuleSettings(self: *ZonWriter, modules: *const schema.ModuleSettings) !void {
        try self.writeIndent();
        try self.write(".modules = .{\n");
        self.depth += 1;

        try self.writeBoolField("enabled", modules.enabled);

        if (modules.interfaces) |ifaces| {
            try self.writeSourceSpecs("interfaces", ifaces);
        }
        if (modules.partitions) |parts| {
            try self.writeSourceSpecs("partitions", parts);
        }
        if (modules.cache_dir) |cd| {
            try self.writeField("cache_dir", cd);
        }

        self.depth -= 1;
        try self.writeIndent();
        try self.write("},\n");
    }
};

/// Create a minimal project template.
pub fn createMinimalTemplate(allocator: std.mem.Allocator, name: []const u8) !schema.Project {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    const version = schema.Version{ .major = 0, .minor = 1, .patch = 0 };

    var sources = try allocator.alloc(schema.SourceSpec, 1);
    errdefer allocator.free(sources);
    sources[0] = schema.SourceSpec{
        .pattern = try allocator.dupe(u8, "src/**/*.cpp"),
    };

    var targets = try allocator.alloc(schema.Target, 1);
    errdefer {
        for (targets) |*t| t.deinit(allocator);
        allocator.free(targets);
    }
    targets[0] = schema.Target{
        .name = try allocator.dupe(u8, name),
        .target_type = .executable,
        .sources = sources,
    };

    return schema.Project{
        .name = owned_name,
        .version = version,
        .targets = targets,
    };
}

/// Create a library project template.
pub fn createLibraryTemplate(allocator: std.mem.Allocator, name: []const u8, static: bool) !schema.Project {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    const version = schema.Version{ .major = 0, .minor = 1, .patch = 0 };

    var sources = try allocator.alloc(schema.SourceSpec, 1);
    errdefer allocator.free(sources);
    sources[0] = schema.SourceSpec{
        .pattern = try allocator.dupe(u8, "src/**/*.cpp"),
    };

    var includes = try allocator.alloc(schema.IncludeSpec, 1);
    errdefer allocator.free(includes);
    includes[0] = schema.IncludeSpec{
        .path = try allocator.dupe(u8, "include"),
    };

    var targets = try allocator.alloc(schema.Target, 1);
    errdefer {
        for (targets) |*t| t.deinit(allocator);
        allocator.free(targets);
    }
    targets[0] = schema.Target{
        .name = try allocator.dupe(u8, name),
        .target_type = if (static) .static_library else .shared_library,
        .sources = sources,
        .includes = includes,
    };

    return schema.Project{
        .name = owned_name,
        .version = version,
        .targets = targets,
    };
}

test "write minimal project" {
    const allocator = std.testing.allocator;

    var project = try createMinimalTemplate(allocator, "test_project");
    defer project.deinit(allocator);

    const output = try writeProject(allocator, &project, .{});
    defer allocator.free(output);

    // Verify output contains expected content
    try std.testing.expect(std.mem.indexOf(u8, output, ".name = \"test_project\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ".version = \"0.1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ".targets = .{") != null);
}
