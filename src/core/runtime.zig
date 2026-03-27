const std = @import("std");

var global_io: ?std.Io = null;

pub fn setIo(io_handle: std.Io) void {
    global_io = io_handle;
}

pub fn io() std.Io {
    return global_io orelse @panic("runtime io has not been initialized");
}

test "runtime io getter returns set value" {
    const mock_io: std.Io = undefined;
    setIo(mock_io);
    const result = io();
    _ = result;
}
