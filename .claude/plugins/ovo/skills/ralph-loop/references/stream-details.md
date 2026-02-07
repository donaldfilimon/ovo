# Ralph Loop Stream Details

Detailed audit procedures and grep patterns for each improvement stream.

## Stream A: Memory Safety

### Audit Procedure

1. Search for allocations without defer:
```bash
grep -n "allocPrint\|allocator.alloc\|allocator.dupe" src/cli/*_cmd.zig
```

2. For each match, verify a corresponding `defer allocator.free()` exists in the same scope.

3. Search for parseFile without deinit:
```bash
grep -n "parseFile" src/cli/*_cmd.zig
```

4. For each match, verify `defer project.deinit(ctx.allocator)` follows.

### Common Leak Patterns

**Loop allocation leak:**
```zig
// BAD: leaks on each iteration
for (items) |item| {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, item });
    // path is never freed
}

// GOOD: free each iteration
for (items) |item| {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, item });
    defer allocator.free(path);
    // use path
}
```

**Conditional ownership leak:**
```zig
// BAD: leaks when default_path is used
const path = user_path orelse try getDefaultPath(allocator);
defer allocator.free(path); // crashes if user_path was used (not owned)

// GOOD: track ownership
const default_path = if (user_path == null) try getDefaultPath(allocator) else null;
defer if (default_path) |p| allocator.free(p);
const path = user_path orelse default_path.?;
```

### Fixed Issues (Iteration 1)

- `install_cmd.zig`: dir paths + loop allocs
- `export_cmd.zig`: output_path + generate* content

## Stream B: Code Deduplication

### Audit Procedure

1. Search for inline file-exists checks:
```bash
grep -n "access.*F.OK\|std.c.access" src/cli/*_cmd.zig | grep -v "commands.fileExistsC"
```

2. Search for inline manifest filename strings:
```bash
grep -n '"build.zon"' src/cli/*_cmd.zig
```
All should use `manifest.manifest_filename` instead.

3. Search for inline source type strings:
```bash
grep -n '"url"\|"path"\|"git"\|"system"' src/cli/*_cmd.zig
```
All should use `DependencySource.typeName()` instead.

### Shared Helpers in commands.zig

| Helper | Purpose | Replaces |
|--------|---------|----------|
| `fileExistsC(path)` | Check file existence | Inline `std.c.access` calls |
| `manifestExists()` | Check build.zon exists | Repeated access patterns |
| `hasHelpFlag(args)` | Check -h/--help | Inline flag loops |
| `hasVerboseFlag(args)` | Check -v/--verbose | Inline flag loops |

### Fixed Issues (Iteration 1)

- `fileExistsC()` moved to commands.zig from init_cmd.zig
- `DependencySource.typeName()` added to schema.zig
- Dead `toUpperSnake` removed from new_cmd.zig

## Stream C: Zig 0.16 Compat Migration

### Current Status

| Module | std.fs.cwd() | std.posix.getenv() | Migrated |
|--------|-------------|-------------------|----------|
| translate/ | ~30 | 0 | No |
| compiler/ | ~18 | 7 | No |
| util/ | ~6 | 4 | No |
| package/ | ~6 | 6 | No |
| cli/ | 0 | 0 | Done (uses DirHandle) |

### Migration Procedure

1. Identify files with deprecated calls:
```bash
grep -rn "std.fs.cwd()" src/translate/ src/compiler/ src/util/ src/package/
grep -rn "std.posix.getenv" src/translate/ src/compiler/ src/util/ src/package/
```

2. For each file, add `const compat = @import("compat");`

3. Replace calls:
- `std.fs.cwd()` → `compat.cwd()` (returns a Dir-like handle)
- `std.posix.getenv("KEY")` → `compat.getenv("KEY")`

4. These are latent issues — Zig evaluates lazily, so they compile but fail at runtime when exercised.

## Stream D: Documentation Accuracy

### Audit Procedure

1. Check CLAUDE.md command status matches reality:
```bash
ls src/cli/*_cmd.zig | wc -l  # Should match documented count
```

2. Verify API call counts:
```bash
grep -rn "std.fs.cwd()" src/ | wc -l
grep -rn "std.posix.getenv" src/ | wc -l
```

3. Check module dependency graph matches build.zig imports.

## Stream E: Stub Completion

### Current Stubs

| Stub | Location | Current Behavior | Required Behavior |
|------|----------|-----------------|-------------------|
| `deleteTree()` | commands.zig DirHandle | No-op | Recursive directory deletion |
| `getDirSize()` | install_cmd.zig | Returns 1MB fake | Actual directory size calculation |
| `generate*()` | export_cmd.zig | Returns string | Write actual files |

## Stream F: Architecture

### Comptime Dispatch Map

Replace the if-else chain in `commands.zig dispatchCommand()` with a comptime string map
for O(1) dispatch and cleaner code.

### --color Flag

Add `--color=auto|always|never` support to TermWriter, allowing color disable for
piped output or CI environments.

### Process Spawning

Replace `system()` calls in run_cmd.zig with `std.process.Child` for proper
process management, signal handling, and exit code propagation.
