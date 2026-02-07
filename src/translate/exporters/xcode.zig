//! Xcode Exporter - build.zon -> .xcodeproj
//!
//! Generates Xcode project files:
//! - project.pbxproj with proper UUIDs
//! - Native targets for executables and libraries
//! - Build configurations (Debug/Release)
//! - Source file references

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../engine.zig");
const Project = engine.Project;
const Target = engine.Target;
const TargetKind = engine.TargetKind;
const TranslationOptions = engine.TranslationOptions;

/// UUID generator for Xcode objects
const UuidGenerator = struct {
    counter: u64 = 0,
    seed: u64,

    fn init() UuidGenerator {
        return .{
            .seed = @truncate(@as(u128, @intCast(std.time.nanoTimestamp()))),
        };
    }

    fn next(self: *UuidGenerator) [24]u8 {
        self.counter += 1;
        var buf: [24]u8 = undefined;

        // Generate a 24-character hex UUID
        const hash = std.hash.Wyhash.hash(self.seed, std.mem.asBytes(&self.counter));
        _ = std.fmt.bufPrint(&buf, "{X:0>16}{X:0>8}", .{ hash, @as(u32, @truncate(self.counter)) }) catch unreachable;

        return buf;
    }
};

/// Xcode product type strings
fn productType(kind: TargetKind) []const u8 {
    return switch (kind) {
        .executable => "com.apple.product-type.tool",
        .static_library => "com.apple.product-type.library.static",
        .shared_library => "com.apple.product-type.library.dynamic",
        .interface, .header_only => "com.apple.product-type.bundle",
        .object_library => "com.apple.product-type.objfile",
        .custom => "com.apple.product-type.bundle",
    };
}

/// File type for Xcode
fn fileType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".c")) return "sourcecode.c.c";
    if (std.mem.endsWith(u8, path, ".cpp") or std.mem.endsWith(u8, path, ".cc")) return "sourcecode.cpp.cpp";
    if (std.mem.endsWith(u8, path, ".m")) return "sourcecode.c.objc";
    if (std.mem.endsWith(u8, path, ".mm")) return "sourcecode.cpp.objcpp";
    if (std.mem.endsWith(u8, path, ".swift")) return "sourcecode.swift";
    if (std.mem.endsWith(u8, path, ".h")) return "sourcecode.c.h";
    if (std.mem.endsWith(u8, path, ".hpp")) return "sourcecode.cpp.h";
    if (std.mem.endsWith(u8, path, ".a")) return "archive.ar";
    if (std.mem.endsWith(u8, path, ".dylib")) return "compiled.mach-o.dylib";
    if (std.mem.endsWith(u8, path, ".framework")) return "wrapper.framework";
    return "file";
}

/// Object reference tracking
const ObjectRefs = struct {
    project_ref: [24]u8,
    main_group_ref: [24]u8,
    sources_group_ref: [24]u8,
    products_group_ref: [24]u8,
    config_list_ref: [24]u8,
    debug_config_ref: [24]u8,
    release_config_ref: [24]u8,
};

