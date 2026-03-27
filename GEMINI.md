# Workspace Overview: OVO

This directory contains **OVO**, a modern, ZON-based package manager and build system for C/C++, intended to serve as a modern replacement for CMake.

## Technologies and Architecture

- **Language:** Zig `0.16.0` (or newer)
- **Target Audience:** C/C++ developers needing a unified build system and package manager.
- **Architecture:**
  - `src/core/`: Shared domain model
  - `src/zon/`: ZON schema and parser boundary
  - `src/build/`: Build orchestration and backend command execution
  - `src/compiler/`: Backend abstractions (Clang/GCC/MSVC/Zig CC)
  - `src/package/`: Dependency management and lockfile operations
  - `src/translate/`: Import/export format adapters (e.g., CMake import compatibility)
  - `src/graph/`: Build graph visualization (`tree` command)
  - `src/cli/`: CLI parser, registry, help, dispatch, and handlers

## Building and Running

The project relies heavily on `./scripts/zigw build` with various steps defined in `build.zig`.
Use `./scripts/zigw` as the canonical Zig entrypoint from a source checkout; on
macOS it applies the CLT 15.4 SDK workaround automatically and honors
`OVO_MACOS_SDKROOT` when you need to override the SDK path.

**Core Build Steps:**
- `./scripts/zigw build`: Build the main executable.
- `./scripts/zigw build run`: Run the OVO CLI.
- `./scripts/zigw build typecheck`: Compile without running tests.

**Testing Steps:**
- `./scripts/zigw build unit-tests`: Run all unit tests.
- `./scripts/zigw build cli-tests-smoke`: Run basic CLI smoke checks.
- `./scripts/zigw build cli-tests-deep`: Run deep CLI checks.
- `./scripts/zigw build cli-tests-stress`: Run stress CLI checks.
- `./scripts/zigw build cli-tests-integration`: Run integration CLI checks.
- `./scripts/zigw build cli-tests-variations`: Run full CLI variation checks (requires multiple toolchains like clang, gcc, cmake, ninja).
- `./scripts/zigw build cli-tests`: Run all CLI testing tiers.
- `./scripts/zigw build full-check`: Run full verification gates (version consistency, typecheck, unit tests, cli tests, help matrix).

## Development Conventions

- **Workflow Orchestration:** Non-trivial engineering tasks (3+ steps or architectural decisions) should use the local workflow script.
  - Start a task: `./scripts/workflow.sh init "<objective>"`
  - This populates `tasks/todo.md` where progress should be tracked.
  - Verify work: `./scripts/workflow.sh check` before marking completion.
  - Document lessons: `./scripts/workflow.sh lesson --task "<task>" --correction "<correction>" --root-cause "<root cause>" --rule "<prevention rule>" --signal "<detection signal>"`
- **Version Consistency:** The active Zig version must match `.zigversion` and the minimum in `build.zig.zon`. The `./scripts/zigw build zig-version-consistency` step enforces this.
- **Project Structure:** Source code is neatly categorized by domain under `src/`, with comprehensive testing logic under `tests/`.

## Command Surface

OVO provides an extensive CLI for project initialization, package management, tooling, and build orchestration.
- **Basic:** `ovo new`, `ovo init`, `ovo build`, `ovo run`, `ovo test`
- **Package Management:** `ovo add`, `ovo remove`, `ovo fetch`, `ovo update`, `ovo lock`, `ovo deps`
- **Tooling:** `ovo doc`, `ovo fmt`, `ovo lint`, `ovo tree`
- **Translation:** `ovo import cmake <path>` parses CMakeLists.txt recursively and ports definitions to the OVO build model.
