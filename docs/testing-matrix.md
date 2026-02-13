# Testing Matrix

## Build Modes

- `Debug`
- `ReleaseSafe`
- `ReleaseFast`
- `ReleaseSmall`

## Test Tiers

- `test`:
  - Unit model/parsing/module checks
- `test-cli-smoke`:
  - Registry + dispatch parity
  - Global flag parsing baseline
- `test-cli-deep`:
  - Unknown command and invalid global flag behavior
- `test-cli-stress`:
  - Parser repeatability loops
  - Repeated command dispatch loops
- `test-cli-integration`:
  - `--help` flow validation for every command
- `test-cli-all`:
  - Runs smoke + deep + stress + integration as one aggregate step
