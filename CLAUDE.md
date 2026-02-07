# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

OVO is a ZON-based package manager and build system for C/C++ projects (like Cargo for Rust, but targeting C/C++). Written in Zig 0.16-dev (master), it uses `build.zon` for project configuration and supports multiple compiler backends (Zig CC, Clang, GCC, MSVC, Emscripten).

## Build Commands

Requires Zig 0.16-dev. If Homebrew Zig is older, use zvm: `~/.zvm/bin/zig build`

```bash
zig build              # compile the `ovo` executable → zig-out/bin/ovo
zig build test         # run all unit tests (entry: src/main.zig)
zig build run -- <args> # run the CLI with arguments
zig build docs         # generate documentation to zig-out/docs/
zig build check        # type-check without codegen (IDE integration)
```

Integration test (requires a prior `zig build`):
```bash
export OVO_TEMPLATES="$PWD/templates"
./scripts/integration_test.sh    # runs: ovo new demo && ovo build && ovo run
```

No external dependencies — OVO uses only Zig stdlib.

## Zig 0.16 API Patterns

This codebase targets Zig 0.16-dev (master). Key API differences from earlier Zig versions:

- **Entry point**: `pub fn main(init: std.process.Init) !u8` — not `pub fn main() !void`
- **ArrayList**: Unmanaged — `std.ArrayList(u8).empty`, then `list.append(allocator, item)`, `list.appendSlice(allocator, slice)`, `list.toOwnedSlice(allocator)`, `list.deinit(allocator)`
- **Filesystem**: No `std.fs.cwd()` in CLI layer; use `DirHandle` wrapper in `src/cli/commands.zig` which calls `std.c.access()`, `std.c.fopen()`, `std.c.mkdir()`, etc. A compat layer exists at `src/util/compat.zig` but is not yet used in all modules.
- **Env vars**: `std.c.getenv(@ptrCast(&key_buf))` — avoid `std.posix.getenv`. Compat wrapper: `compat.getenv()`
- **Args**: `std.process.Args.Iterator.initAllocator(init.minimal.args, allocator)`
- **Build modules**: `b.addModule("name", .{ .imports = &.{ .{ .name = "dep", .module = dep_mod } } })`

## Architecture

### Module Dependency Graph (bottom-up)

```
util       ← no deps (fs, glob, http, process, hash, semver, terminal, compat)
core       ← util (Project, Target, Dependency, Profile, Platform, Workspace)
zon        ← core, util (parser, schema, writer, merge for build.zon)
compiler   ← core, util (interface + backends: zig_cc, clang, gcc, msvc, emscripten, modules)
build      ← core, compiler, util (engine, graph, scheduler, cache, artifacts)
package    ← core, util (resolver, fetcher, lockfile, registry, integrity, sources/)
translate  ← core, zon, util (importers/ + exporters/ for CMake, Xcode, MSBuild, Meson, Ninja)
cli        ← all above (commands.zig dispatcher + 20 *_cmd.zig files)
ovo        ← re-exports everything (src/root.zig)
neural     ← legacy ML module, separate from package manager (deprecated)
```

Modules are declared in `build.zig` with explicit import lists. Each module has a `root.zig` that re-exports its public API.

### CLI Command Pattern

- `src/cli/commands.zig` — dispatcher (`dispatch()` → `dispatchCommand()`), `Context`, `DirHandle`, `CFile`, `TermWriter`, shared helpers (`fileExistsC`, `findInPathC`, `hasHelpFlag`, `hasVerboseFlag`)
- `src/cli/*_cmd.zig` — each command exports `pub fn execute(ctx: *Context, args: []const []const u8) !u8`
- `src/cli/manifest.zig` — template handling: `getTemplateDir()`, `substituteInContent()`, `renderTemplate()`

### Build Pipeline Data Flow

```
build.zon → zon.parser.parseFile() → schema.Project
  → build_cmd.convertTarget() → engine.BuildTarget[]
  → BuildEngine.addTarget() → BuildEngine.build()
  → compiler invocation → artifacts
```

### Key Types

- `commands.Context` — passed to every command; holds allocator, args, stdout/stderr writers, cwd DirHandle
- `commands.DirHandle` — C-library-based filesystem abstraction (workaround for Zig 0.16 fs changes)
- `commands.CFile` — C FILE* wrapper with readAll/writeAll
- `engine.BuildEngine` — orchestrates compilation (init → addTarget → build → clean)
- `engine.EngineConfig` — profile, cross_target, jobs, compiler paths, output/cache dirs
- `schema.Project` — parsed build.zon representation (name, version, targets, dependencies)

## Coding Conventions

### Zig Style

- **Import order**: `std`, then domain modules (`zon`, `build`, `cli`), then relative imports
- **Module layout**: `//!` docs → constants/aliases → `pub` types/functions → private helpers
- **Naming**: `snake_case` identifiers, `PascalCase` types, `_` prefix for unused params
- **Allocator discipline**: pass `allocator` as first param, `defer allocator.free()` for owned slices
- **One concern per file**: CLI commands in `*_cmd.zig`, parsers in `zon/`, build logic in `build/`

### ZON Format (build.zon)

- Field order: name, version, targets, defaults, dependencies, tests, profiles
- Named targets use `.@"name"` syntax
- Template placeholders: `{{PROJECT_NAME}}`, `{{AUTHOR_NAME}}`, `{{AUTHOR_EMAIL}}`

## Command Implementation Status

Fully wired to build.zon: `build`, `run`, `new`, `init`, `clean`, `doctor`, `info`, `add`, `remove`, `deps`, `fetch`, `lock`, `update`, `doc`, `install`, `test`, `export`, `import`, `fmt`, `lint`

All 20 CLI commands now parse real build.zon data. `manifest.manifest_filename` constant used everywhere (no hardcoded strings). Import command supports real CMake scanning; other import formats show honest "not yet implemented" messages.

## Latent Zig 0.16 Migration Issues

These don't block `zig build` today (Zig evaluates lazily), but will fail when the code paths are exercised:
- **60 uses of `std.fs.cwd()`** in translate/ (~31), compiler/ (~22), util/ (~6), package/ (~1) — should use `compat.zig` or `DirHandle`
- **20 uses of `std.posix.getenv()`** in compiler/ (7), package/ (9), util/ (4) — should use `compat.getenv()`
- `src/util/compat.zig` exists with wrappers; only `util/root.zig` re-exports it — CLI uses its own `DirHandle`/`CFile` in `commands.zig`

## CI

GitHub Actions (`.github/workflows/ci.yml`): build → unit tests → integration test on `ubuntu-latest` with Zig master.
