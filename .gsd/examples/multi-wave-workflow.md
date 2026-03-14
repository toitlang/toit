# Multi-Wave Workflow Example

This example demonstrates a complete GSD workflow with:
- Short spec
- Plan breakdown
- 2-wave execution
- Verification with commands
- State snapshots

---

## Example: Add User Authentication

### 1. SPEC.md (Finalized)

```markdown
---
status: FINALIZED
updated: 2026-02-07
---

# User Authentication Feature

## Overview
Add login/logout functionality with JWT tokens.

## Requirements
1. POST /api/auth/login endpoint
2. POST /api/auth/logout endpoint
3. JWT stored in httpOnly cookie
4. Protected route middleware

## Success Criteria
- User can login with email/password
- Invalid credentials return 401
- Protected routes require valid JWT
- Logout clears the cookie
```

---

### 2. ROADMAP.md (Phase Entry)

```markdown
## Phase 1: User Authentication

- [ ] Plan 1.1: Auth endpoints (Wave 1)
- [ ] Plan 1.2: Protected middleware (Wave 2)
```

---

### 3. PLAN 1.1 (Wave 1)

```xml
---
phase: 1
plan: 1
type: implementation
wave: 1
---

<objective>
Create login and logout endpoints with JWT handling.
</objective>

<context>
Files to read: src/app/api/ structure, existing auth if any
</context>

<tasks>
<task type="auto" effort="medium">
  <name>Create login endpoint</name>
  <files>src/app/api/auth/login/route.ts</files>
  <action>
    Create POST handler accepting {email, password}.
    Query users table, compare password with bcrypt.
    On success: generate JWT, set httpOnly cookie, return 200.
    On failure: return 401 with generic error.
  </action>
  <verify>curl -X POST localhost:3000/api/auth/login -d '{"email":"test@example.com","password":"test123"}'</verify>
  <done>Valid credentials return 200 + Set-Cookie header</done>
</task>

<task type="auto" effort="low">
  <name>Create logout endpoint</name>
  <files>src/app/api/auth/logout/route.ts</files>
  <action>
    Create POST handler that clears the auth cookie.
    Return 200 on success.
  </action>
  <verify>curl -X POST localhost:3000/api/auth/logout --cookie "token=..."</verify>
  <done>Cookie is cleared, response is 200</done>
</task>
</tasks>
```

---

### 4. Wave 1 Execution

**Task 1 Commit:**
```
git commit -m "feat(phase-1): create login endpoint"
```

**Task 2 Commit:**
```
git commit -m "feat(phase-1): create logout endpoint"
```

---

### 5. Wave 1 State Snapshot

```markdown
---
wave: 1
phase: 1
created: 2026-02-07T10:30:00
status: complete
---

# Wave 1 State Snapshot

## Objective
Create authentication endpoints.

## Changes Realized
- Created login endpoint with JWT generation
- Created logout endpoint with cookie clearing
- Added bcrypt password comparison

## Files Touched
| File | Change Type | Description |
|------|-------------|-------------|
| src/app/api/auth/login/route.ts | created | Login handler |
| src/app/api/auth/logout/route.ts | created | Logout handler |

## Verification Results
| Check | Command | Result |
|-------|---------|--------|
| Login works | `curl -X POST .../login` | ✅ 200 + cookie |
| Logout works | `curl -X POST .../logout` | ✅ 200 + cleared |

## Commits in This Wave
| Hash | Message |
|------|---------|
| abc123 | feat(phase-1): create login endpoint |
| def456 | feat(phase-1): create logout endpoint |

## TODO for Next Wave
1. Create auth middleware
2. Apply to protected routes
```

---

### 6. PLAN 1.2 (Wave 2)

```xml
---
phase: 1
plan: 2
type: implementation
wave: 2
depends_on: [1]
---

<objective>
Create middleware to protect routes requiring authentication.
</objective>

<context>
Wave 1 complete: login/logout endpoints exist.
JWT is stored in httpOnly cookie named "token".
</context>

<tasks>
<task type="auto" effort="high">
  <name>Create auth middleware</name>
  <files>src/middleware/auth.ts</files>
  <action>
    Create middleware that:
    1. Reads JWT from cookie
    2. Verifies signature with jose
    3. Attaches user to request
    4. Returns 401 if invalid/missing
  </action>
  <verify>Import and call middleware with mock request</verify>
  <done>Valid JWT passes, invalid/missing returns 401</done>
</task>

<task type="auto" effort="medium">
  <name>Apply middleware to protected route</name>
  <files>src/app/api/user/profile/route.ts</files>
  <action>
    Create example protected route.
    Apply auth middleware.
    Return user data if authenticated.
  </action>
  <verify>curl localhost:3000/api/user/profile with and without cookie</verify>
  <done>With cookie: 200 + data. Without: 401</done>
</task>
</tasks>
```

---

### 7. Wave 2 Execution & Snapshot

**Commits:**
```
git commit -m "feat(phase-1): create auth middleware"
git commit -m "feat(phase-1): apply middleware to profile route"
```

**State Snapshot:** (similar format to Wave 1)

---

### 8. Verification

```bash
# Full verification sequence
curl -X POST localhost:3000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"user@example.com","password":"secret"}' \
  -c cookies.txt

# Expected: 200 + Set-Cookie: token=...

curl localhost:3000/api/user/profile -b cookies.txt
# Expected: 200 + user data

curl localhost:3000/api/user/profile
# Expected: 401

curl -X POST localhost:3000/api/auth/logout -b cookies.txt
# Expected: 200 + cookie cleared
```

---

## Key Takeaways

1. **Waves group dependent work** — Wave 2 waited for Wave 1
2. **State snapshots preserve context** — Each wave ends with documented state
3. **Atomic commits per task** — Easy to trace and revert
4. **Verification built into plan** — No "trust me, it works"
5. **Effort hints model selection** — `high` effort = use reasoning model

---

*See PROJECT_RULES.md for wave execution rules.*
*See templates/state_snapshot.md for snapshot format.*
