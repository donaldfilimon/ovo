# OVO: ZON-Based Package Manager and Build System for C/C++

## Overview

OVO is a unified package manager and build system for C/C++ projects, designed as a modern replacement for CMake. It uses Zig's ZON format for configuration and leverages Zig's compiler infrastructure for compilation.

## Design Goals

1. **Unified Build + Package System** (like Cargo for Rust) - Package format IS the build configuration
2. **Zig as Backend** - Leverage Zig's build system with ZON-based DSL, no Zig code required for simple projects
3. **Full C/C++ Standard Support** - C99-C23, C++11-C++26
4. **Compiler Agnostic** - Zig's Clang (default), system Clang, GCC, MSVC
5. **Seamless C++ Modules** - Auto-detect and compile C++20/23/26 modules
6. **Hybrid Package Sources** - Decentralized (git, paths) + vcpkg/Conan integration

## CLI Commands

### Basic Commands

```bash
ovo new <name>           # scaffold new project
ovo init                 # init in existing directory
ovo build [target]       # compile
ovo run [target] [-- args]  # build + execute
ovo test [pattern]       # run tests
ovo clean                # remove build artifacts
ovo install              # install to system
```

### Package Management

```bash
ovo add <package>        # add dependency
ovo add <pkg> --git=<url>
ovo add <pkg> --vcpkg
ovo add <pkg> --conan
ovo remove <package>
ovo fetch                # download dependencies
ovo update [pkg]         # update to latest
ovo lock                 # generate lockfile
ovo deps                 # show dependency tree
ovo deps --why <pkg>     # explain why pkg included
```

### Build Options

```bash
ovo build --release
ovo build --target=x86_64-linux
ovo build --compiler=gcc
ovo build --std=c++23
ovo build --jobs=N
ovo build --verbose
ovo build --export-compile-commands
```

### Project Translation

```bash
# Import FROM other build systems
ovo import cmake .
ovo import xcode MyApp.xcodeproj
ovo import msbuild MyProject.sln
ovo import meson .

# Export TO other build systems
ovo export cmake
ovo export xcode
ovo export msbuild
ovo export ninja
ovo export compile-commands
```

### Tooling

```bash
ovo fmt                  # clang-format
ovo lint                 # clang-tidy
ovo doc                  # generate documentation
ovo info                 # project info
ovo doctor               # diagnose issues
```

## build.zon Format

### Package Metadata

```zon
.{
    .name = "myproject",
    .version = "1.0.0",
    .description = "A modern C++ application",
    .license = "MIT",
    .authors = .{ "Jane Doe <jane@example.com>" },

    .defaults = .{
        .cpp_standard = .cpp23,
        .c_standard = .c17,
        .compiler = .auto,
        .optimization = .debug,
    },
}
```

### Build Targets

```zon
.targets = .{
    .myapp = .{
        .type = .executable,
        .sources = .{ "src/main.cpp", "src/**/*.cpp" },
        .include_dirs = .{ "include" },
        .link = .{ "mylib", "fmt" },
        .cpp_standard = .cpp26,
        .flags = .{
            .common = .{ "-Wall", "-Wextra" },
            .release = .{ "-flto" },
        },
        .platform = .{
            .windows = .{ .link = .{ "ws2_32" } },
            .macos = .{ .frameworks = .{ "CoreFoundation" } },
        },
    },

    .mylib = .{
        .type = .static_library,
        .sources = .{ "src/lib/**/*.cpp" },
        .public_include = .{ "include" },
        .modules = .auto,  // auto-detect C++ modules
    },
}
```

### Dependencies

```zon
.dependencies = .{
    // Git
    .fmt = .{
        .git = "https://github.com/fmtlib/fmt",
        .tag = "10.2.0",
        .hash = "0x1234...",
    },

    // vcpkg
    .openssl = .{
        .vcpkg = "openssl",
        .version = "3.2.0",
    },

    // Conan
    .poco = .{
        .conan = "poco/1.13.0",
    },

    // System with fallback
    .zlib = .{
        .system = "zlib",
        .pkg_config = "zlib",
        .fallback = .{
            .git = "https://github.com/madler/zlib",
            .tag = "v1.3.1",
        },
    },
}
```

### Tests & Profiles

```zon
.tests = .{
    .unit = .{
        .sources = .{ "tests/unit/**/*.cpp" },
        .link = .{ "mylib", "googletest" },
    },
},

.profiles = .{
    .debug = .{
        .optimization = .none,
        .debug_info = true,
        .sanitizers = .{ .address, .undefined },
    },
    .release = .{
        .optimization = .speed,
        .lto = true,
    },
},
```

## Architecture

