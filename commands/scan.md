# scan — Scoped Module Examination

Runs a focused examination of a single System 1701 module. Like `/meet` but scoped to one module's paths. Writes output to `.autocode/modules/[module]/tasks.md`.

Call with `/scan [module]` from `/1701` or `/scope`, or just `/scan` if already scoped.

---

## MODULE REGISTRY

```
email       apps/web/src/app/dashboard/inbox
            apps/web/src/components/email
            apps/web/src/lib/email
            apps/web/src/app/api/email
            packages/ordinatio-email

scheduling  apps/web/src/app/dashboard/scheduling
            apps/web/src/components/scheduling
            apps/web/src/app/api/scheduling
            packages/ordinatio-scheduling
            packages/ordinatio-booking-widget

clients     apps/web/src/app/dashboard/clients
            apps/web/src/app/api/clients

orders      apps/web/src/app/dashboard/orders
            apps/web/src/app/api/orders
            apps/worker/src/consumers

sms         apps/web/src/app/dashboard/texts
            apps/web/src/app/api/sms

cms         apps/web/src/app/dashboard/website
            packages/ordinatio-cms

agents      apps/web/src/app/api/agent
            packages/ordinatio-agent

auth        packages/ordinatio-auth
            packages/ordinatio-security

settings    apps/web/src/app/dashboard/settings
            packages/ordinatio-settings

worker      apps/worker/src

ui          packages/ordinatio-ui
            packages/ordinatio-errors
            packages/ordinatio-activities
```

---

## STEP 1 — Identify module

If `[module]` was passed, use it. If this window is already scoped (from `/scope`), use the active module. If neither, ask which module to scan.

---

## STEP 2 — Gather module state

Run the following. Capture all output.

**A. Recent commits (last 20):**
```bash
git log --oneline -20 -- [module paths]
```

**B. File inventory:**
```bash
find [each module path] -type f \( -name "*.ts" -o -name "*.tsx" \) | grep -v node_modules | grep -v .next | sort
```

**C. Test file inventory:**
```bash
find [each module path] -type f \( -name "*.test.ts" -o -name "*.test.tsx" \) | grep -v node_modules | sort
```

**D. Existing module memory** — read if they exist:
  - `.autocode/modules/[module]/state.md` — free-form state of the nation: history, known decisions, current status. Read this first.
  - `.autocode/modules/[module]/profile.md`
  - `.autocode/modules/[module]/security.md`
  - `.autocode/modules/[module]/architect.md`
  - `.autocode/modules/[module]/qa.md`
  - `.autocode/modules/[module]/tasks.md` (existing tasks — carry forward incomplete ones)

**E. Recent patterns** — read `.autocode/patterns.md`. Find any entries that touch this module's paths. Note the findings and severities.

---

## STEP 3 — Examine the module

Spawn 4 parallel examination agents using `subagent_type: "Explore"`. Each agent is read-only and scoped to one dimension. Pass each agent a fully self-contained prompt that includes: the module name, the exact file paths, the SCAN finding format, and the specific examination task. Do NOT rely on inherited context.

**Each agent prompt MUST begin with:**
```
You are doing a focused read-only scan. Do NOT spawn sub-agents or forks. Read files directly and produce your findings only.
Module: [module]
Paths to examine: [exact paths]
```

**REQUIRED OUTPUT FORMAT — applies to ALL 4 agents (TOYOTA_EVIDENCE_RULE):**

Every finding must use this exact format:
```
[SCAN-{id}|sev:{N}|{category}|{file}:{function}:{line}|{description}]
Evidence: {file} line {N}: "{quoted or paraphrased line that directly supports this finding}"
```

- `{id}` is a sequential number within the agent's output (S1-001, S2-001, etc.)
- `{category}` must be one of: security, auth, async, error-handling, code-quality, tests, edge-case, requirements, feature-flag, performance, data-loss
- `{file}` is the full relative path from repo root
- `{function}` is the function/handler name, or "—" if file-level
- `{line}` is the line number from the file read
- Every finding MUST have an Evidence line citing a specific file and line number
- "I found this pattern" without a file:line citation is INVALID — discard that finding

If the agent cannot find a specific file location to cite, do NOT include the finding.
A finding without evidence is a guess, not a finding.

### Agent 1: Security & Auth
- Check every route for: requireAuth, requireFeature, requiredRoles, CSRF, rate limiting
- Check every package function for: org ownership validation, permission checks
- Note any endpoint that can be reached without proper guards
- Check for Rule 8 compliance: every error code has a ref ID, no empty catch blocks
- Output: structured findings in SCAN format above

### Agent 2: Architecture & Data
- Check for: async race conditions, missing transactions, N+1 queries, silent truncation (take: without hasMore)
- Check for: Rule 1 (file length > 300 lines), Rule 14 (components without co-located tests)
- Check for: data loss risks, missing validation, env var handling (trim at boundary)
- Note any exported package functions with undocumented preconditions
- Output: structured findings in SCAN format above

### Agent 3: Test Quality
- For each source file, check for a co-located test file
- For each test file: check for self-referential tests (expected built from same method as actual), mocks that pass instead of real implementations
- **Rule 16 — Enumerate Before You Assert (HARD CHECK):** For every `it(` / `test(` block, grep for `.toBeDefined()`, `.toBeTruthy()`, `.not.toBeNull()`, `.not.toBeUndefined()`. If any appear as the ONLY assertion in that block (no `.toBe(`, `.toEqual(`, `.toContain(`, `.toMatchObject(`, `.toHaveBeenCalledWith(`), flag it as severity-8: "pseudocode assertion — passes with wrong implementation"
- Check: are the critical paths tested? Are error branches tested?
- Note: test files that mock too much vs test files that test behavior
- Output: structured findings in SCAN format above

