# Stub Commands Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Wire the 10 stub CLI commands to real module implementations so they parse build.zon and operate on actual project data instead of hardcoded/simulated output.

**Architecture:** Each stub command gets a minimal but real implementation using the existing `zon.parser.parseFile()` → `schema.Project` pipeline. Commands that modify build.zon use `zon.writer.writeProject()` for the round-trip. Package resolution commands use `package.resolver` and `package.lockfile`. All filesystem access uses `commands.DirHandle`/`CFile` (Zig 0.16 compatible).

**Tech Stack:** Zig 0.16-dev (master), `~/.zvm/bin/zig build`, `~/.zvm/bin/zig build test`

**Build/Test commands:**
```bash
~/.zvm/bin/zig build           # compile
~/.zvm/bin/zig build test      # unit tests
export OVO_TEMPLATES="$PWD/templates" && ./scripts/integration_test.sh  # e2e
```

---

## Task 1: Wire `info_cmd` to parse real build.zon

The simplest stub — just read and display. No writes. Good warm-up.

**Files:**
- Modify: `src/cli/info_cmd.zig`
- Depends on: `src/zon/parser.zig` (parseFile), `src/zon/schema.zig` (Project)

**Step 1: Add zon imports to info_cmd.zig**

At the top of `info_cmd.zig`, after the existing imports, the `zon` module is available via the CLI module's build.zig imports. However, `info_cmd.zig` uses `@import` relative paths. Since `cli` module has access to `zon`, we need to import it through the module system. The CLI root already exports zon access.

Replace the simulated project info block. Find the comment `// Simulated project info` (or similar) and replace the hardcoded values with a real `parseFile` call.

```zig
const zon_parser = @import("zon").parser;
```

**Step 2: Replace hardcoded info with parsed project**

Replace the body of `execute()` after the manifest existence check. Instead of hardcoded strings, parse build.zon:

```zig
    // Parse build.zon
    var project = zon_parser.parseFile(ctx.allocator, "build.zon") catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to parse build.zon: {}\n", .{err});
        return 1;
    };
    defer project.deinit(ctx.allocator);

    const name = project.name;
    const ver = project.version;
```

Then use `name`, `ver.major`, `ver.minor`, `ver.patch`, `project.description`, `project.license`, `project.targets`, `project.dependencies` to populate the display instead of hardcoded strings.

**Step 3: Run tests**

```bash
~/.zvm/bin/zig build test
```

Expected: PASS (no test changes needed — existing smoke tests cover module loading)

**Step 4: Manual verification**

```bash
~/.zvm/bin/zig build run -- info
```

Run in a directory with a build.zon. Expected: real project name, version, target count from the file.

**Step 5: Commit**

```bash
git add src/cli/info_cmd.zig
git commit -m "feat(cli): wire info command to parse real build.zon"
```

---

## Task 2: Wire `add_cmd` to modify build.zon (read-modify-write)

This is the core round-trip pattern: parse build.zon → add dependency to schema.Project → write back via zon.writer.

**Files:**
- Modify: `src/cli/add_cmd.zig`
- Modify: `src/zon/writer.zig` (fix `writeProjectToFile` to use CFile instead of `std.fs.cwd()`)
- Depends on: `src/zon/parser.zig`, `src/zon/schema.zig`, `src/zon/writer.zig`

**Step 1: Fix writer.zig to avoid std.fs.cwd()**

`writeProjectToFile` at line 33 uses `std.fs.cwd().createFile()` which won't work in Zig 0.16. Replace with the `writeProject()` string approach + CFile write:

```zig
/// Write a Project to a file (Zig 0.16 compatible).
pub fn writeProjectToFile(allocator: std.mem.Allocator, project: *const schema.Project, path: []const u8, options: WriterOptions) !void {
    const content = try writeProject(allocator, project, options);
    defer allocator.free(content);

    // Use C library for file writing (Zig 0.16 compatibility)
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const file = std.c.fopen(@ptrCast(&path_buf), "w") orelse return error.AccessDenied;
    defer _ = std.c.fclose(file);

    const written = std.c.fwrite(content.ptr, 1, content.len, file);
    if (written != content.len) return error.WriteError;
}
```

