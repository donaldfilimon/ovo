# OVO

ZON-based package manager and build system for C/C++, designed as a modern replacement for CMake.

## Requirements

- Zig `0.16.0` or newer (baseline: `0.16.0-dev.2535+b5bd49460`)
- Project-managed toolchain (`~/.zvm/bin/zig`) for local parity

## Quick Start

```bash
ovo new myapp
cd myapp
ovo build
ovo run
ovo test
```

## Build Steps

```bash
zig build
zig build check
zig build test
zig build test-cli-smoke
zig build test-cli-deep
zig build test-cli-stress
zig build test-cli-integration
zig build test-cli-all
zig build test-cli-help-matrix
zig build test-all
```

## Command Surface

### Basic

- `ovo new <name>`
- `ovo init`
- `ovo build [target]`
- `ovo run [target] [-- args]`
- `ovo test [pattern]`
- `ovo clean`
- `ovo install`

### Package Management

- `ovo add <package> [version]`
- `ovo remove <package>`
- `ovo fetch`
- `ovo update [pkg]`
- `ovo lock`
- `ovo deps`

### Tooling

- `ovo doc`
- `ovo doctor`
- `ovo fmt`
- `ovo lint`
- `ovo info`

### Translation

- `ovo import <format> [path]`
- `ovo export <format> [output_path]`

## Architecture

- `src/core/` shared domain model
- `src/zon/` ZON schema and parser boundary
- `src/build/` build orchestration and backend command execution
- `src/compiler/` backend abstraction (Clang/GCC/MSVC/Zig CC)
- `src/package/` dependency management and lockflow operations
- `src/translate/` import/export format adapters
- `src/cli/` CLI parser, registry, help, dispatch, and handlers
- `src/neural/` legacy neural utilities

## Documentation

- `docs/command-reference.md`
- `docs/verification.md`
- `docs/testing-matrix.md`
- `docs/zig-0-16-migration.md`
