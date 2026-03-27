# Verification

## Build Steps

OVO exposes verification gates that can be run independently or through the umbrella `full-check` step. Use `./scripts/zigw` for source-checkout verification commands. On macOS it applies the CLT 15.4 SDK workaround automatically and honors `OVO_MACOS_SDKROOT` when you need to override the SDK path.

### Quick Verification

```bash
./scripts/zigw build cli-tests-smoke  # Fastest CLI regression loop
./scripts/zigw build typecheck        # Compile-only sanity check
```

### Full Verification

```bash
./scripts/zigw build full-check
```

`full-check` runs `zig-version-consistency`, `typecheck`, `unit-tests`, `cli-tests`, `cli-help-matrix`, `toolchain-doctor`, and `check-docs`.

## Verification Matrix

| Order | Step | Description |
|-------|------|-------------|
| 1 | `cli-tests-smoke` | Quick loop for basic CLI behavior |
| 2 | `typecheck` | Compile-only validation |
| 3 | `unit-tests` | Unit coverage across parser/build/package logic |
| 4 | `cli-tests-deep` | Deeper CLI behavior coverage |
| 5 | `cli-tests-stress` | Stress CLI behavior under heavier scenarios |
| 6 | `cli-tests-integration` | End-to-end CLI integration flows |
| 7 | `cli-tests-variations` | Full CLI variation matrix with strict tool prerequisites |
| 8 | `full-check` | Full repository verification gate |

## Additional Verification Steps

| Step | Description |
|------|-------------|
| `zig-version-consistency` | Verify the active Zig version matches `.zigversion` and `build.zig.zon` |
| `cli-tests` | Run the aggregate CLI tier gate |
| `cli-help-matrix` | Run `--help` for every registered command |
| `toolchain-doctor` | Report pinned/active Zig versions and tool availability |
| `gendocs` | Generate `docs/project-reference.md` from the current project |
| `check-docs` | Run the documentation verification step |

`check-docs` currently regenerates `docs/project-reference.md` via `ovo doc`.

## CLI Test Environment

`cli-tests-variations` requires these tools before it will run:

- `zig`
- `clang-format`
- `clang-tidy`
- `clang++`
- `g++`
- `cmake`
- `ninja`
- `doxygen`
- `clang-doc`

## Running Verification

```bash
# Run one verification step
./scripts/zigw build cli-tests-smoke

# Run all verification steps
./scripts/zigw build full-check

# Refresh generated docs explicitly
./scripts/zigw build gendocs -- --check --no-wasm --untracked-md
./scripts/zigw build check-docs

# Run a specific unit test file
./scripts/zigw test tests/unit/test_all.zig

# Run a specific unit test by name pattern
./scripts/zigw build unit-tests -- --test-name-pattern "test_name"
```
