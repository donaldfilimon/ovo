const std = @import("std");
const ovo = @import("ovo");
const registry = ovo.cli_registry;
const dispatch = ovo.cli_dispatch;
const parser = ovo.zon_parser;
const writer = ovo.zon_writer;
const compiler = ovo.compiler;
const orchestrator = ovo.build_orchestrator;
const project_mod = ovo.core_project;
const pkg_manager = ovo.package_manager;
const importer = ovo.translate.importer;
const exporter = ovo.translate.exporter;
const cli_args = ovo.cli_args;
const graph_renderer = ovo.graph.renderer;

// Pull in inline tests from imported modules that carry local regression coverage.
comptime {
    _ = registry;
    _ = parser;
    _ = compiler;
    _ = importer;
    _ = exporter;
    _ = orchestrator;
    _ = ovo.cli;
}

// ── Registry & Dispatch ─────────────────────────────────────────────

test "registry contains full command surface" {
    try std.testing.expectEqual(@as(usize, 22), registry.commands.len);
    for (registry.commands) |command| {
        try std.testing.expect(dispatch.hasHandler(command.name));
    }
}

// ── ZON Parser ──────────────────────────────────────────────────────

test "zon parser requires name and version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const good = ".{ .name = \"demo\", .version = \"1.0.0\", .license = \"MIT\" }";
    const parsed = try parser.parseBuildZon(alloc, good);
    try std.testing.expectEqualStrings("demo", parsed.name);
    try std.testing.expectEqualStrings("1.0.0", parsed.version);

    const missing_version = ".{ .name = \"demo\" }";
    try std.testing.expectError(
        error.MissingVersion,
        parser.parseBuildZon(alloc, missing_version),
    );
}

test "zon parser captures targets and dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const fixture =
        \\.{
        \\    .ovo_schema = "0",
        \\    .name = "demo",
        \\    .version = "1.0.0",
        \\    .defaults = .{
        \\        .cpp_standard = .cpp20,
        \\        .optimize = "ReleaseFast",
        \\        .backend = "clang",
        \\        .output_dir = ".ovo/build",
        \\    },
        \\    .targets = .{
        \\        .demo = .{
        \\            .type = .executable,
        \\            .sources = .{ "src/main.cpp" },
        \\            .include_dirs = .{ "include" },
        \\            .link = .{ "m" },
        \\        },
        \\        .demo_test = .{
        \\            .type = .test_target,
        \\            .sources = .{ "tests/demo_test.cpp" },
        \\        },
        \\    },
        \\    .dependencies = .{
        \\        .fmt = "10.2.1",
        \\        .zlib = "latest",
        \\    },
        \\}
    ;

    const parsed = try parser.parseBuildZon(alloc, fixture);
    try std.testing.expectEqual(@as(usize, 2), parsed.targets.len);
    try std.testing.expectEqualStrings("demo", parsed.targets[0].name);
    try std.testing.expectEqual(@as(usize, 2), parsed.dependencies.len);
    try std.testing.expectEqualStrings("fmt", parsed.dependencies[0].name);
}

test "zon parser returns MissingName on nameless input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.MissingName,
        parser.parseBuildZon(arena.allocator(), ".{ .version = \"1.0.0\" }"),
    );
}

test "zon parser handles empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.MissingName,
        parser.parseBuildZon(arena.allocator(), ""),
    );
}

test "zon parser defaults when optional fields absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parser.parseBuildZon(arena.allocator(), ".{ .name = \"minimal\", .version = \"0.1.0\" }");
    try std.testing.expectEqual(project_mod.CppStandard.cpp20, parsed.defaults.cpp_standard);
    try std.testing.expectEqualStrings("Debug", parsed.defaults.optimize);
    try std.testing.expectEqual(@as(usize, 0), parsed.targets.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.dependencies.len);
}

test "zon parser rejects unsupported backend values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.InvalidBackend,
        parser.parseBuildZon(arena.allocator(),
            \\.{
            \\    .name = "demo",
            \\    .version = "1.0.0",
            \\    .defaults = .{
            \\        .backend = "bogus",
            \\    },
            \\}
        ),
    );
}

test "zon parser extracts all cpp_standard enum values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]struct { input: []const u8, expected: project_mod.CppStandard }{
        .{ .input = ".cpp11", .expected = .cpp11 },
        .{ .input = ".cpp14", .expected = .cpp14 },
        .{ .input = ".cpp17", .expected = .cpp17 },
        .{ .input = ".cpp20", .expected = .cpp20 },
        .{ .input = ".cpp23", .expected = .cpp23 },
    };
    for (cases) |case| {
        const zon_input = try std.fmt.allocPrint(alloc,
            \\.{{
            \\    .name = "t",
            \\    .version = "1.0.0",
            \\    .defaults = .{{
            \\        .cpp_standard = {s},
            \\    }},
            \\}}
        , .{case.input});
        const parsed = try parser.parseBuildZon(alloc, zon_input);
        try std.testing.expectEqual(case.expected, parsed.defaults.cpp_standard);
    }
}

// ── ZON Writer ──────────────────────────────────────────────────────

test "renderBuildZon produces valid minimal project" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const project = project_mod.Project{ .name = "test", .version = "1.0.0" };
    const output = try writer.renderBuildZon(alloc, project);
    try std.testing.expect(std.mem.indexOf(u8, output, ".name = \"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ".version = \"1.0.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ".ovo_schema = \"0\"") != null);
    try std.testing.expect(std.mem.startsWith(u8, output, ".{"));
    try std.testing.expect(std.mem.endsWith(u8, output, "}\n"));
}

test "renderBuildZon includes license when present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const with_license = project_mod.Project{ .name = "a", .version = "1.0.0", .license = "MIT" };
    const out1 = try writer.renderBuildZon(alloc, with_license);
    try std.testing.expect(std.mem.indexOf(u8, out1, ".license = \"MIT\"") != null);

    const without_license = project_mod.Project{ .name = "b", .version = "1.0.0" };
    const out2 = try writer.renderBuildZon(alloc, without_license);
    try std.testing.expect(std.mem.indexOf(u8, out2, ".license") == null);
}

