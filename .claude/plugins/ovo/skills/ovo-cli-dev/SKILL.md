---
name: ovo-cli-dev
description: >
  This skill should be used when the user asks to "add a CLI command", "create a new ovo command",
  "wire a command to build.zon", "implement a command", "modify a CLI command", "add an option to a command",
  "add a subcommand", "dispatcher wiring", or mentions OVO CLI command development patterns.
  Provides the canonical command structure, build.zon round-trip pattern, output conventions,
  and dispatch wiring.
version: 0.1.0
---

# OVO CLI Command Development

Develop and extend OVO CLI commands following established codebase conventions.

## Command Architecture

OVO CLI commands are dispatched from `src/cli/commands.zig`. Each command lives in its own
`src/cli/*_cmd.zig` file and exports a single entry point:

```zig
pub fn execute(ctx: *Context, args: []const []const u8) !u8
```

**Key types** (all from `commands.zig`):
- `Context` — allocator, args, stdout/stderr writers, cwd DirHandle
- `TermWriter` — terminal output with `print()`, `bold()`, `dim()`, `success()`, `warn()`, `err()`, `info()`
- `DirHandle` — C-library filesystem abstraction (Zig 0.16 compatible)
- `CFile` — C FILE* wrapper with `readAll()`, `writeAll()`
- `ProgressBar` — simple progress display

## Creating a New Command

### Step 1: Create the Command File

Create `src/cli/<name>_cmd.zig` with this structure:

```zig
//! ovo <name> command
//!
//! Brief description of what this command does.
//! Usage: ovo <name> [args] [options]

const std = @import("std");
const commands = @import("commands.zig");
const manifest = @import("manifest.zig");
const zon = @import("zon");

const zon_parser = zon.parser;
const zon_schema = zon.schema;

const Context = commands.Context;
const TermWriter = commands.TermWriter;

fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo <name>", .{});
    try writer.print(" - Brief description\n\n", .{});
    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo <name> [options]\n\n", .{});
    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    -h, --help       Show this help message\n", .{});
    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo <name>              # Example usage\n", .{});
}

pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }
    // Implementation here
    return 0;
}
```

### Step 2: Wire into Dispatcher

In `src/cli/commands.zig`, add two things:

1. Add to `command_list` array (for help/listing):
```zig
.{ .name = "<name>", .description = "Brief description", .usage = "ovo <name> [options]" },
```

2. Add dispatch branch in `dispatchCommand()`:
```zig
} else if (std.mem.eql(u8, cmd, "<name>")) {
    const name_cmd = @import("<name>_cmd.zig");
    return name_cmd.execute(ctx, remaining_args);
}
```

### Step 3: Register the Module

In `build.zig`, ensure the new file is included in the `cli` module's source set.

## Build.zon Round-Trip Pattern

Commands that read, modify, and write back `build.zon` follow this pattern:

```zig
// 1. Check manifest exists
const manifest_exists = blk: {
    ctx.cwd.access(manifest.manifest_filename, .{}) catch break :blk false;
    break :blk true;
};
if (!manifest_exists) {
    try ctx.stderr.err("error: ", .{});
    try ctx.stderr.print("no {s} found\n", .{manifest.manifest_filename});
    return 1;
}

// 2. Parse
var project = zon_parser.parseFile(ctx.allocator, manifest.manifest_filename) catch |err| {
    try ctx.stderr.err("error: ", .{});
    try ctx.stderr.print("failed to parse {s}: {s}\n", .{ manifest.manifest_filename, @errorName(err) });
    return 1;
};
defer project.deinit(ctx.allocator);

// 3. Modify (example: add dependency)
// ... modify project.dependencies ...

// 4. Write back
const content = zon.writer.writeProject(ctx.allocator, &project, .{}) catch |err| {
    try ctx.stderr.err("error: ", .{});
    try ctx.stderr.print("failed to serialize: {s}\n", .{@errorName(err)});
    return 1;
};
defer ctx.allocator.free(content);

const file = ctx.cwd.createFile(manifest.manifest_filename, .{ .truncate = true }) catch |err| {
    try ctx.stderr.err("error: ", .{});
    try ctx.stderr.print("failed to write: {s}\n", .{@errorName(err)});
    return 1;
};
defer file.close();
try file.writeAll(content);
```

## Output Conventions

Use semantic output methods for consistent terminal UX:

| Method | Purpose | Example |
|--------|---------|---------|
| `bold()` | Section headers, titles | `"Fetching dependencies\n"` |
| `success()` | Success indicators | `"+" prefix, "done"` |
| `warn()` | Warnings | `"(dry run - no changes made)\n"` |
| `err()` | Error labels | `"error: "` prefix |
| `info()` | Informational | `"up to date"`, status messages |
| `dim()` | Secondary info | Examples, counts, hints |
| `print()` | Plain text | Separators, punctuation |

**Output structure pattern:**
```zig
try ctx.stdout.bold("Phase Title\n", .{});
try ctx.stdout.print("  ", .{});
try ctx.stdout.success("*", .{});
try ctx.stdout.print(" Action description...\n", .{});
```

## Shared Helpers

Use helpers from `commands.zig` — avoid reimplementing:

- `commands.hasHelpFlag(args)` — check for `-h` or `--help`
- `commands.hasVerboseFlag(args)` — check for `-v` or `--verbose`
- `commands.fileExistsC(path)` — check file existence via C library
- `manifest.manifest_filename` — always use this constant, never hardcode `"build.zon"`

## Dependency Source Labels

When displaying dependency types, use the shared method:

```zig
const sourceTypeName = zon_schema.DependencySource.typeName;
// Usage: sourceTypeName(dep.source) returns "url", "path", "git", "system"
```

## Additional Resources

### Reference Files

- **`references/command-checklist.md`** — Pre-commit checklist for new commands
- **`references/option-parsing.md`** — Option/argument parsing patterns

### Existing Commands to Study

- **`add_cmd.zig`** — Full read-modify-write round-trip (add dependency)
- **`remove_cmd.zig`** — Read-modify-write (remove dependency)
- **`info_cmd.zig`** — Read-only build.zon display
- **`fetch_cmd.zig`** — Multi-phase progress output with ProgressBar
- **`init_cmd.zig`** — Template rendering, directory creation, .gitignore
