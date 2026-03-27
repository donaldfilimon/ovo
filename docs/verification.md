# Verification

## Build Steps

OVO provides a comprehensive set of verification gates that can be run independently or combined.

### Quick Verification

```bash
zig build typecheck        # Compile-only (no tests)
zig build cli-tests-smoke  # Quick smoke tests
```

### Full Verification

```bash
zig build full-check       # All gates (recommended before merge)
```

## Verification Matrix

| Order | Step | Description |
|-------|------|-------------|
| 1 | `cli-tests-smoke` | Quick loop - basic CLI functionality |
| 2 | `typecheck` | Compile-only - no runtime execution |
| 3 | `unit-tests` | Unit test coverage |
| 4 | `cli-tests-deep` | Deep CLI behavior testing |
| 5 | `cli-tests-stress` | Stress testing CLI under load |
| 6 | `cli-tests-integration` | Integration flows |
| 7 | `cli-tests-variations` | Full CLI variation matrix (requires full toolchain) |
| 8 | `full-check` | Complete verification suite |

## Additional Verification Steps

| Step | Description |
|------|-------------|
| `zig-version-consistency` | Verify Zig version matches .zigversion and build.zig.zon |
| `cli-help-matrix` | Run `--help` for every registered command |
| `toolchain-doctor` | Diagnose toolchain environment |
| `check-docs` | Verify documentation is up to date |

## CLI Test Environment

`cli-tests-variations` requires a strict tool prerequisite check before running:

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
# Run a single verification step
zig build cli-tests-smoke

# Run all verification steps
zig build full-check

# Run specific test file
zig test tests/unit/test_all.zig

# Run specific test by name pattern
zig build unit-tests -- --test-name-pattern "test_name"
```
