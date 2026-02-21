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
zig build test-cli-deep        # deep CLI checks (invalid input, error paths)
zig build test-cli-stress      # stress CLI checks (repeatability, parser stability)
zig build test-cli-integration # integration CLI checks (end-to-end flows)
zig build test-cli-all         # all CLI tiers
zig build test-cli-help-matrix # runs --help for every registered command
zig build test-all             # full pre-merge gate (check + unit + all CLI + help matrix)
zig build run -- <args>        # run the ovo CLI locally
```

Minimum local loop: `zig build test-cli-smoke`. Full verification before merge: `zig build test-all`.

## Toolchain

Requires Zig 0.16.0+ (exact version pinned in `.zigversion`, currently `0.16.0-dev.2623+27eec9bd6`). Uses project-managed toolchain at `~/.zvm/bin/zig`. You can also run the built CLI directly via the `./ovo` launcher script in the repo root.

## Architecture

### Module root: `src/ovo.zig`

This is the library root re-exported as the `"ovo"` module. All test files import domain code through `@import("ovo")`, not direct file paths. The build system (`build.zig`) creates an `ovo_module` from `src/ovo.zig` and injects it into every test step. **Never use direct file path imports in tests.**

### Request lifecycle: CLI → Dispatch → Handlers → Domain

1. **`src/main.zig`** — entry point; initializes `core.runtime` I/O, creates a GPA, calls `cli.run()`
2. **`src/cli/args.zig`** — parses raw argv into `ParsedArgs` (global flags, command name, command args, passthrough args separated by `--`). Hard limit of 128 args.
3. **`src/cli/command_dispatch.zig`** — resolves command name via registry, handles `--help`/`--version`, delegates to handler functions. A comptime check ensures the dispatch table stays in sync with the registry.
4. **`src/cli/handlers.zig`** — per-command handler functions (`handleBuild`, `handleNew`, etc.) that call into domain modules
5. **Domain modules** — `build/orchestrator.zig`, `zon/parser.zig`, `package/manager.zig`, `translate/`, `compiler/backend.zig`

### Key domain modules

- **`src/zon/parser.zig`** — hand-rolled ZON parser (not `std.zon`) that extracts project config from `.zon` text using cursor-based field extraction. Returns a `core.project.Project`. Parsed strings point into the original bytes buffer — the arena allocator must keep the source alive for the Project's lifetime.
- **`src/build/orchestrator.zig`** — builds the project by loading `build.zon`, resolving source globs, invoking the compiler backend, and auto-generating `compile_commands.json` to `.ovo/build/`.
- **`src/compiler/backend.zig`** — enum of supported backends (clang, gcc, msvc, zigcc) with parse/label helpers.
- **`src/core/project.zig`** — shared domain types: `Project`, `Target` (with `defines` and `cflags` fields), `Dependency`, `Defaults`, `TargetType`, `CppStandard`.
- **`src/core/runtime.zig`** — global I/O handle (set once from `main`, panics if accessed before initialization). All filesystem ops go through `runtime.io()`.
- **`src/core/fs.zig`** — filesystem helpers using `std.Io.Dir.cwd().*(runtime.io(), ...)`. `writeFile` auto-creates parent dirs. `readFileAlloc` has a 32 MB limit.
- **`src/package/manager.zig`** — package manager with `add`, `remove`, `fetch`, `update`, `lock` commands. `fetch()` supports git URLs (`git clone --depth 1`), local paths (`cp -r`), and registry stubs. Dependencies cached to `.ovo/cache/{name}-{version}/`.
- **`src/cli/context.zig`** — wraps allocator + flags (`verbose`, `quiet`, `profile`, `suppress_stderr`). `quiet` suppresses stdout via `ctx.print()`; `suppress_stderr` silences `ctx.printErr()` (used in tests).
- **`src/cli/scaffold.zig`** — creates project skeletons for `ovo new` and `ovo init` (generates `build.zon`, `src/main.cpp`, directory structure).
- **`src/graph/renderer.zig`** — build graph visualization for the `tree` command. Renders project targets, dependencies, and link relationships in four formats: ascii, dot (Graphviz), json, and mermaid. Distinguishes internal links (between project targets) from external links.
- **`src/translate/`** — import/export adapters for converting between OVO's ZON format and other build systems.

### Command registry pattern

`src/cli/command_registry.zig` defines all 21 commands as a comptime `CommandSpec` array. `command_dispatch.zig` has a parallel `CommandHandler` array and a **comptime validation** that every registry entry has a matching dispatch handler. When adding a new command, you must update both files together or the build fails.

**CommandId naming convention:** Zig reserved words get a `_cmd` suffix: `.new_cmd`, `.test_cmd`, `.import_cmd`, `.export_cmd`. Standard commands use plain names: `.build`, `.run`, `.clean`.

### Translation layer

**Import formats** (7): cmake, xcode, msbuild, meson, makefile, vcpkg, conan
**Export formats** (8): cmake, xcode, msbuild, ninja, compile_commands, makefile, pkg_config, meson

- **CMake import** (`src/translate/import.zig`) — the most mature importer; supports recursive `add_subdirectory` with visit guards (prevents infinite recursion on circular includes), `include` handling for `.cmake` files, `${VAR}` expansion (token + embedded), semicolon list parsing, `find_package()` → dependency extraction, `target_compile_definitions()`, `target_compile_options()`, `target_compile_features()`, `list(APPEND)`, and `option()`. The CMake exporter emits `CMAKE_CXX_STANDARD`, `find_package()` stubs, `target_compile_definitions()`/`target_compile_options()` for defines/cflags, and `install(TARGETS)` rules.
- **Meson import** — recursive parser supporting `project()`, `executable()`, `library()`, `static_library()`, `shared_library()`, `dependency()`, `include_directories()`, `subdir()` with visit guards, variable assignments (`=`, `+=`), array literals, and `cpp_std` detection from `default_options`.
- **Meson export** — generates valid `meson.build` with `project()`, dependency declarations, target function mapping, and `cpp_args` for defines/cflags.
- **Makefile export** — generates per-source `.o` compile rules, proper link/archive rules per target type, `all:`, `clean:`, `.PHONY`, include dirs, defines (`-D`), cflags, and link libraries (`-l`).
- **Ninja export** — generates `compile`/`link`/`archive`/`shared` rules with per-source build edges, proper flags propagation (standard, optimize, includes, defines, cflags), and `default all` target.
- **Makefile import** — parses Make variables (`=`, `:=`, `?=`, `+=`), extracts `-I` flags, detects target rules and recipe-based library type (`ar` → static, `-shared` → shared). Falls back to naive `.cpp` scanning when no structured rules are found.
- **Xcode export** — generates `.pbxproj` with deterministic UUIDs via `pbxUuid(seed, &counter)`.
- **MSBuild export** — generates `.vcxproj` with deterministic GUIDs via hash-based generation.
- **Pkg-config export** — generates `.pc` files with real `Libs:` (from first library target), `Cflags:` (includes + defines), and `Requires:` (from dependencies).
- **Conan import** — dual format: tries `conanfile.txt` (INI-style) first, then `conanfile.py` (regex-like pattern matching).

### Test structure

- `tests/unit/test_all.zig` — unit tests that import `"ovo"` module; covers parser, registry, neural, compiler, orchestrator
- **Inline tests in translate modules**: `test_all.zig` pulls in inline tests from both `src/translate/import.zig` and `src/translate/export.zig` via `_ = importer; _ = exporter;` — parsing/generation tests live in the source files, not separate test files
- `tests/cli/{smoke,deep,stress,integration}/` — tiered CLI tests
- `tests/fixtures/` — sample project fixtures for integration/translation tests
- The help matrix test iterates `command_registry.commands` at build time to generate a `--help` invocation for every command
- **Smoke tests scan source files for forbidden 0.15 APIs** (e.g., `std.process.argsAlloc()`, `std.posix.getenv()`)

## Coding Conventions

- Zig idiomatic naming: `snake_case` locals, `camelCase` functions, `PascalCase` types
- Run `zig fmt` before committing
- Conventional Commits: `feat:`, `fix:`, `test:`, `chore:`
- Table-driven tests preferred; test descriptions should state expected behavior

### Zig 0.16 API patterns (follow existing code)

- `std.ArrayList(T)` initialized with `.empty`, allocator passed to methods: `try list.append(allocator, item)`
- `std.Io`, `std.process.Init`, `std.Io.Dir.cwd()` — NOT old POSIX APIs
- Process args via `process_args.iterateAllocator(arena_alloc)` — NOT `std.process.argsAlloc()`
- Thread-safe chdir: `std.Io.Threaded.chdir(cwd)`
- Arena allocator wraps GPA for the entire CLI run (`src/cli/mod.zig`); no manual frees in handlers

### Zig gotchas

- **Recursive parser error sets**: Functions in mutual recursion (e.g., `parseMesonBuffer` → `handleMesonSubdir` → `importMesonFromPath` → `parseMesonBuffer`) can't infer error sets. Use `const MesonParseError = anyerror;` and annotate return types explicitly (see `CMakeParseError`, `MesonParseError`).
- **Multiline strings can't contain tabs**: Zig `\\` string literals reject `\t`. For test fixtures needing literal tabs (e.g., Makefile recipes), use regular string literals: `"target:\n\trecipe\n"` instead of multiline syntax.

### Known limitations

- **Neural module is legacy**: `src/neural/` is not wired to any CLI command. It exists as experimental code but has no user-facing entry point.
- **Package registry is a stub**: `src/package/manager.zig` `fetch()` only supports git URLs (`git clone --depth 1`) and local paths (`cp -r`). The registry path is a placeholder.
- **Generated artifacts in repo root are gitignored**: `build.zon`, `src/main.cpp`, `tests/main_test.cpp`, and `ovo` are in `.gitignore` because `ovo init`/`ovo new` generate them when run in the repo root.
