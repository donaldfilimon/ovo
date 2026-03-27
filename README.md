# OVO

ZON-based package manager and build system for C/C++, designed as a modern replacement for CMake.

## Requirements

- Zig version pinned in `.zigversion` (currently `0.16.0-dev.2984+cb7d2b056`)
- Use `./scripts/zigw` for source-checkout builds and verification

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

Use `./scripts/zigw` as the canonical Zig entrypoint for repository builds and
verification. On macOS it applies the CommandLineTools 15.4 SDK workaround
automatically and honors `OVO_MACOS_SDKROOT` when you need to override the SDK
path.

## Build Steps

```bash
./scripts/zigw build
./scripts/zigw build zig-version-consistency
./scripts/zigw build typecheck
./scripts/zigw build unit-tests
./scripts/zigw build cli-tests-smoke
./scripts/zigw build cli-tests-deep
./scripts/zigw build cli-tests-stress
./scripts/zigw build cli-tests-integration
./scripts/zigw build cli-tests-variations
./scripts/zigw build cli-tests
./scripts/zigw build cli-help-matrix
./scripts/zigw build toolchain-doctor
./scripts/zigw build gendocs -- --check --no-wasm --untracked-md
./scripts/zigw build check-docs
./scripts/zigw build full-check
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

- `ovo version`
- `ovo new <relative_path>`
- `ovo init`
- `ovo build [--force] [-jN] [--jobs=N] [target]`
- `ovo run [target] [-- args]`
- `ovo test [pattern]`
- `ovo clean`
- `ovo install`

### Package Management

- `ovo add <package> [version] [--git <url>|--path <path>|--registry <version>]`
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
- Import formats: `cmake`, `meson`, `xcode`, `msbuild`
- Export formats: `cmake`, `meson`, `xcode`, `msbuild`, `compile_commands.json`

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

- Backend aliases such as `clang++`, `g++`, `cl`, and `zig c++` are normalized to `clang`, `gcc`, `msvc`, and `zigcc` during builds.
- Import defaults to `src/main.cpp` when no targets are detected.
- Includes are merged from project-level and target-level include directives.
- Declared C++ standards from supported commands are mapped to `defaults.cpp_standard`.

## Documentation

- `docs/command-reference.md`
- `docs/verification.md`
- `docs/testing-matrix.md`
- `docs/workflow-orchestration.md`
- `docs/zig-0-16-migration.md`