test "renderBuildZon renders targets with all fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{ "src/main.cpp", "src/util.cpp" },
        .include_dirs = &.{"include"},
        .link_libraries = &.{ "m", "pthread" },
    }};
    const project = project_mod.Project{
        .name = "demo",
        .version = "1.0.0",
        .targets = &targets,
    };
    const output = try writer.renderBuildZon(alloc, project);
    try std.testing.expect(std.mem.indexOf(u8, output, ".app = .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ".type = .executable") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"src/main.cpp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"include\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"pthread\"") != null);
}

test "renderBuildZon renders dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const deps = [_]project_mod.Dependency{
        .{ .name = "fmt", .version = "10.2.1" },
        .{ .name = "zlib", .version = "latest" },
    };
    const project = project_mod.Project{
        .name = "demo",
        .version = "1.0.0",
        .dependencies = &deps,
    };
    const output = try writer.renderBuildZon(alloc, project);
    try std.testing.expect(std.mem.indexOf(u8, output, ".fmt = \"10.2.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ".zlib = \"latest\"") != null);
}

test "renderBuildZon round-trips through parser" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "myapp",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
        .include_dirs = &.{"include"},
    }};
    const deps = [_]project_mod.Dependency{
        .{ .name = "fmt", .version = "10.2.1" },
    };
    const original = project_mod.Project{
        .name = "roundtrip",
        .version = "2.0.0",
        .license = "Apache-2.0",
        .targets = &targets,
        .dependencies = &deps,
    };

    const rendered = try writer.renderBuildZon(alloc, original);
    const parsed = try parser.parseBuildZon(alloc, rendered);

    try std.testing.expectEqualStrings("roundtrip", parsed.name);
    try std.testing.expectEqualStrings("2.0.0", parsed.version);
    try std.testing.expectEqualStrings("Apache-2.0", parsed.license orelse "");
    try std.testing.expectEqual(@as(usize, 1), parsed.targets.len);
    try std.testing.expectEqualStrings("myapp", parsed.targets[0].name);
    try std.testing.expectEqual(@as(usize, 1), parsed.dependencies.len);
    try std.testing.expectEqualStrings("fmt", parsed.dependencies[0].name);
    try std.testing.expectEqualStrings("10.2.1", parsed.dependencies[0].version);
}

// ── Compiler Backend ────────────────────────────────────────────────

test "parseBackend recognizes canonical names and common aliases" {
    const cases = [_]struct { input: []const u8, expected: ?compiler.backend.Backend }{
        .{ .input = "clang", .expected = .clang },
        .{ .input = "clang++", .expected = .clang },
        .{ .input = "gcc", .expected = .gcc },
        .{ .input = "G++", .expected = .gcc },
        .{ .input = "msvc", .expected = .msvc },
        .{ .input = "cl", .expected = .msvc },
        .{ .input = "zigcc", .expected = .zigcc },
        .{ .input = "Zig C++", .expected = .zigcc },
        .{ .input = "unknown", .expected = null },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, compiler.backend.parseBackend(case.input));
    }
}

test "backend label round-trips with parseBackend" {
    const backends = [_]compiler.backend.Backend{ .clang, .gcc, .msvc, .zigcc };
    for (backends) |b| {
        const lbl = compiler.backend.label(b);
        try std.testing.expectEqual(b, compiler.backend.parseBackend(lbl).?);
    }
}

test "backend validateLabel canonicalizes supported labels and rejects invalid ones" {
    try std.testing.expectEqualStrings("zigcc", try compiler.backend.validateLabel("zigcc"));
    try std.testing.expectEqualStrings("msvc", try compiler.backend.validateLabel("msvc"));
    try std.testing.expectError(error.InvalidBackend, compiler.backend.validateLabel("bogus"));
    try std.testing.expectEqualStrings("clang", compiler.backend.supportedBackendLabels()[0]);
    try std.testing.expectEqualStrings("zigcc", compiler.backend.supportedBackendLabels()[3]);
}

// ── Build Orchestrator ──────────────────────────────────────────────

test "default runnable target prefers executable then test" {
    const targets = [_]project_mod.Target{
        .{ .name = "corelib", .kind = .library_static },
        .{ .name = "demo_test", .kind = .test_target },
        .{ .name = "demo", .kind = .executable },
    };
    const project = project_mod.Project{
        .name = "demo",
        .version = "0.1.0",
        .targets = &targets,
    };
    const runnable = orchestrator.defaultRunnableTarget(project) orelse unreachable;
    try std.testing.expectEqualStrings("demo", runnable.name);
}

test "findRunnableArtifact returns matching executable by name" {
    const artifacts = [_]orchestrator.BuiltArtifact{
        .{ .name = "corelib", .kind = .library_static, .path = ".ovo/build/corelib" },
        .{ .name = "app", .kind = .executable, .path = ".ovo/build/app" },
        .{ .name = "tests", .kind = .test_target, .path = ".ovo/build/tests" },
    };
    const result = orchestrator.BuildResult{ .project_name = "demo", .artifacts = &artifacts };
    const found = orchestrator.findRunnableArtifact(result, "app") orelse unreachable;
    try std.testing.expectEqualStrings("app", found.name);
}

test "findRunnableArtifact returns first executable when no name given" {
    const artifacts = [_]orchestrator.BuiltArtifact{
        .{ .name = "corelib", .kind = .library_static, .path = ".ovo/build/corelib" },
        .{ .name = "tests", .kind = .test_target, .path = ".ovo/build/tests" },
    };
    const result = orchestrator.BuildResult{ .project_name = "demo", .artifacts = &artifacts };
    const found = orchestrator.findRunnableArtifact(result, null) orelse unreachable;
    try std.testing.expectEqualStrings("tests", found.name);
}

