# GSD Quick Reference Card

## Workflow Lifecycle

```
┌─────────┐    ┌─────────┐    ┌──────────┐    ┌─────────┐
│  /map   │ →  │  /plan  │ →  │ /execute │ →  │ /verify │
│         │    │         │    │          │    │         │
│ Analyze │    │ Create  │    │   Run    │    │  Check  │
│codebase │    │ phases  │    │  tasks   │    │  work   │
└─────────┘    └─────────┘    └──────────┘    └─────────┘
                                   ↑              │
                                   └──────────────┘
                                   (if gaps found)
```

## All Commands

| Command | Args | Purpose |
|---------|------|---------|
| `/map` | - | Analyze codebase → ARCHITECTURE.md |
| `/plan` | `[phase]` | Create PLAN.md files for phase |
| `/execute` | `phase [--gaps-only]` | Run plans with wave execution |
| `/verify` | `phase` | Validate with empirical proof |
| `/debug` | `description` | Systematic debugging |
| `/progress` | - | Show current position |
| `/pause` | - | Save state, end session |
| `/resume` | - | Load state, start session |
| `/add-todo` | `item [--priority]` | Quick capture |
| `/check-todos` | `[--all]` | List pending items |

## Core Rules

| Rule | Enforcement |
|------|-------------|
| 🔒 Planning Lock | No code until SPEC finalized |
| 💾 State Persistence | Update STATE.md after tasks |
| 🧹 Context Hygiene | 3 failures → fresh session |
| ✅ Empirical Validation | Proof required for "done" |

## Key Files

| File | Purpose | Updated By |
|------|---------|------------|
| SPEC.md | Vision (finalize first!) | User |
| ROADMAP.md | Phase definitions | /plan |
| STATE.md | Session memory | All |
| ARCHITECTURE.md | System design | /map |
| TODO.md | Quick capture | /add-todo |

## XML Task Structure

```xml
<task type="auto">
  <name>Clear name</name>
  <files>exact/path.ts</files>
  <action>Specific instructions</action>
  <verify>Executable command</verify>
  <done>Measurable criteria</done>
</task>
```

## Priority Indicators

| Priority | Icon |
|----------|------|
| High | 🔴 |
| Medium | 🟡 |
| Low | 🟢 |

---

*Print this for quick reference!*
