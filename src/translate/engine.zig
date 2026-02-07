//! Translation Engine - Coordinates import/export between build systems
//!
//! Supports bidirectional translation:
//! - Import: CMake, Xcode, MSBuild, Meson, Makefile, vcpkg, Conan -> build.zon
//! - Export: build.zon -> CMake, Xcode, MSBuild, Ninja, compile_commands.json

const std = @import("std");
const Allocator = std.mem.Allocator;

// Import modules
pub const cmake_importer = @import("importers/cmake.zig");
pub const xcode_importer = @import("importers/xcode.zig");
pub const msbuild_importer = @import("importers/msbuild.zig");
pub const meson_importer = @import("importers/meson.zig");
pub const makefile_importer = @import("importers/makefile.zig");
pub const vcpkg_importer = @import("importers/vcpkg_manifest.zig");
pub const conan_importer = @import("importers/conan_manifest.zig");

// Export modules
pub const cmake_exporter = @import("exporters/cmake.zig");
pub const xcode_exporter = @import("exporters/xcode.zig");
pub const msbuild_exporter = @import("exporters/msbuild.zig");
pub const ninja_exporter = @import("exporters/ninja.zig");
pub const compile_db_exporter = @import("exporters/compile_db.zig");

// Analysis modules
pub const source_scan = @import("analysis/source_scan.zig");
pub const dep_detect = @import("analysis/dep_detect.zig");

/// Build system format enumeration
pub const BuildFormat = enum {
    build_zon,
    cmake,
    xcode,
    msbuild,
    meson,
    makefile,
    ninja,
    compile_commands,
    vcpkg,
    conan,

    pub fn extension(self: BuildFormat) []const u8 {
        return switch (self) {
            .build_zon => "build.zon",
            .cmake => "CMakeLists.txt",
            .xcode => ".xcodeproj",
            .msbuild => ".vcxproj",
            .meson => "meson.build",
            .makefile => "Makefile",
            .ninja => "build.ninja",
            .compile_commands => "compile_commands.json",
            .vcpkg => "vcpkg.json",
            .conan => "conanfile.txt",
        };
    }

    pub fn displayName(self: BuildFormat) []const u8 {
        return switch (self) {
            .build_zon => "Zig Build (build.zon)",
            .cmake => "CMake",
            .xcode => "Xcode Project",
            .msbuild => "MSBuild (Visual Studio)",
            .meson => "Meson",
            .makefile => "Makefile",
            .ninja => "Ninja",
            .compile_commands => "Compilation Database",
            .vcpkg => "vcpkg Manifest",
            .conan => "Conan Package Manager",
        };
    }
};

/// Translation warning severity levels
pub const WarningSeverity = enum {
    info,
    warning,
    @"error",

    pub fn prefix(self: WarningSeverity) []const u8 {
        return switch (self) {
            .info => "info",
            .warning => "warning",
            .@"error" => "error",
        };
    }
};

/// Translation warning for untranslatable features
pub const TranslationWarning = struct {
    severity: WarningSeverity,
    message: []const u8,
    source_location: ?[]const u8 = null,
    suggestion: ?[]const u8 = null,

    pub fn format(
        self: TranslationWarning,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("[{s}]", .{self.severity.prefix()});

        if (self.source_location) |loc| {
            try writer.print(" {s}:", .{loc});
        }

        try writer.print(" {s}", .{self.message});

        if (self.suggestion) |sug| {
            try writer.print(" (suggestion: {s})", .{sug});
        }
    }
};

/// Project target type
pub const TargetKind = enum {
    executable,
    static_library,
    shared_library,
    header_only,
    interface,
    object_library,
    custom,
};

