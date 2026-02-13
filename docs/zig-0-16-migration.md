# Zig 0.16 Migration Notes

OVO targets Zig `0.16+` only.

## Baseline Rules

- Keep `.zigversion` and `build.zig.zon` synchronized.
- Avoid deprecated APIs in new code.
- Keep CLI help and registry in one source of truth (`src/cli/command_registry.zig`).
- Keep `build.zig` help-matrix generation sourced from `command_registry` to avoid drift.

## Follow-ups

- Expand compiler backend option coverage (MSVC-specific flag mapping).
- Add richer schema validation diagnostics for malformed target blocks.
- Improve translation fidelity for Xcode/MSBuild/vcpkg/Conan import/export.
