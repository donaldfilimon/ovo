# New Command Checklist

Before committing a new OVO CLI command, verify all items:

## File Structure
- [ ] File named `src/cli/<name>_cmd.zig`
- [ ] Module doc comment (`//!`) with command name, description, usage
- [ ] Imports: `std`, `commands`, `manifest`, `zon` (as needed)
- [ ] Type aliases: `Context`, `TermWriter` from `commands`
- [ ] `printHelp()` function with USAGE, OPTIONS, EXAMPLES sections
- [ ] `pub fn execute(ctx: *Context, args: []const []const u8) !u8`

## Implementation
- [ ] Help flag check first: `if (commands.hasHelpFlag(args)) { ... return 0; }`
- [ ] Uses `manifest.manifest_filename` constant (never `"build.zon"`)
- [ ] Manifest existence check uses `ctx.cwd.access()` pattern
- [ ] `zon_parser.parseFile()` has matching `defer project.deinit(ctx.allocator)`
- [ ] All `allocPrint` calls have matching `defer allocator.free()`
- [ ] Error output uses `ctx.stderr.err()` + `ctx.stderr.print()` pattern
- [ ] Returns 0 on success, 1 on error

## Wiring
- [ ] Added to `command_list` in `src/cli/commands.zig`
- [ ] Added `else if` dispatch branch in `dispatchCommand()`
- [ ] Module registered in `build.zig` CLI module imports

## Output
- [ ] Uses semantic TermWriter methods (bold, success, warn, err, info, dim)
- [ ] Help text follows existing format (USAGE, OPTIONS, EXAMPLES)
- [ ] Progress output for long operations uses ProgressBar

## Testing
- [ ] `zig build` compiles cleanly
- [ ] `zig build test` passes
- [ ] Integration test added to `scripts/integration_test.sh`
- [ ] Integration test passes
