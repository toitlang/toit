# RESEARCH.md Template

> Copy this template when documenting phase research.

```markdown
---
phase: {N}
researched_at: {YYYY-MM-DD}
discovery_level: 1 | 2 | 3
---

# Phase {N} Research

## Objective
{What question is this research answering?}

## Discovery Level
**Level {1|2|3}** — {Quick verification | Standard research | Deep dive}

## Key Decisions

### Decision 1: {Topic}
**Question:** {What needed to be decided?}
**Options Considered:**
1. {Option A}: {pros/cons}
2. {Option B}: {pros/cons}
3. {Option C}: {pros/cons}

**Decision:** {Which option and why}
**Confidence:** {High | Medium | Low}

### Decision 2: {Topic}
...

## Findings

### {Topic 1}
{What was learned}

**Sources:**
- {URL or reference}
- {URL or reference}

### {Topic 2}
{What was learned}

## Patterns to Follow
- {Pattern 1}: {How to apply it}
- {Pattern 2}: {How to apply it}

## Anti-Patterns to Avoid
- {Anti-pattern 1}: {Why to avoid}
- {Anti-pattern 2}: {Why to avoid}

## Dependencies Identified
| Package | Version | Purpose |
|---------|---------|---------|
| {pkg} | {ver} | {why needed} |

## Risks
- **{Risk 1}:** {Impact and mitigation}
- **{Risk 2}:** {Impact and mitigation}

## Recommendations for Planning
1. {Recommendation 1}
2. {Recommendation 2}
```

## Discovery Levels

| Level | Time | Use When |
|-------|------|----------|
| 1 | 2-5 min | Single known library, confirming syntax |
| 2 | 15-30 min | Choosing between options, new integration |
| 3 | 1+ hour | Architectural decision, novel problem |
