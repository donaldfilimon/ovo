# OVO

A ZON-based package manager and build system for C/C++, designed as a modern replacement for CMake.

## Overview

OVO unifies package management and builds for C/C++ projects. Configuration lives in `build.zon` (Zig Object Notation). OVO uses Zig's compiler infrastructure and supports multiple compiler backends (Clang, GCC, MSVC, Zig CC).

## Requirements

- [Zig](https://ziglang.org/) 0.16.x or master (see `.zigversion`)

## Quick Start

```bash
# Create a new project
ovo new myapp
cd myapp

# Build
ovo build

# Run (for executables)
ovo run

# Run tests
ovo test
```

## Build

```bash
zig build
zig build test
```

## CLI Commands

### Basic

| Command | Description |
|---------|-------------|
| `ovo new <name>` | Create a new project |
| `ovo init` | Initialize in current directory |
| `ovo build [target]` | Build the project |
| `ovo run [target] [-- args]` | Build and run |
| `ovo test [pattern]` | Run tests |
| `ovo clean` | Remove build artifacts |
| `ovo install` | Install to system |

### Package Management

| Command | Description |
|---------|-------------|
| `ovo add <package>` | Add a dependency |
| `ovo remove <package>` | Remove a dependency |
| `ovo fetch` | Download dependencies |
| `ovo update [pkg]` | Update dependencies |
| `ovo lock` | Generate lock file |
| `ovo deps` | Show dependency tree |

### Tooling

| Command | Description |
|---------|-------------|
| `ovo doc` | Generate documentation |
| `ovo doctor` | Diagnose environment |
| `ovo fmt` | Format source code |
| `ovo lint` | Run linter |
| `ovo info` | Project information |

### Project Translation

| Command | Description |
|---------|-------------|
| `ovo import <path>` | Import from CMake, Xcode, MSBuild, Meson |
| `ovo export <format>` | Export to CMake, Xcode, MSBuild, Ninja |

## build.zon Example

```zon
.{
    .name = "myapp",
    .version = "1.0.0",
    .license = "MIT",
    .targets = .{
        .myapp = .{
            .type = .executable,
            .sources = .{ .{ .pattern = "src/**/*.cpp" } },
            .include_dirs = .{ "include" },
            .link = .{ "m" },
        },
    },
    .defaults = .{
        .cpp_standard = .cpp20,
    },
}
```

## Architecture

- **core/** — Data structures (project, target, dependency, profile)
- **zon/** — ZON parsing and schema for build.zon
- **build/** — Build orchestration (graph, scheduler, cache)
- **compiler/** — Compiler abstraction (Clang, GCC, MSVC, Zig CC)
- **package/** — Package resolution and fetching
- **translate/** — Import/export (CMake, Xcode, MSBuild, Ninja)
- **cli/** — CLI commands

## Legacy: Neural Module

OVO includes a minimal neural network module (`src/neural/`) for ML experimentation. It is separate from the package manager. See `src/neural/` for activation, layers, loss, and training utilities.

## License

See repository.
