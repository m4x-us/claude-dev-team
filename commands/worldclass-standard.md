# WorldClass Building Standard

This document defines what "world-class" means when writing code — not as a post-build checklist, but as the lens through which you build. Read it before writing a single line.

## How Principles Get Here

**Rubric-derived principles** (founding set): One principle per WorldClass deduction category. These are the WorldClass grading rubric stated from the builder's perspective. They don't change unless the rubric changes.

**Elevated principles** (added over time): When the same deduction category graduates independently 3+ times in `philosophy.md`, it is promoted here via `/patterns` Step 4D. This is how universal principles are *discovered from evidence*, not asserted.

Your project's own learnings live in `philosophy.md`. They appear in your build context as PROJECT_PRINCIPLES. Both documents together define what excellent code looks like for this codebase.

---

## The 8 Principles

### 1. Design failure modes before the happy path
*(Rubric category: error-handling)*

Before writing any function: name the 3 ways it can fail. Write those handlers first, then the happy path. If you cannot name 3 failure modes, you do not understand the problem well enough to implement it.

Bolted-on error handling — written after the happy path — catches the obvious case and misses contract violations, infrastructure failures, and concurrent edge cases. Designed-in error handling starts from the contract.

**Applies to:** HTTP routes, queue consumers, service functions, DB operations, external API calls.

---

### 2. Name the contract exactly
*(Rubric category: code-quality)*

Every function name is a promise. After writing it, ask: does this code keep that promise completely? `getUser()` that also increments `lastActiveAt` is lying. `saveOrder()` that silently returns `null` on failure is lying. `validateToken()` that returns `true` for expired tokens under certain conditions is lying.

Rename or split until every name is true.

---

### 3. Validate at every boundary
*(Rubric categories: auth · security)*

Identify every system boundary: HTTP routes, DB calls, external API calls, queue consumers, file I/O. Everything crossing a boundary inward is untrusted until explicitly validated.

Write validation at the entry point, before any logic. Validation buried inside service functions is skipped by callers who take alternate paths through the system.

**The test:** Can you point to one function that is the single entry point for each boundary, and confirm it validates all inputs before any business logic runs?

---

### 4. Tests prove behavior, not structure
*(Rubric category: tests)*

For every test: ask whether it would catch a silent regression where the function does something subtly wrong.

A test for `validateEmail()` that never passes an invalid email proves nothing about validation. A test that asserts "this function was called with these arguments" proves the plumbing is connected, not that the behavior is correct.

Every non-trivial function needs at least one test that can only pass if the function handles something going wrong correctly. Test the rejection case, the null case, the expired case, the concurrent case.

---

### 5. Close every async path
*(Rubric category: async)*

For every `await`: (1) What happens if it rejects? (2) What happens if it never resolves? (3) What happens if two run concurrently for the same resource?

Async code that only handles success is a delayed crash waiting for the right conditions. Every async operation needs an explicit failure path, even if that path is "log with a reference ID and rethrow."

Concurrent execution is the default in production, not a rare edge case.

---

### 6. Types must be honest
*(Rubric category: data-loss)*

Return types must reflect what the function actually returns. If a function can return `null`, the type must say so. If a function can throw, callers must handle it explicitly. No `as any` at a module boundary.

Optimistic typing — "this will always be a string here" — creates null dereference failures that pass all tests and break silently in production.

---

### 7. State names must be true at all times
*(Rubric category: edge-case)*

Every variable and field name must accurately describe the value it holds — not just when set, but when read by any consumer. `isLoading: false` during an in-flight fetch is a lie. `error: null` after swallowing an error is a lie.

When state names drift from state values, every function or component that reads that state makes decisions on false information.

---

### 8. Earn every abstraction
*(Rubric category: code-quality / vibes)*

Before extracting any helper, utility, or abstraction: ask whether a reader unfamiliar with this codebase would find the code clearer with or without it.

Extract when: the same logic appears in 3+ places, OR the abstraction hides genuinely complex logic. Do not extract when the logic only appears once.

**The deletion test:** If you removed this abstraction and inlined the logic, would the code be harder or easier to read? If easier, inline it. Premature abstraction is the second most common WorldClass Vibes deduction on a first pass.

---

## Provenance

| Principle | WorldClass deduction category | Why this maps |
|-----------|------------------------------|---------------|
| 1. Failure modes first | error-handling | Deductions for bolted-on / shallow catches |
| 2. Honest names | code-quality | Deductions for misleading function contracts |
| 3. Boundary validation | auth · security | Deductions for missing entry validation |
| 4. Behavior tests | tests | Deductions for structural-only test suites |
| 5. Closed async paths | async | Deductions for unhandled rejection and concurrency |
| 6. Honest types | data-loss | Deductions for optimistic typing causing null derefs |
| 7. True state | edge-case | Deductions for state that drifts from truth |
| 8. Earned abstractions | code-quality / vibes | Deductions for premature extraction |

Principles 9+ (if any) will have "Elevated from philosophy.md" in the Provenance column, with the graduation count that triggered elevation.

---

## CHANGELOG

Entries added when a principle is elevated from philosophy.md (Step 4D of /patterns).

| Date | Principle | Change | Evidence |
|------|-----------|--------|----------|
