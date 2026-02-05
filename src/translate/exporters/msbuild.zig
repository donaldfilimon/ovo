//! MSBuild Exporter - build.zon -> .vcxproj/.sln
//!
//! Generates Visual Studio project files:
//! - .vcxproj files for each target
//! - .sln solution file
//! - Property sheets for Debug/Release configurations
//! - Proper project GUIDs and references

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../engine.zig");
const Project = engine.Project;
const Target = engine.Target;
const TargetKind = engine.TargetKind;
const TranslationOptions = engine.TranslationOptions;

/// GUID generator for Visual Studio projects
const GuidGenerator = struct {
    counter: u64 = 0,
    seed: u64,

    fn init() GuidGenerator {
        return .{
            .seed = @truncate(@as(u128, @intCast(std.time.nanoTimestamp()))),
        };
    }

    fn next(self: *GuidGenerator, buf: *[36]u8) void {
        self.counter += 1;
        const hash1 = std.hash.Wyhash.hash(self.seed, std.mem.asBytes(&self.counter));
        const hash2 = std.hash.Wyhash.hash(hash1, "guid");

        _ = std.fmt.bufPrint(buf, "{X:0>8}-{X:0>4}-{X:0>4}-{X:0>4}-{X:0>12}", .{
            @as(u32, @truncate(hash1)),
            @as(u16, @truncate(hash1 >> 32)),
            @as(u16, @truncate(hash1 >> 48)),
            @as(u16, @truncate(hash2)),
            @as(u48, @truncate(hash2 >> 16)),
        }) catch unreachable;
    }
};

/// Configuration type string
fn configType(kind: TargetKind) []const u8 {
    return switch (kind) {
        .executable => "Application",
        .static_library => "StaticLibrary",
        .shared_library => "DynamicLibrary",
        else => "Application",
    };
}

/// Target extension
fn targetExtension(kind: TargetKind) []const u8 {
    return switch (kind) {
        .executable => ".exe",
        .static_library => ".lib",
        .shared_library => ".dll",
        else => ".exe",
    };
}

/// Generate .vcxproj and .sln from Project
pub fn generate(allocator: Allocator, project: *const Project, output_path: []const u8, options: TranslationOptions) !void {
    _ = options;

    // Determine if output_path is .sln or directory
    const is_sln = std.mem.endsWith(u8, output_path, ".sln");
    const output_dir = if (is_sln)
        std.fs.path.dirname(output_path) orelse "."
    else
        output_path;

    // Create output directory if needed
    std.fs.cwd().makePath(output_dir) catch {};

    var guid_gen = GuidGenerator.init();

    // Generate GUIDs for each target
    const TargetGuid = struct {
        guid: [36]u8,
        vcxproj_path: []const u8,
    };

    var target_guids = std.ArrayList(TargetGuid).init(allocator);
    defer {
        for (target_guids.items) |tg| {
            allocator.free(tg.vcxproj_path);
        }
        target_guids.deinit();
    }

    // Generate .vcxproj for each target
    for (project.targets.items) |target| {
        var guid: [36]u8 = undefined;
        guid_gen.next(&guid);

        const vcxproj_name = try std.fmt.allocPrint(allocator, "{s}.vcxproj", .{target.name});
        defer allocator.free(vcxproj_name);

        const vcxproj_path = try std.fs.path.join(allocator, &.{ output_dir, vcxproj_name });

        try generateVcxproj(allocator, &target, vcxproj_path, guid, project.source_root);

        try target_guids.append(.{
            .guid = guid,
            .vcxproj_path = vcxproj_path,
        });
    }

    // Generate .sln file
    const sln_path = if (is_sln)
        output_path
    else
        try std.fs.path.join(allocator, &.{ output_dir, try std.fmt.allocPrint(allocator, "{s}.sln", .{project.name}) });

    try generateSolution(allocator, project, sln_path, target_guids.items);
}

