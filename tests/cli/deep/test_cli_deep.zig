const std = @import("std");
const ovo = @import("ovo");
const args = ovo.cli_args;
const dispatch = ovo.cli_dispatch;
const Context = ovo.cli_context.Context;

test "unknown global flag fails parse" {
    const argv = [_][]const u8{
        "ovo",
        "--does-not-exist",
    };
    try std.testing.expectError(error.UnknownGlobalFlag, args.parse(argv[0..]));
}

test "unknown command returns non-zero" {
    const argv = [_][]const u8{
        "ovo",
        "unknown-command",
    };
    var parsed = try args.parse(argv[0..]);
    var ctx = Context{
        .allocator = std.testing.allocator,
        .cwd_path = ".",
        .quiet = true,
    };
    const exit_code = try dispatch.dispatch(&ctx, &parsed);
    try std.testing.expectEqual(@as(u8, 1), exit_code);
}

test "command help can be requested at command level" {
    const argv = [_][]const u8{
        "ovo",
        "build",
        "--help",
    };
    var parsed = try args.parse(argv[0..]);
    var ctx = Context{
        .allocator = std.testing.allocator,
        .cwd_path = ".",
        .quiet = true,
    };
    const exit_code = try dispatch.dispatch(&ctx, &parsed);
    try std.testing.expectEqual(@as(u8, 0), exit_code);
}