/// Compiler/linker flags
pub const CompileFlags = struct {
    allocator: Allocator,
    defines: std.ArrayList([]const u8),
    include_paths: std.ArrayList([]const u8),
    system_include_paths: std.ArrayList([]const u8),
    compile_flags: std.ArrayList([]const u8),
    link_flags: std.ArrayList([]const u8),
    link_libraries: std.ArrayList([]const u8),
    frameworks: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator) CompileFlags {
        return .{
            .allocator = allocator,
            .defines = .empty,
            .include_paths = .empty,
            .system_include_paths = .empty,
            .compile_flags = .empty,
            .link_flags = .empty,
            .link_libraries = .empty,
            .frameworks = .empty,
        };
    }

    pub fn deinit(self: *CompileFlags) void {
        self.defines.deinit(self.allocator);
        self.include_paths.deinit(self.allocator);
        self.system_include_paths.deinit(self.allocator);
        self.compile_flags.deinit(self.allocator);
        self.link_flags.deinit(self.allocator);
        self.link_libraries.deinit(self.allocator);
        self.frameworks.deinit(self.allocator);
    }
};

/// Build configuration (Debug, Release, etc.)
pub const BuildConfig = struct {
    name: []const u8,
    flags: CompileFlags,
    optimization: OptimizationLevel = .none,

    pub const OptimizationLevel = enum {
        none,
        debug,
        release_safe,
        release_fast,
        release_small,
    };
};

/// Project dependency
pub const Dependency = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    url: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    path: ?[]const u8 = null,
    kind: Kind = .build,

    pub const Kind = enum {
        build,
        dev,
        optional,
        system,
    };
};

/// Build target representation
pub const Target = struct {
    allocator: Allocator,
    name: []const u8,
    kind: TargetKind,
    sources: std.ArrayList([]const u8),
    headers: std.ArrayList([]const u8),
    flags: CompileFlags,
    dependencies: std.ArrayList([]const u8),
    output_name: ?[]const u8 = null,
    install_path: ?[]const u8 = null,

    pub fn init(allocator: Allocator, name: []const u8, kind: TargetKind) Target {
        return .{
            .allocator = allocator,
            .name = name,
            .kind = kind,
            .sources = .empty,
            .headers = .empty,
            .flags = CompileFlags.init(allocator),
            .dependencies = .empty,
        };
    }

    pub fn deinit(self: *Target, allocator: Allocator) void {
        self.sources.deinit(allocator);
        self.headers.deinit(allocator);
        self.flags.deinit();
        self.dependencies.deinit(allocator);
    }
};

/// Unified project representation
pub const Project = struct {
    allocator: Allocator,
    name: []const u8,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    license: ?[]const u8 = null,
    minimum_zig_version: ?[]const u8 = null,
    targets: std.ArrayList(Target),
    dependencies: std.ArrayList(Dependency),
    configs: std.ArrayList(BuildConfig),
    source_root: []const u8,
    warnings: std.ArrayList(TranslationWarning),

    pub fn init(allocator: Allocator, name: []const u8, source_root: []const u8) Project {
        return .{
            .allocator = allocator,
            .name = name,
            .source_root = source_root,
            .targets = .empty,
            .dependencies = .empty,
            .configs = .empty,
            .warnings = .empty,
        };
    }

    pub fn deinit(self: *Project) void {
        for (self.targets.items) |*target| {
            target.deinit(self.allocator);
        }
        self.targets.deinit(self.allocator);
        self.dependencies.deinit(self.allocator);
        for (self.configs.items) |*config| {
            config.flags.deinit();
        }
        self.configs.deinit(self.allocator);
        self.warnings.deinit(self.allocator);
    }

    pub fn addWarning(self: *Project, warning: TranslationWarning) !void {
        try self.warnings.append(self.allocator, warning);
    }

    pub fn addTarget(self: *Project, target: Target) !void {
        try self.targets.append(self.allocator, target);
    }

    pub fn addDependency(self: *Project, dep: Dependency) !void {
        try self.dependencies.append(self.allocator, dep);
    }
};

/// Translation result
pub const TranslationResult = struct {
    success: bool,
    project: ?Project = null,
    output_path: ?[]const u8 = null,
    warnings: std.ArrayList(TranslationWarning),
    error_message: ?[]const u8 = null,

    pub fn init(allocator: Allocator) TranslationResult {
        return .{
            .success = false,
            .warnings = std.ArrayList(TranslationWarning).init(allocator),
        };
    }

    pub fn deinit(self: *TranslationResult) void {
        if (self.project) |*proj| {
            proj.deinit();
        }
        self.warnings.deinit();
    }
};

