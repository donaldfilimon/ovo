const std = @import("std");

var global_io: ?std.Io = null;

pub fn setIo(io_handle: std.Io) void {
    global_io = io_handle;
}

pub fn io() std.Io {
    return global_io orelse @panic("runtime io has not been initialized");
}
