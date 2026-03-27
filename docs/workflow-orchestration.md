# Workflow Orchestration

## Overview

OVO uses a structured workflow for non-trivial engineering tasks (3+ steps or architectural decisions).

## Lifecycle

1. **Initialize**: Create `tasks/todo.md` with objective and checklist
2. **Implement**: Execute work, tracking progress in todo.md
3. **Verify**: Run verification before marking complete
4. **Document**: Update lessons after user corrections

## Workflow Commands

```bash
# Initialize workflow
./scripts/workflow.sh init "<objective>"

# Check workflow status
./scripts/workflow.sh check

# Log lessons learned
./scripts/workflow.sh lesson --task "<task>" --correction "<correction>" --root-cause "<root cause>" --rule "<prevention rule>" --signal "<detection signal>"
```

## Task Management

### tasks/todo.md

Track work with checkable items:

```markdown
## Objective
<description of the task>

## Tasks
- [ ] Task 1
- [x] Task 2 (completed)
- [ ] Task 3

## Verification Evidence
<output from verification steps>
```

### tasks/lessons.md

Capture learnings after corrections:

```markdown
## <date> - <task>
- **Correction**: What was wrong
- **Root Cause**: Why it happened
- **Rule**: Prevention rule
- **Signal**: How to detect early
```

## Plan Mode

Enter plan mode for:
- 3+ step tasks
- Architectural decisions
- Verification steps
- Non-trivial changes

Plan mode workflow:
1. Write detailed specs upfront
2. Present plan for approval
3. Execute implementation
4. Verify results

## Self-Improvement Loop

After ANY correction from the user:
1. Update `tasks/lessons.md` with the pattern
2. Write rules that prevent the same mistake
3. Review lessons at session start for relevant project
4. Capture root causes, not just symptoms
