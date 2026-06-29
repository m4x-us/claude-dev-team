# Slow-Coding Toyota System Philosophy

This document is the single source of truth for what "world-class" means when planning and auditing code. Every planning agent and every audit agent must read and apply these standards. Nothing ships without passing them.

---

## THE PRIME DIRECTIVE

> **Built to last 10 years, managed by a non-technical person who didn't write the code.**

Every decision flows from this. If a non-technical person can't understand it, fix it. If it won't survive 10 years, redesign it.

---

## THE TOYOTA PRINCIPLE

Quality is the ONLY priority. Speed of delivery does not matter at all. Every shortcut creates rework that costs 3x the time saved. A feature that ships with corners cut is WORSE than a feature that ships tomorrow.

- Never optimize for "getting it done"
- Tests BEFORE implementation — write failing tests first, make them pass
- Stop and fix immediately when a problem is found — never defer it
- If you find yourself writing code without tests, STOP and write the tests first

---

## THE 15 RULES

Every piece of code must comply with all 15 rules. These are not suggestions.

| # | Rule | What It Means |
|---|------|---------------|
| 1 | **Small Files** | 150–400 lines max. Routes: 150. Services: 400. Utils: 250. Types: 300. |
| 2 | **Human Headers** | Every file starts with a plain English explanation of what it does, who uses it, what it depends on, and what uses it. |
| 3 | **Layers Down Only** | Routes → Services → Utilities → Config. Never import upward. |
| 4 | **Feature Flags** | Every new feature can be turned off. No exceptions. |
| 5 | **Test Ruthlessly** | Every new behavior has a test. Tests must test real behavior, not implementation details. |
| 6 | **Extract Ready** | Every module can become its own SaaS product. No tight coupling. |
| 7 | **API Everything** | Every module exposes an API. Other modules call the API, never import internals directly. |
| 8 | **Log Everything** | Never swallow errors. Every error gets a unique timestamped ref ID with full diagnostic metadata. |
| 9 | **Learn from Mistakes** | Document non-obvious bugs and lessons. The "why" matters more than the "what." |
| 10 | **Design for Smarter AI** | Code must be clear enough for a better AI to improve it later. Comments explain WHY, not WHAT. |
| 11 | **Browser Truth** | If it doesn't work in a real browser, it doesn't work. |
| 12 | **Agent-Controllable** | Every module exposes typed tools for AI agents. LLM provider is swappable. |
| 13 | **Test the Seams** | When data crosses module boundaries, at least one test traces real data through the full chain without mocking intermediate layers. |
| 14 | **Component Truth** | Every user-facing React component has a co-located `.test.tsx` verifying renders, interactions, and error states. |
| 15 | **Pure Classification** | Any logic that maps data → UI state (badge color, icon, label) involving more than a single ternary MUST be a pure tested function in an `@ordinatio/*` package, not inline JSX. |
| 16 | **Enumerate Before You Assert** | Before writing any assertion about a set, map, collection, or output type: enumerate every member explicitly. Write the member count. Assert each member individually or document why it is skipped. Three assertions on an 8-field output type is a Rule 16 violation. |
| 17 | **Explicit Trust Boundaries** | Trust is declared at every boundary, never inferred from call context. **(a) Multi-context components:** Any dialog, Fragment, or class reused across caller contexts with different privilege levels must receive every security-sensitive behavior as an explicit factory/constructor parameter — not inferred from a shared mode or enum. Before adding any feature to a shared component, `grep` for every caller and verify the new behavior is correct in each. **(b) Untrusted input at entry points:** Any function reading from an Intent extra, URL path segment, deep-link parameter, or external API field must validate format against an explicit allowlist before any business logic executes — no Firestore reads, no whitelist lookups, no UI construction until format is verified. **(c) Validators claim what they enforce:** Any function declared `asserts x is T` or named `assertValid*`/`validate*` must enforce every required field of T at runtime — verify by reading the body, not just the signature. |

---

## THE 15 RULES COMPLIANCE CHECKLIST

Before any code is declared done, check every applicable rule:

```
[ ] Rule 1:  Files are within size limits (routes ≤150, services ≤400, utils ≤250, types ≤300)
[ ] Rule 2:  All new files have proper human-readable headers
[ ] Rule 3:  No upward imports — layers flow down only
[ ] Rule 4:  Feature flag exists and is enforced for any new feature
[ ] Rule 5:  Unit tests written and passing — no pseudocode tests
[ ] Rule 6:  No tight coupling — module could be extracted independently
[ ] Rule 7:  Exposed via API, not direct internal imports
[ ] Rule 8:  All errors have unique ref IDs with full diagnostic metadata
[ ] Rule 9:  Any non-obvious decisions or bugs documented
[ ] Rule 10: Comments explain WHY — code is clear enough for a smarter AI
[ ] Rule 13: Cross-boundary data flow has at least one seam test
[ ] Rule 14: New React components have co-located .test.tsx files
[ ] Rule 15: Data→UI mapping logic is a pure tested function, not inline JSX
```

---

## REQUIRED FILE HEADER

Every new TypeScript file MUST begin with this exact format:

```typescript
// ===========================================
// [PURPOSE IN CAPS]
// ===========================================
// [Plain English: what this does]
// [Who uses this]
// ===========================================
// DEPENDS ON: [key imports]
// USED BY: [what calls this]
// ===========================================
```

---

## LAYER CAKE ARCHITECTURE

```
Routes (≤150 lines)  →  Services (≤400 lines)  →  Utilities (≤250 lines)  →  Config (≤300 lines)
```

- Routes: request/response handling, auth checks, validation only
- Services: business logic, database operations, orchestration
- Utilities: pure functions, helpers, no side effects
- Config: constants, mappings, static data
- **Lower layers NEVER import from higher layers**

---

## ERROR REFERENCE SYSTEM (Rule 8 — Mandatory)

Every error in every module must have a unique timestamped reference ID.

**Format:** `{MODULE}_{CODE}-{TIMESTAMP}` → e.g., `EMAIL_613-20260319T145200`

**Every new module must have:**
1. `errors.ts` with a `moduleError(code, context?)` helper
2. A `{MODULE}_ERRORS` registry with every error code
3. Every registry entry must include: `file`, `function`, `httpStatus`, `severity`, `recoverable`, `description`, `diagnosis[]`
4. Every catch block logs with a ref ID and runtime context
5. Errors appear on all 3 surfaces: API response, server log, browser console

**Never use empty `catch {}` — always bind the error and log it with a ref.**

---

## THE FIVE FORCING FUNCTIONS

Ask these out loud after every feature or fix. Answer honestly.

1. Where did I choose easy over right?
2. If I showed this to the best engineer I know, what would they criticize?
3. Am I building for the person who USES this, or the person who READS the code?
4. Does the code actually DO what it CLAIMS to do?
5. If this code ran unchanged for 10 years, what would go wrong?

---

## ANTI-PATTERNS THAT ARE ALWAYS WRONG

These are never acceptable. If any are present, the code fails immediately.

- `catch {}` — always bind the error and log it with a ref ID
- `organization.findFirst()` in worker code — resolve org from the entity
- `dangerouslySetInnerHTML` — use React's default escaping
- `as any` in application code — fix the types
- Duplicated logic — extract to a shared function
- Skipping tests — every new behavior needs a test
- Feature without a feature flag — always gate new features
- Declaring done without running the shipping gate
- **Shared component feature added without auditing every caller** — if a new button, branch, or capability is added to a component used in more than one context, every call site must be reviewed for whether the new behavior is appropriate in that caller's privilege context before the change is committed (Rule 17a)
- **Untrusted external input used before format validation** — validate shape, length, and character set at the entry point; never pass raw Intent extras, URL segments, or API fields into Firestore queries, whitelist lookups, or UI constructors (Rule 17b)
- **Security CVE patched without encoding the floor in the version range** — after any security upgrade, pin the minimum version (e.g. `>=2.1.4` not `^2.0.0`); `npm audit` must run in CI without `--no-audit`; indirect dependency additions with module-interception capabilities require documented review (Rule 17c)

---

## RULE 13: TEST THE SEAMS

When data flows across module boundaries (web → worker, API → external service, UI → DB), at least one test must trace real data through the full chain without mocking intermediate layers.

**Why:** Unit tests verify individual functions. Bugs hide at handoffs. A field can pass every unit test and still arrive at the destination with the wrong value — because every test mocked the layer above it.

**The checklist:**
1. Can you trace a specific field from UI input to final destination?
2. Is there at least one integration test for the transformation chain (no mocks)?
3. Does intentionally breaking a field mapping cause a test to fail?

---

## RULE 14: COMPONENT TRUTH

Every user-facing React component must have a co-located `.test.tsx` file covering:

1. Renders without crashing
2. Shows correct data after loading
3. Handles user interactions correctly
4. Shows loading state while data loads
5. Shows correct error state when something fails

Tests are co-located — placed next to the component file, not in a separate test directory.

---

## THE SHIPPING GATE

Before declaring any work done:

1. Run `bash scripts/deep-audit.sh <changed-files>` — catches incident-class bugs, async contract violations, caller gaps
2. Run `bash scripts/shipping-gate.sh <changed-directory>` — catches missing tests, auth gaps, missing feature flags
3. If either script shows ✗ — fix it. Do not skip. Do not declare done.

**You cannot fake what a script prints.**

---

## CHANGELOG

Entries added below when a recurring audit or worldclass pattern graduates into this philosophy.

| Date | Section Updated | What Was Added | Trigger |
|------|----------------|----------------|---------|
| 2026-06-26 | THE 15 RULES | Rule 16: Enumerate Before You Assert — before writing any assertion about a set, map, or output type, enumerate every member explicitly and assert each one individually | Pattern P004 graduated after 5 occurrences across 4 domains (Android access control, Android integration tests, Android data tests, Web error registry) |
| 2026-06-28 | THE 15 RULES + ANTI-PATTERNS | Rule 17: Explicit Trust Boundaries — trust is declared at every boundary, never inferred; 3 checks: multi-context components get explicit privilege params, untrusted input is validated at entry points, runtime validators must enforce what they claim | Security pattern graduated after 8 occurrences across 6 audit cycles (avg severity 6.3, max severity 9 — child escaped bedtime enforcement via Forgot PIN?) |