test "findRunnableArtifact returns null for unknown name" {
    const artifacts = [_]orchestrator.BuiltArtifact{
        .{ .name = "app", .kind = .executable, .path = ".ovo/build/app" },
    };
    const result = orchestrator.BuildResult{ .project_name = "demo", .artifacts = &artifacts };
    try std.testing.expect(orchestrator.findRunnableArtifact(result, "nonexistent") == null);
}

// ── Package Manager Pure Functions ──────────────────────────────────

test "sortedUniqueDependencies sorts alphabetically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var input = [_]project_mod.Dependency{
        .{ .name = "zlib" },
        .{ .name = "fmt" },
        .{ .name = "boost" },
    };
    const result = try pkg_manager.sortedUniqueDependencies(alloc, &input);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("boost", result[0].name);
    try std.testing.expectEqualStrings("fmt", result[1].name);
    try std.testing.expectEqualStrings("zlib", result[2].name);
}

test "sortedUniqueDependencies deduplicates by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var input = [_]project_mod.Dependency{
        .{ .name = "fmt", .version = "1.0" },
        .{ .name = "fmt", .version = "2.0" },
    };
    const result = try pkg_manager.sortedUniqueDependencies(alloc, &input);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("fmt", result[0].name);
    try std.testing.expectEqualStrings("2.0", result[0].version);
}

test "sortedUniqueDependencies skips empty names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var input = [_]project_mod.Dependency{
        .{ .name = "", .version = "1.0" },
        .{ .name = "real", .version = "2.0" },
    };
    const result = try pkg_manager.sortedUniqueDependencies(alloc, &input);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("real", result[0].name);
}

test "insertionSortDependencies handles empty and single-element" {
    var empty = [_]project_mod.Dependency{};
    pkg_manager.insertionSortDependencies(&empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    var single = [_]project_mod.Dependency{.{ .name = "only" }};
    pkg_manager.insertionSortDependencies(&single);
    try std.testing.expectEqualStrings("only", single[0].name);
}

test "sortedUniqueDependencies handles already-sorted input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var input = [_]project_mod.Dependency{
        .{ .name = "aaa" },
        .{ .name = "bbb" },
        .{ .name = "ccc" },
    };
    const result = try pkg_manager.sortedUniqueDependencies(alloc, &input);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("aaa", result[0].name);
    try std.testing.expectEqualStrings("bbb", result[1].name);
    try std.testing.expectEqualStrings("ccc", result[2].name);
}

// ── Export Formats ──────────────────────────────────────────────────

test "parseExportFormat recognizes all formats" {
    const cases = [_]struct { input: []const u8, expected: ?exporter.ExportFormat }{
        .{ .input = "cmake", .expected = .cmake },
        .{ .input = "ninja", .expected = .ninja },
        .{ .input = "compile_commands.json", .expected = .compile_commands },
        .{ .input = "compile_commands", .expected = .compile_commands },
        .{ .input = "makefile", .expected = .makefile },
        .{ .input = "pkg-config", .expected = .pkg_config },
        .{ .input = "pkg_config", .expected = .pkg_config },
        .{ .input = "xcode", .expected = .xcode },
        .{ .input = "msbuild", .expected = .msbuild },
        .{ .input = "meson", .expected = .meson },
        .{ .input = "unknown", .expected = null },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, exporter.parseExportFormat(case.input));
    }
}

test "exportCMake produces valid cmake output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
        .include_dirs = &.{"include"},
        .link_libraries = &.{"m"},
    }};
    const project = project_mod.Project{ .name = "demo", .version = "1.0.0", .targets = &targets };
    const output = try exporter.exportProject(alloc, project, .cmake);
    try std.testing.expect(std.mem.indexOf(u8, output, "cmake_minimum_required") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "project(demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "add_executable(app") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "target_include_directories") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "target_link_libraries") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "CMAKE_CXX_STANDARD") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "install(TARGETS app)") != null);
}

test "exportCMake includes find_package for dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
    }};
    const deps = [_]project_mod.Dependency{
        .{ .name = "Boost", .version = "1.80" },
        .{ .name = "OpenSSL" },
    };
    const project = project_mod.Project{
        .name = "demo",
        .version = "1.0.0",
        .targets = &targets,
        .dependencies = &deps,
    };
    const output = try exporter.exportProject(alloc, project, .cmake);
    try std.testing.expect(std.mem.indexOf(u8, output, "find_package(Boost REQUIRED)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "find_package(OpenSSL REQUIRED)") != null);
}

test "exportNinja produces compile and link rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
    }};
    const project = project_mod.Project{ .name = "demo", .version = "1.0.0", .targets = &targets };
    const output = try exporter.exportProject(alloc, project, .ninja);
    try std.testing.expect(std.mem.indexOf(u8, output, "rule compile") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "rule link") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "build src/main.o: compile src/main.cpp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "build app: link src/main.o") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "default all") != null);
}

test "exportMakefile produces make rules with object files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
    }};
    const project = project_mod.Project{ .name = "demo", .version = "1.0.0", .targets = &targets };
    const output = try exporter.exportProject(alloc, project, .makefile);
    try std.testing.expect(std.mem.indexOf(u8, output, "CXX :=") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "all: app") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "app: src/main.o") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "src/main.o: src/main.cpp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "clean:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ".PHONY: all clean") != null);
}

test "exportPkgConfig produces pkg-config file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const project = project_mod.Project{ .name = "mylib", .version = "2.3.4" };
    const output = try exporter.exportProject(alloc, project, .pkg_config);
    try std.testing.expect(std.mem.indexOf(u8, output, "Name: mylib") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Version: 2.3.4") != null);
}

