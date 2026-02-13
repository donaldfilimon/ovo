const std = @import("std");
const ovo = @import("ovo");
const args = ovo.cli_args;
const dispatch = ovo.cli_dispatch;
const Context = ovo.cli_context.Context;

test "argument parser remains stable across repeated runs" {
    var i: usize = 0;
    while (i < 250) : (i += 1) {
        const argv = [_][]const u8{
            "ovo",
            "--profile",
            "debug",
            "build",
            "app",
            "--",
            "--flag",
        };
        const parsed = try args.parse(argv[0..]);
        try std.testing.expect(parsed.command != null);
        try std.testing.expectEqualStrings("build", parsed.command.?);
        try std.testing.expectEqual(@as(usize, 1), parsed.commandArgs().len);
    }
}

test "dispatch remains deterministic for repeated help command" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .cwd_path = ".",
        .quiet = true,
    };

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const argv = [_][]const u8{
            "ovo",
            "--help",
        };
        var parsed = try args.parse(argv[0..]);
        const exit_code = try dispatch.dispatch(&ctx, &parsed);
        try std.testing.expectEqual(@as(u8, 0), exit_code);
    }
}
