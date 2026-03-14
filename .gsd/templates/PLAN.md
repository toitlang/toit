# PLAN.md Template

> Copy this template when creating execution plans.

```markdown
---
phase: {N}
plan: {M}
wave: {W}
gap_closure: false
---

# Plan {N}.{M}: {Descriptive Name}

## Objective
{One paragraph explaining what this plan delivers and why it matters}

## Context
Load these files for context:
- .gsd/SPEC.md
- .gsd/ARCHITECTURE.md
- {relevant source files}

## Tasks

<task type="auto">
  <name>{Clear, specific task name}</name>
  <files>
    {exact/file/path1.ext}
    {exact/file/path2.ext}
  </files>
  <action>
    {Specific implementation instructions}
    
    Steps:
    1. {Step 1}
    2. {Step 2}
    3. {Step 3}
    
    AVOID: {common mistake} because {reason}
    USE: {preferred approach} because {reason}
  </action>
  <verify>
    {Executable command or check}
    Example: npm test -- --testNamePattern="auth"
    Example: curl -X POST localhost:3000/api/login
  </verify>
  <done>
    {Measurable acceptance criteria}
    Example: Valid credentials → 200 + Set-Cookie, invalid → 401
  </done>
</task>

<task type="auto">
  <name>{Task 2 name}</name>
  <files>{files}</files>
  <action>{instructions}</action>
  <verify>{command}</verify>
  <done>{criteria}</done>
</task>

## Must-Haves
After all tasks complete, verify:
- [ ] {Must-have 1 — derived from phase goal}
- [ ] {Must-have 2}

## Success Criteria
- [ ] All tasks verified passing
- [ ] Must-haves confirmed
- [ ] No regressions in tests
```

## Task Types

| Type | Use For | Behavior |
|------|---------|----------|
| `auto` | Everything Claude can do independently | Fully autonomous |
| `checkpoint:human-verify` | Visual/functional verification | Pauses for user |
| `checkpoint:decision` | Implementation choices | Pauses for user |

## Wave Assignment

| Wave | Use For |
|------|---------|
| 1 | Foundation (types, schemas, utilities) |
| 2 | Core implementations |
| 3 | Integration and validation |

Plans in the same wave can run in parallel.
Later waves depend on earlier waves.
