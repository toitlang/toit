# Debug Template

Template for `.gsd/debug/[slug].md` — active debug session tracking.

---

## File Template

```markdown
---
status: gathering | investigating | fixing | verifying | resolved
trigger: "[verbatim user input]"
created: [ISO timestamp]
updated: [ISO timestamp]
---

## Current Focus
<!-- OVERWRITE on each update - always reflects NOW -->

hypothesis: [current theory being tested]
test: [how testing it]
expecting: [what result means if true/false]
next_action: [immediate next step]

## Symptoms
<!-- Written during gathering, then immutable -->

expected: [what should happen]
actual: [what actually happens]
errors: [error messages if any]
reproduction: [how to trigger]
started: [when it broke / always broken]

## Eliminated
<!-- APPEND only - prevents re-investigating after context reset -->

- hypothesis: [theory that was wrong]
  evidence: [what disproved it]
  timestamp: [when eliminated]

## Evidence
<!-- APPEND only - facts discovered during investigation -->

- timestamp: [when found]
  checked: [what was examined]
  found: [what was observed]
  implication: [what this means]

## Resolution
<!-- OVERWRITE as understanding evolves -->

root_cause: [empty until found]
fix: [empty until applied]
verification: [empty until verified]
files_changed: []
```

---

## Section Rules

**Frontmatter (status, trigger, timestamps):**
- `status`: OVERWRITE - reflects current phase
- `trigger`: IMMUTABLE - verbatim user input, never changes
- `created`: IMMUTABLE - set once
- `updated`: OVERWRITE - update on every change

**Current Focus:**
- OVERWRITE entirely on each update
- Always reflects what AI is doing RIGHT NOW
- If AI reads this after session reset, it knows exactly where to resume
- Fields: hypothesis, test, expecting, next_action

**Symptoms:**
- Written during initial gathering phase
- IMMUTABLE after gathering complete
- Reference point for what we're trying to fix

**Eliminated:**
- APPEND only - never remove entries
- Prevents re-investigating dead ends after context reset
- Critical for efficiency across session boundaries

**Evidence:**
- APPEND only - never remove entries
- Facts discovered during investigation
- Builds the case for root cause

**Resolution:**
- OVERWRITE as understanding evolves
- Final state shows confirmed root cause and verified fix

---

## Lifecycle

**Creation:** When /debug is called
- Create file with trigger from user input
- Set status to "gathering"
- next_action = "gather symptoms"

**During investigation:**
- OVERWRITE Current Focus with each hypothesis
- APPEND to Evidence with each finding
- APPEND to Eliminated when hypothesis disproved

**On resolution:**
- status → "resolved"
- Move file to .gsd/debug/resolved/

---

## Resume Behavior

When AI reads this file after session reset:

1. Parse frontmatter → know status
2. Read Current Focus → know exactly what was happening
3. Read Eliminated → know what NOT to retry
4. Read Evidence → know what's been learned
5. Continue from next_action

The file IS the debugging brain.
