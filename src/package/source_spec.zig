const std = @import("std");

pub const SourceKind = enum {
    registry,
    git,
    tar,
    local,
};

pub const DependencyOrigin = enum {
    registry,
    direct,
};

pub const DependencySpec = struct {
    kind: SourceKind,
    request: []const u8,
    explicit: bool,
};

pub fn classify(request: []const u8) DependencySpec {
    if (std.mem.startsWith(u8, request, "git+")) {
        return .{ .kind = .git, .request = request["git+".len..], .explicit = true };
    }

    if (std.mem.startsWith(u8, request, "path:")) {
        return .{ .kind = .local, .request = request["path:".len..], .explicit = true };
    }

    if (isLikelyUrl(request)) {
        if (isLikelyTarArchive(request)) {
            return .{ .kind = .tar, .request = request, .explicit = false };
        }
        return .{ .kind = .git, .request = request, .explicit = false };
    }

    if (isLikelyPath(request)) {
        return .{ .kind = .local, .request = request, .explicit = false };
    }

    return .{ .kind = .registry, .request = request, .explicit = false };
}

pub fn canonicalSpec(kind: SourceKind, request: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    return switch (kind) {
        .git => try std.fmt.allocPrint(allocator, "git+{s}", .{request}),
        .local => try std.fmt.allocPrint(allocator, "path:{s}", .{request}),
        .registry, .tar => try allocator.dupe(u8, request),
    };
}

pub fn splitGitRef(request: []const u8) struct { url: []const u8, ref: []const u8 } {
    const i = std.mem.indexOfScalar(u8, request, '#') orelse return .{ .url = request, .ref = "" };
    if (i == 0) return .{ .url = "", .ref = request[1..] };
    if (i == request.len - 1) return .{ .url = request[0..i], .ref = "HEAD" };
    return .{ .url = request[0..i], .ref = request[i + 1 ..] };
}

pub fn sourceLabel(kind: SourceKind) []const u8 {
    return switch (kind) {
        .registry => "registry",
        .git => "git",
        .tar => "tar",
        .local => "local",
    };
}

fn isLikelyUrl(request: []const u8) bool {
    if (request.len == 0) return false;
    return std.mem.startsWith(u8, request, "https://") or
        std.mem.startsWith(u8, request, "http://") or
        std.mem.startsWith(u8, request, "git@") or
        std.mem.startsWith(u8, request, "ssh://") or
        std.mem.endsWith(u8, request, ".git") or
        std.mem.indexOf(u8, request, "://") != null;
}

fn isLikelyTarArchive(request: []const u8) bool {
    return std.mem.endsWith(u8, request, ".tar") or
        std.mem.endsWith(u8, request, ".tar.gz") or
        std.mem.endsWith(u8, request, ".tgz") or
        std.mem.endsWith(u8, request, ".zip");
}

fn isLikelyPath(request: []const u8) bool {
    if (request.len == 0) return false;
    if (std.fs.path.isAbsolute(request)) return true;
    return std.mem.startsWith(u8, request, "./") or
        std.mem.startsWith(u8, request, "../") or
        std.mem.indexOf(u8, request, "/") != null;
}
