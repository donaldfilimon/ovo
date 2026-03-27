# Testing Matrix

## Test Structure

OVO organizes tests into multiple tiers based on scope and confidence level.

### Unit Tests

Located in `tests/unit/`:

| File | Description |
|------|-------------|
| `test_all.zig` | Main unit test suite |
| `test_zig_version_consistency.zig` | Zig version verification |

**Running:**
```bash
zig build unit-tests
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
zig build cli-tests-smoke
zig build cli-tests-deep
zig build cli-tests-stress
zig build cli-tests-integration
zig build cli-tests-variations

# All CLI tests
zig build cli-tests
```

## Test Naming Convention

Tests use descriptive sentence-case names describing behavior:

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
zig test tests/unit/test_all.zig
```

### By Name Pattern

```bash
zig build unit-tests -- --test-name-pattern "test_name"
```

### All Tests

```bash
zig build full-check
```

## Test Dependencies

CLI tests that require external tools are gated by environment checks:

| Test Tier | Requirements |
|-----------|-------------|
| Smoke | zig |
| Deep | zig, basic tools |
| Integration | zig, build tools |
| Variations | zig, clang-format, clang-tidy, clang++, g++, cmake, ninja, doxygen, clang-doc |