fn generateVcxproj(allocator: Allocator, target: *const Target, output_path: []const u8, guid: [36]u8, source_root: []const u8) !void {
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    var writer = file.writer();

    // XML header
    try writer.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    try writer.writeAll("<Project DefaultTargets=\"Build\" xmlns=\"http://schemas.microsoft.com/developer/msbuild/2003\">\n");

    // Project configurations
    try writer.writeAll("  <ItemGroup Label=\"ProjectConfigurations\">\n");
    for ([_][]const u8{ "Debug", "Release" }) |config| {
        for ([_][]const u8{ "Win32", "x64" }) |platform| {
            try writer.print("    <ProjectConfiguration Include=\"{s}|{s}\">\n", .{ config, platform });
            try writer.print("      <Configuration>{s}</Configuration>\n", .{config});
            try writer.print("      <Platform>{s}</Platform>\n", .{platform});
            try writer.writeAll("    </ProjectConfiguration>\n");
        }
    }
    try writer.writeAll("  </ItemGroup>\n\n");

    // Global properties
    try writer.writeAll("  <PropertyGroup Label=\"Globals\">\n");
    try writer.writeAll("    <VCProjectVersion>16.0</VCProjectVersion>\n");
    try writer.print("    <ProjectGuid>{{{s}}}</ProjectGuid>\n", .{guid});
    try writer.print("    <RootNamespace>{s}</RootNamespace>\n", .{target.name});
    try writer.writeAll("    <WindowsTargetPlatformVersion>10.0</WindowsTargetPlatformVersion>\n");
    try writer.writeAll("  </PropertyGroup>\n\n");

    // Import default props
    try writer.writeAll("  <Import Project=\"$(VCTargetsPath)\\Microsoft.Cpp.Default.props\" />\n\n");

    // Configuration properties
    for ([_][]const u8{ "Debug", "Release" }) |config| {
        for ([_][]const u8{ "Win32", "x64" }) |platform| {
            try writer.print("  <PropertyGroup Condition=\"'$(Configuration)|$(Platform)'=='{s}|{s}'\" Label=\"Configuration\">\n", .{ config, platform });
            try writer.print("    <ConfigurationType>{s}</ConfigurationType>\n", .{configType(target.kind)});
            try writer.writeAll("    <UseDebugLibraries>");
            try writer.writeAll(if (std.mem.eql(u8, config, "Debug")) "true" else "false");
            try writer.writeAll("</UseDebugLibraries>\n");
            try writer.writeAll("    <PlatformToolset>v143</PlatformToolset>\n");
            if (std.mem.eql(u8, config, "Release")) {
                try writer.writeAll("    <WholeProgramOptimization>true</WholeProgramOptimization>\n");
            }
            try writer.writeAll("    <CharacterSet>Unicode</CharacterSet>\n");
            try writer.writeAll("  </PropertyGroup>\n");
        }
    }
    try writer.writeAll("\n");

    // Import C++ props
    try writer.writeAll("  <Import Project=\"$(VCTargetsPath)\\Microsoft.Cpp.props\" />\n");
    try writer.writeAll("  <ImportGroup Label=\"ExtensionSettings\">\n  </ImportGroup>\n\n");

    // Property sheets
    for ([_][]const u8{ "Debug", "Release" }) |config| {
        for ([_][]const u8{ "Win32", "x64" }) |platform| {
            try writer.print("  <ImportGroup Label=\"PropertySheets\" Condition=\"'$(Configuration)|$(Platform)'=='{s}|{s}'\">\n", .{ config, platform });
            try writer.writeAll("    <Import Project=\"$(UserRootDir)\\Microsoft.Cpp.$(Platform).user.props\" Condition=\"exists('$(UserRootDir)\\Microsoft.Cpp.$(Platform).user.props')\" Label=\"LocalAppDataPlatform\" />\n");
            try writer.writeAll("  </ImportGroup>\n");
        }
    }
    try writer.writeAll("\n");

    // Output directories
    for ([_][]const u8{ "Debug", "Release" }) |config| {
        for ([_][]const u8{ "Win32", "x64" }) |platform| {
            try writer.print("  <PropertyGroup Condition=\"'$(Configuration)|$(Platform)'=='{s}|{s}'\">\n", .{ config, platform });
            try writer.print("    <OutDir>$(SolutionDir)bin\\$(Configuration)\\</OutDir>\n", .{});
            try writer.print("    <IntDir>$(SolutionDir)obj\\$(Configuration)\\{s}\\</IntDir>\n", .{target.name});
            if (target.output_name) |out_name| {
                try writer.print("    <TargetName>{s}</TargetName>\n", .{out_name});
            }
            try writer.writeAll("  </PropertyGroup>\n");
        }
    }
    try writer.writeAll("\n");

    // Item definition groups (compiler/linker settings)
    for ([_][]const u8{ "Debug", "Release" }) |config| {
        for ([_][]const u8{ "Win32", "x64" }) |platform| {
            try writer.print("  <ItemDefinitionGroup Condition=\"'$(Configuration)|$(Platform)'=='{s}|{s}'\">\n", .{ config, platform });

            // ClCompile settings
            try writer.writeAll("    <ClCompile>\n");

            const is_debug = std.mem.eql(u8, config, "Debug");
            if (is_debug) {
                try writer.writeAll("      <Optimization>Disabled</Optimization>\n");
                try writer.writeAll("      <RuntimeLibrary>MultiThreadedDebugDLL</RuntimeLibrary>\n");
            } else {
                try writer.writeAll("      <Optimization>MaxSpeed</Optimization>\n");
                try writer.writeAll("      <FunctionLevelLinking>true</FunctionLevelLinking>\n");
                try writer.writeAll("      <IntrinsicFunctions>true</IntrinsicFunctions>\n");
                try writer.writeAll("      <RuntimeLibrary>MultiThreadedDLL</RuntimeLibrary>\n");
            }

            try writer.writeAll("      <WarningLevel>Level3</WarningLevel>\n");
            try writer.writeAll("      <SDLCheck>true</SDLCheck>\n");
            try writer.writeAll("      <ConformanceMode>true</ConformanceMode>\n");

            // Preprocessor definitions
            try writer.writeAll("      <PreprocessorDefinitions>");
            if (is_debug) {
                try writer.writeAll("_DEBUG;");
            } else {
                try writer.writeAll("NDEBUG;");
            }
            if (target.kind == .shared_library) {
                try writer.print("{s}_EXPORTS;", .{std.ascii.upperString(undefined[0..target.name.len], target.name)});
            }
            try writer.writeAll("WIN32;_WINDOWS;");
            for (target.flags.defines.items) |def| {
                try writer.print("{s};", .{def});
            }
            try writer.writeAll("%(PreprocessorDefinitions)</PreprocessorDefinitions>\n");

            // Include directories
            if (target.flags.include_paths.items.len > 0) {
                try writer.writeAll("      <AdditionalIncludeDirectories>");
                for (target.flags.include_paths.items) |inc| {
                    const rel = makeRelativePath(inc, source_root);
                    try writer.print("{s};", .{toWindowsPath(rel)});
                }
                try writer.writeAll("%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>\n");
            }

            try writer.writeAll("    </ClCompile>\n");

            // Link settings
            try writer.writeAll("    <Link>\n");
            try writer.writeAll("      <SubSystem>");
            try writer.writeAll(if (target.kind == .executable) "Console" else "Windows");
            try writer.writeAll("</SubSystem>\n");

            if (!is_debug) {
                try writer.writeAll("      <EnableCOMDATFolding>true</EnableCOMDATFolding>\n");
                try writer.writeAll("      <OptimizeReferences>true</OptimizeReferences>\n");
            }

            try writer.writeAll("      <GenerateDebugInformation>true</GenerateDebugInformation>\n");

            // Link libraries
            if (target.flags.link_libraries.items.len > 0) {
                try writer.writeAll("      <AdditionalDependencies>");
                for (target.flags.link_libraries.items) |lib| {
                    if (std.mem.endsWith(u8, lib, ".lib")) {
                        try writer.print("{s};", .{lib});
                    } else {
                        try writer.print("{s}.lib;", .{lib});
                    }
                }
                try writer.writeAll("%(AdditionalDependencies)</AdditionalDependencies>\n");
            }

            try writer.writeAll("    </Link>\n");

            // Lib settings for static libraries
            if (target.kind == .static_library) {
                try writer.writeAll("    <Lib>\n");
                try writer.writeAll("    </Lib>\n");
            }

            try writer.writeAll("  </ItemDefinitionGroup>\n");
        }
    }
    try writer.writeAll("\n");

    // Source files
    try writer.writeAll("  <ItemGroup>\n");
    for (target.sources.items) |src| {
        const rel = makeRelativePath(src, source_root);
        try writer.print("    <ClCompile Include=\"{s}\" />\n", .{toWindowsPath(rel)});
    }
    try writer.writeAll("  </ItemGroup>\n\n");

    // Header files
    if (target.headers.items.len > 0) {
        try writer.writeAll("  <ItemGroup>\n");
        for (target.headers.items) |hdr| {
            const rel = makeRelativePath(hdr, source_root);
            try writer.print("    <ClInclude Include=\"{s}\" />\n", .{toWindowsPath(rel)});
        }
        try writer.writeAll("  </ItemGroup>\n\n");
    }

    // Import targets
    try writer.writeAll("  <Import Project=\"$(VCTargetsPath)\\Microsoft.Cpp.targets\" />\n");
    try writer.writeAll("  <ImportGroup Label=\"ExtensionTargets\">\n  </ImportGroup>\n");

    try writer.writeAll("</Project>\n");

    _ = allocator;
}

