# Discovery Template

Template for `.gsd/phases/{N}/DISCOVERY.md` — shallow research for library/option decisions.

**Purpose:** Answer "which library/option should we use" questions during planning.

For deep ecosystem research, use `/research-phase` which produces RESEARCH.md.

---

## File Template

```markdown
---
phase: {N}
type: discovery
topic: [discovery-topic]
---

<discovery_objective>
Discover [topic] to inform [phase name] implementation.

Purpose: [What decision/implementation this enables]
Scope: [Boundaries]
Output: DISCOVERY.md with recommendation
</discovery_objective>

<discovery_scope>
<include>
- [Question to answer]
- [Area to investigate]
- [Specific comparison if needed]
</include>

<exclude>
- [Out of scope for this discovery]
- [Defer to implementation phase]
</exclude>
</discovery_scope>

<discovery_protocol>

**Source Priority:**
1. **Official Docs** — Authoritative, current
2. **Web Search** — For comparisons, trends (verify findings)
3. **GitHub** — For real usage patterns

**Quality Checklist:**
- [ ] All claims have authoritative sources
- [ ] Negative claims verified with official docs
- [ ] Alternative approaches considered
- [ ] Recent updates checked for breaking changes

**Confidence Levels:**
- HIGH: Official docs confirm
- MEDIUM: Multiple sources confirm
- LOW: Single source or training knowledge only

</discovery_protocol>
```

---

## Output Structure

Create `.gsd/phases/{N}/DISCOVERY.md`:

```markdown
# [Topic] Discovery

## Summary
[2-3 paragraph executive summary]

## Primary Recommendation
[What to do and why — specific and actionable]

## Alternatives Considered
[What else was evaluated and why not chosen]

## Key Findings

### [Category 1]
- [Finding with source URL]

### [Category 2]
- [Finding with relevance]

## Code Examples
[Relevant patterns if applicable]

## Metadata

<confidence level="high|medium|low">
[Why this confidence level]
</confidence>

<sources>
- [Primary sources used]
</sources>

<open_questions>
[What needs validation during implementation]
</open_questions>
```

---

## When to Use

**Use discovery when:**
- Technology choice unclear (library A vs B)
- Best practices needed for unfamiliar integration
- API/library investigation required

**Don't use when:**
- Established patterns (CRUD, auth with known library)
- Questions answerable from project context

**Use RESEARCH.md instead when:**
- Niche/complex domains (3D, games, audio)
- Need ecosystem knowledge, not just library choice
- "How do experts build this" questions