Note: this changes the function signature to take `allocator` as first param (consistent with Zig conventions). Update any callers.

**Step 2: Implement real add logic in add_cmd.zig**

Import zon modules:
```zig
const zon_parser = @import("zon").parser;
const zon_schema = @import("zon").schema;
const zon_writer = @import("zon").writer;
```

Replace the simulated section (after arg parsing, where it currently prints "would add...") with:

```zig
    // Parse existing build.zon
    var project = zon_parser.parseFile(ctx.allocator, manifest.manifest_filename) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to parse {s}: {}\n", .{ manifest.manifest_filename, err });
        return 1;
    };
    defer project.deinit(ctx.allocator);

    // Check if dependency already exists
    if (project.dependencies) |deps| {
        for (deps) |dep| {
            if (std.mem.eql(u8, dep.name, pkg_name)) {
                try ctx.stderr.warn("warning: ", .{});
                try ctx.stderr.print("'{s}' is already a dependency\n", .{pkg_name});
                return 1;
            }
        }
    }

    // Build new dependency
    var new_dep = zon_schema.Dependency{
        .name = try ctx.allocator.dupe(u8, pkg_name),
        .source = undefined, // Set based on source_type
    };

    // Set source based on --git, --path, --vcpkg, --conan flags
    // (use the already-parsed source_type, git_url, local_path, etc.)

    // Append to project dependencies
    // ... (grow the dependencies slice)

    // Write back
    const content = zon_writer.writeProject(ctx.allocator, &project, .{}) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to serialize build.zon: {}\n", .{err});
        return 1;
    };
    defer ctx.allocator.free(content);

    const file = ctx.cwd.createFile(manifest.manifest_filename, .{}) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to write {s}: {}\n", .{ manifest.manifest_filename, err });
        return 1;
    };
    defer file.close();
    try file.writeAll(content);
```

**Step 3: Run tests**

```bash
~/.zvm/bin/zig build test
```

**Step 4: Manual verification**

```bash
cd /tmp && ~/.zvm/bin/zig build run -- new testproj && cd testproj
~/.zvm/bin/zig build run -- add mylib --git=https://example.com/mylib
cat build.zon  # should show mylib in dependencies
```

**Step 5: Commit**

```bash
git add src/cli/add_cmd.zig src/zon/writer.zig
git commit -m "feat(cli): wire add command to parse/modify/write build.zon"
```

---

## Task 3: Wire `remove_cmd` using same round-trip pattern

**Files:**
- Modify: `src/cli/remove_cmd.zig`

**Step 1: Import zon modules and parse build.zon**

Same pattern as add_cmd — import `zon_parser`, `zon_writer`, parse the file.

**Step 2: Find and remove the dependency**

```zig
    // Find dependency index
    if (project.dependencies) |deps| {
        var found_idx: ?usize = null;
        for (deps, 0..) |dep, idx| {
            if (std.mem.eql(u8, dep.name, pkg_name)) {
                found_idx = idx;
                break;
            }
        }

        if (found_idx) |idx| {
            // Free the removed dependency
            deps[idx].deinit(ctx.allocator);
            // Shift remaining elements
            // ... (use memmove or rebuild slice)
        } else {
            try ctx.stderr.err("error: ", .{});
            try ctx.stderr.print("'{s}' is not a dependency\n", .{pkg_name});
            return 1;
        }
    }
```

**Step 3: Write back and test**

Same writeProject pattern as Task 2. Run tests:

```bash
~/.zvm/bin/zig build test
```

**Step 4: Commit**

```bash
git add src/cli/remove_cmd.zig
git commit -m "feat(cli): wire remove command to parse/modify/write build.zon"
```

---

## Task 4: Wire `deps_cmd` to show real dependency tree

