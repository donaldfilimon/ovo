const std = @import("std");
const cli_registry = @import("src/cli/command_registry.zig");

fn addTestStep(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    root_source_file: []const u8,
    ovo_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step {
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source_file),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ovo", .module = ovo_module },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const step = b.step(name, description);
    step.dependOn(&run_tests.step);
    return step;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ovo_module = b.createModule(.{
        .root_source_file = b.path("src/ovo.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "ovo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run OVO");
    run_step.dependOn(&run_cmd.step);

    const check_step = b.step("check", "Compile OVO without running tests");
    check_step.dependOn(&exe.step);

    const unit = addTestStep(
        b,
        "test",
        "Run unit tests",
        "tests/unit/test_all.zig",
        ovo_module,
        target,
        optimize,
    );
    const smoke = addTestStep(
        b,
        "test-cli-smoke",
        "Run smoke CLI checks",
        "tests/cli/smoke/test_cli_smoke.zig",
        ovo_module,
        target,
        optimize,
    );
    const deep = addTestStep(
        b,
        "test-cli-deep",
        "Run deep CLI checks",
        "tests/cli/deep/test_cli_deep.zig",
        ovo_module,
        target,
        optimize,
    );
    const stress = addTestStep(
        b,
        "test-cli-stress",
        "Run stress CLI checks",
        "tests/cli/stress/test_cli_stress.zig",
        ovo_module,
        target,
        optimize,
    );
    const integration = addTestStep(
        b,
        "test-cli-integration",
        "Run integration CLI checks",
        "tests/cli/integration/test_cli_integration.zig",
        ovo_module,
        target,
        optimize,
    );

    const cli_all = b.step("test-cli-all", "Run all CLI tiers");
    cli_all.dependOn(smoke);
    cli_all.dependOn(deep);
    cli_all.dependOn(stress);
    cli_all.dependOn(integration);

    const help_matrix = b.step("test-cli-help-matrix", "Run `--help` for every CLI command");
    const base_help = b.addRunArtifact(exe);
    base_help.addArg("--quiet");
    base_help.addArg("--help");
    help_matrix.dependOn(&base_help.step);

    for (cli_registry.commands) |command_spec| {
        const run_help = b.addRunArtifact(exe);
        run_help.addArg("--quiet");
        run_help.addArg(command_spec.name);
        run_help.addArg("--help");
        help_matrix.dependOn(&run_help.step);
    }

    const test_all = b.step("test-all", "Run all verification steps");
    test_all.dependOn(check_step);
    test_all.dependOn(unit);
    test_all.dependOn(cli_all);
    test_all.dependOn(help_matrix);
}
