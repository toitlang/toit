# Summary Template

Template for `.gsd/phases/{N}/{plan}-SUMMARY.md` — execution summary after plan completion.

---

## File Template

```markdown
---
phase: {N}
plan: {M}
completed_at: [ISO timestamp]
duration_minutes: {N}
status: complete | partial | failed
---

# Summary: {Plan Name}

## Results

- **Tasks:** {N}/{M} completed
- **Commits:** {N}
- **Verification:** {passed | failed}

---

## Tasks Completed

| Task | Description | Commit | Status |
|------|-------------|--------|--------|
| 1 | {task name} | {hash} | ✅ Complete |
| 2 | {task name} | {hash} | ✅ Complete |
| 3 | {task name} | — | ❌ Blocked |

---

## Files Changed

| File | Change Type | Description |
|------|-------------|-------------|
| {path} | Created | {what it does} |
| {path} | Modified | {what changed} |
| {path} | Deleted | {why removed} |

---

## Deviations Applied

{If none: "None — executed as planned."}

### Rule 1 — Bug Fixes
- {description of bug fixed}

### Rule 2 — Missing Critical
- {description of functionality added}

### Rule 3 — Blocking Issues
- {description of blocker fixed}

---

## Verification

| Check | Status | Evidence |
|-------|--------|----------|
| {verification 1} | ✅ Pass | {command/output} |
| {verification 2} | ✅ Pass | {command/output} |

---

## Notes

{Any observations, concerns, or recommendations for future phases}

---

## Metadata

- **Started:** {timestamp}
- **Completed:** {timestamp}
- **Duration:** {N} minutes
- **Context Usage:** ~{N}%
```

---

## Guidelines

**Create SUMMARY.md:**
- After each plan completes
- Before moving to next plan
- Even if plan failed (document what happened)

**Include:**
- All commits with hashes
- All deviations (never hide these)
- Verification results with evidence

**Keep it factual:**
- No opinions
- Just what happened
- Evidence over claims
