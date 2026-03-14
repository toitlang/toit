# User Setup Template

Template for user setup instructions when external services are needed.

---

## File Template

```markdown
---
phase: {N}
plan: {M}
type: user-setup
---

# User Setup Required

## Overview

This plan requires manual setup that the AI cannot perform.

**Time estimate:** {X minutes}
**Blocking:** Plan cannot proceed until complete

---

## Setup Steps

### 1. {Service Name}

**Why needed:** {Purpose in the project}

**Create account:**
- Go to: {URL}
- Sign up with: {recommendations}

**Get credentials:**
1. Navigate to: {dashboard location}
2. Find: {API keys section}
3. Create: {what to create}

**Add to project:**
```powershell
# Add to .env.local
{ENV_VAR}=your_key_here
```

**Verify:**
```powershell
# Test the connection
{verification command}
```

---

### 2. {Another Service}

**Why needed:** {Purpose}

**Steps:**
1. {Step 1}
2. {Step 2}
3. {Step 3}

**Environment variables:**
```
{VAR_1}=value
{VAR_2}=value
```

---

## Dashboard Configuration

Some things require manual dashboard setup:

| Service | Task | Location | Notes |
|---------|------|----------|-------|
| {service} | {task} | {where} | {notes} |

---

## Verification Checklist

Before continuing, verify:

- [ ] All environment variables set
- [ ] All accounts created
- [ ] All dashboard configurations complete
- [ ] Verification commands pass

---

## When Complete

Type "done" or "setup complete" to continue with execution.
```

---

## Guidelines

**Include only what AI cannot do:**
- Account creation (requires human identity)
- Secret retrieval (protected behind login)
- Dashboard configuration (no API available)
- Payment method setup
- 2FA enrollment

**Do NOT include:**
- npm install (AI can do)
- File creation (AI can do)
- Configuration file edits (AI can do)
- API calls (AI can do)

**Keep minimal** — every manual step slows down execution.
