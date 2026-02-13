const std = @import("std");

pub const Context = struct {
    allocator: std.mem.Allocator,
    cwd_path: []const u8 = ".",
    profile: ?[]const u8 = null,
    verbose: bool = false,
    quiet: bool = false,
    suppress_stderr: bool = false,

    pub fn print(self: *Context, comptime fmt: []const u8, args: anytype) !void {
        if (self.quiet) return;
        std.debug.print(fmt, args);
    }

    pub fn printErr(self: *Context, comptime fmt: []const u8, args: anytype) !void {
        if (self.suppress_stderr) return;
        std.debug.print(fmt, args);
    }
};
