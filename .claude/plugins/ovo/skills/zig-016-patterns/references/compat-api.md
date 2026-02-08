# compat.zig API Reference

Location: `src/util/compat.zig`

Zig 0.16 compatibility layer providing filesystem and environment wrappers
that work without `std.fs.cwd()` or `std.posix.getenv()`.

## File Operations

### exists(path: []const u8) bool
Check if a file or directory exists.
```zig
if (compat.exists("build.zon")) { ... }
```

### existsZ(path: [*:0]const u8) bool
Null-terminated version of exists.

### openFile(path: []const u8) !std.fs.File
Open a file for reading.
```zig
const file = try compat.openFile("build.zon");
defer file.close();
```

### openFileZ(path: [*:0]const u8) !std.fs.File
Null-terminated version of openFile.

### createFile(path: []const u8) !std.fs.File
Create or truncate a file for writing.
```zig
const file = try compat.createFile("output.txt");
defer file.close();
try file.writeAll(content);
```

### readFileAlloc(allocator: Allocator, path: []const u8) ![]u8
Read entire file contents into allocated buffer.
```zig
const content = try compat.readFileAlloc(allocator, "config.txt");
defer allocator.free(content);
```

### writeFileData(path: []const u8, data: []const u8) !void
Write data to a file (create or overwrite).
```zig
try compat.writeFileData("output.txt", content);
```

### stat(path: []const u8) !std.fs.File.Stat
Get file metadata (size, timestamps, type).

### isDirectory(path: []const u8) bool
Check if path is a directory.

### isFile(path: []const u8) bool
Check if path is a regular file.

## Directory Operations

### mkdir(path: []const u8) !void
Create a single directory.
```zig
try compat.mkdir("build");
```

### mkdirp(path: []const u8) !void
Create directory and all parent directories (recursive).
```zig
try compat.mkdirp("build/cache/objects");
```

### unlink(path: []const u8) !void
Delete a file.

### rmdir(path: []const u8) !void
Remove an empty directory.

## Environment

### getenv(key: []const u8) ?[]const u8
Get environment variable value.
```zig
const home = compat.getenv("HOME") orelse "/tmp";
```

## I/O

### io() type
Get I/O interface for standard streams.

### cwd() type
Get current working directory handle.

## Constants

- `fd_t` — File descriptor type
- `AT_FDCWD` — Current directory file descriptor constant
- `O` — File open flags struct
- `mode_t` — File mode/permission type

## FixedBufferWriter

Custom writer backed by a fixed-size buffer.

### init(buffer: []u8) FixedBufferWriter
### write(self: *Self, bytes: []const u8) !usize
### writeAll(self: *Self, bytes: []const u8) !void
### print(self: *Self, comptime fmt: []const u8, args: anytype) !void
### getWritten(self: *Self) []const u8
### reset(self: *Self) void

## Usage in Non-CLI Modules

```zig
const compat = @import("compat");

pub fn findCompiler(name: []const u8) ?[]const u8 {
    const path_env = compat.getenv("PATH") orelse return null;
    // ... search PATH ...
    if (compat.exists(candidate)) return candidate;
    return null;
}
```

## Important Notes

- `compat.zig` exists but is NOT yet imported by any non-CLI module
- CLI layer uses its own `DirHandle`/`CFile` in `commands.zig` instead
- Migration of translate/, compiler/, util/, package/ to use compat is Stream C work