/// Translation engine options
pub const TranslationOptions = struct {
    /// Preserve comments where possible
    preserve_comments: bool = true,
    /// Generate IDE integration files
    generate_ide_files: bool = true,
    /// Verbose output during translation
    verbose: bool = false,
    /// Strict mode - fail on warnings
    strict: bool = false,
    /// Target architecture override
    target_arch: ?[]const u8 = null,
    /// Target OS override
    target_os: ?[]const u8 = null,
    /// Output directory override
    output_dir: ?[]const u8 = null,
    /// CMake minimum version for export
    cmake_min_version: []const u8 = "3.20",
    /// Generate compile_commands.json
    generate_compile_commands: bool = true,
};

/// Main translation engine
pub const Engine = struct {
    allocator: Allocator,
    options: TranslationOptions,

    const Self = @This();

    pub fn init(allocator: Allocator, options: TranslationOptions) Self {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    /// Detect build system format from file/directory path
    pub fn detectFormat(self: *Self, path: []const u8) !BuildFormat {
        _ = self;
        const basename = std.fs.path.basename(path);

        // Check exact filename matches
        if (std.mem.eql(u8, basename, "CMakeLists.txt")) return .cmake;
        if (std.mem.eql(u8, basename, "meson.build")) return .meson;
        if (std.mem.eql(u8, basename, "Makefile") or std.mem.eql(u8, basename, "makefile")) return .makefile;
        if (std.mem.eql(u8, basename, "build.ninja")) return .ninja;
        if (std.mem.eql(u8, basename, "compile_commands.json")) return .compile_commands;
        if (std.mem.eql(u8, basename, "vcpkg.json")) return .vcpkg;
        if (std.mem.eql(u8, basename, "conanfile.txt") or std.mem.eql(u8, basename, "conanfile.py")) return .conan;
        if (std.mem.eql(u8, basename, "build.zon")) return .build_zon;

        // Check extensions
        if (std.mem.endsWith(u8, path, ".xcodeproj")) return .xcode;
        if (std.mem.endsWith(u8, path, ".vcxproj") or std.mem.endsWith(u8, path, ".sln")) return .msbuild;

        return error.UnknownFormat;
    }

    /// Import from external build system to Project
    pub fn import(self: *Self, format: BuildFormat, input_path: []const u8) !Project {
        return switch (format) {
            .cmake => try cmake_importer.parse(self.allocator, input_path, self.options),
            .xcode => try xcode_importer.parse(self.allocator, input_path, self.options),
            .msbuild => try msbuild_importer.parse(self.allocator, input_path, self.options),
            .meson => try meson_importer.parse(self.allocator, input_path, self.options),
            .makefile => try makefile_importer.parse(self.allocator, input_path, self.options),
            .vcpkg => try vcpkg_importer.parse(self.allocator, input_path, self.options),
            .conan => try conan_importer.parse(self.allocator, input_path, self.options),
            .build_zon => return error.AlreadyBuildZon,
            else => return error.ImportNotSupported,
        };
    }

    /// Export Project to external build system format
    pub fn @"export"(self: *Self, project: *const Project, format: BuildFormat, output_path: []const u8) !void {
        switch (format) {
            .cmake => try cmake_exporter.generate(self.allocator, project, output_path, self.options),
            .xcode => try xcode_exporter.generate(self.allocator, project, output_path, self.options),
            .msbuild => try msbuild_exporter.generate(self.allocator, project, output_path, self.options),
            .ninja => try ninja_exporter.generate(self.allocator, project, output_path, self.options),
            .compile_commands => try compile_db_exporter.generate(self.allocator, project, output_path, self.options),
            .build_zon => try self.exportBuildZon(project, output_path),
            else => return error.ExportNotSupported,
        }

        // Generate compile_commands.json alongside if requested
        if (self.options.generate_compile_commands and format != .compile_commands) {
            const dir = std.fs.path.dirname(output_path) orelse ".";
            const compile_db_path = try std.fs.path.join(self.allocator, &.{ dir, "compile_commands.json" });
            defer self.allocator.free(compile_db_path);
            try compile_db_exporter.generate(self.allocator, project, compile_db_path, self.options);
        }
    }

    /// Translate between two formats
    pub fn translate(self: *Self, source_format: BuildFormat, source_path: []const u8, target_format: BuildFormat, target_path: []const u8) !TranslationResult {
        var result = TranslationResult.init(self.allocator);
        errdefer result.deinit();

        // Import from source format
        var project = self.import(source_format, source_path) catch |err| {
            result.error_message = @errorName(err);
            return result;
        };
        errdefer project.deinit();

        // Copy warnings from project
        for (project.warnings.items) |warning| {
            try result.warnings.append(warning);
        }

        // Check strict mode
        if (self.options.strict) {
            for (result.warnings.items) |warning| {
                if (warning.severity == .@"error") {
                    result.error_message = "Translation failed due to errors in strict mode";
                    return result;
                }
            }
        }

        // Export to target format
        self.@"export"(&project, target_format, target_path) catch |err| {
            result.error_message = @errorName(err);
            return result;
        };

        result.success = true;
        result.project = project;
        result.output_path = target_path;
        return result;
    }

    /// Export to build.zon format
    fn exportBuildZon(self: *Self, project: *const Project, output_path: []const u8) !void {
        const file = try std.fs.cwd().createFile(output_path, .{});
        defer file.close();

        var writer = file.writer();

        try writer.print(
            \\.{{
            \\    .name = "{s}",
            \\
        , .{project.name});

        if (project.version) |ver| {
            try writer.print("    .version = \"{s}\",\n", .{ver});
        }

        if (project.minimum_zig_version) |zig_ver| {
            try writer.print("    .minimum_zig_version = \"{s}\",\n", .{zig_ver});
        }

        // Dependencies
        try writer.writeAll("    .dependencies = .{\n");
        for (project.dependencies.items) |dep| {
            try writer.print("        .{s} = .{{\n", .{dep.name});
            if (dep.url) |url| {
                try writer.print("            .url = \"{s}\",\n", .{url});
            }
            if (dep.hash) |hash| {
                try writer.print("            .hash = \"{s}\",\n", .{hash});
            }
            if (dep.path) |path| {
                try writer.print("            .path = \"{s}\",\n", .{path});
            }
            try writer.writeAll("        },\n");
        }
        try writer.writeAll("    },\n");

        // Paths
        try writer.writeAll("    .paths = .{\n");
        try writer.writeAll("        \"build.zig\",\n");
        try writer.writeAll("        \"build.zig.zon\",\n");
        try writer.writeAll("        \"src\",\n");
        try writer.writeAll("    },\n");

        try writer.writeAll("}\n");

        _ = self;
    }

    /// Analyze project directory and detect sources/dependencies
    pub fn analyzeProject(self: *Self, project_dir: []const u8) !source_scan.ScanResult {
        return try source_scan.scan(self.allocator, project_dir, .{
            .recursive = true,
            .follow_symlinks = false,
            .include_headers = true,
            .detect_dependencies = true,
        });
    }

    /// Print translation warnings
    pub fn printWarnings(self: *Self, warnings: []const TranslationWarning, writer: anytype) !void {
        _ = self;
        for (warnings) |warning| {
            try writer.print("{}\n", .{warning});
        }
    }
};

// Tests
test "Engine.detectFormat" {
    var engine = Engine.init(std.testing.allocator, .{});

    try std.testing.expectEqual(BuildFormat.cmake, try engine.detectFormat("CMakeLists.txt"));
    try std.testing.expectEqual(BuildFormat.meson, try engine.detectFormat("/path/to/meson.build"));
    try std.testing.expectEqual(BuildFormat.makefile, try engine.detectFormat("Makefile"));
    try std.testing.expectEqual(BuildFormat.xcode, try engine.detectFormat("Project.xcodeproj"));
    try std.testing.expectEqual(BuildFormat.msbuild, try engine.detectFormat("Project.vcxproj"));
    try std.testing.expectEqual(BuildFormat.vcpkg, try engine.detectFormat("vcpkg.json"));
}

test "Project lifecycle" {
    const allocator = std.testing.allocator;
    var project = Project.init(allocator, "test_project", "/path/to/project");
    defer project.deinit();

    try project.addWarning(.{
        .severity = .warning,
        .message = "Test warning",
    });

    try std.testing.expectEqual(@as(usize, 1), project.warnings.items.len);
}
