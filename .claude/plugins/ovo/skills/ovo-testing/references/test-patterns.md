# Test Patterns for OVO Modules

Common testing patterns used across the OVO codebase.

## Unit Test Template

```zig
const std = @import("std");
const testing = std.testing;

// ... production code above ...

test "descriptive behavior name" {
    const allocator = testing.allocator;
    // setup
    const result = functionUnderTest(allocator, input);
    // assertions
    try testing.expectEqual(expected, result);
}
```

## Testing Allocations (Leak Detection)

`std.testing.allocator` automatically detects memory leaks:

```zig
test "function does not leak memory" {
    const allocator = testing.allocator;
    const result = try allocateAndProcess(allocator, data);
    defer allocator.free(result);
    try testing.expect(result.len > 0);
}
// If the function leaks, test will FAIL with "memory leak detected"
```

## Testing Error Returns

```zig
test "function returns specific error" {
    const result = riskyFunction(bad_input);
    try testing.expectError(error.InvalidInput, result);
}

test "function succeeds with good input" {
    const result = try riskyFunction(good_input);
    try testing.expect(result != null);
}
```

## Testing String Output

```zig
test "format produces expected string" {
    const allocator = testing.allocator;
    const result = try std.fmt.allocPrint(allocator, "hello {s}", .{"world"});
    defer allocator.free(result);
    try testing.expectEqualStrings("hello world", result);
}
```

## Testing Slices

```zig
test "parser returns expected items" {
    const allocator = testing.allocator;
    const items = try parseItems(allocator, input);
    defer allocator.free(items);
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("first", items[0].name);
}
```

## Integration Test Assertion Patterns

### Check Command Succeeds

```bash
output=$($OVO command args 2>&1) || {
    echo "FAIL: command returned non-zero"
    exit 1
}
echo "  PASS: command succeeds"
```

### Check Output Contains Text

```bash
echo "$output" | grep -q "expected text" || {
    echo "FAIL: missing expected text"
    echo "Got: $output"
    exit 1
}
```

### Check File Was Created

```bash
[ -f expected/file/path ] || {
    echo "FAIL: expected file not created"
    exit 1
}
```

### Check File Contains Content

```bash
grep -q "expected content" expected/file/path || {
    echo "FAIL: file missing expected content"
    exit 1
}
```

### Round-Trip Test (Add then Remove)

```bash
# Add
$OVO add testpkg --url "https://example.com/pkg.tar.gz"
grep -q "testpkg" build.zon || fail "add didn't write"

# Remove
$OVO remove testpkg
grep -q "testpkg" build.zon && fail "remove didn't clean up"
echo "  PASS: add/remove round-trip"
```

## Testing ZON Parser

```zig
test "parser handles minimal build.zon" {
    const allocator = testing.allocator;
    const input =
        \\.{
        \\    .name = .@"test",
        \\    .version = "1.0.0",
        \\}
    ;
    var project = try parser.parse(allocator, input);
    defer project.deinit(allocator);
    try testing.expectEqualStrings("test", project.name);
    try testing.expectEqualStrings("1.0.0", project.version);
}
```

## Testing with Temporary Files

```zig
test "write and read back" {
    const allocator = testing.allocator;
    const tmp_path = "/tmp/ovo-test-temp.zon";
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    // Write
    try compat.writeFileData(tmp_path, content);

    // Read back
    const read = try compat.readFileAlloc(allocator, tmp_path);
    defer allocator.free(read);
    try testing.expectEqualStrings(content, read);
}
```

## Test Organization Rules

1. Place tests at the END of the file they test
2. Use `std.testing.allocator` for leak detection
3. Name tests descriptively: `"parser handles empty dependencies list"`
4. Each test should test ONE behavior
5. Clean up all resources with `defer`
6. Use `try testing.expect*` (not `assert`)