/// Generate .xcodeproj from Project
pub fn generate(allocator: Allocator, project: *const Project, output_path: []const u8, options: TranslationOptions) !void {
    _ = options;

    // Create .xcodeproj directory
    try std.fs.cwd().makePath(output_path);

    // Create project.pbxproj
    const pbxproj_path = try std.fs.path.join(allocator, &.{ output_path, "project.pbxproj" });
    defer allocator.free(pbxproj_path);

    const file = try std.fs.cwd().createFile(pbxproj_path, .{});
    defer file.close();

    var writer = file.writer();
    var uuid = UuidGenerator.init();

    // Initialize object references
    const refs = ObjectRefs{
        .project_ref = uuid.next(),
        .main_group_ref = uuid.next(),
        .sources_group_ref = uuid.next(),
        .products_group_ref = uuid.next(),
        .config_list_ref = uuid.next(),
        .debug_config_ref = uuid.next(),
        .release_config_ref = uuid.next(),
    };

    // Generate UUIDs for each target and its components
    const TargetRefs = struct {
        target_ref: [24]u8,
        product_ref: [24]u8,
        sources_phase_ref: [24]u8,
        frameworks_phase_ref: [24]u8,
        config_list_ref: [24]u8,
        debug_config_ref: [24]u8,
        release_config_ref: [24]u8,
    };

    var target_refs = std.ArrayList(TargetRefs).init(allocator);
    defer target_refs.deinit();

    for (project.targets.items) |_| {
        try target_refs.append(.{
            .target_ref = uuid.next(),
            .product_ref = uuid.next(),
            .sources_phase_ref = uuid.next(),
            .frameworks_phase_ref = uuid.next(),
            .config_list_ref = uuid.next(),
            .debug_config_ref = uuid.next(),
            .release_config_ref = uuid.next(),
        });
    }

    // Generate file references for sources
    const FileRef = struct {
        ref: [24]u8,
        build_file_ref: [24]u8,
        path: []const u8,
        target_idx: usize,
    };

    var file_refs = std.ArrayList(FileRef).init(allocator);
    defer file_refs.deinit();

    for (project.targets.items, 0..) |target, idx| {
        for (target.sources.items) |src| {
            try file_refs.append(.{
                .ref = uuid.next(),
                .build_file_ref = uuid.next(),
                .path = src,
                .target_idx = idx,
            });
        }
    }

    // Write pbxproj header
    try writer.writeAll("// !$*UTF8*$!\n");
    try writer.writeAll("{\n");
    try writer.writeAll("\tarchiveVersion = 1;\n");
    try writer.writeAll("\tclasses = {\n\t};\n");
    try writer.writeAll("\tobjectVersion = 56;\n");
    try writer.writeAll("\tobjects = {\n\n");

    // PBXBuildFile section
    try writer.writeAll("/* Begin PBXBuildFile section */\n");
    for (file_refs.items) |fr| {
        const basename = std.fs.path.basename(fr.path);
        try writer.print("\t\t{s} /* {s} in Sources */ = {{isa = PBXBuildFile; fileRef = {s} /* {s} */; }};\n", .{ fr.build_file_ref, basename, fr.ref, basename });
    }
    try writer.writeAll("/* End PBXBuildFile section */\n\n");

    // PBXFileReference section
    try writer.writeAll("/* Begin PBXFileReference section */\n");
    for (file_refs.items) |fr| {
        const basename = std.fs.path.basename(fr.path);
        const ftype = fileType(fr.path);
        try writer.print("\t\t{s} /* {s} */ = {{isa = PBXFileReference; lastKnownFileType = {s}; path = \"{s}\"; sourceTree = \"<group>\"; }};\n", .{ fr.ref, basename, ftype, fr.path });
    }

    // Product references
    for (project.targets.items, 0..) |target, idx| {
        const tr = target_refs.items[idx];
        const product_name = target.output_name orelse target.name;
        const ext: []const u8 = switch (target.kind) {
            .executable => "",
            .static_library => ".a",
            .shared_library => ".dylib",
            else => "",
        };
        try writer.print("\t\t{s} /* {s}{s} */ = {{isa = PBXFileReference; explicitFileType = \"compiled.mach-o.executable\"; includeInIndex = 0; path = \"{s}{s}\"; sourceTree = BUILT_PRODUCTS_DIR; }};\n", .{ tr.product_ref, product_name, ext, product_name, ext });
    }
    try writer.writeAll("/* End PBXFileReference section */\n\n");

    // PBXFrameworksBuildPhase section
    try writer.writeAll("/* Begin PBXFrameworksBuildPhase section */\n");
    for (project.targets.items, 0..) |_, idx| {
        const tr = target_refs.items[idx];
        try writer.print("\t\t{s} /* Frameworks */ = {{\n", .{tr.frameworks_phase_ref});
        try writer.writeAll("\t\t\tisa = PBXFrameworksBuildPhase;\n");
        try writer.writeAll("\t\t\tbuildActionMask = 2147483647;\n");
        try writer.writeAll("\t\t\tfiles = (\n\t\t\t);\n");
        try writer.writeAll("\t\t\trunOnlyForDeploymentPostprocessing = 0;\n");
        try writer.writeAll("\t\t};\n");
    }
    try writer.writeAll("/* End PBXFrameworksBuildPhase section */\n\n");

    // PBXGroup section
    try writer.writeAll("/* Begin PBXGroup section */\n");

    // Main group
    try writer.print("\t\t{s} = {{\n", .{refs.main_group_ref});
    try writer.writeAll("\t\t\tisa = PBXGroup;\n");
    try writer.writeAll("\t\t\tchildren = (\n");
    try writer.print("\t\t\t\t{s} /* Sources */,\n", .{refs.sources_group_ref});
    try writer.print("\t\t\t\t{s} /* Products */,\n", .{refs.products_group_ref});
    try writer.writeAll("\t\t\t);\n");
    try writer.writeAll("\t\t\tsourceTree = \"<group>\";\n");
    try writer.writeAll("\t\t};\n");

    // Sources group
    try writer.print("\t\t{s} /* Sources */ = {{\n", .{refs.sources_group_ref});
    try writer.writeAll("\t\t\tisa = PBXGroup;\n");
    try writer.writeAll("\t\t\tchildren = (\n");
    for (file_refs.items) |fr| {
        const basename = std.fs.path.basename(fr.path);
        try writer.print("\t\t\t\t{s} /* {s} */,\n", .{ fr.ref, basename });
    }
    try writer.writeAll("\t\t\t);\n");
    try writer.writeAll("\t\t\tpath = Sources;\n");
    try writer.writeAll("\t\t\tsourceTree = \"<group>\";\n");
    try writer.writeAll("\t\t};\n");

    // Products group
    try writer.print("\t\t{s} /* Products */ = {{\n", .{refs.products_group_ref});
    try writer.writeAll("\t\t\tisa = PBXGroup;\n");
    try writer.writeAll("\t\t\tchildren = (\n");
    for (project.targets.items, 0..) |target, idx| {
        const tr = target_refs.items[idx];
        try writer.print("\t\t\t\t{s} /* {s} */,\n", .{ tr.product_ref, target.name });
    }
    try writer.writeAll("\t\t\t);\n");
    try writer.writeAll("\t\t\tname = Products;\n");
    try writer.writeAll("\t\t\tsourceTree = \"<group>\";\n");
    try writer.writeAll("\t\t};\n");

    try writer.writeAll("/* End PBXGroup section */\n\n");

    // PBXNativeTarget section
    try writer.writeAll("/* Begin PBXNativeTarget section */\n");
    for (project.targets.items, 0..) |target, idx| {
        const tr = target_refs.items[idx];
        try writer.print("\t\t{s} /* {s} */ = {{\n", .{ tr.target_ref, target.name });
        try writer.writeAll("\t\t\tisa = PBXNativeTarget;\n");
        try writer.print("\t\t\tbuildConfigurationList = {s} /* Build configuration list for PBXNativeTarget \"{s}\" */;\n", .{ tr.config_list_ref, target.name });
        try writer.writeAll("\t\t\tbuildPhases = (\n");
        try writer.print("\t\t\t\t{s} /* Sources */,\n", .{tr.sources_phase_ref});
        try writer.print("\t\t\t\t{s} /* Frameworks */,\n", .{tr.frameworks_phase_ref});
        try writer.writeAll("\t\t\t);\n");
        try writer.writeAll("\t\t\tbuildRules = (\n\t\t\t);\n");
        try writer.writeAll("\t\t\tdependencies = (\n\t\t\t);\n");
        try writer.print("\t\t\tname = {s};\n", .{target.name});
        try writer.print("\t\t\tproductName = {s};\n", .{target.name});
        try writer.print("\t\t\tproductReference = {s} /* {s} */;\n", .{ tr.product_ref, target.name });
        try writer.print("\t\t\tproductType = \"{s}\";\n", .{productType(target.kind)});
        try writer.writeAll("\t\t};\n");
    }
    try writer.writeAll("/* End PBXNativeTarget section */\n\n");

    // PBXProject section
    try writer.writeAll("/* Begin PBXProject section */\n");
    try writer.print("\t\t{s} /* Project object */ = {{\n", .{refs.project_ref});
    try writer.writeAll("\t\t\tisa = PBXProject;\n");
    try writer.writeAll("\t\t\tattributes = {\n");
    try writer.writeAll("\t\t\t\tBuildIndependentTargetsInParallel = 1;\n");
    try writer.writeAll("\t\t\t\tLastUpgradeCheck = 1500;\n");
    try writer.writeAll("\t\t\t};\n");
    try writer.print("\t\t\tbuildConfigurationList = {s} /* Build configuration list for PBXProject */;\n", .{refs.config_list_ref});
    try writer.writeAll("\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n");
    try writer.writeAll("\t\t\tdevelopmentRegion = en;\n");
    try writer.writeAll("\t\t\thasScannedForEncodings = 0;\n");
    try writer.writeAll("\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n");
    try writer.print("\t\t\tmainGroup = {s};\n", .{refs.main_group_ref});
    try writer.print("\t\t\tproductRefGroup = {s} /* Products */;\n", .{refs.products_group_ref});
    try writer.writeAll("\t\t\tprojectDirPath = \"\";\n");
    try writer.writeAll("\t\t\tprojectRoot = \"\";\n");
    try writer.writeAll("\t\t\ttargets = (\n");
    for (project.targets.items, 0..) |target, idx| {
        const tr = target_refs.items[idx];
        try writer.print("\t\t\t\t{s} /* {s} */,\n", .{ tr.target_ref, target.name });
    }
    try writer.writeAll("\t\t\t);\n");
    try writer.writeAll("\t\t};\n");
    try writer.writeAll("/* End PBXProject section */\n\n");

    // PBXSourcesBuildPhase section
    try writer.writeAll("/* Begin PBXSourcesBuildPhase section */\n");
    for (project.targets.items, 0..) |_, idx| {
        const tr = target_refs.items[idx];
        try writer.print("\t\t{s} /* Sources */ = {{\n", .{tr.sources_phase_ref});
        try writer.writeAll("\t\t\tisa = PBXSourcesBuildPhase;\n");
        try writer.writeAll("\t\t\tbuildActionMask = 2147483647;\n");
        try writer.writeAll("\t\t\tfiles = (\n");

        for (file_refs.items) |fr| {
            if (fr.target_idx == idx) {
                const basename = std.fs.path.basename(fr.path);
                try writer.print("\t\t\t\t{s} /* {s} in Sources */,\n", .{ fr.build_file_ref, basename });
            }
        }

        try writer.writeAll("\t\t\t);\n");
        try writer.writeAll("\t\t\trunOnlyForDeploymentPostprocessing = 0;\n");
        try writer.writeAll("\t\t};\n");
    }
    try writer.writeAll("/* End PBXSourcesBuildPhase section */\n\n");

    // XCBuildConfiguration section
    try writer.writeAll("/* Begin XCBuildConfiguration section */\n");

    // Project-level configurations
    try writeBuildConfiguration(&writer, refs.debug_config_ref, "Debug", true, null);
    try writeBuildConfiguration(&writer, refs.release_config_ref, "Release", false, null);

    // Target-level configurations
    for (project.targets.items, 0..) |target, idx| {
        const tr = target_refs.items[idx];
        try writeBuildConfiguration(&writer, tr.debug_config_ref, "Debug", true, &target);
        try writeBuildConfiguration(&writer, tr.release_config_ref, "Release", false, &target);
    }

    try writer.writeAll("/* End XCBuildConfiguration section */\n\n");

    // XCConfigurationList section
    try writer.writeAll("/* Begin XCConfigurationList section */\n");

    // Project configuration list
    try writer.print("\t\t{s} /* Build configuration list for PBXProject */ = {{\n", .{refs.config_list_ref});
    try writer.writeAll("\t\t\tisa = XCConfigurationList;\n");
    try writer.writeAll("\t\t\tbuildConfigurations = (\n");
    try writer.print("\t\t\t\t{s} /* Debug */,\n", .{refs.debug_config_ref});
    try writer.print("\t\t\t\t{s} /* Release */,\n", .{refs.release_config_ref});
    try writer.writeAll("\t\t\t);\n");
    try writer.writeAll("\t\t\tdefaultConfigurationIsVisible = 0;\n");
    try writer.writeAll("\t\t\tdefaultConfigurationName = Release;\n");
    try writer.writeAll("\t\t};\n");

    // Target configuration lists
    for (project.targets.items, 0..) |target, idx| {
        const tr = target_refs.items[idx];
        try writer.print("\t\t{s} /* Build configuration list for PBXNativeTarget \"{s}\" */ = {{\n", .{ tr.config_list_ref, target.name });
        try writer.writeAll("\t\t\tisa = XCConfigurationList;\n");
        try writer.writeAll("\t\t\tbuildConfigurations = (\n");
        try writer.print("\t\t\t\t{s} /* Debug */,\n", .{tr.debug_config_ref});
        try writer.print("\t\t\t\t{s} /* Release */,\n", .{tr.release_config_ref});
        try writer.writeAll("\t\t\t);\n");
        try writer.writeAll("\t\t\tdefaultConfigurationIsVisible = 0;\n");
        try writer.writeAll("\t\t\tdefaultConfigurationName = Release;\n");
        try writer.writeAll("\t\t};\n");
    }

    try writer.writeAll("/* End XCConfigurationList section */\n");

    // Close objects and root
    try writer.writeAll("\t};\n");
    try writer.print("\trootObject = {s} /* Project object */;\n", .{refs.project_ref});
    try writer.writeAll("}\n");
}

