# Zig 0.16 Migration Notes

OVO targets Zig `0.16+` only.

## Baseline Rules

- Keep `.zigversion` and `build.zig.zon` synchronized.
- Avoid deprecated APIs in new code.
- Keep CLI help and registry in one source of truth (`src/cli/command_registry.zig`).
- Keep `build.zig` help-matrix generation sourced from `command_registry` to avoid drift.

## Current CMake Import Progress

- CMake import parsing has moved from a single-command parser to a command/token pipeline with recursive `add_subdirectory` and `include` support.
- Variable expansion now supports both exact and embedded `${VAR}` forms.
- Include directories and source lists are merged with deduplication across recursive imports.

## Follow-ups

- Expand compiler backend option coverage (MSVC-specific flag mapping).
- Add richer schema validation diagnostics for malformed target blocks.
- Improve translation fidelity for Xcode/MSBuild/vcpkg/Conan import/export.
