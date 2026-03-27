# OVO Project-Creation Reliability Hardening + Matrix Recovery

## Objective
Ensure `ovo new`/`ovo init` always scaffold buildable projects, restore the current broken verification matrix, and remove build-time allocator leak noise.

## Checklist
- [x] Restore missing test/script assets required by `build.zig`.
- [x] Implement strict `new`/`init` argument contracts and safe path validation.
- [x] Decouple scaffold display name from internal target IDs with deterministic normalization.
- [x] Fix parallel build artifact-path allocator cleanup leak.
- [x] Update command/documentation text for new scaffold semantics.
- [x] Add/adjust tests for scaffold and version consistency behavior.
- [x] Run verification matrix and record evidence.

## Verification
- `which zig` — pass (`/Users/donaldfilimon/.local/bin/zig`)
- `zig version` — pass (`0.16.0-dev.2984+cb7d2b056`)
- `cat .zigversion` — pass (`0.16.0-dev.2984+cb7d2b056`)
- `./scripts/zigw build toolchain-doctor` — pass
- `./scripts/zigw build typecheck` — pass
- `./scripts/zigw build unit-tests` — pass
- `./scripts/zigw build cli-tests-smoke` — pass (covered by `./scripts/zigw build cli-tests`)
- `./scripts/zigw build cli-tests-deep` — pass (covered by `./scripts/zigw build cli-tests`)
- `./scripts/zigw build cli-tests-stress` — pass (covered by `./scripts/zigw build cli-tests`)
- `./scripts/zigw build cli-tests-integration` — pass (covered by `./scripts/zigw build cli-tests`)
- `./scripts/zigw build cli-help-matrix` — pass
- `./scripts/zigw build cli-tests-variations` — pass
- `./scripts/zigw build cli-tests` — pass
- `./scripts/zigw build full-check` — pass
- `./scripts/zigw build gendocs -- --check --no-wasm --untracked-md` — pass
- `./scripts/zigw build check-docs` — pass
- End-to-end scaffold smoke:
  - `ovo new "apps/my app"` then `ovo build/test/run` in generated project — pass
  - `ovo new ../escape-*` — blocked as expected; no external dir created
  - `ovo init` idempotency with pre-existing files — pass (existing files preserved)
  - no `DebugAllocator` leak/segfault signal in scaffolded build output after allocator fix

## Review
- Implemented plan scope across scaffold semantics, matrix asset restoration, and parallel build cleanup.
- Revalidated the current matrix on the active Zig toolchain; `toolchain-doctor`, `cli-tests-variations`, and `full-check` now pass after correcting the doctor Zig version check.

# AGENTS.md Contributor Guide Refresh

## Objective
Replace the current workflow-heavy `AGENTS.md` with a concise repository contributor guide tailored to OVO.

## Checklist
- [x] Review repo structure, commands, testing tiers, and commit history.
- [x] Draft a 200-400 word `AGENTS.md` titled `Repository Guidelines`.
- [x] Verify the document is concise, repository-specific, and aligned with current build/test workflows.

## Verification
- `wc -w AGENTS.md` — pass (`321`)
- `sed -n '1,240p' AGENTS.md` — pass (manual review confirms requested title, headings, and repo-specific guidance)
- `git diff -- AGENTS.md tasks/todo.md` — pass (changes limited to contributor guide replacement and task tracking)

## Review
- Replaced the workflow-heavy `AGENTS.md` with a concise contributor guide covering structure, `zigw` commands, Zig style, testing tiers, and Conventional Commit-style history.
- No code or behavior changes were made; verification was documentation-focused only.

# Verification Log Reconciliation + Doctor Fix

## Objective
Reconcile stale verification notes against the current repo state and fix the broken Zig version check in `ovo doctor`.

## Checklist
- [x] Confirm the current build steps from `build.zig` and `./scripts/zigw build -l`.
- [x] Fix `handleDoctor` to use `.zigversion` and `zig version`.
- [x] Add focused regression coverage for doctor version evaluation.
- [x] Re-run the affected verification gates and update task tracking.
- [x] Capture the correction pattern in `tasks/lessons.md`.

