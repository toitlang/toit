# State Snapshot Template

Template for wave summaries and session state captures.

---

## When to Use

Create a state snapshot:
- After completing each wave
- Before pausing work
- After 3 debugging failures
- When switching models mid-session
- At any significant milestone

---

## Template

```markdown
---
wave: {N}
phase: {phase number}
created: {ISO timestamp}
status: {complete | partial | blocked}
---

# Wave {N} State Snapshot

## Objective

{What this wave aimed to accomplish — 1-2 sentences}

## Changes Realized

- {Change 1}
- {Change 2}
- {Change 3}

## Files Touched

| File | Change Type | Description |
|------|-------------|-------------|
| {path/to/file1} | created | {brief description} |
| {path/to/file2} | modified | {brief description} |
| {path/to/file3} | deleted | {brief description} |

## Verification Results

| Check | Command | Result |
|-------|---------|--------|
| {Test 1} | `{command}` | ✅ Passed |
| {Test 2} | `{command}` | ✅ Passed |
| {Test 3} | `{command}` | ❌ Failed: {reason} |

## Commits in This Wave

| Hash | Message |
|------|---------|
| {abc123} | {commit message 1} |
| {def456} | {commit message 2} |

## Risks & Technical Debt

{None if clear}

- ⚠️ {Risk or debt item 1}
- ⚠️ {Risk or debt item 2}

## TODO for Next Wave

1. {Next task 1}
2. {Next task 2}
3. {Next task 3}

## Context for Fresh Session

{Any information the next session needs — decisions made, blockers encountered, hypotheses to test}

## Token Usage (Optional)

| Metric | Value |
|--------|-------|
| Files loaded | {count} |
| Est. tokens | {number} |
| Budget used | {percentage}% |
| Compression | {yes/no} |

{Notes on token efficiency for this wave}
```

---

## Minimal Snapshot (Debug Session)

For quick state dumps during debugging:

```markdown
# Debug State Snapshot

**Time:** {timestamp}
**Problem:** {what you're debugging}

**Tried:**
1. {approach 1} → {result}
2. {approach 2} → {result}
3. {approach 3} → {result}

**Current Hypothesis:** {theory}

**Files Involved:**
- {file1}
- {file2}

**Recommended Next:** {suggested approach for fresh session}
```

---

## Integration with STATE.md

State snapshots are point-in-time captures. After creating a snapshot:

1. Update STATE.md with current position
2. Reference the snapshot in SESSION Context
3. Commit both together

STATE.md is current state; snapshots are historical records.

---

*Part of GSD methodology. See PROJECT_RULES.md for wave execution rules.*