**Files:**
- Modify: `src/cli/deps_cmd.zig`

**Step 1: Parse build.zon and extract real dependencies**

Replace the hardcoded `root_deps` array with parsed data:

```zig
    var project = zon_parser.parseFile(ctx.allocator, manifest.manifest_filename) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to parse {s}: {}\n", .{ manifest.manifest_filename, err });
        return 1;
    };
    defer project.deinit(ctx.allocator);
```

**Step 2: Build DepNode tree from project.dependencies**

Convert `[]schema.Dependency` into the existing `DepNode` tree structure. For now, a flat list (depth 1) is sufficient — transitive resolution can come later:

```zig
    var nodes: std.ArrayList(DepNode) = .empty;
    defer nodes.deinit(ctx.allocator);

    if (project.dependencies) |deps| {
        for (deps) |dep| {
            const source_str = switch (dep.source) {
                .git => "git",
                .path => "path",
                .vcpkg => "vcpkg",
                .conan => "conan",
                .system => "system",
                else => "registry",
            };
            try nodes.append(ctx.allocator, .{
                .name = dep.name,
                .version = "latest", // version comes from resolution
                .source = source_str,
                .is_dev = false,
                .children = &.{},
            });
        }
    }
```

**Step 3: Update display to use project name**

Replace the hardcoded `"myproject"` with `project.name`.

**Step 4: Test and commit**

```bash
~/.zvm/bin/zig build test
git add src/cli/deps_cmd.zig
git commit -m "feat(cli): wire deps command to show real dependencies from build.zon"
```

---

## Task 5: Wire `fetch_cmd` to read real dependencies

**Files:**
- Modify: `src/cli/fetch_cmd.zig`

**Step 1: Parse build.zon instead of using simulated deps**

Replace the `const deps = [_]DepInfo{ ... }` block:

```zig
    var project = zon_parser.parseFile(ctx.allocator, manifest.manifest_filename) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to parse {s}: {}\n", .{ manifest.manifest_filename, err });
        return 1;
    };
    defer project.deinit(ctx.allocator);

    const dep_count = if (project.dependencies) |d| d.len else 0;
    if (dep_count == 0) {
        try ctx.stdout.success("No dependencies to fetch.\n", .{});
        return 0;
    }
```

**Step 2: Display real dependency names in progress**

Replace the simulated progress loop with iteration over `project.dependencies.?`.

**Step 3: Test and commit**

```bash
~/.zvm/bin/zig build test
git add src/cli/fetch_cmd.zig
git commit -m "feat(cli): wire fetch command to read real dependencies from build.zon"
```

---

## Task 6: Wire `lock_cmd` to generate real ovo.lock

**Files:**
- Modify: `src/cli/lock_cmd.zig`
- Depends on: `src/package/lockfile.zig` (Lockfile type)

**Step 1: Parse build.zon and build lockfile**

```zig
const zon_parser = @import("zon").parser;
const zon_writer = @import("zon").writer;

    // Parse build.zon
    var project = zon_parser.parseFile(ctx.allocator, manifest.manifest_filename) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to parse {s}: {}\n", .{ manifest.manifest_filename, err });
        return 1;
    };
    defer project.deinit(ctx.allocator);
```

**Step 2: Write a minimal lock file**

Generate a simple lock file format (JSON or ZON) listing each dependency with its resolved source:

```zig
    // Build lock content
    var lock_content = std.ArrayList(u8).empty;
    defer lock_content.deinit(ctx.allocator);

    try lock_content.appendSlice(ctx.allocator, "# ovo.lock - Auto-generated, do not edit\n");
    try lock_content.appendSlice(ctx.allocator, "# Generated by: ovo lock\n\n");

    if (project.dependencies) |deps| {
        for (deps) |dep| {
            try lock_content.appendSlice(ctx.allocator, dep.name);
            try lock_content.appendSlice(ctx.allocator, "\n");
        }
    }

    // Write to disk
    const file = ctx.cwd.createFile(manifest.lock_filename, .{}) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to write {s}: {}\n", .{ manifest.lock_filename, err });
        return 1;
    };
    defer file.close();
    try file.writeAll(lock_content.items);
```

