const std = @import("std");
const ovo = @import("ovo");
const registry = ovo.cli_registry;
const dispatch = ovo.cli_dispatch;
const parser = ovo.zon_parser;
const neural = ovo.neural;
const compiler = ovo.compiler;
const orchestrator = ovo.build_orchestrator;

test "registry contains full command surface" {
    try std.testing.expectEqual(@as(usize, 20), registry.commands.len);
    for (registry.commands) |command| {
        try std.testing.expect(dispatch.hasHandler(command.name));
    }
}

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

test "neural layer and loss are deterministic" {
    var layer = neural.layers.DenseLayer{ .weight = 1.5, .bias = 0.5 };
    const output = layer.apply(2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 3.5), output, 0.0001);

    const relu_neg = neural.activation.relu(-4.0);
    try std.testing.expectEqual(@as(f32, 0.0), relu_neg);

    const mse = neural.loss.meanSquaredError(output, 1.0);
    try std.testing.expect(mse > 0.0);
}

test "compiler backend parser accepts zigcc" {
    const backend = compiler.backend.parseBackend("zigcc");
    try std.testing.expect(backend != null);
}

test "default runnable target prefers executable then test" {
    const targets = [_]ovo.core_project.Target{
        .{ .name = "corelib", .kind = .library_static },
        .{ .name = "demo_test", .kind = .test_target },
        .{ .name = "demo", .kind = .executable },
    };
    const project = ovo.core_project.Project{
        .name = "demo",
        .version = "0.1.0",
        .targets = &targets,
    };
    const runnable = orchestrator.defaultRunnableTarget(project) orelse unreachable;
    try std.testing.expectEqualStrings("demo", runnable.name);
}
