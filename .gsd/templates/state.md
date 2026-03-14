# State Template

Template for `.gsd/STATE.md` — project memory across sessions.

---

## File Template

```markdown
---
updated: [ISO timestamp]
---

# Project State

## Current Position

**Milestone:** {name}
**Phase:** {N} - {name}
**Status:** {planning | executing | verifying | blocked}
**Plan:** {current plan if executing}

## Last Action

{What was just completed}

## Next Steps

1. {Immediate next action}
2. {Following action}
3. {Third action if known}

## Active Decisions

Decisions made that affect current work:

| Decision | Choice | Made | Affects |
|----------|--------|------|---------|
| {what} | {choice} | {date} | {phases/plans} |

## Blockers

{None if clear}

- [ ] {Blocker 1}: {resolution approach}
- [ ] {Blocker 2}: {resolution approach}

## Concerns

Things to watch but not blocking:

- {Concern 1}
- {Concern 2}

## Session Context

{Any context the next session needs to know}
```

---

## Update Rules

**Update STATE.md after:**
- Every completed task
- Every decision made
- Any blocker identified
- Session end/pause

**What to update:**
- `updated` timestamp
- Current Position
- Last Action
- Next Steps

**Keep it lean:**
- STATE.md is read frequently
- Only current context, not history
- History goes in JOURNAL.md

---

## Resume Protocol

When starting a new session:

1. Read STATE.md first
2. Understand current position
3. Check blockers/concerns
4. Continue from Next Steps

The STATE.md is the "save game" for the project.