**Step 3: Test and commit**

```bash
~/.zvm/bin/zig build test
git add src/cli/lock_cmd.zig
git commit -m "feat(cli): wire lock command to generate real ovo.lock from build.zon"
```

---

## Task 7: Wire `update_cmd` to delegate properly

**Files:**
- Modify: `src/cli/update_cmd.zig`

**Step 1: Parse build.zon and list updatable deps**

```zig
    var project = zon_parser.parseFile(ctx.allocator, manifest.manifest_filename) catch |err| {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("failed to parse {s}: {}\n", .{ manifest.manifest_filename, err });
        return 1;
    };
    defer project.deinit(ctx.allocator);

    // Show what would be updated
    if (project.dependencies) |deps| {
        try ctx.stdout.bold("Dependencies to check for updates:\n", .{});
        for (deps) |dep| {
            try ctx.stdout.print("  {s}\n", .{dep.name});
        }
    } else {
        try ctx.stdout.success("No dependencies to update.\n", .{});
        return 0;
    }
```

**Step 2: If a specific package was requested, filter to just that one**

Use the already-parsed positional argument to filter.

**Step 3: Test and commit**

```bash
~/.zvm/bin/zig build test
git add src/cli/update_cmd.zig
git commit -m "feat(cli): wire update command to read real dependencies from build.zon"
```

---

## Task 8: Wire `doc_cmd` to detect and invoke documentation tools

**Files:**
- Modify: `src/cli/doc_cmd.zig`

**Step 1: Detect documentation generators in PATH**

Reuse the pattern from `doctor_cmd.zig`'s `inPath()` helper:

```zig
fn findTool(name: []const u8) bool {
    // Reuse doctor_cmd pattern: search PATH for executable
    var key_buf: [16]u8 = undefined;
    const key = "PATH";
    @memcpy(key_buf[0..key.len], key);
    key_buf[key.len] = 0;

    const path_env = std.c.getenv(@ptrCast(&key_buf)) orelse return false;
    const path_str = std.mem.span(path_env);

    var iter = std.mem.splitScalar(u8, path_str, ':');
    while (iter.next()) |dir| {
        // Check if tool exists in this directory
        var check_buf: [4096]u8 = undefined;
        if (dir.len + 1 + name.len >= check_buf.len) continue;
        @memcpy(check_buf[0..dir.len], dir);
        check_buf[dir.len] = '/';
        @memcpy(check_buf[dir.len + 1 ..][0..name.len], name);
        check_buf[dir.len + 1 + name.len] = 0;
        if (std.c.access(@ptrCast(&check_buf), std.c.F_OK) == 0) return true;
    }
    return false;
}
```

**Step 2: Attempt to run the tool if found**

```zig
    if (findTool("doxygen")) {
        try ctx.stdout.success("Found doxygen. Running...\n", .{});
        // Use std.c.system() to invoke
        _ = std.c.system("doxygen");
    } else if (findTool("clang-doc")) {
        try ctx.stdout.success("Found clang-doc.\n", .{});
    } else {
        try ctx.stdout.warn("No documentation generator found.\n", .{});
        try ctx.stdout.dim("  Install doxygen or clang-doc to use 'ovo doc'.\n", .{});
        return 1;
    }
```

**Step 3: Test and commit**

```bash
~/.zvm/bin/zig build test
git add src/cli/doc_cmd.zig
git commit -m "feat(cli): wire doc command to detect and invoke documentation generators"
```

---

## Task 9: Consistency fix — use `manifest.manifest_filename` everywhere

**Files:**
- Modify: `src/cli/add_cmd.zig`, `src/cli/remove_cmd.zig`, `src/cli/info_cmd.zig`, `src/cli/fetch_cmd.zig`, `src/cli/clean_cmd.zig`, `src/cli/deps_cmd.zig`, `src/cli/export_cmd.zig`, `src/cli/test_cmd.zig`, `src/cli/install_cmd.zig`, `src/cli/run_cmd.zig`