### Agent 4: Product Completeness
- Read each route handler: does it do what the API contract implies?
- Check for: silent truncation without pagination, missing error states in UI, features flagged but not gated
- Check: does the UI reflect real data states or just happy path?
- Note: any feature that is half-built or has a known gap from patterns.md
- Output: structured findings in SCAN format above

---

## STEP 4 — Deduplicate and generate task list

**First, deduplicate across all 4 agents:**

For each agent:
- If the agent produced ANY `[SCAN-` formatted lines: use those findings.
- If the agent produced ONLY prose (no `[SCAN-` lines): note "Agent [N] produced unstructured output — findings discarded." Do NOT create tasks from unstructured prose.

Group structured findings by key = `(category, description[:50].lower())`.
For each group with multiple findings: keep the highest-severity instance. Discard the rest.
This prevents two agents finding the same issue and generating duplicate tasks.

**Then generate tasks from the deduplicated finding set. Apply the following rules:**

**Prioritization:**
1. Severity 8-9 (data loss, auth bypass, production incident risk) → top of list, mandatory
2. Severity 6-7 (real bugs, wrong behavior, coverage gaps) → next
3. Severity 4-5 (technical debt, quality gaps) → below
4. Severity 1-3 (polish, style) → bottom, optional

**Task format:**
```markdown
### Task #N: [Title]

**Module:** [module]
**File:** [primary file(s) — used by /advance for stream isolation]
**Complexity:** ⚡ Direct — [evidence] / 🔧 Full — [evidence]
**Owner:** —
**Blocked by:** Nothing
**Priority:** P1 / P2 / P3
**Status:** OPEN

**What:**
[What is wrong and why it matters]

**Acceptance Criteria:**
- [ ] [Specific, testable outcome]
- [ ] [Tests written and passing]
- [ ] Audit passes (bash scripts/deep-audit.sh [files])

**Source:** [Security / Architecture / Tests / Product] — severity [N]
```

**Complexity labeling rules** (apply mechanically — /advance re-checks these but scan should pre-label correctly):
- 3+ files in **File:** field → `🔧 Full — [N] files`
- Any path containing `packages/` → `🔧 Full — packages/ boundary`
- **What:** contains implement/integrate/new endpoint/new component/refactor/extract → `🔧 Full — [matched word]`
- All three clear → `⚡ Direct — 1 file, no package boundary, single-scope change`

**Batch structure** — wrap ALL tasks in this header so /advance can run immediately:
```markdown
## Batch 1 [CURRENT SPRINT]
```
Place this header at the top of the task file, before Task #1. Every task goes inside this batch.

**Carry-forward:** If `.autocode/modules/[module]/tasks.md` already exists with a Batch structure, append new tasks to the existing batch and increment task numbers from the highest existing number. Preserve any tasks with `**Status: OPEN` that are not superseded by new findings. Mark carried tasks with `**Carried from: [date]`.

---

## STEP 5 — Write output files

**Write task list:**
Save to `.autocode/modules/[module]/tasks.md`.

**Write/update memory files:**
Route findings to the appropriate module memory file. Append — never overwrite.

- Security/auth findings → `.autocode/modules/[module]/security.md`
  ```markdown
  ## [today's date] — /scan findings
  [list findings with severity]
  ```

- Async, architecture, data-loss → `.autocode/modules/[module]/architect.md`
  ```markdown
  ## [today's date] — /scan findings
  [list findings with severity]
  ```

- Tests, coverage → `.autocode/modules/[module]/qa.md`
  ```markdown
  ## [today's date] — /scan findings
  [list findings with severity]
  ```

**Write profile if it doesn't exist:**
If `.autocode/modules/[module]/profile.md` doesn't exist, write it:
```markdown
# [Module] Profile

**Type:** [API module / UI module / Package / Worker consumer]
**Last scanned:** [date]

## Paths
[list]

## Integrations
[what other modules this one calls or depends on]

## Seam Contracts
[what APIs/interfaces this module exposes to other modules]

## Known Gotchas
[non-obvious constraints, pitfalls, recurring issues]
```

**Write standards.md if it doesn't exist:**
If `.autocode/modules/[module]/standards.md` doesn't exist, write it — synthesized from what the 4 scan agents found:
```markdown
# [Module] Standards

**Module:** [module]
**Last updated:** [date]

## Module-Specific Quality Criteria
[synthesize from scan agent findings — e.g. required auth patterns, async contracts specific to this module, test requirements, naming conventions observed across this module's files]

## Known Fragile Areas
[from scan agents — code areas that generated incidents, repeated findings, or are flagged in patterns.md]

## Seam Contracts
[from scan agents — what invariants this module must uphold at its boundaries with other modules]
```

If `.autocode/modules/[module]/standards.md` already exists: **do not overwrite**. Instead append a dated update section if the scan found new criteria not already covered:
```markdown
## [today's date] — /scan update
[new module-specific criteria discovered this scan that aren't in the existing standards]
```

---

## STEP 6 — Print scan summary

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SCAN COMPLETE: [MODULE]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Tasks generated: [N] ([N] critical, [N] high, [N] medium, [N] low)
  Carried forward: [N] existing open tasks

  Top findings:
    [sev 8-9 findings, one line each]

  Memory written:
    .autocode/modules/[module]/tasks.md
    .autocode/modules/[module]/security.md  ([N] findings)
    .autocode/modules/[module]/architect.md ([N] findings)
    .autocode/modules/[module]/qa.md        ([N] findings)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Start working?
    /task 1        — start with the highest priority task
    /tasks         — review the full task list first
    no             — just reviewing
```

Wait for input.
