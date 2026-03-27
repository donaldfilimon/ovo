# OVO

ZON-based package manager and build system for C/C++, designed as a modern replacement for CMake.

## Requirements

- Zig `0.16.0` or newer (baseline: `0.16.0-dev.2682+02142a54d`)
- Project-managed toolchain (`~/.zvm/bin/zig`) for local parity

## Quick Start

```bash
ovo new myapp
cd myapp
ovo build
ovo run
ovo test
```

`ovo new` accepts safe relative paths (including nested paths like `apps/myapp`).
Scaffold metadata uses the path basename for `build.zon .name`, and target IDs are normalized to safe internal identifiers.

From a source checkout of this repository, you can run the local launcher directly:

```bash
./ovo --help
./ovo build
```

## Build Steps

```bash
zig build
zig build zig-version-consistency
zig build typecheck
zig build unit-tests
zig build cli-tests-smoke
zig build cli-tests-deep
zig build cli-tests-stress
zig build cli-tests-integration
zig build cli-tests-variations
zig build cli-tests
zig build cli-help-matrix
zig build full-check
```

`cli-tests-variations` enforces a strict tool prerequisite check before running:
`zig`, `clang-format`, `clang-tidy`, `clang++`, `g++`, `cmake`, `ninja`, `doxygen`, `clang-doc`.

## Workflow Orchestration

Use the local workflow contract for non-trivial engineering tasks (3+ steps or architectural decisions).

Expected lifecycle:

1. Initialize `tasks/todo.md` before implementation.
2. Track progress and verification evidence while implementing.
3. Run verification gates before marking completion.
4. Append lessons to `tasks/lessons.md` after user corrections.

See `AGENTS.md` for detailed workflow orchestration guidelines.

## Command Surface

### Basic

- `ovo new <relative_path>`
- `ovo init`
- `ovo build [target]`
- `ovo run [target] [-- args]`
- `ovo test [pattern]`
- `ovo clean`
- `ovo install`

### Package Management

- `ovo add <package> [version]`
- `ovo add <package> --git <url>`
- `ovo add <package> --path <path>`
- `ovo add <package> --registry <version>`
- `ovo remove <package>`
- `ovo fetch [--refresh]`
- `ovo update [pkg]`
- `ovo lock`
- `ovo deps`

### Tooling

- `ovo doc`
- `ovo doctor`
- `ovo fmt`
- `ovo lint`
- `ovo info`
- `ovo tree [--format=ascii|dot|json|mermaid] [--target=name]`

### Translation

- `ovo import <format> [path]`
- `ovo export <format> [output_path]`

### CMake Import Compatibility

- `ovo import cmake <path>` parses:
  - `project`, `set`, `add_executable`, `add_library`
  - `add_subdirectory` recursively
  - `include` and `.cmake` include files
  - `${VAR}` variable expansion and embedded expansions
  - semicolon-separated source/include list values
  - visited path guards to avoid duplicate recursive imports

## Architecture

- `src/core/` shared domain model
- `src/zon/` ZON schema and parser boundary
- `src/build/` build orchestration and backend command execution
- `src/compiler/` backend abstraction (Clang/GCC/MSVC/Zig CC)
- `src/package/` dependency management and lockflow operations
- `src/translate/` import/export format adapters
- `src/graph/` build graph visualization (`tree` command)
- `src/cli/` CLI parser, registry, help, dispatch, and handlers

## Translation Notes

- Import defaults to `src/main.cpp` when no targets are detected.
- Includes are merged from project-level and target-level include directives.
- Declared C++ standards from supported commands are mapped to `defaults.cpp_standard`.

## Documentation

- `docs/command-reference.md`
- `docs/verification.md`
- `docs/testing-matrix.md`
- `docs/workflow-orchestration.md`
- `docs/zig-0-16-migration.md`
