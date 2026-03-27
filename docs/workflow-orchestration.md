# Workflow Orchestration

## Overview

OVO tracks non-trivial work directly in `tasks/todo.md` and `tasks/lessons.md`.

## Lifecycle

1. **Review lessons**: Check `tasks/lessons.md` before planning follow-up work.
2. **Plan**: Add objective, checklist, verification, and review sections to `tasks/todo.md`.
3. **Implement**: Make the smallest defensible change set and keep the checklist current.
4. **Verify**: Run the relevant `./scripts/zigw build ...` gates before marking the task complete.
5. **Document**: Update `tasks/lessons.md` after user corrections.

## Task Files

### `tasks/todo.md`

Track work with checkable items and verification evidence:

```markdown
## Objective
<description of the task>

## Tasks
- [ ] Task 1
- [x] Task 2 (completed)
- [ ] Task 3

## Verification
- `./scripts/zigw build typecheck` — pass
- `./scripts/zigw build unit-tests` — pass
```

### `tasks/lessons.md`

Capture learnings after corrections:

```markdown
- Correction pattern and root cause
- Prevention rule for future turns
```

## Suggested Verification Flow

Use the smallest gate that proves the change:

```bash
./scripts/zigw build cli-tests-smoke
./scripts/zigw build typecheck
./scripts/zigw build unit-tests
./scripts/zigw build full-check
```

## Self-Improvement Loop

After ANY correction from the user:
1. Update `tasks/lessons.md` with the pattern.
2. Write a rule that prevents the same mistake.
3. Re-check the current repo state before continuing.
