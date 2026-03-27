# Command Reference

## Basic Commands

| Command | Description | Usage |
|---------|-------------|-------|
| `version` | Show version information | `ovo version` |
| `new` | Create a new project | `ovo new <relative_path>` |
| `init` | Initialize OVO in current directory | `ovo init` |
| `build` | Build the project | `ovo build [--force] [-jN] [--jobs=N] [target]` |
| `run` | Build and run target | `ovo run [target] [-- args]` |
| `test` | Run tests | `ovo test [pattern]` |
| `clean` | Remove build artifacts | `ovo clean` |
| `install` | Install project artifacts | `ovo install` |

## Package Management

| Command | Description | Usage |
|---------|-------------|-------|
| `add` | Add a dependency | `ovo add <package> [version] [--git <url>\|--path <path>\|--registry <version>]` |
| `remove` | Remove a dependency | `ovo remove <package>` |
| `fetch` | Download dependencies | `ovo fetch [--refresh]` |
| `update` | Update dependencies | `ovo update [pkg]` |
| `lock` | Generate lock file | `ovo lock` |
| `deps` | Show dependency tree | `ovo deps` |

## Tooling

| Command | Description | Usage |
|---------|-------------|-------|
| `doc` | Generate documentation | `ovo doc` |
| `doctor` | Diagnose environment | `ovo doctor` |
| `fmt` | Format source code | `ovo fmt` |
| `lint` | Run linter | `ovo lint` |
| `info` | Show project information | `ovo info` |
| `tree` | Visualize the build graph | `ovo tree [--format=ascii\|dot\|json\|mermaid] [--target=name]` |

## Translation

| Command | Description | Usage |
|---------|-------------|-------|
| `import` | Import from another project format | `ovo import <format> [path]` |
| `export` | Export to another project format | `ovo export <format> [output_path]` |

## Selected Examples

### `new`

```bash
ovo new myapp
ovo new apps/myapp
```

### `build`

```bash
ovo build
ovo build -j8
ovo build --jobs=4 mylib
```

### `add`

```bash
ovo add zlib
ovo add fmt 10.2.1
ovo add fmt --git https://github.com/fmtlib/fmt.git
ovo add fmt --path ../vendor/fmt
ovo add fmt --registry latest
```

### `fetch`

```bash
ovo fetch
ovo fetch --refresh
```

### `tree`

```bash
ovo tree
ovo tree --format=dot
ovo tree --target=mylib
```

### `export`

```bash
ovo export cmake
ovo export compile_commands.json build/compile_commands.json
```

## Global Options

| Option | Description |
|--------|-------------|
| `--help, -h` | Show help |
| `--version, -V` | Show version |
| `--verbose` | Enable verbose output |
| `--quiet` | Minimize output |
| `--cwd <path>` | Override working directory |
| `--profile <name>` | Build profile override |
