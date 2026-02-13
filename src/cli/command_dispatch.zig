const std = @import("std");
const ParsedArgs = @import("args.zig").ParsedArgs;
const args = @import("args.zig");
const Context = @import("context.zig").Context;
const registry = @import("command_registry.zig");
const help = @import("help.zig");
const handlers = @import("handlers.zig");
const version = @import("../version.zig");

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
    return std.mem.eql(u8, command, "new") or
        std.mem.eql(u8, command, "init") or
        std.mem.eql(u8, command, "build") or
        std.mem.eql(u8, command, "run") or
        std.mem.eql(u8, command, "test") or
        std.mem.eql(u8, command, "clean") or
        std.mem.eql(u8, command, "install") or
        std.mem.eql(u8, command, "add") or
        std.mem.eql(u8, command, "remove") or
        std.mem.eql(u8, command, "fetch") or
        std.mem.eql(u8, command, "update") or
        std.mem.eql(u8, command, "lock") or
        std.mem.eql(u8, command, "deps") or
        std.mem.eql(u8, command, "doc") or
        std.mem.eql(u8, command, "doctor") or
        std.mem.eql(u8, command, "fmt") or
        std.mem.eql(u8, command, "lint") or
        std.mem.eql(u8, command, "info") or
        std.mem.eql(u8, command, "import") or
        std.mem.eql(u8, command, "export");
}

fn dispatchCommand(
    ctx: *Context,
    command: []const u8,
    command_args: []const []const u8,
    passthrough_args: []const []const u8,
) !u8 {
    if (std.mem.eql(u8, command, "new")) return handlers.handleNew(ctx, command_args);
    if (std.mem.eql(u8, command, "init")) return handlers.handleInit(ctx, command_args);
    if (std.mem.eql(u8, command, "build")) return handlers.handleBuild(ctx, command_args, passthrough_args);
    if (std.mem.eql(u8, command, "run")) return handlers.handleRun(ctx, command_args, passthrough_args);
    if (std.mem.eql(u8, command, "test")) return handlers.handleTest(ctx, command_args, passthrough_args);
    if (std.mem.eql(u8, command, "clean")) return handlers.handleClean(ctx, command_args);
    if (std.mem.eql(u8, command, "install")) return handlers.handleInstall(ctx, command_args);
    if (std.mem.eql(u8, command, "add")) return handlers.handleAdd(ctx, command_args);
    if (std.mem.eql(u8, command, "remove")) return handlers.handleRemove(ctx, command_args);
    if (std.mem.eql(u8, command, "fetch")) return handlers.handleFetch(ctx, command_args);
    if (std.mem.eql(u8, command, "update")) return handlers.handleUpdate(ctx, command_args);
    if (std.mem.eql(u8, command, "lock")) return handlers.handleLock(ctx, command_args);
    if (std.mem.eql(u8, command, "deps")) return handlers.handleDeps(ctx, command_args);
    if (std.mem.eql(u8, command, "doc")) return handlers.handleDoc(ctx, command_args);
    if (std.mem.eql(u8, command, "doctor")) return handlers.handleDoctor(ctx, command_args);
    if (std.mem.eql(u8, command, "fmt")) return handlers.handleFmt(ctx, command_args);
    if (std.mem.eql(u8, command, "lint")) return handlers.handleLint(ctx, command_args);
    if (std.mem.eql(u8, command, "info")) return handlers.handleInfo(ctx, command_args);
    if (std.mem.eql(u8, command, "import")) return handlers.handleImport(ctx, command_args);
    if (std.mem.eql(u8, command, "export")) return handlers.handleExport(ctx, command_args);

    try ctx.printErr("error: unimplemented command '{s}'\n", .{command});
    return 1;
}
