const std = @import("std");

pub const Backend = enum {
    clang,
    gcc,
    msvc,
    zigcc,
};

pub fn supportedBackends() []const Backend {
    return &.{ .clang, .gcc, .msvc, .zigcc };
}

pub fn parseBackend(value: []const u8) ?Backend {
    if (std.mem.eql(u8, value, "clang")) return .clang;
    if (std.mem.eql(u8, value, "gcc")) return .gcc;
    if (std.mem.eql(u8, value, "msvc")) return .msvc;
    if (std.mem.eql(u8, value, "zigcc")) return .zigcc;
    return null;
}

pub fn label(backend: Backend) []const u8 {
    return switch (backend) {
        .clang => "clang",
        .gcc => "gcc",
        .msvc => "msvc",
        .zigcc => "zigcc",
    };
}
