const std = @import("std");

pub const TargetType = enum {
    executable,
    library_static,
    library_shared,
    test_target,
};

pub const CppStandard = enum {
    c89,
    c99,
    c11,
    c17,
    cpp11,
    cpp14,
    cpp17,
    cpp20,
    cpp23,
};

pub const Target = struct {
    name: []const u8,
    kind: TargetType = .executable,
    sources: []const []const u8 = &.{},
    include_dirs: []const []const u8 = &.{},
    link_libraries: []const []const u8 = &.{},
};

pub const Dependency = struct {
    name: []const u8,
    version: []const u8 = "latest",
};

pub const Defaults = struct {
    cpp_standard: CppStandard = .cpp20,
    optimize: []const u8 = "Debug",
    backend: []const u8 = "zigcc",
    output_dir: []const u8 = ".ovo/build",
};

pub const Project = struct {
    ovo_schema: []const u8 = "0",
    name: []const u8,
    version: []const u8,
    license: ?[]const u8 = null,
    targets: []const Target = &.{},
    defaults: Defaults = .{},
    dependencies: []const Dependency = &.{},
};

pub fn parseTargetType(value: []const u8) ?TargetType {
    if (std.mem.eql(u8, value, "executable")) return .executable;
    if (std.mem.eql(u8, value, "library_static")) return .library_static;
    if (std.mem.eql(u8, value, "library_shared")) return .library_shared;
    if (std.mem.eql(u8, value, "test")) return .test_target;
    if (std.mem.eql(u8, value, "test_target")) return .test_target;
    return null;
}

pub fn targetTypeLabel(kind: TargetType) []const u8 {
    return switch (kind) {
        .executable => "executable",
        .library_static => "library_static",
        .library_shared => "library_shared",
        .test_target => "test",
    };
}

pub fn parseCppStandard(value: []const u8) ?CppStandard {
    if (std.mem.eql(u8, value, "c89")) return .c89;
    if (std.mem.eql(u8, value, "c99")) return .c99;
    if (std.mem.eql(u8, value, "c11")) return .c11;
    if (std.mem.eql(u8, value, "c17")) return .c17;
    if (std.mem.eql(u8, value, "cpp11")) return .cpp11;
    if (std.mem.eql(u8, value, "cpp14")) return .cpp14;
    if (std.mem.eql(u8, value, "cpp17")) return .cpp17;
    if (std.mem.eql(u8, value, "cpp20")) return .cpp20;
    if (std.mem.eql(u8, value, "cpp23")) return .cpp23;
    return null;
}

pub fn cppStandardLabel(value: CppStandard) []const u8 {
    return switch (value) {
        .c89 => "c89",
        .c99 => "c99",
        .c11 => "c11",
        .c17 => "c17",
        .cpp11 => "cpp11",
        .cpp14 => "cpp14",
        .cpp17 => "cpp17",
        .cpp20 => "cpp20",
        .cpp23 => "cpp23",
    };
}

pub fn guessProjectNameFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (base.len == 0 or std.mem.eql(u8, base, ".")) {
        return "app";
    }
    return base;
}
