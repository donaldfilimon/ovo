const std = @import("std");
const ovo = @import("ovo");
const args = ovo.cli_args;
const registry = ovo.cli_registry;
const dispatch = ovo.cli_dispatch;

test "global flags parse before command" {
    const argv = [_][]const u8{
        "ovo",
        "--verbose",
        "--profile",
        "release-fast",
        "build",
    };
    const parsed = try args.parse(argv[0..]);

    try std.testing.expect(parsed.verbose);
    try std.testing.expect(parsed.profile != null);
    try std.testing.expectEqualStrings("release-fast", parsed.profile.?);
    try std.testing.expect(parsed.command != null);
    try std.testing.expectEqualStrings("build", parsed.command.?);
}

test "global flags support inline assignment form" {
    const argv = [_][]const u8{
        "ovo",
        "--cwd=.",
        "--profile=release-small",
        "info",
    };
    const parsed = try args.parse(argv[0..]);
    try std.testing.expect(parsed.cwd != null);
    try std.testing.expectEqualStrings(".", parsed.cwd.?);
    try std.testing.expect(parsed.profile != null);
    try std.testing.expectEqualStrings("release-small", parsed.profile.?);
}

test "registry and command dispatch parity" {
    for (registry.commands) |command| {
        try std.testing.expect(dispatch.hasHandler(command.name));
    }
}

test "zig 0.16 migration forbidden APIs are absent" {
    const forbidden = [_][]const u8{
        "std.process.argsAlloc()",
        "std.posix.getenv()",
    };

    var src = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer src.close(std.testing.io);
    var walker = try src.walk(std.testing.allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const full_path = try std.fmt.allocPrint(std.testing.allocator, "src/{s}", .{entry.path});
        defer std.testing.allocator.free(full_path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            full_path,
            std.testing.allocator,
            .limited(2 * 1024 * 1024),
        );
        defer std.testing.allocator.free(bytes);

        for (forbidden) |needle| {
            try std.testing.expect(std.mem.indexOf(u8, bytes, needle) == null);
        }
    }
}
