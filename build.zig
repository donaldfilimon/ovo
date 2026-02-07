const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ═══════════════════════════════════════════════════════════════════
    // Core modules
    // ═══════════════════════════════════════════════════════════════════

    // Utility module (no dependencies)
    const util_mod = b.addModule("util", .{
        .root_source_file = b.path("src/util/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Core data structures module
    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_mod },
        },
    });

    // ZON parsing module
    const zon_mod = b.addModule("zon", .{
        .root_source_file = b.path("src/zon/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "util", .module = util_mod },
        },
    });

    // Compiler abstraction module
    const compiler_mod = b.addModule("compiler", .{
        .root_source_file = b.path("src/compiler/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "util", .module = util_mod },
        },
    });

    // Build engine module
    const build_mod = b.addModule("build", .{
        .root_source_file = b.path("src/build/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "compiler", .module = compiler_mod },
            .{ .name = "util", .module = util_mod },
        },
    });

    // Package management module
    const package_mod = b.addModule("package", .{
        .root_source_file = b.path("src/package/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "util", .module = util_mod },
        },
    });

    // Translation module (importers/exporters)
    const translate_mod = b.addModule("translate", .{
        .root_source_file = b.path("src/translate/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "zon", .module = zon_mod },
            .{ .name = "util", .module = util_mod },
        },
    });

    // CLI module
    const cli_mod = b.addModule("cli", .{
        .root_source_file = b.path("src/cli/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "zon", .module = zon_mod },
            .{ .name = "build", .module = build_mod },
            .{ .name = "compiler", .module = compiler_mod },
            .{ .name = "package", .module = package_mod },
            .{ .name = "translate", .module = translate_mod },
            .{ .name = "util", .module = util_mod },
        },
    });

    // Main public module (re-exports everything)
    const ovo_mod = b.addModule("ovo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "zon", .module = zon_mod },
            .{ .name = "build", .module = build_mod },
            .{ .name = "compiler", .module = compiler_mod },
            .{ .name = "package", .module = package_mod },
            .{ .name = "translate", .module = translate_mod },
            .{ .name = "cli", .module = cli_mod },
            .{ .name = "util", .module = util_mod },
        },
    });

    // ═══════════════════════════════════════════════════════════════════
    // Main executable
    // ═══════════════════════════════════════════════════════════════════

    const exe = b.addExecutable(.{
        .name = "ovo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ovo", .module = ovo_mod },
                .{ .name = "cli", .module = cli_mod },
                .{ .name = "core", .module = core_mod },
                .{ .name = "util", .module = util_mod },
            },
        }),
    });

    b.installArtifact(exe);

    // ═══════════════════════════════════════════════════════════════════
    // Run step
    // ═══════════════════════════════════════════════════════════════════

    const run_step = b.step("run", "Run the ovo CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Tests
    // ═══════════════════════════════════════════════════════════════════

    const test_step = b.step("test", "Run all tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ovo", .module = ovo_mod },
                .{ .name = "cli", .module = cli_mod },
                .{ .name = "core", .module = core_mod },
                .{ .name = "util", .module = util_mod },
            },
        }),
    });
    unit_tests.root_module.addImport("ovo", ovo_mod);
    unit_tests.root_module.addImport("cli", cli_mod);
    unit_tests.root_module.addImport("core", core_mod);
    unit_tests.root_module.addImport("util", util_mod);
    unit_tests.root_module.addImport("zon", zon_mod);
    unit_tests.root_module.addImport("build", build_mod);
    unit_tests.root_module.addImport("compiler", compiler_mod);
    unit_tests.root_module.addImport("package", package_mod);
    unit_tests.root_module.addImport("translate", translate_mod);
    test_step.dependOn(&unit_tests.step);

    // ═══════════════════════════════════════════════════════════════════
    // Documentation
    // ═══════════════════════════════════════════════════════════════════

    const doc_step = b.step("docs", "Generate documentation");
    const doc_obj = b.addObject(.{
        .name = "ovo_docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "zon", .module = zon_mod },
                .{ .name = "build", .module = build_mod },
                .{ .name = "compiler", .module = compiler_mod },
                .{ .name = "package", .module = package_mod },
                .{ .name = "translate", .module = translate_mod },
                .{ .name = "cli", .module = cli_mod },
                .{ .name = "util", .module = util_mod },
            },
        }),
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = doc_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    doc_step.dependOn(&install_docs.step);

    // ═══════════════════════════════════════════════════════════════════
    // Check step (for IDE integration)
    // ═══════════════════════════════════════════════════════════════════

    const check_step = b.step("check", "Check compilation without codegen");
    const check_exe = b.addExecutable(.{
        .name = "ovo_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ovo", .module = ovo_mod },
                .{ .name = "cli", .module = cli_mod },
                .{ .name = "core", .module = core_mod },
                .{ .name = "util", .module = util_mod },
            },
        }),
    });
    check_step.dependOn(&check_exe.step);
}
