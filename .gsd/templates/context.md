# Context Template

Template for `.gsd/phases/{N}/CONTEXT.md` — user's vision for a phase.

---

## File Template

```markdown
---
phase: {N}
name: {phase-name}
created: [ISO timestamp]
---

# Phase {N} Context

## Vision

{How the user imagines this phase working — in their words}

## What's Essential

Non-negotiable aspects:

- {Essential 1}
- {Essential 2}
- {Essential 3}

## What's Flexible

Open to different implementations:

- {Flexible 1}
- {Flexible 2}

## What's Out of Scope

Explicitly NOT part of this phase:

- {Out of scope 1}
- {Out of scope 2}

## User Expectations

### Look and Feel
{How it should appear/behave}

### Performance
{Speed/responsiveness expectations}

### Integration
{How it fits with existing work}

## Examples / Inspiration

{Any examples the user referenced}

## Questions Answered

Clarifications from /discuss-phase:

| Question | Answer |
|----------|--------|
| {question} | {answer} |

## Constraints

Technical or business constraints:

- {Constraint 1}
- {Constraint 2}
```

---

## When to Create

Created by `/discuss-phase` to capture user's vision before planning.

## How to Use

- Planner reads CONTEXT.md to understand intent
- Executor honors the vision during implementation
- Verifier checks against user expectations

## Guidelines

- Capture user's words, not AI interpretation
- Focus on WHAT, not HOW
- Keep it short — vision, not specification