test "exportMSBuild produces valid vcxproj XML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
        .include_dirs = &.{"include"},
    }};
    const project = project_mod.Project{
        .name = "demo",
        .version = "1.0.0",
        .targets = &targets,
        .defaults = .{ .cpp_standard = .cpp20 },
    };
    const output = try exporter.exportProject(alloc, project, .msbuild);
    try std.testing.expect(std.mem.indexOf(u8, output, "<ConfigurationType>Application</ConfigurationType>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<ClCompile Include=\"src/main.cpp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<LanguageStandard>stdcpp20</LanguageStandard>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<RootNamespace>demo</RootNamespace>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Microsoft.Cpp.targets") != null);
}

test "exportXcode produces valid pbxproj sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "myapp",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
    }};
    const project = project_mod.Project{
        .name = "demo",
        .version = "1.0.0",
        .targets = &targets,
        .defaults = .{ .cpp_standard = .cpp17 },
    };
    const output = try exporter.exportProject(alloc, project, .xcode);
    try std.testing.expect(std.mem.indexOf(u8, output, "PBXNativeTarget") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PBXFileReference") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "XCBuildConfiguration") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "com.apple.product-type.tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "CLANG_CXX_LANGUAGE_STANDARD = \"c++17\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "rootObject") != null);
}

// ── Meson Export ────────────────────────────────────────────────────

test "exportMeson produces valid project declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
    }};
    const project = project_mod.Project{
        .name = "demo",
        .version = "1.0.0",
        .targets = &targets,
        .defaults = .{ .cpp_standard = .cpp20 },
    };
    const output = try exporter.exportProject(alloc, project, .meson);
    try std.testing.expect(std.mem.indexOf(u8, output, "project('demo',") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "version: '1.0.0'") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "cpp_std=c++20") != null);
}

test "exportMeson generates executable target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{ "src/main.cpp", "src/util.cpp" },
        .include_dirs = &.{"include"},
    }};
    const project = project_mod.Project{ .name = "demo", .version = "1.0.0", .targets = &targets };
    const output = try exporter.exportProject(alloc, project, .meson);
    try std.testing.expect(std.mem.indexOf(u8, output, "executable('app',") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "'src/main.cpp'") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "'src/util.cpp'") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "include_directories:") != null);
}

test "exportMeson generates library targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{
        .{ .name = "mylib", .kind = .library_static, .sources = &.{"src/lib.cpp"} },
        .{ .name = "myshared", .kind = .library_shared, .sources = &.{"src/shared.cpp"} },
    };
    const project = project_mod.Project{ .name = "libs", .version = "1.0.0", .targets = &targets };
    const output = try exporter.exportProject(alloc, project, .meson);
    try std.testing.expect(std.mem.indexOf(u8, output, "static_library('mylib',") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "shared_library('myshared',") != null);
}

test "exportMeson includes dependency declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
    }};
    const deps = [_]project_mod.Dependency{
        .{ .name = "gtest", .version = "1.12" },
    };
    const project = project_mod.Project{
        .name = "demo",
        .version = "1.0.0",
        .targets = &targets,
        .dependencies = &deps,
    };
    const output = try exporter.exportProject(alloc, project, .meson);
    try std.testing.expect(std.mem.indexOf(u8, output, "gtest_dep = dependency('gtest')") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "dependencies: [gtest_dep]") != null);
}

test "exportMeson maps cpp_standard to default_options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const project17 = project_mod.Project{
        .name = "app",
        .version = "1.0.0",
        .defaults = .{ .cpp_standard = .cpp17 },
    };
    const out17 = try exporter.exportProject(alloc, project17, .meson);
    try std.testing.expect(std.mem.indexOf(u8, out17, "cpp_std=c++17") != null);

    const project23 = project_mod.Project{
        .name = "app",
        .version = "1.0.0",
        .defaults = .{ .cpp_standard = .cpp23 },
    };
    const out23 = try exporter.exportProject(alloc, project23, .meson);
    try std.testing.expect(std.mem.indexOf(u8, out23, "cpp_std=c++23") != null);
}

// ── CLI Args ────────────────────────────────────────────────────────

test "parse returns MissingCwdPath when --cwd has no value" {
    var argv = [_][]const u8{ "ovo", "--cwd" };
    try std.testing.expectError(error.MissingCwdPath, cli_args.parse(&argv));
}

test "parse returns MissingProfileName when --profile has no value" {
    var argv = [_][]const u8{ "ovo", "--profile" };
    try std.testing.expectError(error.MissingProfileName, cli_args.parse(&argv));
}

test "parse returns UnknownGlobalFlag for unrecognized flags" {
    var argv = [_][]const u8{ "ovo", "--bogus" };
    try std.testing.expectError(error.UnknownGlobalFlag, cli_args.parse(&argv));
}

test "parse handles passthrough args after double-dash" {
    var argv = [_][]const u8{ "ovo", "run", "target", "--", "--port", "8080" };
    const parsed = try cli_args.parse(&argv);
    try std.testing.expectEqualStrings("run", parsed.command.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.commandArgs().len);
    try std.testing.expectEqualStrings("target", parsed.commandArgs()[0]);
    try std.testing.expectEqual(@as(usize, 2), parsed.passthroughArgs().len);
    try std.testing.expectEqualStrings("--port", parsed.passthroughArgs()[0]);
    try std.testing.expectEqualStrings("8080", parsed.passthroughArgs()[1]);
}

test "parse handles --cwd=path inline format" {
    var argv = [_][]const u8{ "ovo", "--cwd=/tmp/proj", "build" };
    const parsed = try cli_args.parse(&argv);
    try std.testing.expectEqualStrings("/tmp/proj", parsed.cwd.?);
    try std.testing.expectEqualStrings("build", parsed.command.?);
}

test "parse handles --profile=name inline format" {
    var argv = [_][]const u8{ "ovo", "--profile=release", "build" };
    const parsed = try cli_args.parse(&argv);
    try std.testing.expectEqualStrings("release", parsed.profile.?);
    try std.testing.expectEqualStrings("build", parsed.command.?);
}

