/ex---
description: 
alwaysApply: true
---

## Workflow Orchestration

### 1. Plan Node Default

• Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
• If something goes sideways, STOP and re-plan immediately - don't keep pushing
• Use plan mode for verification steps, not just building
• Write detailed specs upfront to reduce ambiguity
• Present plan for approval before implementation on high-stakes changes

### 2. Subagent Strategy

• Use subagents liberally to keep main context window clean
• Offload research, exploration, and parallel analysis to subagents
• For complex problems, throw more compute at it via subagents
• One task per subagent for focused execution
• Aggregate and synthesize subagent results before proceeding

### 3. Self-Improvement Loop

• After ANY correction from the user: update `tasks/lessons.md` with the pattern
• Write rules for yourself that prevent the same mistake
• Ruthlessly iterate on these lessons until mistake rate drops
• Review lessons at session start for relevant project
• Patterns to capture: root causes, not just symptoms

### 4. Verification Before Done

• Never mark a task complete without proving it works
• Diff behavior between main and your changes when relevant
• Ask yourself: "Would a staff engineer approve this?"
• Run tests, check logs, demonstrate correctness
• For UI changes: verify visually; for API changes: test the endpoint

### 5. Demand Elegance (Balanced)

• For non-trivial changes: pause and ask "is there a more elegant way?"
• If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
• Skip this for simple, obvious fixes - don't over-engineer
• Challenge your own work before presenting it
• Simplicity is the ultimate sophistication

### 6. Autonomous Bug Fixing

• When given a bug report: just fix it. Don't ask for hand-holding
• Point at logs, errors, failing tests - then resolve them
• Zero context switching required from the user
• Go fix failing CI tests without being told how
• Investigate root cause; fix the disease, not the symptom

---

## Task Management

1. **Plan First**: Write plan to `tasks/todo.md` with checkable items
2. **Verify Plan**: Check in before starting implementation
3. **Track Progress**: Mark items complete as you go
4. **Explain Changes**: High-level summary at each step
5. **Document Results**: Add review section to `tasks/todo.md`
6. **Capture Lessons**: Update `tasks/lessons.md` after corrections

---

## Core Principles

| Principle | Description |
|-----------|-------------|
| **Simplicity First** | Make every change as simple as possible. Minimal code impact. |
| **No Laziness** | Find root causes. No temporary fixes. Senior developer standards. |
| **Minimal Impact** | Changes should only touch what's necessary. Avoid introducing bugs. |
| **Review Lessons** | Review `lessons.md` at session start for the relevant project. |

> **Note**: AI responses may include mistakes. Always verify critical changes.

---

## OVO Technical Guidance

### Verification Matrix

Use these gates in order of confidence:

1. Quick loop: `zig build cli-tests-smoke`
2. Compile-only: `zig build typecheck`
3. Unit coverage: `zig build unit-tests`
4. Deep CLI behavior: `zig build cli-tests-deep`
5. Stress CLI behavior: `zig build cli-tests-stress`
6. Integration CLI flows: `zig build cli-tests-integration`
7. Exhaustive CLI variations: `zig build cli-tests-variations`
8. Full pre-merge gate: `zig build full-check`

`cli-tests-variations` enforces a strict CLI test environment (`zig`, `clang-format`, `clang-tidy`, `clang++`, `g++`, `cmake`, `ninja`, `doxygen`, `clang-doc`) before executing.
`full-check` is the umbrella gate (version-consistency + typecheck + unit + CLI tiers + help matrix).

### Module Map

- `src/main.zig`: CLI entry point and runtime initialization.
- `src/ovo.zig`: library root exported as module `ovo`.
- `src/cli/`: args parsing, command registry, command dispatch, handlers.
- `src/core/`: project model, filesystem/runtime/process helpers.
- `src/build/`: build orchestration and dependency include resolution.
- `src/package/`: dependency source classification, registry, lockfile, fetch/update/lock manager.
- `src/translate/`: import/export adapters.
- `src/graph/`: dependency graph renderers for `tree`.
- `src/compiler/`: backend abstraction (Clang/GCC/MSVC/Zig CC).
- `src/zon/`: ZON schema, parser, and writer boundary.
- `src/version.zig`: version metadata.
- `src/main.cpp`: C++ entry point (scaffold target).
- `tests/unit/`: unit suite via `tests/unit/test_all.zig`.
- `tests/cli/`: smoke/deep/stress/integration CLI tiers.

