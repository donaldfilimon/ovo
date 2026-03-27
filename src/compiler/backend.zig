const std = @import("std");
const testing = std.testing;

pub const Backend = enum {
    clang,
    gcc,
    msvc,
    zigcc,
    cell,
};

pub const BackendValidationError = error{InvalidBackend};

pub fn supportedBackends() []const Backend {
    return &.{ .clang, .gcc, .msvc, .zigcc, .cell };
}

pub fn supportedBackendLabels() []const []const u8 {
    return &.{ "clang", "gcc", "msvc", "zigcc", "cell" };
}

pub fn parseBackend(value: []const u8) ?Backend {
    if (std.ascii.eqlIgnoreCase(value, "clang") or std.ascii.eqlIgnoreCase(value, "clang++")) return .clang;
    if (std.ascii.eqlIgnoreCase(value, "gcc") or std.ascii.eqlIgnoreCase(value, "g++")) return .gcc;
    if (std.ascii.eqlIgnoreCase(value, "msvc") or std.ascii.eqlIgnoreCase(value, "cl")) return .msvc;
    if (std.ascii.eqlIgnoreCase(value, "zigcc") or
        std.ascii.eqlIgnoreCase(value, "zig") or
        std.ascii.eqlIgnoreCase(value, "zig-cc") or
        std.ascii.eqlIgnoreCase(value, "zig c++") or
        std.ascii.eqlIgnoreCase(value, "zig-c++")) return .zigcc;
    if (std.ascii.eqlIgnoreCase(value, "cell") or
        std.ascii.eqlIgnoreCase(value, "cell-lang") or
        std.ascii.eqlIgnoreCase(value, "cellc")) return .cell;
    return null;
}

pub fn normalizeLabel(value: []const u8) ?[]const u8 {
    const backend = parseBackend(value) orelse return null;
    return label(backend);
}

pub fn label(backend: Backend) []const u8 {
    return switch (backend) {
        .clang => "clang",
        .gcc => "gcc",
        .msvc => "msvc",
        .zigcc => "zigcc",
        .cell => "cell",
    };
}

pub fn validateLabel(value: []const u8) BackendValidationError![]const u8 {
    const parsed = parseBackend(value) orelse return error.InvalidBackend;
    return label(parsed);
}

test "parseBackend accepts canonical names and common aliases" {
    const cases = [_]struct { input: []const u8, expected: ?Backend }{
        .{ .input = "clang", .expected = .clang },
        .{ .input = "clang++", .expected = .clang },
        .{ .input = "gcc", .expected = .gcc },
        .{ .input = "g++", .expected = .gcc },
        .{ .input = "msvc", .expected = .msvc },
        .{ .input = "cl", .expected = .msvc },
        .{ .input = "zigcc", .expected = .zigcc },
        .{ .input = "zig", .expected = .zigcc },
        .{ .input = "zig-cc", .expected = .zigcc },
        .{ .input = "zig-c++", .expected = .zigcc },
        .{ .input = "cell", .expected = .cell },
        .{ .input = "cell-lang", .expected = .cell },
        .{ .input = "cellc", .expected = .cell },
        .{ .input = "unknown", .expected = null },
    };

    for (cases) |case| {
        try testing.expectEqual(case.expected, parseBackend(case.input));
    }
}
