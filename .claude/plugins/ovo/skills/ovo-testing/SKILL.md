---
name: ovo-testing
description: >
  This skill should be used when the user asks to "write tests", "add a test", "run tests",
  "extend integration tests", "test a command", "verify the build", "add test coverage",
  "fix a failing test", "debug test failure", "CI", or mentions OVO testing workflows.
  Provides unit test patterns (Zig test blocks), integration test extension,
  and verification procedures.
version: 0.1.0
---

# OVO Testing Workflows

Write and run tests for the OVO package manager using Zig test blocks and shell-based integration tests.

## Test Infrastructure Overview

OVO has two testing layers:

| Layer | Location | Runner | Scope |
|-------|----------|--------|-------|
| Unit tests | Inline `test` blocks in `.zig` files | `zig build test` | Module-level logic |
| Integration tests | `scripts/integration_test.sh` | `bash` | End-to-end CLI workflows |

## Running Tests

```bash
# Unit tests (requires Zig 0.16-dev)
~/.zvm/bin/zig build test

# Integration tests (requires prior zig build)
~/.zvm/bin/zig build
export OVO_TEMPLATES="$PWD/templates"
./scripts/integration_test.sh

# Type check only (fast, no codegen)
~/.zvm/bin/zig build check
```

## Unit Tests (Zig Test Blocks)

### Writing Tests

Place `test` blocks at the bottom of the module they test:

```zig
test "command list is populated" {
    const cmds = getCommandList();
    try std.testing.expect(cmds.len > 0);
}

test "dispatch handles empty args" {
    // ... test setup ...
    const result = try dispatch(allocator, &.{});
    try std.testing.expectEqual(@as(u8, 1), result);
}
```

### Test Conventions

- **Test names**: Descriptive lowercase, like function behavior specs
- **Location**: Bottom of the file being tested, after all production code
- **Assertions**: Use `std.testing.expect*` family:
  - `std.testing.expect(condition)` — boolean assertion
  - `std.testing.expectEqual(expected, actual)` — equality
  - `std.testing.expectEqualStrings(expected, actual)` — string comparison
  - `std.testing.expectError(expected_error, result)` — error assertion
- **Allocator**: Use `std.testing.allocator` for leak detection
- **Cleanup**: Use `defer` for all test resources

### Test Allocator for Leak Detection

```zig
test "parseFile handles valid input" {
    const allocator = std.testing.allocator;
    var project = try zon_parser.parseFile(allocator, "test_fixtures/valid.zon");
    defer project.deinit(allocator);
    try std.testing.expectEqualStrings("test-project", project.name);
}
```

The test allocator automatically fails if memory is leaked.

### Testing Error Paths

```zig
test "parseFile returns error for missing file" {
    const allocator = std.testing.allocator;
    const result = zon_parser.parseFile(allocator, "nonexistent.zon");
    try std.testing.expectError(error.FileNotFound, result);
}
```

## Integration Tests

### Structure

`scripts/integration_test.sh` uses a temp directory workflow:

```bash
#!/bin/bash
set -euo pipefail

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
OVO="$PWD/zig-out/bin/ovo"

# Test: ovo new
$OVO new demo --dir "$TMPDIR/demo"
# Assert output
grep -q "Created new project" <<< "$output" || fail "..."

# Test: ovo build
cd "$TMPDIR/demo"
$OVO build
# Assert artifacts exist

# Cleanup happens via trap
```

### Adding a New Integration Test

Follow this pattern to add a test for a new command:

```bash
# Test: ovo <command>
echo "Testing: ovo <command>..."
output=$($OVO <command> <args> 2>&1) || {
    echo "FAIL: ovo <command> returned non-zero"
    exit 1
}
echo "$output" | grep -q "expected text" || {
    echo "FAIL: ovo <command> output missing expected text"
    echo "Got: $output"
    exit 1
}
echo "  PASS: ovo <command>"
```

### Currently Covered Commands

See `scripts/integration_test.sh` for the current coverage list. Commands are added as they are wired to real build.zon data.

### Environment Requirements

```bash
export OVO_TEMPLATES="$PWD/templates"  # Required for new/init
```

Template files in `templates/` provide build.zon scaffolds for `ovo new` and `ovo init`.

## Verification Workflow

Before committing any changes, run the full verification:

```bash
# 1. Compile
~/.zvm/bin/zig build

# 2. Unit tests
~/.zvm/bin/zig build test

# 3. Integration tests
export OVO_TEMPLATES="$PWD/templates"
./scripts/integration_test.sh
```

All three must pass. If unit tests pass but integration tests fail, the issue is likely in CLI
wiring or filesystem operations rather than logic.

## Testing Tips

- **Zig 0.16 caveat**: `std.fs.cwd()` calls in test code will fail — use absolute paths or test fixtures
- **No external deps**: OVO uses only Zig stdlib, so no mocking frameworks — write test helpers inline
- **Lazy evaluation**: Zig only compiles referenced code paths, so untested modules may hide compile errors — use `zig build check` to catch these

## Additional Resources

### Reference Files

- **`references/test-patterns.md`** — Common test patterns for OVO modules

### Scripts

- **`scripts/run-full-verification.sh`** — Combined verification script (build + test + integration)