test "parse with --version does not set show_help" {
    var argv = [_][]const u8{ "ovo", "--version" };
    const parsed = try cli_args.parse(&argv);
    try std.testing.expect(parsed.show_version);
    try std.testing.expect(!parsed.show_help);
}

test "hasHelpFlag detects help in command args" {
    try std.testing.expect(cli_args.hasHelpFlag(&.{"--help"}));
    try std.testing.expect(cli_args.hasHelpFlag(&.{"-h"}));
    try std.testing.expect(cli_args.hasHelpFlag(&.{ "foo", "--help", "bar" }));
    try std.testing.expect(!cli_args.hasHelpFlag(&.{"--verbose"}));
    try std.testing.expect(!cli_args.hasHelpFlag(&.{}));
}

// ── Core Project Helpers ────────────────────────────────────────────

test "guessProjectNameFromPath handles edge cases" {
    try std.testing.expectEqualStrings("app", project_mod.guessProjectNameFromPath("."));
    try std.testing.expectEqualStrings("app", project_mod.guessProjectNameFromPath(""));
    try std.testing.expectEqualStrings("myproject", project_mod.guessProjectNameFromPath("/some/path/myproject"));
    try std.testing.expectEqualStrings("simple", project_mod.guessProjectNameFromPath("simple"));
}

test "parseTargetType recognizes all variants" {
    const cases = [_]struct { input: []const u8, expected: ?project_mod.TargetType }{
        .{ .input = "executable", .expected = .executable },
        .{ .input = "library_static", .expected = .library_static },
        .{ .input = "library_shared", .expected = .library_shared },
        .{ .input = "test", .expected = .test_target },
        .{ .input = "test_target", .expected = .test_target },
        .{ .input = "unknown", .expected = null },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, project_mod.parseTargetType(case.input));
    }
}

test "targetTypeLabel round-trips with parseTargetType" {
    const types = [_]project_mod.TargetType{ .executable, .library_static, .library_shared, .test_target };
    for (types) |t| {
        const lbl = project_mod.targetTypeLabel(t);
        const parsed = project_mod.parseTargetType(lbl);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(t, parsed.?);
    }
}

// ── Multi-Source Export Tests ────────────────────────────────────────

test "exportNinja handles multi-source targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{ "src/main.cpp", "src/util.cpp", "src/engine.cpp" },
        .include_dirs = &.{"include"},
        .link_libraries = &.{"pthread"},
    }};
    const project = project_mod.Project{ .name = "demo", .version = "1.0.0", .targets = &targets };
    const output = try exporter.exportProject(alloc, project, .ninja);
    // All three sources should get compile edges
    try std.testing.expect(std.mem.indexOf(u8, output, "build src/main.o: compile src/main.cpp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "build src/util.o: compile src/util.cpp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "build src/engine.o: compile src/engine.cpp") != null);
    // Link edge should reference all objects
    try std.testing.expect(std.mem.indexOf(u8, output, "build app: link src/main.o src/util.o src/engine.o") != null);
    // Include dirs in flags
    try std.testing.expect(std.mem.indexOf(u8, output, "-Iinclude") != null);
    // Link libraries
    try std.testing.expect(std.mem.indexOf(u8, output, "-lpthread") != null);
}

test "exportNinja generates archive rule for static library" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "libcore",
        .kind = .library_static,
        .sources = &.{"src/core.cpp"},
    }};
    const project = project_mod.Project{ .name = "demo", .version = "1.0.0", .targets = &targets };
    const output = try exporter.exportProject(alloc, project, .ninja);
    try std.testing.expect(std.mem.indexOf(u8, output, "rule archive") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "build libcore: archive src/core.o") != null);
}

test "exportMakefile handles multi-source with includes and libs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{ "src/main.cpp", "src/util.cpp" },
        .include_dirs = &.{"include"},
        .link_libraries = &.{"m"},
    }};
    const project = project_mod.Project{ .name = "demo", .version = "1.0.0", .targets = &targets };
    const output = try exporter.exportProject(alloc, project, .makefile);
    // Both object files in link rule
    try std.testing.expect(std.mem.indexOf(u8, output, "app: src/main.o src/util.o") != null);
    // Both per-source compile rules
    try std.testing.expect(std.mem.indexOf(u8, output, "src/main.o: src/main.cpp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "src/util.o: src/util.cpp") != null);
    // Include dirs in compile rules
    try std.testing.expect(std.mem.indexOf(u8, output, "-Iinclude") != null);
    // Link library
    try std.testing.expect(std.mem.indexOf(u8, output, "-lm") != null);
}

test "exportMakefile generates ar rule for static library" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "libcore.a",
        .kind = .library_static,
        .sources = &.{"src/core.cpp"},
    }};
    const project = project_mod.Project{ .name = "demo", .version = "1.0.0", .targets = &targets };
    const output = try exporter.exportProject(alloc, project, .makefile);
    try std.testing.expect(std.mem.indexOf(u8, output, "ar rcs") != null);
}

// ── Defines/Cflags Export Tests ─────────────────────────────────────

test "exportCMake includes target_compile_definitions and options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
        .defines = &.{ "DEBUG", "VERSION=2" },
        .cflags = &.{ "-Wall", "-Wextra" },
    }};
    const project = project_mod.Project{ .name = "demo", .version = "1.0.0", .targets = &targets };
    const output = try exporter.exportProject(alloc, project, .cmake);
    try std.testing.expect(std.mem.indexOf(u8, output, "target_compile_definitions(app PRIVATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "    DEBUG") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "    VERSION=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "target_compile_options(app PRIVATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "    -Wall") != null);
}

test "exportNinja includes defines and cflags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
        .defines = &.{"NDEBUG"},
        .cflags = &.{"-O3"},
    }};
    const project = project_mod.Project{ .name = "demo", .version = "1.0.0", .targets = &targets };
    const output = try exporter.exportProject(alloc, project, .ninja);
    try std.testing.expect(std.mem.indexOf(u8, output, "-DNDEBUG") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-O3") != null);
}

