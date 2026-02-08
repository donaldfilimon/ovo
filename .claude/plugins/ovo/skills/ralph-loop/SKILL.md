---
name: ralph-loop
description: >
  This skill should be used when the user asks to "run the Ralph loop", "start an improvement sweep",
  "audit the codebase", "run improvement iteration", "check for code quality issues", "find memory leaks",
  "deduplicate code", "check compat migration status", "code review", "refactor for quality",
  or mentions the Ralph improvement process.
  Provides the 6-stream improvement framework for systematic OVO codebase quality work.
version: 0.1.0
---

# Ralph Loop — OVO Improvement Framework

Run systematic improvement iterations across the OVO codebase using a 6-stream audit framework.

## Overview

The Ralph Loop is a structured process for continuously improving the OVO package manager codebase.
Each iteration audits all six streams, prioritizes findings, implements fixes, and verifies results.

## The Six Streams

| Stream | Focus | Priority |
|--------|-------|----------|
| **A** | Memory safety | Critical |
| **B** | Code deduplication | High |
| **C** | Zig 0.16 compat migration | High |
| **D** | Documentation accuracy | Medium |
| **E** | Stub completion | Medium |
| **F** | Architecture improvements | Low |

### Stream A: Memory Safety

Audit all allocations for proper cleanup:

- Every `allocator.alloc` or `allocPrint` must have matching `defer allocator.free()`
- Every `zon_parser.parseFile()` must have `defer project.deinit(ctx.allocator)`
- Loop allocations need per-iteration cleanup or arena allocator
- Conditional ownership: `defer if (owned) allocator.free(ptr);`

**Scan pattern:** Search for `allocPrint`, `allocator.alloc`, `parseFile` without matching `defer`

### Stream B: Code Deduplication

Eliminate repeated patterns across `*_cmd.zig` files:

- File existence checks → use `commands.fileExistsC()`
- Manifest existence → use `commands.manifestExists()`
- Help flag checks → use `commands.hasHelpFlag(args)`
- Dependency source labels → use `zon_schema.DependencySource.typeName`
- Dead code → remove unused functions, unreachable branches

**Scan pattern:** Search for inline implementations of patterns that exist in `commands.zig`

### Stream C: Zig 0.16 Compat Migration

Migrate deprecated API calls to Zig 0.16 alternatives. **True scope: ~140 calls across ~32 files:**
- `std.fs.cwd()` — ~60 direct + ~60 via `const fs = std.fs; fs.cwd()` alias
- `std.posix.getenv()` — ~20 calls across compiler/, package/, util/

**Critical:** `compat.cwd()` returns `std.Io.Dir` but call sites expect `std.fs.Dir` — these are
incompatible types. Do NOT attempt bulk find-and-replace. The compat layer needs expansion first.

For migration procedures, patterns, and file-by-file status, load the **zig-016-patterns** skill.
The migration checklist at `zig-016-patterns/references/migration-checklist.md` tracks progress.

### Stream D: Documentation Accuracy

Keep CLAUDE.md and memory files aligned with reality:

- Command implementation status list
- Module dependency graph
- API call counts (std.fs.cwd, std.posix.getenv)
- Coding conventions and patterns

**Scan pattern:** Compare documented claims against actual code

### Stream E: Stub Completion

Replace placeholder implementations with real logic. **Six stubs identified:**

- `DirHandle.deleteTree()` — currently a no-op (commands.zig:206)
- `getDirSize()` — returns fake 1MB (clean_cmd.zig:206)
- 5x `generate*()` — generate content string but don't write files (export_cmd.zig:220-359)
- Tool detection — hardcoded compiler + tool availability (info_cmd.zig:170)
- Import formats — Meson/Xcode/MSBuild show "not yet implemented" (import_cmd.zig:185-191)

### Stream F: Architecture

Structural improvements for maintainability:

- Comptime dispatch map (replace if-else in commands.zig)
- `--color` flag support in TermWriter
- Replace `system()` in run_cmd with proper process spawning

## Running an Iteration

### Phase 1: Audit

Scan all six streams in parallel. For each finding, record:
- **Stream** (A-F)
- **File** and line number
- **Issue** description
- **Fix** approach

### Phase 2: Prioritize

Sort findings by stream priority (A > B > C > D > E > F).
Within each stream, sort by impact and effort.

### Phase 3: Fix

Implement fixes stream by stream, starting with highest priority.
After each stream's fixes:

```bash
~/.zvm/bin/zig build           # Must compile
~/.zvm/bin/zig build test      # Tests must pass
```

After all fixes:

```bash
export OVO_TEMPLATES="$PWD/templates"
./scripts/integration_test.sh  # Integration tests must pass
```

### Phase 4: Report

Summarize the iteration with:
- Findings per stream (count and severity)
- Fixes applied (with file paths)
- Remaining issues
- Updated stream status

## Progress Tracking

Track stream status in memory files using this format:

```
## Ralph Loop Stream Status
- Stream A (Memory): CLEAN / X issues remaining
- Stream B (Dedup): CLEAN / X issues remaining
- Stream C (Compat): X of Y files migrated
- Stream D (Docs): CURRENT / STALE
- Stream E (Stubs): X of Y completed
- Stream F (Arch): NOT STARTED / IN PROGRESS / X items done
```

## Additional Resources

### Reference Files

- **`references/stream-details.md`** — Detailed audit procedures per stream with grep patterns
