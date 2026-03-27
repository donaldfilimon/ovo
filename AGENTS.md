# Repository Guidelines

**Note:** No Cursor rules (`.cursor/rules/`, `.cursorrules`) or Copilot rules (`.github/copilot-instructions.md`) were found in this repository.

## Project Structure & Module Organization
OVO is a ZON-based package manager and build system for C/C++, written in Zig 0.16.

**Source Layout:**
- `src/main.zig` — CLI entrypoint
- `src/ovo.zig` — Library module for tests and public API
- `src/cli/` — Command parsing, registry, help text, dispatch, and handlers
- `src/core/` — Shared runtime, filesystem, and project utilities
- `src/build/` — Build orchestration and backend command execution
- `src/compiler/` — Compiler backend abstractions (Clang/GCC/MSVC/Zig CC)
- `src/package/` — Dependency management, lockfile, and registry operations
- `src/translate/` — Import/export format adapters (CMake, Meson, etc.)
- `src/graph/` — Build graph visualization (`tree` command)
- `src/zon/` — ZON parsing and writing utilities

**Test Layout:**
- `tests/unit/` — Unit tests (`test_all.zig` aggregates all unit tests)
- `tests/cli/smoke/` — Fast CLI regression checks
- `tests/cli/deep/` — Deep CLI coverage
- `tests/cli/stress/` — Stress tests
- `tests/cli/integration/` — Integration tests
- `tests/cli/variations/` — Variation matrix (requires `clang-tidy`, `doxygen`, `clang-doc`)

**Other Directories:**
- `scripts/` — Repo helpers (`zigw` wrapper, environment checks)
- `docs/` — Reference material (command reference, verification guide)
- `tasks/` — Workflow tracking (`todo.md`, `lessons.md`)
- `testproj/` — Sample project built with OVO

## Build, Test, and Development Commands

Use `./scripts/zigw` as the canonical Zig wrapper. It handles macOS SDK workarounds automatically.

**Core Build Steps:**
- `./scripts/zigw build` — Build the `ovo` executable
- `./scripts/zigw build run` — Run OVO with passthrough arguments
- `./scripts/zigw build typecheck` — Compile without running tests (CI gate)

**Testing Steps:**
- `./scripts/zigw build unit-tests` — Run all unit tests
- `./scripts/zigw build cli-tests-smoke` — Fast CLI regression (default for quick checks)
- `./scripts/zigw build cli-tests-deep` — Deep CLI checks
- `./scripts/zigw build cli-tests-stress` — Stress CLI checks
- `./scripts/zigw build cli-tests-integration` — Integration CLI checks
- `./scripts/zigw build cli-tests-variations` — Full variation matrix (requires external tools)
- `./scripts/zigw build cli-tests` — Run all CLI tiers
- `./scripts/zigw build full-check` — Full pre-merge gate (version consistency, typecheck, unit tests, CLI tests, help matrix)

**Running a Single Test:**
Use `--test-name-pattern` to filter tests by name:
```
./scripts/zigw build unit-tests -- --test-name-pattern "zon parser requires name and version"
```
For CLI tests, run the specific tier and check output manually:
```
./scripts/zigw build cli-tests-smoke -- --test-name-pattern "ovo version accepts exactly one argument"
```

**Formatting:**
Run `zig fmt` on all changed Zig files before committing:
```
# Format all changed files in src/ and tests/
git diff --name-only --diff-filter=AM HEAD | grep '\.zig$' | xargs zig fmt
# Or format specific directories:
zig fmt src/ tests/
```

**Other Steps:**
- `./scripts/zigw build cli-help-matrix` — Verify `--help` output for every command
- `./scripts/zigw build zig-version-consistency` — Ensure active Zig matches `.zigversion` and `build.zig.zon` minimum
- `./scripts/zigw build toolchain-doctor` — Diagnose toolchain environment
- `./scripts/zigw build gendocs` — Generate project documentation
- `./scripts/zigw build check-docs` — Verify docs are up to date

## Coding Style & Naming Conventions

**Zig Idioms (0.16):**
- Use 4-space indentation.
- `snake_case` for functions, variables, and file names.
- `PascalCase` for types and error sets.
- Prefer `const` by default; only use `var` when mutation is required.
- Use `try` to propagate failures; reserve `catch` for explicit recovery paths.
- Import project APIs in tests via `@import("ovo")`.

**Module Imports:**
- Use relative imports within `src/` (e.g., `@import("../core/mod.zig")`).
- Group imports: standard library first, then project modules.
- In `src/ovo.zig`, re-export public modules for external consumption.
- Avoid relative imports that exit the `src/` directory (use `@import("ovo")` instead).

**Error Handling:**
- Define error sets at the top of modules when multiple error types are possible.
- Use `error.ErrorName` style for named errors (e.g., `error.MissingVersion`).
- Return `!void` or `!T` for fallible functions; propagate with `try`.
- Use `catch` only when you can meaningfully recover or provide a default.
- Prefer explicit error checks over silent failures.
- Example from handlers.zig: `const ProjectPathValidationError = error{ EmptyPath, AbsolutePath, TraversalSegment, CurrentDirectorySegment };`

