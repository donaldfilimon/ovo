# Zig 0.16 Migration Guide

## Overview

OVO targets Zig 0.16.0-dev.2984+cb7d2b056. This document outlines key API changes and pitfalls.

## Key API Changes

### Filesystem Access

**Old (pre-0.16):**
```zig
const file = try std.fs.cwd().openFile(path, .{});
```

**New (0.16):**
```zig
const file = try std.Io.Dir.cwd().openFile(runtime.io(), path, .{});
```

### Process Arguments

**Old:**
```zig
const args = try std.process.argsAlloc(allocator);
```

**New:**
```zig
var args_iter = std.process.Args.iterate(allocator);
```

### Environment Variables

**Old:**
```zig
const value = std.posix.getenv("VAR_NAME");
```

**New (idiomatic):**
```zig
// Use std.process.getEnvMap or explicit API
```

### IO Pattern

**Old:**
```zig
const stdout = std.io.getStdOut().writer();
try stdout.print("Hello\n", .{});
```

**New (0.16):**
```zig
// Use std.Io patterns with explicit IO handles
```

## Common Pitfalls

### 1. Legacy APIs

Avoid these deprecated patterns:
- `std.process.argsAlloc` → use `std.process.Args.iterate`
- `std.posix.getenv` → use explicit environment APIs
- `std.fs.cwd()` → use `std.Io.Dir.cwd()`

### 2. Multiline Strings

Keep multiline string formatting Zig-safe. Avoid tab pitfalls:

```zig
// BAD - tabs in multiline string
const text = \\
    \\line 1
    \\line 2
;

// GOOD - consistent indentation
const text =
    \\line 1
    \\line 2
;
```

### 3. Error Typing

For recursive parser flows where inference is unstable, prefer explicit error typing:

```zig
// Explicit error set
const ParserError = error{
    UnexpectedToken,
    MissingValue,
};

pub fn parse() ParserError!Result {
    // ...
}
```

### 4. Allocator-on-Method Patterns

Zig 0.16 uses allocator-on-method patterns:

```zig
// Old: allocator passed globally
const result = try someFunction(allocator, args);

// New: allocator on method
const result = try obj.someMethod(allocator, args);
```

## Checking Zig Version

```bash
# Check current version
zig version

# Verify consistency
zig build zig-version-consistency
```

The build system verifies that the active Zig version matches:
- `.zigversion` file
- `build.zig.zon` minimum_zig_version field

## Resources

- [Zig 0.16 Release Notes](https://ziglang.org/release-notes/0.16.0/)
- [Zig Standard Library Documentation](https://ziglang.org/documentation/master/std/)
