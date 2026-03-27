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
            .link_libc = true,
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
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "ovo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    // Link libc on all platforms — required for C stdlib functions
    exe.root_module.linkSystemLibrary("c", .{});
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run OVO");
    run_step.dependOn(&run_cmd.step);

    const typecheck = b.step("typecheck", "Compile OVO without running tests");
    typecheck.dependOn(&exe.step);

    const unit_tests = addTestStep(
        b,
        "unit-tests",
        "Run unit tests",
        "tests/unit/test_all.zig",
        ovo_module,
        target,
        optimize,
    );
    const cli_tests_smoke = addTestStep(
        b,
        "cli-tests-smoke",
        "Run smoke CLI checks",
        "tests/cli/smoke/test_cli_smoke.zig",
        ovo_module,
        target,
        optimize,
    );
    const cli_tests_deep = addTestStep(
        b,
        "cli-tests-deep",
        "Run deep CLI checks",
        "tests/cli/deep/test_cli_deep.zig",
        ovo_module,
        target,
        optimize,
    );
    const cli_tests_stress = addTestStep(
        b,
        "cli-tests-stress",
        "Run stress CLI checks",
        "tests/cli/stress/test_cli_stress.zig",
        ovo_module,
        target,
        optimize,
    );
    const cli_tests_integration = addTestStep(
        b,
        "cli-tests-integration",
        "Run integration CLI checks",
        "tests/cli/integration/test_cli_integration.zig",
        ovo_module,
        target,
        optimize,
    );
    const cli_test_env_check = b.addSystemCommand(&.{"bash"});
    cli_test_env_check.addFileArg(b.path("scripts/check-cli-test-env.sh"));
    const cli_variation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli/variations/test_cli_variations.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "ovo", .module = ovo_module },
            },
        }),
    });
    const run_cli_variations = b.addRunArtifact(cli_variation_tests);
    run_cli_variations.step.dependOn(&cli_test_env_check.step);
    const cli_tests_variations = b.step("cli-tests-variations", "Run full CLI variation matrix checks");
    cli_tests_variations.dependOn(&run_cli_variations.step);

    const cli_tests = b.step("cli-tests", "Run all CLI tiers");
    cli_tests.dependOn(cli_tests_smoke);
    cli_tests.dependOn(cli_tests_deep);
    cli_tests.dependOn(cli_tests_stress);
    cli_tests.dependOn(cli_tests_integration);
    cli_tests.dependOn(cli_tests_variations);

    const help_matrix = b.step("cli-help-matrix", "Run `--help` for every CLI command");
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

    const version_consistency = addTestStep(
        b,
        "zig-version-consistency",
        "Verify active zig version matches .zigversion and build.zig.zon minimum",
        "tests/unit/test_zig_version_consistency.zig",
        ovo_module,
        target,
        optimize,
    );

    const toolchain_doctor = b.step("toolchain-doctor", "Diagnose toolchain environment");
    const doctor_run = b.addRunArtifact(exe);
    doctor_run.addArg("doctor");
    toolchain_doctor.dependOn(&doctor_run.step);

    const gendocs = b.step("gendocs", "Generate project documentation");
    const doc_run = b.addRunArtifact(exe);
    doc_run.addArg("doc");
    // Support passthrough args for gendocs as seen in some requirements
    if (b.args) |args| doc_run.addArgs(args);
    gendocs.dependOn(&doc_run.step);

    const check_docs = b.step("check-docs", "Verify documentation is up to date");
    check_docs.dependOn(gendocs);

    const full_check = b.step("full-check", "Run full verification gates");
    full_check.dependOn(version_consistency);
    full_check.dependOn(typecheck);
    full_check.dependOn(unit_tests);
    full_check.dependOn(cli_tests);
    full_check.dependOn(help_matrix);
    full_check.dependOn(toolchain_doctor);
    full_check.dependOn(check_docs);
}
