# Option Parsing Patterns

OVO CLI commands parse options manually from the args slice. No external argument parser is used.

## Simple Flag Pattern

```zig
var dry_run = false;
var verbose = false;

for (args) |arg| {
    if (std.mem.eql(u8, arg, "--dry-run")) {
        dry_run = true;
    } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
        verbose = true;
    }
}
```

## Flag with Value (Separate Arg)

```zig
var name: ?[]const u8 = null;
var i: usize = 0;
while (i < args.len) : (i += 1) {
    const arg = args[i];
    if (std.mem.eql(u8, arg, "--name") and i + 1 < args.len) {
        i += 1;
        name = args[i];
    }
}
```

## Flag with Value (Equals Syntax)

```zig
if (std.mem.startsWith(u8, arg, "--name=")) {
    name = arg["--name=".len..];
}
```

## Combined Pattern (Both Styles)

```zig
if (std.mem.eql(u8, arg, "--name") and i + 1 < args.len) {
    i += 1;
    name = args[i];
} else if (std.mem.startsWith(u8, arg, "--name=")) {
    name = arg["--name=".len..];
}
```

## Positional Arguments (Non-Flag)

```zig
var pkg_filter: ?[]const u8 = null;

for (args) |arg| {
    if (!std.mem.startsWith(u8, arg, "-")) {
        pkg_filter = arg;
    }
}
```

## Numeric Value Parsing

```zig
if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--jobs")) {
    if (i + 1 < args.len) {
        i += 1;
        jobs = std.fmt.parseInt(u32, args[i], 10) catch 4; // default on parse failure
    }
}
```

## Verbose Flag (Using Shared Helper)

```zig
const verbose = commands.hasVerboseFlag(args);
```

## Help Flag (Using Shared Helper)

```zig
if (commands.hasHelpFlag(args)) {
    try printHelp(ctx.stdout);
    return 0;
}
```
