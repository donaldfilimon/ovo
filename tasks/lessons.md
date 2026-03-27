\# Lessons

- Verify the current repo state before planning follow-up fixes after a user correction; in OVO that includes checking whether `build.zig` and the macOS SDK workaround scripts already contain the claimed change.
- Treat task logs and prior summaries as stale after a user correction; in OVO, confirm build-step availability with `./scripts/zigw build -l` and rerun the affected commands before repeating old verification notes.
- When emitting ZON enum literals or scaffold fixtures, validate them against actual Zig/ZON syntax instead of assuming a human-friendly label is legal; `.test` broke because `test` is a Zig keyword and the canonical literal must be `.test_target`.
