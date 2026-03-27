# Command Reference

## Basic Commands

| Command | Description | Usage |
|---------|-------------|-------|
| `new` | Create a new project | `ovo new <relative_path>` |
| `init` | Initialize project in current directory | `ovo init` |
| `build` | Build the project | `ovo build [target]` |
| `run` | Run the project | `ovo run [target] [-- args]` |
| `test` | Run tests | `ovo test [pattern]` |
| `clean` | Clean build artifacts | `ovo clean` |
| `install` | Install the project | `ovo install` |

## Package Management

| Command | Description | Usage |
|---------|-------------|-------|
| `add` | Add a dependency | `ovo add <package> [version]` |
| `remove` | Remove a dependency | `ovo remove <package>` |
| `fetch` | Fetch dependencies | `ovo fetch [--refresh]` |
| `update` | Update dependencies | `ovo update [pkg]` |
| `lock` | Lock dependency versions | `ovo lock` |
| `deps` | List dependencies | `ovo deps` |

### Add Command Variants

```bash
# From registry
ovo add <package> --registry <version>

# From git repository
ovo add <package> --git <url>

# From local path
ovo add <package> --path <path>
```

## Tooling

| Command | Description | Usage |
|---------|-------------|-------|
| `doc` | Generate documentation | `ovo doc` |
| `doctor` | Diagnose toolchain | `ovo doctor` |
| `fmt` | Format source code | `ovo fmt` |
| `lint` | Lint source code | `ovo lint` |
| `info` | Show project info | `ovo info` |
| `tree` | Show dependency tree | `ovo tree [--format=ascii|dot|json|mermaid] [--target=name]` |

## Translation

| Command | Description | Usage |
|---------|-------------|-------|
| `import` | Import from other build systems | `ovo import <format> [path]` |
| `export` | Export to other build systems | `ovo export <format> [output_path]` |

### Supported Import Formats

- `cmake`: Imports from CMakeLists.txt (project, set, add_executable, add_library, add_subdirectory, include)

### Supported Export Formats

- `cmake`: Generates CMakeLists.txt
- `compile_commands.json`: Generates compilation database

## Global Options

| Option | Description |
|--------|-------------|
| `--help`, `-h` | Show help |
| `--version`, `-V` | Show version |
| `--verbose` | Enable verbose output |
| `--quiet` | Suppress output |
| `--cwd <path>` | Set working directory |
| `--profile <name>` | Set build profile |