```
src/
├── main.zig              # CLI entry point
├── root.zig              # Public API
├── core/                 # Data structures
│   ├── project.zig
│   ├── target.zig
│   ├── dependency.zig
│   ├── profile.zig
│   ├── workspace.zig
│   └── platform.zig
├── zon/                  # ZON processing
│   ├── parser.zig
│   ├── schema.zig
│   └── writer.zig
├── build/                # Build orchestration
│   ├── engine.zig
│   ├── graph.zig
│   ├── scheduler.zig
│   └── cache.zig
├── compiler/             # Compiler abstraction
│   ├── interface.zig
│   ├── zig_cc.zig
│   ├── clang.zig
│   ├── gcc.zig
│   ├── msvc.zig
│   └── modules.zig
├── package/              # Package management
│   ├── resolver.zig
│   ├── fetcher.zig
│   ├── lockfile.zig
│   └── sources/
├── translate/            # Project translation
│   ├── importers/
│   └── exporters/
├── cli/                  # CLI commands
└── util/                 # Utilities
```

## Key Features

### Seamless C++ Modules

- Auto-detect module interface files (.cppm, .ixx, .mpp)
- Scan for `export module` declarations
- Build dependency graph for correct compilation order
- BMI caching for incremental builds

### Compiler Abstraction

- Zig's bundled Clang as zero-config default
- Detect and use system compilers when configured
- Unified flag translation across compilers
- Cross-compilation support via Zig

### Incremental Builds

- Content-based hashing (not timestamps)
- Track header dependencies
- Parallel compilation with dependency ordering
- Persistent cache across builds

### Project Translation

- Bidirectional: import AND export
- Support CMake, Xcode, Visual Studio, Meson
- Generate compile_commands.json for LSP
- Warnings for untranslatable features

## Implementation Status

*Last updated: 2026-02-04 (Ralph Loop review)*

| Component | Status | Notes |
|-----------|--------|-------|
| Core data structures | [x] | `project.zig`, `target.zig`, `dependency.zig`, `profile.zig`, `workspace.zig`, `platform.zig` |
| ZON parsing | [x] | `parser.zig`, `schema.zig`, `writer.zig` — full build.zon schema |
| Compiler abstraction | [x] | `interface.zig`, `zig_cc.zig`, `clang.zig`, `gcc.zig`, `msvc.zig`, `modules.zig` |
| Build engine | [x] | `engine.zig`, `graph.zig`, `scheduler.zig`, `cache.zig`, `artifacts.zig` |
| Package management | [x] | `resolver.zig`, `fetcher.zig`, `lockfile.zig`, `sources/` (git, vcpkg, conan, path, system) |
| Translation system | [x] | Importers: cmake, xcode, msbuild, meson, makefile, vcpkg, conan. Exporters: cmake, xcode, msbuild, ninja, compile_db |
| CLI commands | [x] | All 16 commands registered and dispatch |
| Utilities and templates | [x] | `util/` (fs, glob, hash, http, process, semver, terminal), `templates/` (cpp_exe, cpp_lib, c_project, workspace) |

**Integration gap:** CLI commands still reference `ovo.toml` and use stub logic. Build command invokes `system(clang)` directly instead of the build engine. `new`/`init` emit TOML, not ZON.

## Gap Analysis (Ralph Loop)

### Critical: Manifest Format Mismatch

- **Design:** `build.zon` (ZON format)
- **Templates:** `build.zon` ✓
- **CLI commands:** All check for `ovo.toml` and reference it in messages
- **Action:** Migrate CLI to `build.zon`; support both during transition or switch fully

### Critical: Build Pipeline Not Wired

- **build_cmd.zig:** Uses `system(clang ...)` for single-file compilation
- **build/engine.zig:** Full orchestration exists but is unused
- **Action:** Wire `build_cmd` to `build.engine`; load project via `zon.parser.parseFile("build.zon")`

### Missing CLI Commands (from design)

- `ovo update [pkg]` — not a top-level command (only `fetch --update`)
- `ovo lock` — not a top-level command (lockfile generated by fetch)
- `ovo doc` — not implemented
- `ovo doctor` — not implemented

### new/init Output Format

- **new_cmd.zig:** Writes TOML manifest via `writeManifest()`
- **init_cmd.zig:** Stub — logs to stdout, doesn't write file
- **Action:** Use `zon.writer` or template files to emit `build.zon`

## Ralph Loop: Next Steps

1. **Unify on build.zon** — Replace all `ovo.toml` references with `build.zon` in CLI
2. **Wire build engine** — `build_cmd` → parse `build.zon` → `build.engine.run()`
3. **Fix new/init** — Emit `build.zon` from templates (reuse `templates/cpp_exe/build.zon` pattern)
4. **Add doc/doctor** — Stub implementations for tooling commands
5. **Integration test** — `ovo new foo && cd foo && ovo build` end-to-end

## Future Considerations

- Central package registry
- Remote build caching
- Distributed builds
- IDE plugins (VS Code, CLion)
