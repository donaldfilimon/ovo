# OVO Polish & Hardening Completion Set

**Date:** 2026-02-21
**Status:** Approved

## Goal

Ship-readiness polish: remove dead code, wire dependency includes into builds, clean stale object files, and add build progress output.

## Features

### 1. Remove neural/ module
Delete 5 unused files in `src/neural/`, remove from `ovo.zig`, `test_all.zig`, and README.

### 2. Wire dependency include paths into builds
After `ovo fetch` caches deps to `.ovo/cache/{name}-{version}/`, the build orchestrator auto-discovers `include/` subdirs and appends `-I` flags to compilation commands. Additive to user-declared `include_dirs`.

### 3. Stale .o cleanup
Before compilation, scan `obj-{target}/` for `.o`/`.obj` files not in the expected set from current sources. Delete orphans and force re-link.

### 4. Build progress output
Verbose per-file timing: `Compiling src/main.cpp ... 0.12s`. Summary line at end. Output to stderr. Suppressed by `--quiet`.
