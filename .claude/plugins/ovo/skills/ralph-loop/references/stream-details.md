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
| `findInPathC(name)` | Search PATH for executable | Inline PATH env parsing |
| `manifestExists()` | Check build.zon exists | Repeated access patterns |
| `hasHelpFlag(args)` | Check -h/--help | Inline flag loops |
| `hasVerboseFlag(args)` | Check -v/--verbose | Inline flag loops |

### Fixed Issues

**Iteration 1:**
- `fileExistsC()` moved to commands.zig from init_cmd.zig
- `DependencySource.typeName()` added to schema.zig
- Dead `toUpperSnake` removed from new_cmd.zig

**Iteration 2:**
- `findInPathC()` extracted to commands.zig (was duplicated in doc_cmd + doctor_cmd)
- `DependencySource.typeName()` used in deps_cmd + info_cmd (replaced inline switches)
- Unused `builtin` import removed from doc_cmd

## Stream C: Zig 0.16 Compat Migration

### Current Status

**True scope: ~140 calls across ~32 files** (not the originally documented 80).

| Module | std.fs.cwd() | fs.cwd() alias | std.posix.getenv() | Total | Migrated |
|--------|-------------|---------------|-------------------|-------|----------|
| translate/ | ~31 | 0 | 0 | ~31 | No |
| compiler/ | ~22 | 0 | 7 | ~29 | No |
| util/ | ~6 | ~20 (fs.zig) | 4 | ~30 | No |
| package/ | ~1 | ~40 (9 files) | 9 | ~50 | No |
| cli/ | 0 | 0 | 0 | 0 | Done (uses DirHandle) |
| **Total** | **~60** | **~60** | **~20** | **~140** | |

### Critical Type Mismatch

`compat.cwd()` returns `std.Io.Dir` but all 120 cwd call sites expect `std.fs.Dir`.
These are **incompatible types** with different method signatures. A simple find-and-replace
of `std.fs.cwd()` → `compat.cwd()` will NOT compile.

**Before migration can proceed**, compat.zig needs expansion to either:
- Wrap `fs.Dir` operations with POSIX equivalents (~10 new wrappers needed)
- Provide a unified Dir type that covers the full API surface used at call sites
- Or migrate call sites to use standalone compat functions (openFile, readFileAlloc, etc.)

### Alias Pattern

Many files in package/ and util/ use `const fs = std.fs;` then call `fs.cwd()`.
Grep patterns must catch BOTH forms:
```bash
grep -rn "std.fs.cwd()" src/translate/ src/compiler/ src/util/ src/package/
grep -rn "fs.cwd()" src/util/fs.zig src/package/
```

### These Are Latent Issues

Zig evaluates lazily — these calls compile but fail at runtime when the code paths execute.
The CLI works because it uses the separate `DirHandle`/`CFile` abstraction in `commands.zig`.
Do NOT treat these as build failures; flag and inventory them.

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

### Current Stubs (6 identified)

| Stub | Location | Current Behavior | Required Behavior |
|------|----------|-----------------|-------------------|
| `deleteTree()` | commands.zig:206 | No-op | Recursive directory deletion via C APIs |
| `getDirSize()` | clean_cmd.zig:206 | Returns 1MB fake | Walk dir with opendir/readdir + stat |
| 5x `generate*()` | export_cmd.zig:220-359 | Generates content string, ignores path | Write content to output file via CFile |
| Tool detection | info_cmd.zig:170 | Hardcoded `"clang++ 15.0.0"` + static bools | Use `findInPathC()` for real detection |
| Import formats | import_cmd.zig:185-191 | "not yet implemented" message | Basic scanning (like CMake importer) |

### Implementation Notes

- **export `generate*`** is the easiest win — each function already builds the content string
  and has an `output_path` parameter. Just need to write content to file using `CFile.writeAll()`.
- **`deleteTree`** requires recursive directory walk using `std.c.opendir()`/`std.c.readdir()`/
  `std.c.unlink()`/`std.c.rmdir()` since `std.fs` methods aren't available in 0.16 CLI context.
- **info_cmd tool detection** is trivial — replace hardcoded bools with `commands.findInPathC()`.
- **import formats** can be deferred — the "not yet implemented" message is honest and acceptable.

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