### Coupling Rules

- `src/cli/command_registry.zig` and `src/cli/command_dispatch.zig` must stay in sync.
- Every command listed in the registry must have a dispatch handler.
- When adding/changing command flags, update:
  - parser/handlers,
  - command registry usage/examples,
  - command-reference docs,
  - relevant CLI tests.

### Zig 0.16 Pitfalls

- Do not use legacy APIs (`std.process.argsAlloc`, old `std.posix.getenv`, `std.fs.cwd` patterns).
- Prefer Zig 0.16 idioms (`std.Io`, process init/iterators, allocator-on-method patterns).
- For recursive parser flows where inference is unstable, prefer explicit error typing.
- Keep multiline string formatting Zig-safe (avoid tab pitfalls in multiline literals).

### Test Import Rule

- Tests should import project APIs through `@import("ovo")`.
- Avoid direct source-path imports in tests unless absolutely necessary for fixture-only helpers.

### Exit Code Convention

All CLI handlers return `!u8`:
- `return 0` — success.
- `return 1` — runtime/environment failures.
- `return 2` — user input validation errors (missing args, bad flags, invalid values).
- Forward child process exit codes: `if (code != 0) return code;`

### Command Registry Structure

```zig
pub const CommandGroup = enum { basic, package, tooling, translation };
pub const CommandSpec = struct {
    name: []const u8,
    summary: []const u8,
    usage: []const u8,
    group: CommandGroup,
    examples: []const []const u8 = &.{},
};
```

21 commands registered in `src/cli/command_registry.zig`. Adding/changing commands requires syncing `command_dispatch.zig` and all related tests.

---

## Code Style Guidelines

### Imports
- Use module imports via `@import("path")` pattern.
- Group imports logically: std, internal modules, internal packages.
- Prefer importing the package root (e.g., `@import("ovo")`) in tests.

### Formatting
- Use 4-space indentation (no tabs).
- Keep lines under 100 characters when practical.
- Use multiline strings with consistent indentation (avoid trailing tabs in literals).
- Align related declarations vertically where it aids readability.

### Types and Declarations
- Prefer `const` for immutable bindings; use `var` only when mutation is required.
- Use explicit struct/enum names for public APIs; allow inferred types for internal helpers.
- Prefix error types with `error.` (Zig convention).
- Use descriptive names: `cache_key` over `ck`, `resolvedDependencies` over `RD`.

### Naming Conventions
- **Variables/functions**: `snake_case` (e.g., `file_exists`, `parseArgs`)
- **Types/structs/enums**: `PascalCase` (e.g., `ParsedArgs`, `CommandSpec`)
- **Constants**: `PascalCase` for type-level, `UPPER_SNAKE` for compile-time values.
- **Modules/packages**: `snake_case` directory names.

### Error Handling
- Use `try` for fallible operations that should propagate.
- Use `catch` for known recovery paths; avoid empty catches.
- Prefer explicit error sets over `anyerror` where possible.
- Avoid `@errorReturn`traced functions unless debugging.

### Testing
- Run single test: `zig test <path_to_test_file.zig>` or via build: `zig build unit-tests -- --test-name-pattern <pattern>`.
- Use descriptive test names describing the scenario and expected behavior.
- Group related tests in the same file under a single `test` block or use `test "description"` for granular reporting.

---

## Running Single Tests

```bash
# Specific test file
zig test tests/unit/test_all.zig

# By name pattern
zig build unit-tests -- --test-name-pattern "test_name"

# CLI smoke tests
zig build cli-tests-smoke
```
