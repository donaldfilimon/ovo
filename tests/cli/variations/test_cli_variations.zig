const std = @import("std");
const ovo = @import("ovo");
const args = ovo.cli_args;
const dispatch = ovo.cli_dispatch;
const Context = ovo.cli_context.Context;

test "new parser preserves nested relative path argument" {
    const argv = [_][]const u8{
        "ovo",
        "new",
        "apps/my app",
    };

    const parsed = try args.parse(argv[0..]);
    try std.testing.expect(parsed.command != null);
    try std.testing.expectEqualStrings("new", parsed.command.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.commandArgs().len);
    try std.testing.expectEqualStrings("apps/my app", parsed.commandArgs()[0]);
}

test "new rejects extra positional arguments" {
    const argv = [_][]const u8{
        "ovo",
        "new",
        "myapp",
        "extra",
    };

    var parsed = try args.parse(argv[0..]);
    var ctx = Context{
        .allocator = std.testing.allocator,
        .cwd_path = ".",
        .quiet = true,
        .suppress_stderr = true,
    };

    const exit_code = try dispatch.dispatch(&ctx, &parsed);
    try std.testing.expectEqual(@as(u8, 2), exit_code);
}

test "init rejects positional arguments" {
    const argv = [_][]const u8{
        "ovo",
        "init",
        "extra",
    };

    var parsed = try args.parse(argv[0..]);
    var ctx = Context{
        .allocator = std.testing.allocator,
        .cwd_path = ".",
        .quiet = true,
        .suppress_stderr = true,
    };

    const exit_code = try dispatch.dispatch(&ctx, &parsed);
    try std.testing.expectEqual(@as(u8, 2), exit_code);
}

test "new rejects traversal and absolute paths" {
    const cases = [_][]const u8{
        "../escape",
        "/tmp/escape",
        "apps/../escape",
    };

    for (cases) |candidate| {
        const argv = [_][]const u8{ "ovo", "new", candidate };
        var parsed = try args.parse(argv[0..]);
        var ctx = Context{
            .allocator = std.testing.allocator,
            .cwd_path = ".",
            .quiet = true,
            .suppress_stderr = true,
        };
        const exit_code = try dispatch.dispatch(&ctx, &parsed);
        try std.testing.expectEqual(@as(u8, 2), exit_code);
    }
}
