# Meet — Dev Team Onboarding

You are running the team onboarding ritual. The task is: $ARGUMENTS

When invoked with no arguments, run a full codebase examination. When invoked with a module name or path, scope the examination to that area.

This command brings the development team up to speed: reads all context, examines the codebase through four specialized lenses, asks the project owner informed questions, generates a numbered task list, and writes agent memories so every subsequent run builds on this session.

---

## PHASE 0: LOAD ALL CONTEXT

Run in the orchestrating session:

```
mkdir -p .autocode/agents
```

Read in this order (all mandatory):

1. `~/.claude/autocode/philosophy.md` in full → `PROJECT_PHILOSOPHY`
2. `CLAUDE.md` → `PROJECT_CONTEXT`
3. `docs/STATUS.md` → `PROJECT_STATUS` (or "Not found" if absent)
4. `.autocode/reflections.md` → `REFLECTION_LOG` (full contents, or "None yet")
5. `.autocode/agents/cto.md` → `CTO_MEMORY` (or "No CTO memory — this is the first /meet")
6. `.autocode/agents/security.md` → `MEMORY_SECURITY` (or "None yet")
7. `.autocode/agents/architect.md` → `MEMORY_ARCHITECT` (or "None yet")
8. `.autocode/agents/qa.md` → `MEMORY_QA` (or "None yet")
9. `.autocode/agents/docs.md` → `MEMORY_DOCS` (or "None yet")
10. `.autocode/tasks.md` if exists, else `docs/TODO_AUDIT_FIXES.md` if exists → `EXISTING_TASKS` (full file, or "None")
11. Run: `git log --oneline -50` → `GIT_LOG`
12. Run: `git diff HEAD~10..HEAD --name-only` → `RECENT_FILES`
13. Run: `pnpm audit --json 2>/dev/null | head -30` → `CVE_SNAPSHOT` (or skip if not a Node.js project)
14. Read `ROADMAP.md`, `docs/ROADMAP.md`, or `docs/PLANNED.md` (first found, first 150 lines) → `PRODUCT_ROADMAP` (or "None found")
15. Run: `grep -rn "TODO\|FIXME\|PLANNED\|COMING SOON\|NOT YET\|NYI" --include="*.ts" --include="*.tsx" --include="*.md" . | grep -v node_modules | grep -v ".next" | head -60` → `CODE_TODOS`

From GIT_LOG, identify:
- **CHURN_ZONES:** files or directories appearing in 5+ of the last 50 commit messages
- **DEAD_ZONES:** modules mentioned in PROJECT_CONTEXT with no recent commits