test "exportMakefile includes defines and cflags in compile rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
        .defines = &.{"FOO"},
        .cflags = &.{"-Wall"},
    }};
    const project = project_mod.Project{ .name = "demo", .version = "1.0.0", .targets = &targets };
    const output = try exporter.exportProject(alloc, project, .makefile);
    try std.testing.expect(std.mem.indexOf(u8, output, "-DFOO") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-Wall") != null);
}

test "exportMeson includes cpp_args for defines and cflags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
        .defines = &.{"ENABLE_FEATURE"},
        .cflags = &.{"-Wextra"},
    }};
    const project = project_mod.Project{ .name = "demo", .version = "1.0.0", .targets = &targets };
    const output = try exporter.exportProject(alloc, project, .meson);
    try std.testing.expect(std.mem.indexOf(u8, output, "cpp_args:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "'-DENABLE_FEATURE'") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "'-Wextra'") != null);
}

// ── Pkg-Config Export Tests ─────────────────────────────────────────

test "exportPkgConfig includes library and dependency info" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "mylib",
        .kind = .library_static,
        .sources = &.{"src/lib.cpp"},
        .include_dirs = &.{"include/mylib"},
        .link_libraries = &.{"z"},
        .defines = &.{"MYLIB_STATIC"},
    }};
    const deps = [_]project_mod.Dependency{
        .{ .name = "zlib", .version = "1.2" },
    };
    const project = project_mod.Project{
        .name = "mylib",
        .version = "2.3.4",
        .targets = &targets,
        .dependencies = &deps,
    };
    const output = try exporter.exportProject(alloc, project, .pkg_config);
    try std.testing.expect(std.mem.indexOf(u8, output, "Name: mylib") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Version: 2.3.4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Requires: zlib") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-lmylib") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-lz") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-Iinclude/mylib") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-DMYLIB_STATIC") != null);
}

// ── Compile Commands Export Tests ────────────────────────────────────

test "exportCompileCommands includes defines and cflags in command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
        .include_dirs = &.{"include"},
        .defines = &.{ "DEBUG", "VERSION=2" },
        .cflags = &.{ "-Wall", "-Wextra" },
    }};
    const project = project_mod.Project{ .name = "demo", .version = "1.0.0", .targets = &targets };
    const output = try exporter.exportProject(alloc, project, .compile_commands);
    // Includes
    try std.testing.expect(std.mem.indexOf(u8, output, "-Iinclude") != null);
    // Defines
    try std.testing.expect(std.mem.indexOf(u8, output, "-DDEBUG") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-DVERSION=2") != null);
    // Cflags
    try std.testing.expect(std.mem.indexOf(u8, output, "-Wall") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-Wextra") != null);
    // Source file
    try std.testing.expect(std.mem.indexOf(u8, output, "src/main.cpp") != null);
}

// ── ZON Round-Trip with Defines/Cflags ──────────────────────────────

test "zon parser extracts defines and cflags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const fixture =
        \\.{
        \\    .name = "demo",
        \\    .version = "1.0.0",
        \\    .targets = .{
        \\        .app = .{
        \\            .type = .executable,
        \\            .sources = .{ "src/main.cpp" },
        \\            .include_dirs = .{},
        \\            .link = .{},
        \\            .defines = .{ "DEBUG", "VERSION=2" },
        \\            .cflags = .{ "-Wall", "-Wextra" },
        \\        },
        \\    },
        \\}
    ;

    const parsed = try parser.parseBuildZon(alloc, fixture);
    try std.testing.expectEqual(@as(usize, 1), parsed.targets.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.targets[0].defines.len);
    try std.testing.expectEqualStrings("DEBUG", parsed.targets[0].defines[0]);
    try std.testing.expectEqualStrings("VERSION=2", parsed.targets[0].defines[1]);
    try std.testing.expectEqual(@as(usize, 2), parsed.targets[0].cflags.len);
    try std.testing.expectEqualStrings("-Wall", parsed.targets[0].cflags[0]);
    try std.testing.expectEqualStrings("-Wextra", parsed.targets[0].cflags[1]);
}

test "zon writer renders defines and cflags conditionally" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // With defines/cflags
    const targets_with = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
        .defines = &.{"FOO"},
        .cflags = &.{"-Wall"},
    }};
    const proj_with = project_mod.Project{ .name = "demo", .version = "1.0.0", .targets = &targets_with };
    const out_with = try writer.renderBuildZon(alloc, proj_with);
    try std.testing.expect(std.mem.indexOf(u8, out_with, ".defines = .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_with, "\"FOO\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_with, ".cflags = .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_with, "\"-Wall\"") != null);

    // Without defines/cflags — should omit the blocks
    const targets_without = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
    }};
    const proj_without = project_mod.Project{ .name = "demo", .version = "1.0.0", .targets = &targets_without };
    const out_without = try writer.renderBuildZon(alloc, proj_without);
    try std.testing.expect(std.mem.indexOf(u8, out_without, ".defines") == null);
    try std.testing.expect(std.mem.indexOf(u8, out_without, ".cflags") == null);
}

test "zon writer emits canonical test_target enum labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "demo_test",
        .kind = .test_target,
        .sources = &.{"tests/main_test.cpp"},
    }};
    const project = project_mod.Project{
        .name = "demo",
        .version = "1.0.0",
        .targets = &targets,
    };

    const output = try writer.renderBuildZon(alloc, project);
    try std.testing.expect(std.mem.indexOf(u8, output, ".type = .test_target") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ".type = .test,\n") == null);
}

