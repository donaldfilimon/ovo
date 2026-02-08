---
name: zig-016-patterns
description: >
  This skill should be used when the user encounters Zig 0.16 API incompatibilities,
  asks about "Zig 0.16 patterns", "Zig API changes", "compat layer", "DirHandle",
  "ArrayList patterns", "entry point signature", "std.fs.cwd replacement",
  "std.posix.getenv replacement", or "unmanaged ArrayList". Provides Zig 0.16-dev
  API patterns and migration guidance specific to the OVO codebase.
version: 0.1.0
---

# Zig 0.16-dev API Patterns

Zig 0.16-dev (master) API conventions and migration patterns for the OVO codebase.

## Critical: Zig Version

OVO targets Zig 0.16-dev (master). Build with:

```bash
~/.zvm/bin/zig build        # zvm has 0.16-dev
# NOT /opt/homebrew/bin/zig  # Homebrew has 0.15.2
```

## Entry Point

```zig
pub fn main(init: std.process.Init) !u8 {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // ...
    return 0; // exit code
}
```

**Not** `pub fn main() !void` — that's the old signature.

## ArrayList (Unmanaged)

Zig 0.16 uses unmanaged ArrayLists. The allocator is passed to each operation, not stored:

```zig
// Initialize
var list: std.ArrayList(u8) = .empty;
defer list.deinit(allocator);

// Append
try list.append(allocator, item);
try list.appendSlice(allocator, slice);

// Convert to owned slice
const result = try list.toOwnedSlice(allocator);
defer allocator.free(result);
```

**Common mistake:** Using `.init(allocator)` — this is the old API.

## Filesystem — No std.fs.cwd()

`std.fs.cwd()` is removed in Zig 0.16. Use one of these alternatives:

### In CLI Layer: DirHandle

CLI commands receive `ctx.cwd` (a `DirHandle`) which wraps C library calls:

```zig
// Check file exists
ctx.cwd.access(filename, .{}) catch { /* doesn't exist */ };

// Open file for reading
const file = try ctx.cwd.openFile(path, .{});
defer file.close();

// Create file for writing
const file = try ctx.cwd.createFile(path, .{ .truncate = true });
defer file.close();

// Create directory
ctx.cwd.makeDir(dirname) catch |e| {
    if (e != error.PathAlreadyExists) return e;
};

// Get real path
var buf: [std.fs.max_path_bytes]u8 = undefined;
const real = ctx.cwd.realpath(".", &buf);
```

### In Non-CLI Modules: compat.zig

For code outside the CLI layer (translate/, compiler/, util/, package/), use `src/util/compat.zig`:

```zig
const compat = @import("compat");

// File operations
if (compat.exists(path)) { ... }
const file = try compat.openFile(path);
const content = try compat.readFileAlloc(allocator, path);

// Directory operations
try compat.mkdir(path);
try compat.mkdirp(path); // recursive

// Environment
const val = compat.getenv("HOME"); // returns ?[]const u8
```

### Quick C Library (One-Off Checks)

For simple existence checks without DirHandle:

```zig
fn fileExistsC(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(@ptrCast(&buf), std.c.F.OK) == 0;
}
```

Use `commands.fileExistsC()` in CLI code — it's already a shared helper.

## Environment Variables

```zig
// Old (broken in 0.16):
// const val = std.posix.getenv("HOME");

// Correct: C library
var key_buf: [256]u8 = undefined;
const key = "HOME";
@memcpy(key_buf[0..key.len], key);
key_buf[key.len] = 0;
const val = std.c.getenv(@ptrCast(&key_buf));

// Or use compat wrapper:
const val = compat.getenv("HOME");
```

## Process Arguments

```zig
var args_iter = std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
defer args_iter.deinit();
_ = args_iter.next(); // skip program name
while (args_iter.next()) |arg| { ... }
```

## Build System Modules

In `build.zig`, modules declare explicit imports:

```zig
const cli_mod = b.addModule("cli", .{
    .root_source_file = b.path("src/cli/root.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{
        .{ .name = "core", .module = core_mod },
        .{ .name = "zon", .module = zon_mod },
        .{ .name = "util", .module = util_mod },
    },
});
```

## Allocator Discipline

- Pass `allocator` as first parameter to functions that allocate
- Use `defer allocator.free(slice)` immediately after allocation
- For conditional ownership: `defer if (owned) allocator.free(ptr);`
- `allocPrint` returns owned memory — always free it

```zig
const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, file });
defer allocator.free(path);
```

## Import Order Convention

```zig
const std = @import("std");           // 1. Standard library
const zon = @import("zon");           // 2. Domain modules
const commands = @import("commands.zig"); // 3. Relative imports
```

## Additional Resources

### Reference Files

- **`references/migration-checklist.md`** — File-by-file migration status for std.fs.cwd() and std.posix.getenv()
- **`references/compat-api.md`** — Complete compat.zig API reference