**If CTO_MEMORY exists (returning team), print this team briefing now — before any examination:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  TEAM BRIEFING — [today's date]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [Extract from CTO_MEMORY Team Health table:]
  Security:  [N] runs | reject rate [N]% | blind spots: [list or "none recorded"]
  Architect: [N] runs | reject rate [N]% | blind spots: [list or "none recorded"]
  QA:        [N] runs | reject rate [N]% | blind spots: [list or "none recorded"]
  Docs:      [N] runs | reject rate [N]% | blind spots: [list or "none recorded"]

  Open escalations: [N] awaiting decision
  Last WorldClass avg: [N]/100 (or "no data yet")
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## PHASE 1: FOUR PARALLEL EXAMINATION AGENTS

Spawn all four simultaneously. Each receives its role's memory plus the shared context.

---

**Examination Agent 1 — Architecture**

Spawn an independent agent with this prompt:

"You are the Architecture Agent onboarding to this project. Read your prior memory first — do not re-discover what you already know.

PROJECT_PHILOSOPHY — the complete standard you enforce:
[PROJECT_PHILOSOPHY]

PRIOR MEMORY (what you knew from previous sessions):
[MEMORY_ARCHITECT]

PROJECT CONTEXT:
[PROJECT_CONTEXT]

RECENT FILES (last 10 commits):
[RECENT_FILES]

CHURN ZONES (files with high change rate — examine these first):
[CHURN_ZONES]

For each churn zone file: read the first 100 lines and assess against the 15 Rules.

BLAST RADIUS: For each churn zone basename, run:
  grep -r 'from.*[basename]' --include='*.ts' --include='*.tsx' -l . | grep -v node_modules | head -20

Report the top 5 most-imported files — these are high-blast-radius (many dependents + changes = risk).

Report exactly:
1. LAYER CAKE violations — files exceeding size limits, upward imports
2. 15 RULES violations — Rule #, file, specific line/pattern
3. BLAST RADIUS map — top 5 most-imported files with importer count
4. MODULE EXTRACTION candidates — logic belonging in a shared package but living in app code (could this be extracted and reused across projects?)
5. DEAD ZONES — modules in docs with no recent commits (stable or forgotten?)
6. ALREADY KNOWN — items from prior memory that are still open (do not re-report resolved)

Every finding must cite file:line. No 'appears to' or 'may have' language.
ARCHITECTURE_FINDINGS: [all findings as a numbered list]"

Capture as `FINDINGS_ARCHITECT`.

---

**Examination Agent 2 — Security**

Spawn an independent agent simultaneously with this prompt:

"You are the Security Agent onboarding to this project. Read your prior memory first.

PROJECT_PHILOSOPHY:
[PROJECT_PHILOSOPHY]

PRIOR MEMORY (what you knew from previous sessions):
[MEMORY_SECURITY]

PROJECT CONTEXT:
[PROJECT_CONTEXT]

RECENT FILES:
[RECENT_FILES]

CVE SNAPSHOT:
[CVE_SNAPSHOT]

You are examining this codebase for security vulnerabilities. Do not use a generic checklist.
Read the actual code and find what is specific to this project.

Run these commands to understand the attack surface:
  grep -rn 'req\.\|request\.\|body\.\|params\.\|query\.' --include='*.ts' --include='*.tsx' --include='*.py' --include='*.go' --include='*.rs' -l . | grep -v node_modules | head -20
  grep -rn 'auth\|session\|token\|jwt\|cookie\|password\|secret\|key' --include='*.ts' --include='*.tsx' -l . | grep -v node_modules | head -20
  grep -rn 'exec\|spawn\|eval\|dangerouslySetInnerHTML\|innerHTML' --include='*.ts' --include='*.tsx' -l . | grep -v node_modules | head -20
  grep -rn 'catch\s*{}\|catch\s*(.*)\s*{}' --include='*.ts' --include='*.tsx' -l . | grep -v node_modules | head -10
  [CVE_SNAPSHOT already captured — report vulnerability count from it]

From what you find, answer these four questions for THIS codebase specifically:

1. WHERE DOES UNTRUSTED DATA ENTER? — HTTP routes, IPC calls, file reads, stdin, webhooks, external API responses. For each entry point: who controls this data? Is it validated before use? Cite file:line.

2. WHAT SECRETS OR CREDENTIALS EXIST? — Tokens, API keys, passwords, session data. For each: where stored? Ever logged? Could they appear in error messages or API responses? Cite file:line.

3. WHERE CAN CALLER IDENTITY BE BYPASSED? — Any query fetching by ID, any route returning data — is the caller's identity verified as authorized? Cite the specific file:line where this check exists or is missing.

4. WHAT FAILS SILENTLY? — Empty catch blocks, swallowed errors, fire-and-forget async. For each: what does the caller assume happened that may not have? Cite file:line.

For CVE_SNAPSHOT: report the vulnerability count. Flag any dep with version 0.x.x (pre-stable).

Apply TOYOTA EVIDENCE RULE to every finding:
  VERIFIED: [file:line] — [what you see]
  FINDING: [description of the vulnerability]
  N/A: [specific reason this question doesn't apply to this codebase — cite why]

FORBIDDEN from writing 'No issues found' without citing code.
FORBIDDEN from writing 'Not applicable' without explaining why for this specific project.

ALREADY KNOWN — items from prior memory that are still open (do not re-report resolved)

SECURITY_FINDINGS: [all findings as numbered list with VERIFIED/FINDING/N/A prefix]"

Capture as `FINDINGS_SECURITY`.

---

**Examination Agent 3 — QA**

Spawn an independent agent simultaneously with this prompt:

"You are the QA Agent onboarding to this project. Read your prior memory first.

PROJECT_PHILOSOPHY (especially Rule 5: Test Ruthlessly, Rule 13: Test the Seams, Rule 14: Component Truth):
[PROJECT_PHILOSOPHY]

PRIOR MEMORY (what you knew from previous sessions):
[MEMORY_QA]

PROJECT CONTEXT:
[PROJECT_CONTEXT]

RECENT FILES:
[RECENT_FILES]

CHECKLIST:

TEST EXISTENCE:
[ ] For each file in RECENT_FILES: does a co-located .test.ts / .test.tsx exist?
    List files changed in last 10 commits WITHOUT a test file.

PSEUDOCODE TEST DETECTION:
[ ] Run: grep -rn 'expect(true).toBe(true)\|expect(1).toBe(1)\|toBeTruthy()\s*$' --include='*.test.*' . | grep -v node_modules
    Any hit is a pseudocode test — report the test name and file.

SKIPPED TESTS:
[ ] Run: grep -rn 'it.skip\|xit\|xdescribe\|test.skip' --include='*.test.*' . | grep -v node_modules
    Report all skipped tests. Skipped tests are debt.

SEAM COVERAGE (Rule 13):
[ ] Do critical paths have integration tests?
    Critical paths: auth flows, order placement, payment processing, external API calls.
    Grep for test files in these areas and assess.

MOCK QUALITY:
[ ] Are any tests asserting mock behavior instead of real behavior?
    (Tests that mock the thing they're testing prove nothing.)

ALREADY KNOWN — items from prior memory that are still open

QA_FINDINGS: [all findings as numbered list]"

Capture as `FINDINGS_QA`.

---

**Examination Agent 4 — Documentation**

Spawn an independent agent simultaneously with this prompt:

"You are the Documentation Agent onboarding to this project.

PROJECT_PHILOSOPHY:
[PROJECT_PHILOSOPHY]

PRIOR MEMORY (what you knew from previous sessions):
[MEMORY_DOCS]

CLAUDE.md (first 200 lines):
[PROJECT_CONTEXT first 200 lines]

STATUS.md:
[PROJECT_STATUS]

GIT LOG (last 50 commits):
[GIT_LOG]

THE TEST: If a new Claude Code session started right now with only CLAUDE.md and STATUS.md, would it know about each recent feature? For each commit in GIT_LOG that shipped a feature — does CLAUDE.md or STATUS.md mention it?

CHECKLIST:

COVERAGE GAPS:
[ ] For each feature commit in GIT_LOG: is it reflected in CLAUDE.md or STATUS.md?
    List any features shipped but not documented.

ACCURACY:
[ ] Run: grep -r 'it(' --include='*.test.*' . | grep -v node_modules | wc -l
    Compare to the test count claimed in CLAUDE.md. Stale if off by >10%.
[ ] Module count in CLAUDE.md — does it match actual module directories?
[ ] Any STATUS.md section marked 'in progress' that looks done based on GIT_LOG?

STALE CONTENT:
[ ] Any doc references to removed features, old file paths, or renamed packages?

ALREADY KNOWN — items from prior memory that are still open

DOCS_FINDINGS: [all findings as numbered list with 'should say X, currently says Y' format]"

Capture as `FINDINGS_DOCS`.

---

**Examination Agent 5 — Product Completeness**

Spawn an independent agent simultaneously with this prompt:

"You are a Product Agent onboarding to this project. You are NOT looking for code quality problems — the other agents handle that. You are looking at this product through the eyes of a customer and a business owner: what is it supposed to do, what does it actually do, and what is obviously missing?

PROJECT CONTEXT:
[PROJECT_CONTEXT]

PROJECT STATUS:
[PROJECT_STATUS]

EXISTING PRODUCT ROADMAP (if any):
[PRODUCT_ROADMAP]

CODE TODO MARKERS:
[CODE_TODOS]

GIT LOG (last 50 commits — tells you what was recently built):
[GIT_LOG]

RECENT FILES (last 10 commits):
[RECENT_FILES]

DEAD ZONES (modules mentioned in docs with no recent commits):
[DEAD_ZONES]

Your job — four lenses:

LENS 1 — WHAT EXISTS vs WHAT WAS PROMISED
Compare PROJECT_STATUS and PRODUCT_ROADMAP against GIT_LOG and RECENT_FILES.
What was described as coming or planned that has no matching commit?
What is marked 'in progress' in docs but has no recent activity?
List each gap as: PLANNED: [feature] | STATUS: [no commits / stalled / partially built] | EVIDENCE: [doc line or TODO marker]

LENS 2 — DEAD ZONES (forgotten features)
For each DEAD_ZONE module: is it complete and stable, or incomplete and abandoned?
A stable module has no TODOs and was finished in a prior phase. An abandoned module has TODOs, stubs, or a STATUS entry that says 'in progress' but no recent commits.
List each as: MODULE: [name] | VERDICT: [stable / abandoned] | EVIDENCE: [specific indicator]

LENS 3 — VISIBLE INCOMPLETENESS
From CODE_TODOS: which are product gaps (missing features) vs code debt (quality issues)?
Product gaps = functionality users would notice is missing.
Code debt = internal quality issues (handled by other agents).
List only product gaps as: TODO: [description] | FILE: [file:line] | IMPACT: [what a user cannot do because of this]

LENS 4 — CUSTOMER EXPERIENCE GAPS
Based purely on what the product claims to do (PROJECT_CONTEXT), what would a first-time user hit that would feel broken or incomplete?
Do NOT speculate — only list gaps you can ground in specific evidence from the context or code markers.

Output format:
PRODUCT_FINDINGS: [numbered list — each item covers one of the four lenses, cites specific evidence]"

Capture as `FINDINGS_PRODUCT`.

---

Wait for all five agents to complete before proceeding.

---

## PHASE 1.5: STACK DETECTION + AUDIT CHECKLIST GENERATION

Spawn a single agent with this prompt:

"You are generating a custom audit checklist for this specific codebase.
Your output will replace a generic security checklist in every future audit run.
It must be specific — not generic. Every checklist item must cite a real file or pattern you found.

Run these detection commands first:

  ls -1 package.json tauri.conf.json Cargo.toml pyproject.toml go.mod next.config.js next.config.ts 2>/dev/null
  cat package.json 2>/dev/null | grep -E '\"(tauri|next|express|fastapi|django|rails)\"' | head -10
  find . -name 'tauri.conf.json' -not -path '*/node_modules/*' | head -3
  find . -name '*.prisma' -not -path '*/node_modules/*' | head -3
  grep -r 'invoke\|tauri::command\|ipc' --include='*.ts' --include='*.tsx' --include='*.rs' -l . | grep -v node_modules | head -10
  grep -r 'fetch\|axios\|http\|https' --include='*.ts' --include='*.tsx' -l . | grep -v node_modules | head -10
  grep -r 'JSON\.parse\|JSON\.stringify\|deserialize\|parse(' --include='*.ts' --include='*.tsx' --include='*.rs' -l . | grep -v node_modules | head -10
  grep -r 'catch\s*(' --include='*.ts' --include='*.tsx' -l . | grep -v node_modules | head -10
  grep -rn 'expect(' --include='*.test.*' . | grep -v node_modules | head -20
  grep -r 'middleware\|permission\|role\|session\|tenant\|authorize\|auth' --include='*.ts' --include='*.tsx' -l . | grep -v node_modules | head -10
  grep -rn 'findMany\|findAll\|findFirst\|findUnique\|SELECT' --include='*.ts' --include='*.tsx' --include='*.sql' . | grep -v node_modules | head -20
  grep -rn '^let \|^var \|^export let ' --include='*.ts' --include='*.tsx' . | grep -v node_modules | grep -v '.test.' | head -20
  grep -r 'retry\|queue\|job\|webhook\|cron\|schedule\|worker\|consumer' --include='*.ts' --include='*.tsx' -l . | grep -v node_modules | head -10
  grep -rn 'catch\s*(.*)\s*{' --include='*.ts' --include='*.tsx' . | grep -v node_modules | grep -v '.test.' | head -20
  grep -rn 'for.*await\|Promise\.all.*map\|\.map.*async' --include='*.ts' --include='*.tsx' . | grep -v node_modules | head -20

Then answer these 11 meta-questions from what you found. Each answer becomes 2-4 checklist items.

META-QUESTION 1 — Trust boundaries:
What are the trust boundaries in this codebase? Possible boundaries: IPC calls, HTTP routes, WebSocket messages, filesystem reads, stdin, deserialization from external storage. For each boundary you found: cite the file where data enters.

META-QUESTION 2 — Parse points:
Where does external data change type or representation? (JSON.parse, serde deserialize, file reads, DB query results). For each: cite file:line. These are where type safety must be verified at runtime.

META-QUESTION 3 — Named invariants:
What algorithms, formulas, or state machines exist whose output must always be correct? (FSRS scheduling math, formula derivation, state transition rules). For each: cite the function. These need tests that can fail with wrong outputs.

META-QUESTION 4 — Discriminant types:
What enums, tagged unions, or error variants are used for branching? (match statements in Rust, switch on enum values, discriminated unions in TypeScript). For each: cite file:line. These need exhaustive handling checks.

META-QUESTION 5 — Silent failure zones:
Where can code fail without surfacing an error? (empty catch blocks, optional chains on critical paths, type casts without runtime check, fire-and-forget async). For each: cite file:line.

META-QUESTION 6 — Test assertion quality:
From the grep of expect() calls: do any assertions check only existence (toBeDefined, toBeTruthy) where a specific value should be checked? Do any test names promise behavior the body doesn't verify? List specific test file:line examples.

META-QUESTION 7 — Authorization and data isolation:
Where is caller identity established and where is it enforced? For every data-fetching operation: is the fetcher verified to be authorized for that specific record — not just authenticated? For multi-user or multi-tenant systems: cite exactly where isolation is enforced at the query level. A route that checks authentication but not ownership is a finding.

META-QUESTION 8 — Concurrency and shared mutable state:
Where is mutable state shared across async boundaries? Module-level variables, in-memory caches, counters, connection state — anything written by one async operation and readable by another. If two requests or jobs arrive simultaneously, can they corrupt each other's state? Cite every module-level `let` or `var` that is mutated after initialization. These are race conditions waiting to happen in production.

META-QUESTION 9 — Idempotency of retryable operations:
For every operation that can run more than once — background jobs, webhooks, queue consumers, scheduled tasks, anything with retry logic — what happens on the second execution? Does it double-insert, double-charge, double-notify, or produce inconsistent state? Cite where idempotency is enforced (unique constraints, idempotency keys, existence checks) and where it is absent.

META-QUESTION 10 — Production diagnosability:
If this system fails at 3am without the original author available, can a developer diagnose it from the logs alone? For each error-handling path: does the log contain who was affected, what they were doing, and why it failed? Errors logged without a user ID, request ID, or the input that caused the failure are undiagnosable. Cite specific catch blocks that log without context. Cite critical paths with no correlation ID.

META-QUESTION 11 — Degradation under load:
Where does this code fail as data grows? Queries without pagination that return entire tables. Loops that make one database or API call per item (N+1). In-memory operations that load unbounded result sets. Algorithmic choices that are fine at 100 records but break at 100,000. These are invisible in development and catastrophic in production. Cite file:function for each.

---

From your 11 answers, generate the audit checklist. Format exactly:

# Audit Checklist — [project name]
Generated: [today's date] by /meet
Stack: [runtime] / [framework] / [deployment model]

## Trust Boundary Checks
[ ] [specific item citing file:function] — [what to verify]
[2-4 items]

## Parse Boundary Checks
[ ] [specific item citing file:function] — [what to verify]
[2-4 items]

## Invariant Verification
[ ] [specific item citing file:function] — [what to verify]
[2-4 items]

## Type Discriminant Exhaustiveness
[ ] [specific item citing file:function] — [what to verify]
[2-4 items]

## Silent Failure Audit
[ ] [specific item citing file:function] — [what to verify]
[2-4 items]

## Test Assertion Quality
[ ] [specific item citing file:function] — [what to verify]
[2-4 items]

## Authorization and Data Isolation
[ ] [specific item citing file:function] — [what to verify]
[2-4 items]

## Concurrency Safety
[ ] [specific item citing file:function] — [what to verify]
[2-4 items]

## Idempotency Verification
[ ] [specific item citing file:function] — [what to verify]
[2-4 items]

## Production Diagnosability
[ ] [specific item citing file:function] — [what to verify]
[2-4 items]

## Degradation Under Load
[ ] [specific item citing file:function] — [what to verify]
[2-4 items]

## STRUCTURAL LAYER END
[end of /meet-generated items]

## TEAM_SPECIFIC LAYER
[PRESERVED — populated automatically by /advance after each wave. Do not edit manually. /meet will preserve this section across regenerations.]

MANDATORY RULES for checklist output:
1. Every item must cite a real file from this codebase — no generic items like 'check for SQL injection' if no SQL exists
2. Every item must describe what VERIFIED and FINDING look like for that specific item
3. N/A is acceptable ONLY if the meta-question genuinely does not apply to this codebase — cite why
4. Items must be verifiable using the TOYOTA EVIDENCE RULE format: VERIFIED / FINDING / N/A
5. Maximum 40 items total (STRUCTURAL LAYER only). Minimum 8. 2-4 items per meta-question — skip N/A questions. If you cannot find 8 items, say so explicitly and explain.
6. Do NOT alter or remove the ## STRUCTURAL LAYER END and ## TEAM_SPECIFIC LAYER sections — they are structural markers.

Also write the project profile as a separate section after the checklist:

# Project Profile
Runtime: [Node.js / Rust / Python / Go / other]
Framework: [Next.js / Tauri / Django / Express / other]
Deployment: [SaaS web / desktop app / library / CLI / other]
Key trust boundaries: [comma-separated list from META-QUESTION 1]
Detection date: [today's date]"

Before spawning the checklist agent above, read `.autocode/audit-checklist.md` if it exists.
Extract the contents of the `## TEAM_SPECIFIC LAYER` section verbatim (everything from the line after `## TEAM_SPECIFIC LAYER` up to the end of the file or next `## ` header) → `EXISTING_TEAM_SPECIFIC`.
If the file doesn't exist or the section is empty or contains only the placeholder line: `EXISTING_TEAM_SPECIFIC = ""`.

Write the agent's checklist output to `.autocode/audit-checklist.md`.
Write the agent's project profile output to `.autocode/project-profile.md`.

After the agent writes `.autocode/audit-checklist.md`:
  If `EXISTING_TEAM_SPECIFIC` is non-empty:
    Read the newly-written `.autocode/audit-checklist.md`.
    Find the `## TEAM_SPECIFIC LAYER` header line.
    Replace the placeholder line immediately following it (the `[PRESERVED — ...]` line) with the verbatim contents of `EXISTING_TEAM_SPECIFIC`.
    Write the file back.

Anti-drift rules:
- The agent MUST run the detection commands before answering meta-questions — never write checklist items from imagination
- The STRUCTURAL LAYER is REGENERATED on every `/meet` run — everything above `## STRUCTURAL LAYER END` is overwritten
- The TEAM_SPECIFIC LAYER is PRESERVED — it is never overwritten by /meet

Print:
```
  Audit checklist written: .autocode/audit-checklist.md ([N] items)
  Project profile written: .autocode/project-profile.md (stack: [runtime]/[framework])
```

After the checklist agent completes, run mutation package detection in the orchestrating session:

Run: `find . -name 'stryker.config.json' -not -path '*/node_modules/*' | sort`
Capture output as STRYKER_PATHS.

If STRYKER_PATHS is empty:
  Write `.autocode/mutation-packages.md`:
  ```
  # Mutation Packages
  Generated: [today's date] by /meet
  No Stryker-covered packages detected.
  ```
  Print: `  Mutation packages:    none detected`
Else:
  For each path in STRYKER_PATHS:
    - DIR = directory containing that stryker.config.json (strip filename — e.g., `packages/ordinatio-auth`)
    - Run: `cat [DIR]/package.json | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])"`
    - PACKAGE_NAME = output (e.g., `@ordinatio/auth`)
    - PATH_PREFIX = `[DIR]/` (trailing slash mandatory)

  Write `.autocode/mutation-packages.md`:
  ```
  # Mutation Packages
  Generated: [today's date] by /meet

  | Path prefix | Filter name |
  |---|---|
  | [PATH_PREFIX] | [PACKAGE_NAME] |
  [one row per detected package — repeat pattern]
  ```
  Print: `  Mutation packages:    .autocode/mutation-packages.md ([N] package(s))`

The file is REGENERATED on every `/meet` run — overwritten, not appended.

---

## PHASE 2: SYNTHESIS + INFORMED QUESTIONS

Spawn a single synthesis agent:

"You are a senior CTO who just received four examination reports from your team.
Your job: identify the 4–5 most important questions to ask the project owner
before generating the task list.

PROJECT PHILOSOPHY:
[PROJECT_PHILOSOPHY]

Architecture findings:
[FINDINGS_ARCHITECT]

Security findings:
[FINDINGS_SECURITY]

QA findings:
[FINDINGS_QA]

Documentation findings:
[FINDINGS_DOCS]

EXISTING TASKS (if any):
[EXISTING_TASKS]

GIT LOG (last 20 commits):
[last 20 lines of GIT_LOG]

CRITICAL RULE: Questions must be EARNED by the findings — not generic.
Every question must cite a specific finding. Required format:
  Q1: 'I found [specific finding]. Does that mean [specific decision needed]?'

Questions that would be generic and are FORBIDDEN:
  - 'What are your goals?'
  - 'What should we prioritize?'
  - 'What's most important to you?'

Questions come in two types — produce both:

BUSINESS QUESTIONS (always ask these 2 — regardless of findings):
B1: 'What is the single most important thing this product needs to do for customers in the next 90 days — the thing that would make the biggest difference to the business?'
B2: 'What are customers or users blocked from doing right now that they need to be able to do? What's the most common complaint or request?'

FINDING QUESTIONS (earned by specific findings — produce 3):
Every finding question must cite a specific finding. Required format:
  Q1: 'I found [specific finding]. Does that mean [specific decision needed]?'

Finding questions should surface:
- Priority conflicts (multiple critical findings — which comes first?)
- Intentional vs. accidental (is this a known tradeoff or a real gap?)
- Strategic direction (does Max's answer change the batch ordering?)
- Product gaps (does the product agent finding match Max's understanding of what's built?)

Produce exactly 7 questions total: B1, B2, Q1, Q2, Q3, Q4, Q5. Number them 1–7."

Capture the synthesis agent's output as `SYNTHESIS_QUESTIONS`.

**Present questions to Max:**

Use AskUserQuestion with the 4–5 generated questions. Format them clearly.

Capture Max's answers as `OWNER_ANSWERS`.

---

## PHASE 3: TASK LIST GENERATION

Spawn a single task list agent:

"You are generating a formal, numbered task list for a development team.
This list is the team's work order — it must be specific enough to execute without ambiguity.

PROJECT PHILOSOPHY (the standard all tasks must meet):
[PROJECT_PHILOSOPHY]

Architecture findings:
[FINDINGS_ARCHITECT]

Security findings:
[FINDINGS_SECURITY]

QA findings:
[FINDINGS_QA]

Documentation findings:
[FINDINGS_DOCS]

Product completeness findings (what's missing from the product, not just from the code):
[FINDINGS_PRODUCT]

Existing product roadmap:
[PRODUCT_ROADMAP]

Project owner's answers (especially B1 and B2 — these define what matters most):
[OWNER_ANSWERS]

Existing tasks to carry forward (open items only):
[EXISTING_TASKS]

Generate the full contents of .autocode/tasks.md using EXACTLY this format:

---
# Task List — [extract project name from PROJECT_CONTEXT]
Generated: [today's date] | Method: /meet
Last updated: [today's date]

## Summary
[N] tasks across [N] batches
Critical (severity 8-9): [N] | High (6-7): [N] | Medium (4-5): [N] | Low (1-3): [N]
Current Sprint: Batch 1 — [N] tasks

## Definition of Done (applies to every task)
**Tier 1 — Locally Complete:** Tests pass, no empty catch{}, no `as any`, self-review Five Forcing Functions
**Tier 2 — Team Integration:** Architecture check (no layer violations), agent sign-off, integration tests pass
**Tier 3 — Deployment Ready:** Security audit (OWASP #1-3 checked), backwards compat verified, feature flag if applicable
**Tier 4 — Shipped Complete:** Docs updated (CLAUDE.md / STATUS.md), error ref IDs present, shipping gate passes
Tiers 1-2 are mandatory for all tasks. Tiers 3-4 required for new features and security-adjacent changes.

## Batch 1 — [theme] [CURRENT SPRINT]
Dependency: None. All subsequent batches blocked until this completes.
Theme: [what all these tasks have in common — e.g., 'Security foundation fixes']

### Task #001 | [category] | severity [N]
**What:** [specific description — exactly what to change, not vague]
**Why:** [business impact OR cite the specific Rule # violated]
**File:** [file:line or 'Multiple — see What']
**Blocks:** [Task #N, Task #N — or 'Nothing']
**Blocked by:** Nothing
**Risk:** [Low / Medium (with mitigation) / High (with mitigation)]
**Completion gates:** [Security Agent sign-off / Architecture Agent sign-off / etc.]
**Done when:** [mechanically checkable condition — grep output, test count, script output]
**Complexity:** [⚡ Direct — N file(s), no package boundary, single-scope change / 🔧 Full — reason]
**Owner:** [Security Agent / Architecture Agent / QA Agent / Docs Agent]

[repeat for each task in batch]

## Batch 2 — [theme] [BACKLOG]
Dependency: Batch 1 complete.

[repeat batch structure]

## Escalation Queue
[any findings the team cannot resolve without Max's input — format: Issue | Why it needs a decision | Options]

---

HARD RULES for task generation:
1. Tasks are ordered by DEPENDENCY (DAG flattening), not priority alone
2. Foundation tasks (auth, data model, shared packages) ALWAYS come first
3. Never put a Batch 2 task that depends on Batch 1 work in Batch 1
4. Every 'done when' must be mechanically checkable — NEVER 'feature works correctly'
5. Task numbers are sequential starting at 001 and NEVER reused
6. Carry forward open tasks from EXISTING_TASKS with new numbers
7. Owner's answers OVERRIDE default ordering — if Max said X is priority, X goes in Batch 1
8. Mark current work batch as [CURRENT SPRINT]; all others as [BACKLOG]
9. High-risk tasks (auth, data model, payments) require Tier 3-4 DoD notation
10. Never create a task without a mechanically checkable done condition
11. TWO TASK TYPES — both must appear in the list:
    - FIX tasks: address findings from Architecture, Security, QA, Docs agents (code quality, correctness)
    - BUILD tasks: address findings from the Product agent and owner's B1/B2 answers (features customers need)
    Use [fix] or [build] as the category tag on each task header.
    Owner's B1 answer (90-day priority) must generate at least one BUILD task in Batch 1 or 2.
    Owner's B2 answer (customer blockers) must generate at least one BUILD task per blocker named.
12. BUILD tasks for features must describe the user experience, not just the code change.
    What: describe what the user can do after this is built, then the technical implementation.
    Done when: must be verifiable from the user's perspective AND from the code (e.g., 'User can submit form without page reload — verified by Playwright test + API returns 200')
13. COMPLEXITY EVALUATION — every task gets one label. Evaluate each task individually —
    never label a batch. The label is DERIVED from the task definition, not gut-felt.

    Check these three signals IN ORDER for each task:

    Signal 1 — FILE COUNT: Count the files in the task's File: field.
      "Multiple — see What" counts as 3+.
      ≤2 files → evidence for Direct
      3+ files → label Full immediately, stop checking.

    Signal 2 — PACKAGE BOUNDARY: Does any file path contain 'packages/'?
      Yes → label Full immediately, stop checking.

    Signal 3 — IMPLEMENTATION SCOPE: Does the What: field contain any of:
      implement, integrate, migrate, new endpoint, new route, new component,
      new feature, multi-commit, TDD sequence, refactor, extract, redesign
      Yes → label Full immediately, stop checking.

    If all three signals clear → label Direct.

    The Complexity: line MUST carry its evidence:
      Complexity: ⚡ Direct — [N] file(s), no package boundary, single-scope change
      Complexity: 🔧 Full — [reason: "3 files" / "packages/ path" / "implements new route"]

    A Complexity: line with no evidence is invalid — treat it as unlabeled.

Write the output to `.autocode/tasks.md`.

---

## PHASE 4: WRITE AGENT MEMORIES

Spawn four agents simultaneously to write initial memory files:

**Memory Writer — Architecture**
"Write the initial memory file for the Architecture Agent. Base it on this examination session.

Findings from this session:
[FINDINGS_ARCHITECT]

Project context:
[PROJECT_CONTEXT — first 50 lines only]

Today's date: [today's date]

Write a markdown file using EXACTLY this structure:

---
agent: architect
last-updated: [today's date]
runs: 1
---
# Architecture Agent Memory — [project name]

## Codebase Model
[What you now know about this specific codebase: layer structure, key modules, blast-radius files, known patterns. Specific — not generic.]

## Recurring Patterns
[Patterns found in this session that may recur. With file references.]

## Known Blind Spots
[Leave empty — populated by /patterns after multiple runs]

## Past Findings — Open
[Every finding from this session, with Task # from tasks.md where assigned. Format: Task #N | file:line | description]

## Past Findings — Resolved
[None yet]
---"

Write to `.autocode/agents/architect.md`.

**Memory Writer — Security** (same structure, based on FINDINGS_SECURITY)
Write to `.autocode/agents/security.md`.

**Memory Writer — QA** (same structure, based on FINDINGS_QA)
Write to `.autocode/agents/qa.md`.

**Memory Writer — Documentation** (same structure, based on FINDINGS_DOCS)
Write to `.autocode/agents/docs.md`.

---

## PHASE 5: WRITE CTO MEMORY

Write `.autocode/agents/cto.md`:

```markdown
---
agent: cto
last-updated: [today's date]
meets: 1
---
# CTO Memory — [project name]

## Strategic Priorities
[Max's stated priorities from OWNER_ANSWERS — ordered by what he said]

## Team Health

### Agent Performance
| Agent | Runs | Audit Reject Rate | Known Blind Spots | Last Updated |
|-------|------|-------------------|-------------------|--------------|
| security | 1 | — | none recorded yet | [today] |
| architect | 1 | — | none recorded yet | [today] |
| qa | 1 | — | none recorded yet | [today] |
| docs | 1 | — | none recorded yet | [today] |

### Quality Trends
No data yet — run /autocode tasks to build history.

## Open Escalations
[any items from Phase 3 Escalation Queue]

## Conflict Register
None yet.

## Task Cycle Log

[Populated by /task after each audit cycle.]
```

---

## PHASE 6: HANDOFF BRIEFING

Print:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  /meet COMPLETE — Team is onboarded
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Architecture:  [N] findings ([N] critical)
  Security:      [N] findings ([N] critical)
  QA:            [N] test gaps, [N] pseudocode tests
  Documentation: [N] doc gaps

  Task list:     [N] tasks across [N] batches
  Batch 1:       [N] tasks — [theme] [CURRENT SPRINT]

  Agent memories written:
    .autocode/agents/architect.md
    .autocode/agents/security.md
    .autocode/agents/qa.md
    .autocode/agents/docs.md
    .autocode/agents/cto.md
  Audit checklist:  .autocode/audit-checklist.md ([N] items, [stack])

  Suggested first command:
    /task #001

  Other commands:
    /resume        — quick session-start (reads memory, no scans)
    /tasks         — view full task list
    /team-health   — CTO dashboard
    /consult [role] — ask a single agent directly
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## RULES

- Never skip Phase 2 (questions to Max) — the task list must reflect his priorities, not guessed ones
- Questions in Phase 2 must cite specific findings — never ask generic questions
- Agent memories must be written even if findings are empty — a memory saying "run 1, no issues found" is still useful
- Never reuse task numbers — if carrying forward existing tasks, renumber sequentially from 001
- EXISTING_TASKS must be read and carried forward — never discard prior open work
- Run /meet again after a significant feature ships to update the task list and agent memories
- If invoked with a module argument ($ARGUMENTS), scope all examination agents to that module only
