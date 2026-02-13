# Verification Guide

## Baseline

- Use Zig `0.16.0-dev.2535+b5bd49460` (from `.zigversion`)
- Run commands with the project-managed toolchain when possible

## Fast Path

```bash
zig build test-cli-smoke
```

## Full Tiers

```bash
zig build test
zig build test-cli-smoke
zig build test-cli-deep
zig build test-cli-stress
zig build test-cli-integration
zig build test-cli-all
```

## Notes

- Smoke focuses on API hygiene and command wiring.
- Deep adds option contract and failure-path checks.
- Stress covers repeatability and repeated execution behavior.
- Integration exercises command flows via CLI parser + dispatcher.
