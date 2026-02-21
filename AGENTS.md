# AGENTS.md

Guidance for AI agents working on this codebase. See `CLAUDE.md` for full architecture details.

## Verification Protocol

| When | Command |
|------|---------|
| Quick check (minimum loop) | `zig build test-cli-smoke` |
| After code changes | `zig build check` |
| Before merge / PR | `zig build test-all` |

`test-all` is the umbrella gate: compile check + unit tests + all CLI tiers + help matrix.

## Common Pitfalls

1. **Registry/dispatch coupling** — `command_registry.zig` and `command_dispatch.zig` must stay in sync. A comptime check enforces this: adding a command to one without the other causes a build failure.

2. **Forbidden 0.15 APIs** — Smoke tests scan for old APIs. Never use:
   - `std.process.argsAlloc()` (use `process_args.iterateAllocator()`)
   - `std.posix.getenv()` (use `std.process.Init`)
   - `std.fs.cwd()` (use `std.Io.Dir.cwd()`)

3. **Multiline strings can't contain tabs** — Use `"target:\n\trecipe\n"` not `\\` multiline syntax for strings with `\t`.

4. **Recursive error sets** — Mutually recursive functions (e.g., CMake/Meson parsers) can't infer error sets. Use `const XParseError = anyerror;` and explicit return types.

5. **Test imports** — All tests import `@import("ovo")`, never direct file paths. The build system injects the `ovo` module.

## Module Status

| Module | Status | Notes |
|--------|--------|-------|
| `src/cli/` | Active | Command parsing, dispatch, handlers |
| `src/core/` | Active | Domain types, runtime, filesystem |
| `src/zon/` | Active | ZON parser (hand-rolled, not `std.zon`) |
| `src/build/` | Active | Build orchestration |
| `src/compiler/` | Active | Backend abstraction |
| `src/package/` | Active | Partial — git/local fetch only, registry is stub |
| `src/translate/` | Active | 7 import + 8 export format adapters |
| `src/graph/` | Active | `tree` command visualization |
| `src/neural/` | Legacy | Not wired to any CLI command |

## File Layout

```
src/
  main.zig          Entry point
  ovo.zig            Library root (module boundary)
  cli/               CLI layer (args, dispatch, handlers, registry, scaffold)
  core/              Domain model (project, runtime, fs, exec)
  build/             Build orchestrator
  compiler/          Backend enum + helpers
  package/           Package manager
  translate/         Import/export adapters
  graph/             Build graph renderer
  neural/            Legacy (unused)
tests/
  unit/test_all.zig  Unit tests (imports "ovo" module)
  cli/               Tiered CLI tests (smoke, deep, stress, integration)
  fixtures/          Sample projects for integration tests
docs/                Command reference, verification, testing matrix
```