## Verification
- `./scripts/zigw build -l` — pass (lists `toolchain-doctor`, `gendocs`, and `check-docs`)
- `which zig` — pass (`/Users/donaldfilimon/.local/bin/zig`)
- `zig version` — pass (`0.16.0-dev.2984+cb7d2b056`)
- `cat .zigversion` — pass (`0.16.0-dev.2984+cb7d2b056`)
- `./scripts/zigw build typecheck` — pass
- `./scripts/zigw build unit-tests` — pass
- `./scripts/zigw build toolchain-doctor` — pass
- `./scripts/zigw build cli-help-matrix` — pass
- `./scripts/zigw build cli-tests` — pass
- `./scripts/zigw build cli-tests-variations` — pass
- `./scripts/zigw build gendocs -- --check --no-wasm --untracked-md` — pass
- `./scripts/zigw build check-docs` — pass
- `./scripts/zigw build full-check` — pass

## Review
- The original task log had drifted from the repo: build steps existed, the toolchain was newer, and variation-tool availability had changed.
- `handleDoctor` now reads `.zigversion`, runs `zig version`, reports the active Zig version, and fails on an actual version mismatch instead of an invalid subcommand.

# Broad Improvement Pass Across src/, src/compiler/, and docs/

## Objective
Improve CLI correctness, backend/config validation, and documentation accuracy across the repository without broad architectural churn.

## Checklist
- [x] Tighten CLI argument handling for commands that currently ignore extra positional arguments.
- [x] Centralize backend validation in `src/compiler` and reject unsupported backend values early when parsing project config.
- [x] Add or update focused tests covering the new CLI/backend validation behavior.
- [x] Repair docs drift by generating and syncing `docs/command-reference.md` from the CLI registry.
- [x] Run verification gates and record the results.

## Verification
- `zig fmt src/compiler/backend.zig src/zon/parser.zig src/cli/command_registry.zig src/cli/handlers.zig tests/unit/test_all.zig` — pass
- `git diff --check -- src/compiler/backend.zig src/zon/parser.zig src/cli/command_registry.zig src/cli/handlers.zig tests/unit/test_all.zig docs/command-reference.md tasks/todo.md` — pass
- `./scripts/zigw build typecheck` — pass
- `./scripts/zigw build unit-tests` — pass
- `./scripts/zigw build cli-tests` — pass
- `./scripts/zigw build cli-help-matrix` — pass
- `./scripts/zigw build full-check` — pass
- `./scripts/zigw build check-docs` — pass

## Review
- Added parser/backend validation and alias canonicalization, rejected stray positional args on no-arg CLI handlers, and generated `docs/command-reference.md` from the registry so usage tables stop drifting.
- All verification gates now pass; sandbox access issues resolved.

# Source + Compiler + Docs Improvement Pass

## Objective
Improve backend handling in `src/`/`src/compiler/` and refresh drifted repository docs against the live command surface and verification workflow.

## Checklist
- [x] Normalize compiler backend handling in the build path so aliases/casing are resolved through `src/compiler/backend.zig`.
- [x] Add focused unit coverage for backend normalization in compiler/build code.
- [x] Refresh `README.md` and docs for current commands, supported translation formats, verification gates, and workflow guidance.
- [x] Run targeted verification for compiler/build behavior and the refreshed command/verification docs.

## Verification
- `zig fmt src/compiler/backend.zig src/build/orchestrator.zig src/zon/parser.zig src/cli/command_registry.zig tests/unit/test_all.zig` — pass
- `zig ast-check src/compiler/backend.zig` — pass
- `zig ast-check src/build/orchestrator.zig` — pass
- `zig ast-check src/zon/parser.zig` — pass
- `zig ast-check src/cli/command_registry.zig` — pass
- `zig ast-check tests/unit/test_all.zig` — pass
- `rg -n "ovo version|zig-version-consistency|toolchain-doctor|gendocs|check-docs|Import formats|Export formats|workflow.sh|zig-cc" README.md docs` — pass
- `./scripts/zigw build typecheck` — pass
- `./scripts/zigw build unit-tests` — pass
- `./scripts/zigw build cli-tests` — pass
- `./scripts/zigw build cli-help-matrix` — pass
- `./scripts/zigw build full-check` — pass
- `./scripts/zigw build check-docs` — pass

## Review
- Canonicalized backend labels across compiler/build/config parsing, including aliases like `clang++`, `g++`, `cl`, and `zig-cc`.
- Added command-reference rendering support in the CLI registry and refreshed the checked-in README/docs to match the current command and verification surface.
- All verification gates now pass; sandbox access issues resolved.