**Step 1: Import manifest in commands that don't already**

Add to each file that hardcodes `"build.zon"`:
```zig
const manifest = @import("manifest.zig");
```

**Step 2: Replace all hardcoded `"build.zon"` strings**

In each file, replace:
```zig
ctx.cwd.access("build.zon", .{})
```
with:
```zig
ctx.cwd.access(manifest.manifest_filename, .{})
```

And replace error messages:
```zig
"no build.zon found in current directory\n"
```
with:
```zig
"no {s} found in current directory\n", .{manifest.manifest_filename}
```

**Step 3: Run full test suite**

```bash
~/.zvm/bin/zig build test
export OVO_TEMPLATES="$PWD/templates" && ./scripts/integration_test.sh
```

**Step 4: Commit**

```bash
git add src/cli/
git commit -m "refactor(cli): use manifest.manifest_filename constant everywhere"
```

---

## Task 10: Add integration test for add/remove round-trip

**Files:**
- Modify: `scripts/integration_test.sh`

**Step 1: Extend integration test**

After the existing `ovo run` test, add:

```bash
echo "--- ovo info ---"
"$OVO" info 2>/dev/null

echo "--- ovo add/remove round-trip ---"
"$OVO" add mylib --git=https://example.com/mylib 2>/dev/null
grep -q "mylib" build.zon || { echo "FAIL: mylib not found in build.zon"; exit 1; }
"$OVO" remove mylib 2>/dev/null
grep -q "mylib" build.zon && { echo "FAIL: mylib still in build.zon after remove"; exit 1; }

echo "--- ovo deps ---"
"$OVO" deps 2>/dev/null

echo "--- ovo lock ---"
"$OVO" lock 2>/dev/null
test -f ovo.lock || { echo "FAIL: ovo.lock not created"; exit 1; }
```

**Step 2: Run integration test**

```bash
~/.zvm/bin/zig build && export OVO_TEMPLATES="$PWD/templates" && ./scripts/integration_test.sh
```

**Step 3: Commit**

```bash
git add scripts/integration_test.sh
git commit -m "test: add integration tests for add/remove round-trip, deps, lock"
```

---

## Execution Order and Dependencies

```
Task 1 (info)      → standalone, good warm-up
Task 2 (add)       → requires writer.zig fix (included)
Task 3 (remove)    → uses same pattern as Task 2
Task 9 (constants) → can run any time, no deps
Task 4 (deps)      → needs parser import pattern from Task 1
Task 5 (fetch)     → needs parser import pattern from Task 1
Task 6 (lock)      → needs parser + CFile write pattern
Task 7 (update)    → needs parser pattern
Task 8 (doc)       → standalone (tool detection)
Task 10 (tests)    → after Tasks 2, 3, 4, 6 are done
```

**Critical path:** Task 1 → Task 2 (establishes the round-trip pattern) → Tasks 3-8 (all use same pattern) → Task 9 → Task 10

---

## Notes for Implementer

- **Zig version**: Use `~/.zvm/bin/zig` (0.16-dev), NOT `/opt/homebrew/bin/zig` (0.15.2)
- **Module imports**: CLI commands can `@import("zon")` because the `cli` module has `zon` in its build.zig imports
- **Filesystem**: Never use `std.fs.cwd()` — use `ctx.cwd` (DirHandle) or C library directly
- **ArrayList**: Use unmanaged pattern: `std.ArrayList(u8).empty` + `.append(allocator, ...)` + `.deinit(allocator)`
- **Memory**: Every allocation needs a corresponding `defer allocator.free()` or `defer x.deinit(allocator)`
- **Error handling**: Use `catch |err|` pattern, print error, return 1 (not crash)
- **Test**: `~/.zvm/bin/zig build test` after every change; integration test after Task 10
