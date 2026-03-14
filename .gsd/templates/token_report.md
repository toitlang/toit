# Token Report Template

Template for documenting token usage per wave or session.

---

## Template

```markdown
---
wave: {N}
phase: {phase number}
created: {ISO timestamp}
---

# Token Usage Report

## Summary

| Metric | Value |
|--------|-------|
| Files loaded | {count} |
| Estimated tokens | {number} |
| Budget usage | {percentage}% |
| Compression applied | {yes/no} |

## Files Loaded

| File | Lines | Est. Tokens | Reason |
|------|-------|-------------|--------|
| {path/to/file1} | {N} | {N} | {why loaded} |
| {path/to/file2} | {N} | {N} | {why loaded} |

## Compression Applied

| File | Before | After | Savings |
|------|--------|-------|---------|
| {file} | {N} | summary | {N} tokens |

## Efficiency Analysis

### What Worked Well
- {Strategy that saved tokens}

### Could Improve
- {Opportunity for optimization}

### Recommendations
- {Suggestion for next wave}
```

---

## When to Create

Create a token report:
- After completing a wave with high token usage
- When budget exceeds 50%
- For debugging session performance
- During milestone retrospectives

---

## Quick Report (Minimal)

For simple tracking:

```markdown
## Token Report: Wave {N}

- Files: {count}
- Tokens: ~{number}
- Budget: {X}%
- Status: [OK|WARNING|CRITICAL]
```

---

*Part of GSD v1.6 Token Optimization.*
