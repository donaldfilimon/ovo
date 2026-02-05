const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ═══════════════════════════════════════════════════════════════════
    // Core modules
    // ═══════════════════════════════════════════════════════════════════

    // Utility module (no dependencies)
    const util_mod = b.addModule("ovo_util", .{
        .root_source_file = b.path("src/util/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Core data structures module
    const core_mod = b.addModule("ovo_core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_mod },
        },
    });

    // ZON parsing module
    const zon_mod = b.addModule("ovo_zon", .{
        .root_source_file = b.path("src/zon/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "util", .module = util_mod },
        },
    });

    // Compiler abstraction module
    const compiler_mod = b.addModule("ovo_compiler", .{
        .root_source_file = b.path("src/compiler/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "util", .module = util_mod },
        },
    });

    // Build engine module
    const build_mod = b.addModule("ovo_build", .{
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
    const package_mod = b.addModule("ovo_package", .{
        .root_source_file = b.path("src/package/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "util", .module = util_mod },
        },
    });

    // Translation module (importers/exporters)
    const translate_mod = b.addModule("ovo_translate", .{
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
    const cli_mod = b.addModule("ovo_cli", .{
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

    // Neural network module (legacy, for backwards compatibility)
    const neural_mod = b.addModule("ovo_neural", .{
        .root_source_file = b.path("src/neural/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Main public module (re-exports everything)
    // Note: neural module is imported via file path in root.zig, not as a module dependency
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

    // Test each module
    const test_modules = [_]struct { name: []const u8, mod: *std.Build.Module }{
        .{ .name = "util", .mod = util_mod },
        .{ .name = "core", .mod = core_mod },
        .{ .name = "zon", .mod = zon_mod },
        .{ .name = "compiler", .mod = compiler_mod },
        .{ .name = "build", .mod = build_mod },
        .{ .name = "package", .mod = package_mod },
        .{ .name = "translate", .mod = translate_mod },
        .{ .name = "cli", .mod = cli_mod },
        .{ .name = "neural", .mod = neural_mod },
    };

    for (test_modules) |tm| {
        const mod_test = b.addTest(.{
            .root_module = tm.mod,
        });
        const run_test = b.addRunArtifact(mod_test);
        test_step.dependOn(&run_test.step);
    }

    // Main module tests
    const main_tests = b.addTest(.{
        .root_module = ovo_mod,
    });
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

    // ═══════════════════════════════════════════════════════════════════
    // Documentation
    // ═══════════════════════════════════════════════════════════════════

    const docs_step = b.step("docs", "Generate documentation");
    const docs = b.addObject(.{
        .name = "ovo",
        .root_module = ovo_mod,
    });
    const install_docs = docs.getEmittedDocs();
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = install_docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);

    // ═══════════════════════════════════════════════════════════════════
    // Format check
    // ═══════════════════════════════════════════════════════════════════

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt = b.addFmt(.{
        .paths = &.{"src"},
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);
}