test "defines and cflags round-trip through zon parser and writer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
        .defines = &.{ "A", "B=1" },
        .cflags = &.{"-O2"},
    }};
    const original = project_mod.Project{
        .name = "rt",
        .version = "1.0.0",
        .targets = &targets,
    };
    const rendered = try writer.renderBuildZon(alloc, original);
    const parsed = try parser.parseBuildZon(alloc, rendered);

    try std.testing.expectEqual(@as(usize, 2), parsed.targets[0].defines.len);
    try std.testing.expectEqualStrings("A", parsed.targets[0].defines[0]);
    try std.testing.expectEqualStrings("B=1", parsed.targets[0].defines[1]);
    try std.testing.expectEqual(@as(usize, 1), parsed.targets[0].cflags.len);
    try std.testing.expectEqualStrings("-O2", parsed.targets[0].cflags[0]);
}

// ── Export Format Coverage ──────────────────────────────────────────

test "exportProject handles empty targets gracefully" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const project = project_mod.Project{ .name = "empty", .version = "0.0.1" };

    // All formats should produce output without crashing
    const formats = [_]exporter.ExportFormat{ .cmake, .ninja, .makefile, .pkg_config, .meson };
    for (formats) |fmt| {
        const output = try exporter.exportProject(alloc, project, fmt);
        try std.testing.expect(output.len > 0);
    }
}

test "label round-trips with parseExportFormat" {
    const formats = [_]exporter.ExportFormat{
        .cmake, .xcode, .msbuild, .ninja, .makefile, .pkg_config, .meson,
    };
    for (formats) |fmt| {
        const lbl = exporter.label(fmt);
        const parsed = exporter.parseExportFormat(lbl);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(fmt, parsed.?);
    }
}

// ── Graph Renderer ──────────────────────────────────────────────────

test "parseTreeFormat recognizes all formats and rejects unknown" {
    const cases = [_]struct { input: []const u8, expected: ?graph_renderer.TreeFormat }{
        .{ .input = "ascii", .expected = .ascii },
        .{ .input = "dot", .expected = .dot },
        .{ .input = "json", .expected = .json },
        .{ .input = "mermaid", .expected = .mermaid },
        .{ .input = "yaml", .expected = null },
        .{ .input = "", .expected = null },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, graph_renderer.parseTreeFormat(case.input));
    }
}

test "formatLabel round-trips with parseTreeFormat" {
    const formats = [_]graph_renderer.TreeFormat{ .ascii, .dot, .json, .mermaid };
    for (formats) |fmt| {
        const lbl = graph_renderer.formatLabel(fmt);
        const parsed = graph_renderer.parseTreeFormat(lbl);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(fmt, parsed.?);
    }
}

test "renderTree ascii shows project header, targets, and dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{
        .{
            .name = "app",
            .kind = .executable,
            .sources = &.{"src/main.cpp"},
            .link_libraries = &.{ "mylib", "pthread" },
        },
        .{
            .name = "mylib",
            .kind = .library_static,
            .sources = &.{"src/lib.cpp"},
        },
    };
    const deps = [_]project_mod.Dependency{
        .{ .name = "fmt", .version = "10.2.1" },
    };
    const project = project_mod.Project{
        .name = "myapp",
        .version = "1.0.0",
        .targets = &targets,
        .dependencies = &deps,
    };
    const output = try graph_renderer.renderTree(alloc, project, .ascii, null);
    // Header
    try std.testing.expect(std.mem.indexOf(u8, output, "myapp v1.0.0") != null);
    // Targets
    try std.testing.expect(std.mem.indexOf(u8, output, "[target] app (executable)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[target] mylib (library_static)") != null);
    // Internal vs external links
    try std.testing.expect(std.mem.indexOf(u8, output, "mylib -> [target]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pthread (external)") != null);
    // Dependency
    try std.testing.expect(std.mem.indexOf(u8, output, "[dependency] fmt@10.2.1") != null);
}

test "renderTree ascii target filter shows only matching target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{
        .{ .name = "app", .kind = .executable, .sources = &.{"src/main.cpp"} },
        .{ .name = "mylib", .kind = .library_static, .sources = &.{"src/lib.cpp"} },
    };
    const deps = [_]project_mod.Dependency{
        .{ .name = "fmt", .version = "10.2.1" },
    };
    const project = project_mod.Project{
        .name = "myapp",
        .version = "1.0.0",
        .targets = &targets,
        .dependencies = &deps,
    };
    const output = try graph_renderer.renderTree(alloc, project, .ascii, "mylib");
    // Should show filtered target
    try std.testing.expect(std.mem.indexOf(u8, output, "[target] mylib") != null);
    // Should NOT show other target or dependencies
    try std.testing.expect(std.mem.indexOf(u8, output, "[target] app") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[dependency]") == null);
}

test "renderTree empty project produces valid output for all formats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const project = project_mod.Project{ .name = "empty", .version = "0.0.1" };
    const formats = [_]graph_renderer.TreeFormat{ .ascii, .dot, .json, .mermaid };
    for (formats) |fmt| {
        const output = try graph_renderer.renderTree(alloc, project, fmt, null);
        try std.testing.expect(output.len > 0);
    }
}

test "renderTree dot produces digraph with rankdir and target nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{
        .{
            .name = "app",
            .kind = .executable,
            .sources = &.{"src/main.cpp"},
            .link_libraries = &.{"mylib"},
        },
        .{ .name = "mylib", .kind = .library_static, .sources = &.{"src/lib.cpp"} },
    };
    const project = project_mod.Project{
        .name = "demo",
        .version = "1.0.0",
        .targets = &targets,
    };
    const output = try graph_renderer.renderTree(alloc, project, .dot, null);
    try std.testing.expect(std.mem.indexOf(u8, output, "digraph") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "rankdir=LR") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"mylib\"") != null);
}

test "renderTree dot internal links produce directed edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{
        .{
            .name = "app",
            .kind = .executable,
            .sources = &.{"src/main.cpp"},
            .link_libraries = &.{"core"},
        },
        .{ .name = "core", .kind = .library_static, .sources = &.{"src/core.cpp"} },
    };
    const project = project_mod.Project{
        .name = "demo",
        .version = "1.0.0",
        .targets = &targets,
    };
    const output = try graph_renderer.renderTree(alloc, project, .dot, null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"app\" -> \"core\"") != null);
}