**Types:**
- Use `[]const u8` for immutable string slices; `[]u8` only when mutation is needed.
- Use `std.mem.Allocator` parameter for functions that allocate.
- Prefer `std.ArrayList(T)` over raw slices for growable collections.
- Use `std.heap.ArenaAllocator` for short-lived allocations in tests and handlers.
- For maps, prefer `std.StringHashMap` or `std.HashMap` with appropriate allocator.

**Structs & Enums:**
- Keep structs focused; separate concerns into modules.
- Use `pub` only for types/functions that need to be accessible outside the module.
- Tagged enums for finite sets of options (e.g., `ExportFormat`, `TreeFormat`).
- When possible, use enum values over booleans for better self-documentation.

**Testing:**
- Every CLI, parser, or build-graph change should ship with test coverage.
- Use `std.testing` for assertions (`expect`, `expectEqual`, `expectError`).
- Use `ArenaAllocator` with `std.testing.allocator` in tests.
- Place inline tests at the bottom of source files; aggregate them in `test_all.zig` via `comptime { _ = module; }`.
- Name tests descriptively: `test "zon parser captures targets and dependencies"`.
- Test both success and failure cases for fallible functions.

## CLI Structure

**Command Registry:**
- Commands are defined in `src/cli/command_registry.zig` as `CommandSpec` structs.
- Each command has: `name`, `summary`, `usage`, `group`, and `examples`.
- Command groups: `.basic`, `.package`, `.tooling`, `.translation`.

**Handlers:**
- Handlers in `src/cli/handlers.zig` follow pattern: `pub fn handleXxx(ctx: *Context) !u8`.
- Return `u8` exit code; `0` for success, non-zero for errors.
- Use `ctx.print()` for stdout, `ctx.printErr()` for stderr.
- Access arguments via `ctx.getArg(index)` or named helpers.

**Context:**
- `Context` provides: `allocator`, `cwd`, `print()`, `printErr()`, `getArg()`, `getEnv()`.
- Context is passed to all handlers for unified I/O and environment access.

## Development Workflow

For non-trivial tasks (3+ steps or architectural decisions), use the workflow script:
- Start: `./scripts/workflow.sh init "<objective>"` — populates `tasks/todo.md`
- Verify: `./scripts/workflow.sh check` before marking completion
- Document lessons: `./scripts/workflow.sh lesson --task "<task>" --correction "<correction>" --root-cause "<root cause>" --rule "<prevention rule>" --signal "<detection signal>"`

Keep `src/cli/command_registry.zig` and `src/cli/command_dispatch.zig` synchronized when adding or modifying commands.

## Commit & Pull Request Guidelines

**Commits:**
Follow Conventional Commit style: `feat:`, `fix:`, `test:`, `build:`, `chore:`, etc.
Keep subjects imperative, lowercase after the prefix, and specific about the behavior changed.
Reference issues when applicable: `fix: resolve issue with version parsing (#123)`.

**Pull Requests:**
- Summarize affected modules or commands.
- List the exact `./scripts/zigw` checks you ran (e.g., `unit-tests`, `cli-tests-smoke`, `full-check`).
- Call out any skipped gates or required toolchain prerequisites.
- Update `docs/command-reference.md` for command or help text changes.
- Ensure all new commands are added to the command registry with proper help text.

## CI & Quality Gates

CI runs on push/PR to `main`/`master` via `.github/workflows/ci.yml`:
- **Build matrix:** Ubuntu and macOS with pinned Zig version (`0.16.0-dev.2984+cb7d2b056`).
- **Required checks:** version consistency, typecheck, unit tests, CLI smoke tests, help matrix.
- **Full check job:** Runs `full-check` on Ubuntu (includes all tiers).
- **Merge requirements:** All required checks must pass before merging.

## Debugging & Troubleshooting

**Common Debug Commands:**
- Run OVO with verbose logging: `./scripts/zigw build run -- --verbose <command>`
- Check build artifacts: `ls -la zig-out/`
- Run specific command directly: `./zig-out/bin/ovo <command> --help`
- Enable core dumps for crashes: `ulimit -c unlimited` before running

**When Tests Fail:**
1. First reproduce with the exact command from CI logs
2. Check if it's a unit test or CLI test failure
3. For unit tests: run with `./scripts/zigw build unit-tests -- --test-name-pattern "<failing test>"`
4. For CLI tests: check the specific tier (smoke, deep, etc.) and look at test output
5. Consider adding debug prints to isolate the issue

**Common Issues:**
- macOS SDK path issues: The `zigw` wrapper handles most SDK configuration
- Version mismatches: Run `./scripts/zigw build zig-version-consistency` to verify
- Test flakiness: Some CLI variation tests require external tools (clang-tidy, doxygen, clang-doc)