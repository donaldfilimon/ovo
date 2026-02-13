const std = @import("std");
const ovo = @import("ovo");
const args = ovo.cli_args;
const dispatch = ovo.cli_dispatch;
const Context = ovo.cli_context.Context;
const registry = ovo.cli_registry;

test "every command supports help flow" {
    var ctx = Context{
        .allocator = std.testing.allocator,
        .cwd_path = ".",
        .quiet = true,
    };

    for (registry.commands) |command| {
        const argv = [_][]const u8{
            "ovo",
            command.name,
            "--help",
        };
        var parsed = try args.parse(argv[0..]);
        const exit_code = try dispatch.dispatch(&ctx, &parsed);
        try std.testing.expectEqual(@as(u8, 0), exit_code);
    }
}
