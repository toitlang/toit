# Roadmap Template

Template for `.gsd/ROADMAP.md` — phase structure and progress tracking.

---

## File Template

```markdown
---
milestone: {name}
version: {semantic version}
updated: [ISO timestamp]
---

# Roadmap

> **Current Phase:** {N} - {name}
> **Status:** {planning | executing | verifying}

## Must-Haves (from SPEC)

- [ ] {Must-have 1}
- [ ] {Must-have 2}
- [ ] {Must-have 3}

---

## Phases

### Phase 1: {Foundation}
**Status:** ⬜ Not Started | 🔄 In Progress | ✅ Complete
**Objective:** {What this phase delivers}
**Requirements:** REQ-01, REQ-02

**Plans:**
- [ ] Plan 1.1: {name}
- [ ] Plan 1.2: {name}

---

### Phase 2: {Core Feature}
**Status:** ⬜ Not Started
**Objective:** {What this phase delivers}
**Depends on:** Phase 1

**Plans:**
- [ ] Plan 2.1: {name}
- [ ] Plan 2.2: {name}

---

### Phase 3: {Integration}
**Status:** ⬜ Not Started
**Objective:** {What this phase delivers}
**Depends on:** Phase 2

---

### Phase 4: {Polish/Launch}
**Status:** ⬜ Not Started
**Objective:** {Final touches and deployment}
**Depends on:** Phase 3

---

## Progress Summary

| Phase | Status | Plans | Complete |
|-------|--------|-------|----------|
| 1 | ⬜ | 0/2 | — |
| 2 | ⬜ | 0/2 | — |
| 3 | ⬜ | 0/1 | — |
| 4 | ⬜ | 0/1 | — |

---

## Timeline

| Phase | Started | Completed | Duration |
|-------|---------|-----------|----------|
| 1 | — | — | — |
| 2 | — | — | — |
| 3 | — | — | — |
| 4 | — | — | — |
```

---

## Status Icons

- ⬜ Not Started
- 🔄 In Progress
- ✅ Complete
- ⏸️ Paused
- ❌ Blocked

## Guidelines

- 3-5 phases per milestone
- Each phase has clear deliverable
- Dependencies flow forward
- Update status as work progresses
