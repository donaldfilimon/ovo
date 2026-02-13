# Command Reference

This document mirrors `src/cli/command_registry.zig`.

## Global Flags

- `--help`, `-h`
- `--version`, `-V`
- `--verbose`
- `--quiet`
- `--cwd <path>`
- `--profile <name>`
- `--cwd=<path>`
- `--profile=<name>`

## Basic Commands

- `new <name>`
- `init`
- `build [target]`
- `run [target] [-- args]`
- `test [pattern]`
- `clean`
- `install`

## Package Commands

- `add <package> [version]`
- `remove <package>`
- `fetch`
- `update [pkg]`
- `lock`
- `deps`

## Tooling Commands

- `doc`
- `doctor`
- `fmt`
- `lint`
- `info`

## Translation Commands

- `import <format> [path]`
  - `cmake` mode currently supports `project`, `set`, `add_executable`, `add_library`, `add_subdirectory`, `include` and variable expansion
  - `add_subdirectory` and include paths are parsed recursively with visit guards
- `export <format> [output_path]`
