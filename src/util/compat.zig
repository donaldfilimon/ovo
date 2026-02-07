//! Compatibility layer for Zig 0.16 API changes.
//!
//! Provides synchronous file system operations that work without an Io context,
//! using POSIX APIs directly. This allows existing code to work with minimal changes.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

/// File descriptor type
pub const fd_t = posix.fd_t;

/// Special file descriptor for current working directory
pub const AT_FDCWD = posix.AT.FDCWD;

/// File open flags
pub const O = posix.O;

/// File access mode
pub const mode_t = posix.mode_t;

/// Global I/O instance for synchronous operations.
var global_io: Io.Threaded = Io.Threaded.init(std.heap.page_allocator, .{});

/// Get an I/O context for file operations.
pub fn io() Io {
    return global_io.io();
}

/// Get the current working directory handle.
pub fn cwd() Dir {
    return Dir.cwd();
}

/// Check if a file exists at the given path (relative to cwd).
pub fn exists(path: []const u8) bool {
    const path_z = std.mem.sliceTo(path, 0);
    _ = posix.faccessat(AT_FDCWD, path_z, posix.F_OK, 0) catch return false;
    return true;
}

/// Check if a path exists using a null-terminated string.
pub fn existsZ(path: [*:0]const u8) bool {
    _ = posix.faccessat(AT_FDCWD, path, posix.F_OK, 0) catch return false;
    return true;
}

/// Open a file relative to cwd.
pub fn openFile(path: []const u8, flags: O) !fd_t {
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);
    return posix.openatZ(AT_FDCWD, path_z, flags, 0);
}

/// Open a file with a null-terminated path.
pub fn openFileZ(path: [*:0]const u8, flags: O) !fd_t {
    return posix.openatZ(AT_FDCWD, path, flags, 0);
}

/// Create a file relative to cwd.
pub fn createFile(path: []const u8, mode: mode_t) !fd_t {
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);
    return posix.openatZ(AT_FDCWD, path_z, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, mode);
}

/// Close a file descriptor.
pub fn close(fd: fd_t) void {
    posix.close(fd);
}

/// Read from a file descriptor.
pub fn read(fd: fd_t, buf: []u8) !usize {
    return posix.read(fd, buf);
}

/// Write to a file descriptor.
pub fn write(fd: fd_t, data: []const u8) !usize {
    return posix.write(fd, data);
}

/// Read entire file contents into allocated memory.
pub fn readFileAlloc(allocator: Allocator, path: []const u8, max_size: usize) ![]u8 {
    const fd = try openFile(path, .{ .ACCMODE = .RDONLY });
    defer close(fd);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try read(fd, &buf);
        if (n == 0) break;
        if (result.items.len + n > max_size) return error.FileTooBig;
        try result.appendSlice(allocator, buf[0..n]);
    }

    return result.toOwnedSlice(allocator);
}

/// Write data to a file.
pub fn writeFileData(path: []const u8, data: []const u8) !void {
    const fd = try createFile(path, 0o644);
    defer close(fd);

    var written: usize = 0;
    while (written < data.len) {
        written += try write(fd, data[written..]);
    }
}

/// Get file stat information.
pub fn stat(path: []const u8) !posix.Stat {
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);
    return posix.fstatat(AT_FDCWD, path_z, 0);
}

/// Check if path is a directory.
pub fn isDirectory(path: []const u8) bool {
    const s = stat(path) catch return false;
    return s.mode & posix.S.IFMT == posix.S.IFDIR;
}

/// Check if path is a regular file.
pub fn isFile(path: []const u8) bool {
    const s = stat(path) catch return false;
    return s.mode & posix.S.IFMT == posix.S.IFREG;
}

/// Create a directory.
pub fn mkdir(path: []const u8) !void {
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);
    try posix.mkdirat(AT_FDCWD, path_z, 0o755);
}

/// Create directory and all parent directories.
pub fn mkdirp(allocator: Allocator, path: []const u8) !void {
    var components = std.mem.splitScalar(u8, path, '/');
    var current_path = std.ArrayList(u8).empty;
    defer current_path.deinit(allocator);

    // Handle absolute paths
    if (path.len > 0 and path[0] == '/') {
        try current_path.append(allocator, '/');
    }

    while (components.next()) |component| {
        if (component.len == 0) continue;

        if (current_path.items.len > 0 and current_path.items[current_path.items.len - 1] != '/') {
            try current_path.append(allocator, '/');
        }
        try current_path.appendSlice(allocator, component);

        const path_slice = current_path.items;
        if (!isDirectory(path_slice)) {
            mkdir(path_slice) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }
}

/// Remove a file.
pub fn unlink(path: []const u8) !void {
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);
    try posix.unlinkat(AT_FDCWD, path_z, 0);
}

/// Remove a directory.
pub fn rmdir(path: []const u8) !void {
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);
    try posix.unlinkat(AT_FDCWD, path_z, posix.AT.REMOVEDIR);
}

/// Get environment variable.
pub fn getenv(key: [*:0]const u8) ?[]const u8 {
    const result = std.c.getenv(key) orelse return null;
    return std.mem.span(result);
}

/// Fixed buffer writer (replacement for std.io.fixedBufferStream).
pub const FixedBufferWriter = struct {
    buffer: []u8,
    pos: usize = 0,

    pub fn init(buffer: []u8) FixedBufferWriter {
        return .{ .buffer = buffer };
    }

    pub fn write(self: *FixedBufferWriter, data: []const u8) !usize {
        const available = self.buffer.len - self.pos;
        const to_write = @min(data.len, available);
        if (to_write == 0 and data.len > 0) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.pos..][0..to_write], data[0..to_write]);
        self.pos += to_write;
        return to_write;
    }

    pub fn writeAll(self: *FixedBufferWriter, data: []const u8) !void {
        if (data.len > self.buffer.len - self.pos) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    pub fn print(self: *FixedBufferWriter, comptime fmt: []const u8, args: anytype) !void {
        const result = std.fmt.bufPrint(self.buffer[self.pos..], fmt, args) catch return error.NoSpaceLeft;
        self.pos += result.len;
    }

    pub fn getWritten(self: *const FixedBufferWriter) []u8 {
        return self.buffer[0..self.pos];
    }

    pub fn reset(self: *FixedBufferWriter) void {
        self.pos = 0;
    }
};

test "FixedBufferWriter" {
    var buf: [64]u8 = undefined;
    var writer = FixedBufferWriter.init(&buf);

    try writer.writeAll("Hello, ");
    try writer.print("{s}!", .{"World"});

    try std.testing.expectEqualStrings("Hello, World!", writer.getWritten());
}

test "exists" {
    // Current directory should always exist
    try std.testing.expect(isDirectory("."));
}
