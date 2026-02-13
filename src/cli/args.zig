const std = @import("std");

pub const max_args = 128;

pub const ParsedArgs = struct {
    show_help: bool = false,
    show_version: bool = false,
    verbose: bool = false,
    quiet: bool = false,
    cwd: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    command: ?[]const u8 = null,
    command_args: [max_args][]const u8 = undefined,
    command_args_len: usize = 0,
    passthrough_args: [max_args][]const u8 = undefined,
    passthrough_args_len: usize = 0,

    pub fn commandArgs(self: *const ParsedArgs) []const []const u8 {
        return self.command_args[0..self.command_args_len];
    }

    pub fn passthroughArgs(self: *const ParsedArgs) []const []const u8 {
        return self.passthrough_args[0..self.passthrough_args_len];
    }
};

pub fn parse(argv: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{};
    if (argv.len <= 1) {
        parsed.show_help = true;
        return parsed;
    }

    var index: usize = 1;
    var passthrough = false;

    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (passthrough) {
            try appendArg(&parsed.passthrough_args, &parsed.passthrough_args_len, arg);
            continue;
        }

        if (parsed.command == null) {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                parsed.show_help = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
                parsed.show_version = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--verbose")) {
                parsed.verbose = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--quiet")) {
                parsed.quiet = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--cwd")) {
                index += 1;
                if (index >= argv.len) return error.MissingCwdPath;
                parsed.cwd = argv[index];
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--cwd=")) {
                parsed.cwd = arg["--cwd=".len..];
                continue;
            }
            if (std.mem.eql(u8, arg, "--profile")) {
                index += 1;
                if (index >= argv.len) return error.MissingProfileName;
                parsed.profile = argv[index];
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--profile=")) {
                parsed.profile = arg["--profile=".len..];
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--")) return error.UnknownGlobalFlag;

            parsed.command = arg;
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            passthrough = true;
            continue;
        }

        try appendArg(&parsed.command_args, &parsed.command_args_len, arg);
    }

    if (parsed.command == null and !parsed.show_version) {
        parsed.show_help = true;
    }

    return parsed;
}

fn appendArg(buf: *[max_args][]const u8, len: *usize, value: []const u8) !void {
    if (len.* >= max_args) return error.TooManyArguments;
    buf[len.*] = value;
    len.* += 1;
}

pub fn hasHelpFlag(values: []const []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, "--help") or std.mem.eql(u8, value, "-h")) {
            return true;
        }
    }
    return false;
}