fn generateSolution(allocator: Allocator, project: *const Project, output_path: []const u8, target_guids: []const struct { guid: [36]u8, vcxproj_path: []const u8 }) !void {
    _ = allocator;

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    var writer = file.writer();

    // Solution header
    try writer.writeAll("\xEF\xBB\xBF\n"); // UTF-8 BOM
    try writer.writeAll("Microsoft Visual Studio Solution File, Format Version 12.00\n");
    try writer.writeAll("# Visual Studio Version 17\n");
    try writer.writeAll("VisualStudioVersion = 17.0.31903.59\n");
    try writer.writeAll("MinimumVisualStudioVersion = 10.0.40219.1\n");

    // C++ project type GUID
    const cpp_type_guid = "8BC9CEB8-8B4A-11D0-8D11-00A0C91BC942";

    // Project entries
    for (project.targets.items, 0..) |target, idx| {
        const tg = target_guids[idx];
        const vcxproj_name = std.fs.path.basename(tg.vcxproj_path);

        try writer.print("Project(\"{{{s}}}\") = \"{s}\", \"{s}\", \"{{{s}}}\"\n", .{
            cpp_type_guid,
            target.name,
            vcxproj_name,
            tg.guid,
        });

        // Project dependencies
        if (target.dependencies.items.len > 0) {
            try writer.writeAll("\tProjectSection(ProjectDependencies) = postProject\n");
            for (target.dependencies.items) |dep_name| {
                // Find dependency's GUID
                for (project.targets.items, 0..) |dep_target, dep_idx| {
                    if (std.mem.eql(u8, dep_target.name, dep_name)) {
                        const dep_guid = target_guids[dep_idx].guid;
                        try writer.print("\t\t{{{s}}} = {{{s}}}\n", .{ dep_guid, dep_guid });
                        break;
                    }
                }
            }
            try writer.writeAll("\tEndProjectSection\n");
        }

        try writer.writeAll("EndProject\n");
    }

    // Global section
    try writer.writeAll("Global\n");

    // Solution configuration platforms
    try writer.writeAll("\tGlobalSection(SolutionConfigurationPlatforms) = preSolution\n");
    for ([_][]const u8{ "Debug", "Release" }) |config| {
        for ([_][]const u8{ "Win32", "x64" }) |platform| {
            try writer.print("\t\t{s}|{s} = {s}|{s}\n", .{ config, platform, config, platform });
        }
    }
    try writer.writeAll("\tEndGlobalSection\n");

    // Project configuration platforms
    try writer.writeAll("\tGlobalSection(ProjectConfigurationPlatforms) = postSolution\n");
    for (target_guids) |tg| {
        for ([_][]const u8{ "Debug", "Release" }) |config| {
            for ([_][]const u8{ "Win32", "x64" }) |platform| {
                try writer.print("\t\t{{{s}}}.{s}|{s}.ActiveCfg = {s}|{s}\n", .{ tg.guid, config, platform, config, platform });
                try writer.print("\t\t{{{s}}}.{s}|{s}.Build.0 = {s}|{s}\n", .{ tg.guid, config, platform, config, platform });
            }
        }
    }
    try writer.writeAll("\tEndGlobalSection\n");

    // Solution properties
    try writer.writeAll("\tGlobalSection(SolutionProperties) = preSolution\n");
    try writer.writeAll("\t\tHideSolutionNode = FALSE\n");
    try writer.writeAll("\tEndGlobalSection\n");

    try writer.writeAll("EndGlobal\n");
}

fn makeRelativePath(path: []const u8, base: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, base)) {
        var rel = path[base.len..];
        if (rel.len > 0 and rel[0] == '/') {
            rel = rel[1..];
        }
        if (rel.len == 0) return ".";
        return rel;
    }
    return path;
}

fn toWindowsPath(path: []const u8) []const u8 {
    // In a real implementation, we'd convert / to \
    // For now, return as-is since MSBuild handles both
    return path;
}

// Tests
test "configType" {
    try std.testing.expectEqualStrings("Application", configType(.executable));
    try std.testing.expectEqualStrings("StaticLibrary", configType(.static_library));
    try std.testing.expectEqualStrings("DynamicLibrary", configType(.shared_library));
}

test "makeRelativePath" {
    try std.testing.expectEqualStrings("src/main.cpp", makeRelativePath("/project/src/main.cpp", "/project"));
}
