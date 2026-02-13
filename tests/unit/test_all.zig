const std = @import("std");
const ovo = @import("ovo");
const registry = ovo.cli_registry;
const dispatch = ovo.cli_dispatch;
const parser = ovo.zon_parser;
const writer = ovo.zon_writer;
const neural = ovo.neural;
const compiler = ovo.compiler;
const orchestrator = ovo.build_orchestrator;
const project_mod = ovo.core_project;
const pkg_manager = ovo.package_manager;
const importer = ovo.translate.importer;
const exporter = ovo.translate.exporter;
const cli_args = ovo.cli_args;

// Pull in inline tests from translate modules
comptime {
    _ = importer;
    _ = exporter;
}

// ── Registry & Dispatch ─────────────────────────────────────────────

test "registry contains full command surface" {
    try std.testing.expectEqual(@as(usize, 20), registry.commands.len);
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
        \\            .type = .test,
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

// ── Neural ──────────────────────────────────────────────────────────

test "neural layer and loss are deterministic" {
    var layer = neural.layers.DenseLayer{ .weight = 1.5, .bias = 0.5 };
    const output = layer.apply(2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 3.5), output, 0.0001);

    const relu_neg = neural.activation.relu(-4.0);
    try std.testing.expectEqual(@as(f32, 0.0), relu_neg);

    const mse = neural.loss.meanSquaredError(output, 1.0);
    try std.testing.expect(mse > 0.0);
}

// ── Compiler Backend ────────────────────────────────────────────────

test "parseBackend recognizes all backends" {
    const cases = [_]struct { input: []const u8, expected: ?compiler.backend.Backend }{
        .{ .input = "clang", .expected = .clang },
        .{ .input = "gcc", .expected = .gcc },
        .{ .input = "msvc", .expected = .msvc },
        .{ .input = "zigcc", .expected = .zigcc },
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
}

test "exportNinja produces build rules" {
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
    try std.testing.expect(std.mem.indexOf(u8, output, "rule cxx") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "build app: cxx src/main.cpp") != null);
}

test "exportMakefile produces make rules" {
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
    try std.testing.expect(std.mem.indexOf(u8, output, "app: src/main.cpp") != null);
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