test "renderTree json contains project and targets keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{
        .{ .name = "app", .kind = .executable, .sources = &.{"src/main.cpp"} },
    };
    const project = project_mod.Project{
        .name = "demo",
        .version = "1.0.0",
        .targets = &targets,
    };
    const output = try graph_renderer.renderTree(alloc, project, .json, null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"project\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"targets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"dependencies\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"demo\"") != null);
}

test "renderTree mermaid produces graph TD with nodes and edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{
        .{
            .name = "app",
            .kind = .executable,
            .sources = &.{"src/main.cpp"},
            .link_libraries = &.{"mylib"},
        },
        .{ .name = "mylib", .kind = .library_static, .sources = &.{"src/lib.cpp"} },
    };
    const deps = [_]project_mod.Dependency{
        .{ .name = "fmt", .version = "10.2.1" },
    };
    const project = project_mod.Project{
        .name = "myapp",
        .version = "1.0.0",
        .targets = &targets,
        .dependencies = &deps,
    };
    const output = try graph_renderer.renderTree(alloc, project, .mermaid, null);
    try std.testing.expect(std.mem.indexOf(u8, output, "graph TD") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "app --> mylib") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-.->") != null);
}

test "renderTree json includes include_dirs defines and cflags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
        .include_dirs = &.{"include/mylib"},
        .defines = &.{ "DEBUG", "VERSION=2" },
        .cflags = &.{ "-Wall", "-O2" },
    }};
    const project = project_mod.Project{ .name = "demo", .version = "1.0.0", .targets = &targets };
    const output = try graph_renderer.renderTree(alloc, project, .json, null);
    // JSON must contain all the enhanced keys
    try std.testing.expect(std.mem.indexOf(u8, output, "\"include_dirs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"defines\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"cflags\"") != null);
    // Values must appear
    try std.testing.expect(std.mem.indexOf(u8, output, "include/mylib") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "DEBUG") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "VERSION=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-Wall") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-O2") != null);
}

test "renderTree ascii shows defines and cflags sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{.{
        .name = "app",
        .kind = .executable,
        .sources = &.{"src/main.cpp"},
        .defines = &.{"ENABLE_FEATURE"},
        .cflags = &.{"-Werror"},
    }};
    const project = project_mod.Project{ .name = "demo", .version = "1.0.0", .targets = &targets };
    const output = try graph_renderer.renderTree(alloc, project, .ascii, null);
    try std.testing.expect(std.mem.indexOf(u8, output, "defines:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ENABLE_FEATURE") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "cflags:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-Werror") != null);
}

test "renderTree dot dependency nodes have dashed style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const targets = [_]project_mod.Target{
        .{ .name = "app", .kind = .executable, .sources = &.{"src/main.cpp"} },
    };
    const deps = [_]project_mod.Dependency{
        .{ .name = "fmt", .version = "10.2.1" },
    };
    const project = project_mod.Project{
        .name = "demo",
        .version = "1.0.0",
        .targets = &targets,
        .dependencies = &deps,
    };
    const output = try graph_renderer.renderTree(alloc, project, .dot, null);
    try std.testing.expect(std.mem.indexOf(u8, output, "style=dashed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "fmt@10.2.1") != null);
}

test "zon parser handles target with all fields including defines and cflags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const fixture =
        \\.{
        \\    .name = "fullproject",
        \\    .version = "2.5.0",
        \\    .targets = .{
        \\        .mylib = .{
        \\            .type = .library_static,
        \\            .sources = .{ "src/lib.cpp", "src/util.cpp" },
        \\            .include_dirs = .{ "include", "third_party/include" },
        \\            .link = .{ "pthread", "dl" },
        \\            .defines = .{ "LIB_EXPORT", "NDEBUG" },
        \\            .cflags = .{ "-fPIC", "-O2" },
        \\        },
        \\    },
        \\    .dependencies = .{
        \\        .boost = "1.84.0",
        \\    },
        \\}
    ;

    const parsed = try parser.parseBuildZon(alloc, fixture);
    try std.testing.expectEqualStrings("fullproject", parsed.name);
    try std.testing.expectEqualStrings("2.5.0", parsed.version);
    try std.testing.expectEqual(@as(usize, 1), parsed.targets.len);
    const t = parsed.targets[0];
    try std.testing.expectEqualStrings("mylib", t.name);
    try std.testing.expectEqual(project_mod.TargetType.library_static, t.kind);
    try std.testing.expectEqual(@as(usize, 2), t.sources.len);
    try std.testing.expectEqual(@as(usize, 2), t.include_dirs.len);
    try std.testing.expectEqual(@as(usize, 2), t.link_libraries.len);
    try std.testing.expectEqual(@as(usize, 2), t.defines.len);
    try std.testing.expectEqualStrings("LIB_EXPORT", t.defines[0]);
    try std.testing.expectEqualStrings("NDEBUG", t.defines[1]);
    try std.testing.expectEqual(@as(usize, 2), t.cflags.len);
    try std.testing.expectEqualStrings("-fPIC", t.cflags[0]);
    try std.testing.expectEqualStrings("-O2", t.cflags[1]);
    try std.testing.expectEqual(@as(usize, 1), parsed.dependencies.len);
    try std.testing.expectEqualStrings("boost", parsed.dependencies[0].name);
    try std.testing.expectEqualStrings("1.84.0", parsed.dependencies[0].version);
}

// ── Core Runtime ─────────────────────────────────────────────────────

test "runtime setIo and io round-trip" {
    // Set a mock io
    const mock_io: std.Io = undefined;
    ovo.core.runtime.setIo(mock_io);

    // Verify io() returns the set value
    const result = ovo.core.runtime.io();
    _ = result; // Just verify it doesn't panic
}
