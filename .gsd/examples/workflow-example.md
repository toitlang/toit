# GSD Workflow Example

> A complete walkthrough of using GSD from start to finish.

## Scenario: Building a Simple Todo API

### Step 1: Define the Spec

First, fill out `.gsd/SPEC.md`:

```markdown
# SPEC.md

> **Status**: `FINALIZED`

## Vision
A simple RESTful API for managing todo items.

## Goals
1. CRUD operations for todos
2. Persistence to SQLite
3. Input validation

## Success Criteria
- [ ] POST /todos creates a todo
- [ ] GET /todos returns list
- [ ] DELETE /todos/:id removes item
```

---

### Step 2: Map the Codebase (if existing)

```
/map
```

This creates:
- `.gsd/ARCHITECTURE.md` — Current structure
- `.gsd/STACK.md` — Technologies in use

---

### Step 3: Plan the Phases

```
/plan 1
```

GSD analyzes the SPEC and creates `.gsd/phases/1/` with PLAN.md files:

```markdown
# Plan 1.1: Database Setup

## Objective
Create SQLite database with todos table.

## Tasks

<task type="auto">
  <name>Initialize SQLite database</name>
  <files>src/db.ts</files>
  <action>
    Create SQLite connection using better-sqlite3.
    Create todos table with: id, title, completed, created_at.
  </action>
  <verify>node -e "require('./src/db')" exits without error</verify>
  <done>Database file exists, table created</done>
</task>
```

---

### Step 4: Execute the Phase

```
/execute 1
```

GSD:
1. Loads Plan 1.1
2. Executes tasks in order
3. Runs verify commands
4. Creates atomic commits
5. Creates SUMMARY.md
6. Proceeds to Plan 1.2
7. Verifies phase goal

---

### Step 5: Verify the Work

```
/verify 1
```

GSD:
1. Extracts must-haves from phase
2. Runs verification commands
3. Captures evidence
4. Creates VERIFICATION.md
5. Reports pass/fail

---

### Step 6: Continue or Debug

**If verified:**
```
/plan 2      → Plan next phase
/execute 2   → Execute next phase
```

**If issues found:**
```
/execute 1 --gaps-only   → Run fix plans
/debug "API returns 500" → Debug the issue
```

---

## Quick Commands Reference

| Command | When to Use |
|---------|-------------|
| `/map` | Analyze existing codebase |
| `/plan [N]` | Create plans for phase N |
| `/execute [N]` | Run all plans in phase N |
| `/verify [N]` | Confirm phase N works |
| `/debug [issue]` | Fix a problem |
| `/progress` | See current status |
| `/pause` | End session, save state |
| `/resume` | Start new session |
| `/add-todo` | Capture quick idea |
| `/check-todos` | See pending items |

---

*This example demonstrates the GSD methodology flow.*