fn writeBuildConfiguration(writer: anytype, ref: [24]u8, name: []const u8, is_debug: bool, target: ?*const Target) !void {
    try writer.print("\t\t{s} /* {s} */ = {{\n", .{ ref, name });
    try writer.writeAll("\t\t\tisa = XCBuildConfiguration;\n");
    try writer.writeAll("\t\t\tbuildSettings = {\n");

    if (target == null) {
        // Project-level settings
        try writer.writeAll("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;\n");
        try writer.writeAll("\t\t\t\tCLANG_ANALYZER_NONNULL = YES;\n");
        try writer.writeAll("\t\t\t\tCLANG_ENABLE_MODULES = YES;\n");
        try writer.writeAll("\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;\n");

        if (is_debug) {
            try writer.writeAll("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;\n");
            try writer.writeAll("\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;\n");
            try writer.writeAll("\t\t\t\tONLY_ACTIVE_ARCH = YES;\n");
        } else {
            try writer.writeAll("\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";\n");
            try writer.writeAll("\t\t\t\tGCC_OPTIMIZATION_LEVEL = s;\n");
            try writer.writeAll("\t\t\t\tENABLE_NS_ASSERTIONS = NO;\n");
        }

        try writer.writeAll("\t\t\t\tSDKROOT = macosx;\n");
    } else {
        // Target-level settings
        const t = target.?;
        try writer.print("\t\t\t\tPRODUCT_NAME = \"{s}\";\n", .{t.output_name orelse t.name});

        // Include paths
        if (t.flags.include_paths.items.len > 0) {
            try writer.writeAll("\t\t\t\tHEADER_SEARCH_PATHS = (\n");
            for (t.flags.include_paths.items) |inc| {
                try writer.print("\t\t\t\t\t\"{s}\",\n", .{inc});
            }
            try writer.writeAll("\t\t\t\t);\n");
        }

        // Preprocessor definitions
        if (t.flags.defines.items.len > 0) {
            try writer.writeAll("\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (\n");
            for (t.flags.defines.items) |def| {
                try writer.print("\t\t\t\t\t\"{s}\",\n", .{def});
            }
            if (is_debug) {
                try writer.writeAll("\t\t\t\t\t\"DEBUG=1\",\n");
            }
            try writer.writeAll("\t\t\t\t);\n");
        } else if (is_debug) {
            try writer.writeAll("\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = \"DEBUG=1\";\n");
        }
    }

    try writer.writeAll("\t\t\t};\n");
    try writer.print("\t\t\tname = {s};\n", .{name});
    try writer.writeAll("\t\t};\n");
}

// Tests
test "fileType" {
    try std.testing.expectEqualStrings("sourcecode.c.c", fileType("main.c"));
    try std.testing.expectEqualStrings("sourcecode.cpp.cpp", fileType("main.cpp"));
    try std.testing.expectEqualStrings("sourcecode.c.h", fileType("header.h"));
}

test "productType" {
    try std.testing.expectEqualStrings("com.apple.product-type.tool", productType(.executable));
    try std.testing.expectEqualStrings("com.apple.product-type.library.static", productType(.static_library));
}
