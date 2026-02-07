---
name: zig-0.16-ralph-loop
description: Zig 0.16 and Ralph Loop workflow for OVO. Use when editing Zig, build.zon, workspace.zon, or iterating on package manager design per docs/plans.
---

You are a Zig 0.16 expert for the OVO project, following the Ralph Loop improvement cycle from `docs/plans/2026-02-04-ovo-package-manager-design.md`.

## Zig 0.16 Compatibility

- **stdlib**: Use `std.ArrayList(u8).empty` and `list.appendSlice(allocator, slice)`; `list.toOwnedSlice(allocator)` for unmanaged.
- **fs**: `std.fs.cwd()` may not exist; use `std.c.access()`, `std.c.fopen()` via `commands.DirHandle` / `CFile`.
- **env**: Use `std.c.getenv(@ptrCast(&key_buf))` for env vars; avoid `std.posix.getenv` if not available.
- **Build**: Respect `.zigversion` (master or 0.16.x).

## Ralph Loop: Next Steps

1. **Unify on build.zon** — All CLI uses `build.zon`; no `ovo.toml`.
2. **Wire build engine** — `build_cmd` → parse `build.zon` → `build.engine.build()`.
3. **Fix new/init** — Emit `build.zon` from templates; use `OVO_TEMPLATES` env, substitute `{{PROJECT_NAME}}`, etc.
4. **doc/doctor** — Stub implementations.
5. **Integration test** — `ovo new foo && cd foo && ovo build` end-to-end.

## Templates

- **Single project**: `templates/cpp_exe/`, `templates/cpp_lib/`, `templates/c_project/`.
- **Workspace**: `templates/workspace/workspace.zon` — monorepo with `.members`, `.member_patterns`, `.shared`, `.scripts`, `.ci`.

### workspace.zon Schema

```zon
.{
    .workspace = true,
    .name = "{{PROJECT_NAME}}",
    .members = .{ "packages/core", "packages/utils", "apps/cli" },
    .member_patterns = .{ "libs/*", "services/*" },
    .exclude = .{ "archived/*", "**/node_modules" },
    .shared = .{ .cpp_standard = .cpp23, .flags = .{ .common = .{ "-Wall" } } },
    .workspace_dependencies = .{ },
    .scripts = .{ .@"build:all" = "ovo build --workspace" },
    .ci = .{ .github_actions = true },
}
```

## When Editing

1. Run `zig build` and `zig build test` after changes.
2. Run `./scripts/integration_test.sh` for e2e.
3. Add `defer allocator.free()` for all allocations in CLI commands.
4. Prefer `manifest.getTemplateDir()`, `manifest.substituteInContent()` for templates.
