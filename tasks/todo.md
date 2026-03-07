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
- `which zig` — pass (`/Users/donaldfilimon/.zvm/bin/zig`)
- `zig version` — pass (`0.16.0-dev.2682+02142a54d`)
- `cat .zigversion` — pass (`0.16.0-dev.2682+02142a54d`)
- `zig build toolchain-doctor` — fail (step not defined in this repo)
- `zig build typecheck` — pass
- `zig build unit-tests` — pass
- `zig build cli-tests-smoke` — pass
- `zig build cli-tests-deep` — pass
- `zig build cli-tests-stress` — pass
- `zig build cli-tests-integration` — pass
- `zig build cli-help-matrix` — pass
- `zig build cli-tests-variations` — fail (missing required tools: `clang-tidy`, `doxygen`, `clang-doc`)
- `zig build cli-tests` — fail (transitive from `cli-tests-variations` env gate)
- `zig build full-check` — fail (transitive from `cli-tests-variations` env gate)
- `zig build gendocs -- --check --no-wasm --untracked-md` — fail (step not defined in this repo)
- `zig build check-docs` — fail (step not defined in this repo)
- End-to-end scaffold smoke:
  - `ovo new "apps/my app"` then `ovo build/test/run` in generated project — pass
  - `ovo new ../escape-*` — blocked as expected; no external dir created
  - `ovo init` idempotency with pre-existing files — pass (existing files preserved)
  - no `DebugAllocator` leak/segfault signal in scaffolded build output after allocator fix

## Review
- Implemented plan scope across scaffold semantics, matrix asset restoration, and parallel build cleanup.
- Remaining blocker is external tool availability required by the strict variation environment gate.
