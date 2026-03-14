# UAT Template

Template for `.gsd/phases/{N}/UAT.md` — User Acceptance Testing checklist.

**Purpose:** Structured manual testing protocol for human verification checkpoints.

---

## File Template

```markdown
---
phase: {N}
type: uat
created: [ISO timestamp]
status: pending | in_progress | passed | failed
---

# Phase {N} UAT

## Overview

**Phase:** {name}
**Goal:** {what this phase delivers}
**Tester:** User
**Date:** {date}

---

## Test Environment

**Setup Required:**
- [ ] Dev server running (`npm run dev`)
- [ ] Database seeded with test data
- [ ] Browser dev tools open for error monitoring

**Test Data:**
- User: test@example.com / password123
- Other relevant test accounts/data

---

## Test Cases

### TC-01: {Test Case Name}

**Scenario:** {What user is trying to do}

**Steps:**
1. {Step 1}
2. {Step 2}
3. {Step 3}

**Expected Result:**
- {What should happen}

**Actual Result:**
- [ ] PASS
- [ ] FAIL — Issue: ___

---

### TC-02: {Test Case Name}

**Scenario:** {What user is trying to do}

**Steps:**
1. {Step 1}
2. {Step 2}

**Expected Result:**
- {What should happen}

**Actual Result:**
- [ ] PASS
- [ ] FAIL — Issue: ___

---

## Edge Cases

### EC-01: {Edge Case Name}

**Test:** {What to try}
**Expected:** {Graceful handling}
**Result:** [ ] PASS  [ ] FAIL

---

## Error Scenarios

### ERR-01: {Error Scenario}

**Trigger:** {How to cause error}
**Expected Behavior:** {Error message, recovery}
**Result:** [ ] PASS  [ ] FAIL

---

## Visual Verification

### VIS-01: Layout

- [ ] Responsive on mobile (375px)
- [ ] Responsive on tablet (768px)
- [ ] Desktop layout correct (1024px+)
- [ ] No horizontal scroll
- [ ] All text readable

### VIS-02: Styling

- [ ] Colors match design system
- [ ] Fonts correct
- [ ] Spacing consistent
- [ ] Icons display correctly

---

## Summary

| Category | Pass | Fail | Total |
|----------|------|------|-------|
| Functional | | | |
| Edge Cases | | | |
| Errors | | | |
| Visual | | | |

**Overall Status:** [ ] APPROVED  [ ] NEEDS FIXES

**Issues Found:**
1. {Issue description}
2. {Issue description}

**Notes:**
{Any additional observations}
```

---

## Usage Guidelines

**When to create UAT:**
- After phase execution complete
- Before marking phase as verified
- For any `checkpoint:human-verify` tasks

**Who runs UAT:**
- User (always)
- AI cannot verify visual/UX elements

**After UAT:**
- If PASSED: Phase can be marked complete
- If FAILED: Create gap closure plans with `/plan-milestone-gaps`

---

## Test Case Guidelines

**Good test cases:**
- Specific, reproducible steps
- Clear expected results
- One scenario per test case

**Categories to cover:**
1. Happy path (main functionality)
2. Edge cases (boundary conditions)
3. Error handling (invalid input, failures)
4. Visual/UX (layout, responsiveness)
