const std = @import("std");
const ParsedArgs = @import("args.zig").ParsedArgs;
const args = @import("args.zig");
const Context = @import("context.zig").Context;
const registry = @import("command_registry.zig");
const help = @import("help.zig");
const handlers = @import("handlers.zig");
const version = @import("../version.zig");

const CommandId = enum {
    new_cmd,
    init,
    build,
    run,
    test_cmd,
    clean,
    install,
    add,
    remove,
    fetch,
    update,
    lock,
    deps,
    doc,
    doctor,
    fmt,
    lint,
    info,
    import_cmd,
    export_cmd,
};

const CommandHandler = struct {
    name: []const u8,
    id: CommandId,
};

const command_handlers = [_]CommandHandler{
    .{ .name = "new", .id = .new_cmd },
    .{ .name = "init", .id = .init },
    .{ .name = "build", .id = .build },
    .{ .name = "run", .id = .run },
    .{ .name = "test", .id = .test_cmd },
    .{ .name = "clean", .id = .clean },
    .{ .name = "install", .id = .install },
    .{ .name = "add", .id = .add },
    .{ .name = "remove", .id = .remove },
    .{ .name = "fetch", .id = .fetch },
    .{ .name = "update", .id = .update },
    .{ .name = "lock", .id = .lock },
    .{ .name = "deps", .id = .deps },
    .{ .name = "doc", .id = .doc },
    .{ .name = "doctor", .id = .doctor },
    .{ .name = "fmt", .id = .fmt },
    .{ .name = "lint", .id = .lint },
    .{ .name = "info", .id = .info },
    .{ .name = "import", .id = .import_cmd },
    .{ .name = "export", .id = .export_cmd },
};

comptime {
    if (command_handlers.len != registry.commands.len) {
        @compileError("command dispatch table must match registry command count");
    }
    for (registry.commands) |spec| {
        var found = false;
        for (command_handlers) |entry| {
            if (std.mem.eql(u8, spec.name, entry.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            @compileError("command registry entry missing dispatch handler: " ++ spec.name);
        }
    }
}

pub fn dispatch(ctx: *Context, parsed: *const ParsedArgs) !u8 {
    if (parsed.show_version) {
        try ctx.print("ovo {s}\n", .{version.string});
        return 0;
    }

    const maybe_command = parsed.command;
    if (maybe_command == null) {
        try help.printGlobalHelp(ctx);
        return 0;
    }

    const command_name = maybe_command.?;
    const command_spec = registry.find(command_name) orelse {
        try ctx.printErr("error: unknown command '{s}'\n\n", .{command_name});
        if (suggestCommand(command_name)) |suggested| {
            try ctx.printErr("hint: did you mean '{s}'?\n\n", .{suggested});
        }
        try help.printGlobalHelp(ctx);
        return 1;
    };

    if (parsed.show_help or
        args.hasHelpFlag(parsed.commandArgs()) or
        args.hasHelpFlag(parsed.passthroughArgs()))
    {
        try help.printCommandHelp(ctx, command_spec);
        return 0;
    }

    return dispatchCommand(
        ctx,
        command_name,
        parsed.commandArgs(),
        parsed.passthroughArgs(),
    ) catch |err| {
        try ctx.printErr("error: {s}\n", .{@errorName(err)});
        return 1;
    };
}

fn suggestCommand(input: []const u8) ?[]const u8 {
    for (registry.commands) |command| {
        if (std.mem.startsWith(u8, command.name, input) or std.mem.startsWith(u8, input, command.name)) {
            return command.name;
        }
    }

    var best: ?[]const u8 = null;
    var best_score: usize = std.math.maxInt(usize);
    for (registry.commands) |command| {
        const score = editDistanceCap16(input, command.name);
        if (score < best_score) {
            best_score = score;
            best = command.name;
        }
    }
    if (best_score <= 3) return best;
    return null;
}

fn editDistanceCap16(a: []const u8, b: []const u8) usize {
    var dp: [17][17]usize = undefined;
    const la = @min(a.len, 16);
    const lb = @min(b.len, 16);

    var i: usize = 0;
    while (i <= la) : (i += 1) dp[i][0] = i;
    var j: usize = 0;
    while (j <= lb) : (j += 1) dp[0][j] = j;

    i = 1;
    while (i <= la) : (i += 1) {
        j = 1;
        while (j <= lb) : (j += 1) {
            const cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;
            const del = dp[i - 1][j] + 1;
            const ins = dp[i][j - 1] + 1;
            const sub = dp[i - 1][j - 1] + cost;
            dp[i][j] = @min(del, @min(ins, sub));
        }
    }
    return dp[la][lb];
}

pub fn hasHandler(command: []const u8) bool {
    return commandIdForName(command) != null;
}

fn dispatchCommand(
    ctx: *Context,
    command: []const u8,
    command_args: []const []const u8,
    passthrough_args: []const []const u8,
) !u8 {
    const command_id = commandIdForName(command) orelse {
        try ctx.printErr("error: unimplemented command '{s}'\n", .{command});
        return 1;
    };

    return switch (command_id) {
        .new_cmd => handlers.handleNew(ctx, command_args),
        .init => handlers.handleInit(ctx, command_args),
        .build => handlers.handleBuild(ctx, command_args, passthrough_args),
        .run => handlers.handleRun(ctx, command_args, passthrough_args),
        .test_cmd => handlers.handleTest(ctx, command_args, passthrough_args),
        .clean => handlers.handleClean(ctx, command_args),
        .install => handlers.handleInstall(ctx, command_args),
        .add => handlers.handleAdd(ctx, command_args),
        .remove => handlers.handleRemove(ctx, command_args),
        .fetch => handlers.handleFetch(ctx, command_args),
        .update => handlers.handleUpdate(ctx, command_args),
        .lock => handlers.handleLock(ctx, command_args),
        .deps => handlers.handleDeps(ctx, command_args),
        .doc => handlers.handleDoc(ctx, command_args),
        .doctor => handlers.handleDoctor(ctx, command_args),
        .fmt => handlers.handleFmt(ctx, command_args),
        .lint => handlers.handleLint(ctx, command_args),
        .info => handlers.handleInfo(ctx, command_args),
        .import_cmd => handlers.handleImport(ctx, command_args),
        .export_cmd => handlers.handleExport(ctx, command_args),
    };
}

fn commandIdForName(name: []const u8) ?CommandId {
    for (command_handlers) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.id;
    }
    return null;
}
