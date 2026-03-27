# Testing Matrix

## Test Structure

OVO organizes tests into tiers based on scope and confidence level. Use `./scripts/zigw` for source-checkout test commands. On macOS it applies the CLT 15.4 SDK workaround automatically and honors `OVO_MACOS_SDKROOT` when you need to override the SDK path.

### Unit Tests

Located in `tests/unit/`:

| File | Description |
|------|-------------|
| `test_all.zig` | Main unit test suite |
| `test_zig_version_consistency.zig` | Zig version consistency coverage |

**Running:**
```bash
./scripts/zigw build unit-tests
```

### CLI Tests

Located in `tests/cli/`:

| Tier | Directory | Description |
|------|-----------|-------------|
| Smoke | `tests/cli/smoke/` | Quick basic functionality |
| Deep | `tests/cli/deep/` | Detailed CLI behavior |
| Stress | `tests/cli/stress/` | Load and stress testing |
| Integration | `tests/cli/integration/` | Integration flows |
| Variations | `tests/cli/variations/` | Full variation matrix |

**Running:**
```bash
# Single tier
./scripts/zigw build cli-tests-smoke
./scripts/zigw build cli-tests-deep
./scripts/zigw build cli-tests-stress
./scripts/zigw build cli-tests-integration
./scripts/zigw build cli-tests-variations

# All CLI tiers
./scripts/zigw build cli-tests
```

## Test Naming Convention

Tests use descriptive sentence-case names that describe behavior:

```zig
test "zon parser returns MissingName on nameless input" { ... }
test "renderBuildZon produces valid minimal project" { ... }
test "sortedUniqueDependencies deduplicates by name" { ... }
```

## Test Import Rule

Tests should import project APIs through `@import("ovo")`:

```zig
const ovo = @import("ovo");
```

Avoid direct source-path imports unless necessary for fixture-only helpers.

## Running Tests

### Single Test File

```bash
./scripts/zigw test tests/unit/test_all.zig
```

### By Name Pattern

```bash
./scripts/zigw build unit-tests -- --test-name-pattern "test_name"
```

### Aggregate Gates

```bash
./scripts/zigw build cli-tests    # All CLI tiers
./scripts/zigw build full-check   # Full repository gate (tests + doctor/docs/help)
```

## Test Dependencies

CLI tests that require external tools are gated by environment checks:

| Test Tier | Requirements |
|-----------|-------------|
| Smoke | zig |
| Deep | zig, basic tools |
| Integration | zig, build tools |
| Variations | zig, clang-format, clang-tidy, clang++, g++, cmake, ninja, doxygen, clang-doc |

## Additional Verification Gates

These steps are build gates rather than unit/CLI test tiers:

| Step | Purpose |
|------|---------|
| `./scripts/zigw build zig-version-consistency` | Verify active Zig matches `.zigversion` and `build.zig.zon` |
| `./scripts/zigw build cli-help-matrix` | Run `--help` across the full command surface |
| `./scripts/zigw build toolchain-doctor` | Verify required and optional toolchain pieces |
| `./scripts/zigw build check-docs` | Regenerate `docs/project-reference.md` |

`./scripts/zigw build full-check` runs the full verification suite, including these gates.
