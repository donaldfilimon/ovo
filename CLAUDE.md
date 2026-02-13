# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is OVO

OVO is a ZON-based package manager and build system for C/C++, written in Zig 0.16. It aims to replace CMake by using Zig's ZON format for project configuration. OVO reads a `build.zon` file describing C/C++ targets, dependencies, and build defaults, then shells out to a compiler backend (clang, gcc, msvc, or zig cc) to build them.

## Build & Test Commands

```bash
zig build                      # compile the ovo executable
zig build check                # compile-only verification (no tests)
zig build test                 # unit tests (tests/unit/test_all.zig)
zig build test-cli-smoke       # fast CLI smoke tests (minimum local loop)
zig build test-cli-deep        # deep CLI checks
zig build test-cli-stress      # stress CLI checks
zig build test-cli-integration # integration CLI checks
zig build test-cli-all         # all CLI tiers
zig build test-cli-help-matrix # runs --help for every registered command
zig build test-all             # full pre-merge gate (check + unit + all CLI + help matrix)
zig build run -- <args>        # run the ovo CLI locally
```

Minimum local loop: `zig build test-cli-smoke`. Full verification before merge: `zig build test-all`.

## Toolchain

Requires Zig 0.16.0+ (pinned in `.zigversion`). Uses project-managed toolchain at `~/.zvm/bin/zig`.

## Architecture

### Module root: `src/ovo.zig`

This is the library root re-exported as the `"ovo"` module. All test files import domain code through `@import("ovo")`, not direct file paths. The build system (`build.zig`) creates an `ovo_module` from `src/ovo.zig` and injects it into every test step.

### Request lifecycle: CLI → Dispatch → Handlers → Domain

1. **`src/main.zig`** — entry point; initializes `core.runtime` I/O, creates a GPA, calls `cli.run()`
2. **`src/cli/args.zig`** — parses raw argv into `ParsedArgs` (global flags, command name, command args, passthrough args separated by `--`)
3. **`src/cli/command_dispatch.zig`** — resolves command name via registry, handles `--help`/`--version`, delegates to handler functions. A comptime check ensures the dispatch table stays in sync with the registry.
4. **`src/cli/handlers.zig`** — per-command handler functions (`handleBuild`, `handleNew`, etc.) that call into domain modules
5. **Domain modules** — `build/orchestrator.zig`, `zon/parser.zig`, `package/manager.zig`, `translate/`, `compiler/backend.zig`

### Key domain modules

- **`src/zon/parser.zig`** — hand-rolled ZON parser that extracts project config (name, version, targets, dependencies, defaults) from `.zon` text. Returns a `core.project.Project` struct.
- **`src/build/orchestrator.zig`** — builds the project by loading `build.zon`, resolving source globs, invoking the compiler backend, and writing `compile_commands.json`.
- **`src/compiler/backend.zig`** — enum of supported backends (clang, gcc, msvc, zigcc) with parse/label helpers.
- **`src/core/project.zig`** — shared domain types: `Project`, `Target`, `Dependency`, `Defaults`, `TargetType`, `CppStandard`.
- **`src/core/runtime.zig`** — global I/O handle (set once from `main`, used by filesystem operations).
- **`src/translate/`** — import/export adapters for converting between OVO's ZON format and other build systems (e.g., CMake).

### Command registry pattern

`src/cli/command_registry.zig` defines all 20 commands as a comptime `CommandSpec` array. `command_dispatch.zig` has a parallel `CommandHandler` array and a **comptime validation** that every registry entry has a matching dispatch handler. When adding a new command, you must update both files together or the build fails.

### Test structure

- `tests/unit/test_all.zig` — unit tests that import `"ovo"` module; covers parser, registry, neural, compiler, orchestrator
- `tests/unit/test_all.zig` also links translate importer tests from `src/translate/import.zig` so CMake parsing changes stay covered.
- `tests/cli/{smoke,deep,stress,integration}/` — tiered CLI tests
- `tests/fixtures/` — sample project fixtures for integration/translation tests
- The help matrix test (`test-cli-help-matrix` build step) iterates `command_registry.commands` at build time to generate a `--help` invocation for every command

### CMake importer state

- `src/translate/import.zig` now includes:
  - recursive `add_subdirectory` parsing with include-guarding
  - `include` handling for `.cmake` script files
  - CMake variable expansion for token and embedded substitution
  - semicolon list parsing for source/include token groups

## Coding Conventions

- Zig idiomatic naming: `snake_case` locals, `camelCase` functions, `PascalCase` types
- Run `zig fmt` before committing
- Conventional Commits: `feat:`, `fix:`, `test:`, `chore:`
- Table-driven tests preferred; test descriptions should state expected behavior
- Zig 0.16 APIs: uses `std.ArrayList` (not `ArrayListUnmanaged`), `std.Io`, `std.process.Init`, `std.Io.Dir.cwd()` — follow existing patterns when adding new code
