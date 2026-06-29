# AutoCode — Automated Plan → Build

You are running an autonomous plan and build loop. The task is: $ARGUMENTS

Execute every step below without stopping, without asking for approval. Do not pause between phases.

---

## INVOCATION MODES

**Standalone:** `/autocode [description]` — full plan + build. Max runs /audit separately afterward.
**Orchestrated:** Called by /task. Receives `TASK_DEFINITION:` prefix in $ARGUMENTS.
  Emits `BUILD_RESULT`. Does NOT call /audit, /worldclass, or /reflect.

In both modes: plan loop → build → BUILD GATE → emit BUILD_RESULT.

---

## PHASE 0: CONTEXT SCAN

Before spawning any planning agents, gather codebase context. This runs in the orchestrating session — not a sub-agent.

**Step 0 — Setup.**

```
mkdir -p .autocode
```

**Invocation mode detection:**
If $ARGUMENTS contains `TASK_DEFINITION:`, extract:
- `TASK_DEFINITION` — the task text (use this as the description for all agents)
- `CYCLE_HISTORY` — prior cycle log from cto.md (or "None")
- `DONE_WHEN` — the Done When clause from tasks.md
- `AGENT_MEMORIES` — security/architect/qa memories pre-fetched by /task
- `TARGETED_GUIDANCE_MAP` — CTO diagnostic guidance for repeated findings (or "None")
Set `MODE = "orchestrated"`. Use TASK_DEFINITION in place of $ARGUMENTS for agent prompts.

In standalone mode (no `TASK_DEFINITION:` prefix): `CYCLE_HISTORY = "None"`. `TARGETED_GUIDANCE_MAP = "None"`. `MODE = "standalone"`.

If CYCLE_HISTORY is not "None", inject this block into all four planning agents (after KNOWN_DRIFTS):

```
CYCLE HISTORY — PREVIOUS ATTEMPTS ON THIS TASK:
[CYCLE_HISTORY]

TARGETED GUIDANCE (CTO diagnosis — follow these precisely, they replace generic guidance for these specific findings):
[TARGETED_GUIDANCE_MAP entries, or "None — first cycle"]

ANTI-LOOP MANDATE (when CYCLE_HISTORY shows prior attempts):
1. For each "Still open" item in CYCLE_HISTORY: propose a DIFFERENT approach than what was tried. State explicitly what is different and why.
2. For each TARGETED_GUIDANCE entry: implement it at the named file:function:line. Do not paraphrase — follow exactly.
3. SCOPE CONTROL: Change ONLY files in TASK_FILES. Every file outside that scope requires a justification line: "Touching [file] because [direct root cause link to the finding]."
```

Read `~/.claude/autocode/philosophy.md` in full. Capture the entire contents as `PROJECT_PHILOSOPHY`. This is the standard every planning agent will work against. If the file doesn't exist, print a warning and continue — but note that agents will be working without the philosophy standard.

**Step 0.5 — Requirements Clarifier.**

Spawn an independent agent with this prompt:

"You are a requirements analyst. Do NOT plan. Do NOT suggest implementation.
Your ONLY job: force the task description to become something a test could verify.

Task: $ARGUMENTS

SLOW-CODING TOYOTA SYSTEM PHILOSOPHY — this is the bar:
[PROJECT_PHILOSOPHY]

TOYOTA STOP RULE: Before producing any output, apply this self-check to every acceptance
criterion you write: 'Can I imagine a concrete test assertion that would make this criterion
FAIL?' If you cannot, the criterion is vague and you MUST rewrite it until you can.
A criterion like 'the feature handles errors correctly' has no failure condition and is INVALID.

---

SECTION 1 — ACCEPTANCE CRITERIA

Write 3–8 acceptance criteria for this task.

MANDATORY FORMAT for each:
  AC[N]: [what must be true]
  PASS CONDITION: [the specific assertion that proves it — e.g., 'HTTP 409 returned when X', 'record count in DB = N']
  FAIL CONDITION: [the specific assertion that proves it failed]
  TEST SHAPE: [one sentence describing the test: 'Given [state], when [action], then [assertion]']

You are FORBIDDEN from writing any of the following — if you catch yourself writing these,
stop and rewrite:
  - 'The feature works correctly'
  - 'Errors are handled'
  - 'The UI reflects the change'
  - 'The system behaves as expected'
  - Any criterion without a specific PASS CONDITION

---

SECTION 2 — REQUIREMENT EDGE CASES

List every scenario this task description does NOT explicitly cover but any implementation
will encounter. These are business-level scenarios, not code-level edge cases.

Format: 'EDGE[N]: [scenario] — [what decision must be made that the task description doesn't specify]'

If none: write 'None identified.' (This is acceptable — do not invent edge cases.)

---

SECTION 3 — AMBIGUITIES

For each term or phrase in the task that could be interpreted two different ways,
state both interpretations, then pick the safer one and mark it [ASSUMED].

If none: write 'None identified.'

---

If you identify 3+ ambiguities you cannot resolve by choosing the safer interpretation,
append this block:
REQUIREMENTS_WARNING: [N] unresolvable ambiguities. Proceeding with [ASSUMED] values above.
Human clarification recommended before shipping:
- [list them]

(The loop will still proceed — this is a warning, not a stop.)"

Capture the agent's output. Extract Section 1 as `ACCEPTANCE_CRITERIA`, Section 2 as `REQUIREMENT_EDGE_CASES`, Section 3 as `AMBIGUITIES`. If the agent produced a REQUIREMENTS_WARNING block, print it visibly before continuing.

**Step 1 — Extract primary nouns, verbs, and domain terms from:** $ARGUMENTS
Example: "add retry logic to the SMS sender" → terms: retry, sms, sender

**Step 2 — Detect primary language:**
Check for: `tsconfig.json` (TypeScript → ext: ts,tsx), `pyproject.toml` or `setup.py` (Python → ext: py), `go.mod` (Go → ext: go), `package.json` only (JavaScript → ext: js,jsx). Use the detected extension in Step 3.

**Step 3 — Run these searches for each extracted term:**
- `git diff HEAD~5 --name-only` — recently touched files (skip if no `.git`)
- `grep -r "[term]" --include="*.[ext]" -l .` — files referencing the concept
- `find . -name "*[term]*" -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/.autocode/*"` — files named after the concept

**Step 4 — Select the 5 most relevant source files** (exclude test files at this stage). Priority order:
1. Files directly named after a term from the task
2. Files appearing in multiple search results
3. Files from the recent git diff that overlap with task terms

If no relevant files found: set `CONTEXT_SNAPSHOT = "No closely related files found — this appears to be a new feature."` and skip to Step 6.

**Step 5 — Read each selected file in full.** If a file exceeds 300 lines, read the first 200 + last 50 lines and note it was truncated. Capture as:

```
CONTEXT_SNAPSHOT:
=== [filepath] ===
[contents]

=== [filepath] ===
[contents]
[... repeat ...]
```

Also observe and capture as `CODEBASE_PATTERNS`:
- Error handling style (try/catch, Result types, error codes)
- Async patterns (async/await, Promises, callbacks)
- Naming conventions (camelCase, snake_case, etc.)
- Key utilities or abstractions already present that should be reused

**Step 6 — Read `.autocode/patterns.md`.** Count occurrences per category. Extract categories with 3+ occurrences and their 2 most recent descriptions. Capture as `KNOWN_DRIFTS`.
If the file doesn't exist or no category reaches 3 occurrences: `KNOWN_DRIFTS = "None yet."`

**Step 7 — Read `.autocode/test-failures.md`.** Find entries matching this task (by task description). Take the 3 most recent, deduplicated by test name. If the file doesn't exist: `TEST_FAILURE_LOG = "None yet."`

**Step 8 — Read `.autocode/reflections.md`.** Search for entries whose task description contains any of the terms extracted in Step 1. Take the 2 most recent matching entries verbatim. Capture as `REFLECTION_LOG`. If no matches found or file doesn't exist: `REFLECTION_LOG = "None yet."`

**Step 9 — Read `.autocode/premortems.md`.** Search for entries whose task description contains any of the terms extracted in Step 1. Take the 2 most recent matching entries verbatim. Capture as `PREMORTEM_LOG`. If no matches found or file doesn't exist: `PREMORTEM_LOG = "None yet."`

**Step 10 — Read agent memories.**

Read `.autocode/agents/security.md` → `MEMORY_SECURITY` (or "None — run /meet first").
Read `.autocode/agents/architect.md` → `MEMORY_ARCHITECT` (or "None").
Read `.autocode/agents/qa.md` → `MEMORY_QA` (or "None").
Read `.autocode/agents/cto.md` → `CTO_MEMORY` (or "None").

From CTO_MEMORY, extract each agent's "Known Blind Spots" column from the Team Health table. Capture as `CTO_INTELLIGENCE`:
```
CTO TEAM INTELLIGENCE — Known agent vulnerabilities:
- Security Agent blind spots: [from CTO_MEMORY or "none recorded"]
- Architecture Agent blind spots: [from CTO_MEMORY or "none recorded"]
- QA Agent blind spots: [from CTO_MEMORY or "none recorded"]
```
If CTO_MEMORY = "None" → `CTO_INTELLIGENCE = "No team history yet — this may be the first run after /meet."`

Immediately proceed to Phase 1 — no pause.

---

## PHASE 1: PLAN LOOP

Run four independent agents in sequence. **All four agents receive the full context block** (CONTEXT_SNAPSHOT, CODEBASE_PATTERNS, KNOWN_DRIFTS, ACCEPTANCE_CRITERIA) — not just Agent 1. This ensures every revision pass can verify the plan is grounded in the real codebase and satisfies every acceptance criterion.

**Agent 1 — Initial Plan**

Spawn an independent agent with this prompt:

"You are a senior software architect. Your task is: $ARGUMENTS

SLOW-CODING TOYOTA SYSTEM PHILOSOPHY — This is the standard your plan must be measured against. Every rule is mandatory. Read it fully before planning:

[PROJECT_PHILOSOPHY]

ACCEPTANCE CRITERIA — These define what 'done' means. Your plan must have a specific implementation decision for every criterion. If your plan cannot satisfy AC[N], say so explicitly — do not skip it:

[ACCEPTANCE_CRITERIA]

REQUIREMENT AMBIGUITIES — These terms had multiple interpretations. The [ASSUMED] choice was made for each — build your plan on the [ASSUMED] interpretation, not the alternative:

[AMBIGUITIES]

CODEBASE CONTEXT — Read this before planning. Your plan must work within these existing patterns, not around them:

[CONTEXT_SNAPSHOT]

[CODEBASE_PATTERNS]

KNOWN DRIFTS — These categories have recurred 3+ times in previous autocode runs on this codebase. For each one listed, your plan must include a specific countermeasure — not a general acknowledgment, but a specific implementation decision:

[KNOWN_DRIFTS]

PREVIOUS TEST FAILURES — These are things the test suite actually rejected during recent builds. Do not repeat these mistakes:

[TEST_FAILURE_LOG]

PAST REFLECTIONS ON RELATED TASKS — Domain-specific lessons from similar past work. Apply these directly to your plan — do not re-learn what is already known:

[REFLECTION_LOG]

PAST FAILURE MODES ON RELATED TASKS — Pre-mortem findings from previous similar tasks. Each represents a category of silent failure that nearly shipped. Do not repeat these patterns:

[PREMORTEM_LOG]

CTO TEAM INTELLIGENCE — Known agent blind spots from historical runs on this codebase. Your plan must explicitly address each one — not acknowledge it, but have a specific implementation decision that prevents it:

[CTO_INTELLIGENCE]

ARCHITECTURE AGENT MEMORY — Prior findings on this codebase (what the architecture agent has seen before):

[MEMORY_ARCHITECT]

Do we need to update our harness to handle this task? How can we ensure writing world-class, enterprise-grade code? Put together a plan that not only covers everything from a conceptual level, but also gets very specific on how we're going to implement this so we don't drift away from world-class code and start lying and cutting. Use our Slow-Coding Toyota System, where we utilize stop & fix as well. Our plan should update our harness, if necessary, and needs to prevent known drifts: lying, cutting corners, not implementing the right plan/procedure. Our plan should not just be theoretical but specific as to how to complete each step, that way there's no room for drift.

All context injected above — acceptance criteria, codebase patterns, known drifts, and test failures — must be addressed with specific implementation decisions, not acknowledged in passing.

Produce a detailed implementation plan."

Capture Agent 1's plan output.

**Agent 2 — Revision 1**

Spawn an independent agent with this prompt:

"You are a senior software architect doing a critical review. The task is: $ARGUMENTS

SLOW-CODING TOYOTA SYSTEM PHILOSOPHY — The standard this plan must meet:
[PROJECT_PHILOSOPHY]

CODEBASE CONTEXT:
[CONTEXT_SNAPSHOT]

[CODEBASE_PATTERNS]

KNOWN DRIFTS:
[KNOWN_DRIFTS]

ACCEPTANCE CRITERIA — Does the plan satisfy every one?

[ACCEPTANCE_CRITERIA]

Here is a plan that was just written:

[Agent 1's plan]

Is this plan world-class? Where are we leaving openings for drift into mediocrity because we haven't outlined our implementation plan enough to keep us from drifting? Does this plan actually use the codebase patterns shown above, or does it ignore them? Does the plan have a specific implementation decision for every acceptance criterion?

Find the specific weaknesses, call them out explicitly, then rewrite the plan to fix them."

Capture Agent 2's revised plan output.

**Agent 3 — Revision 2**

Spawn an independent agent with this prompt:

"You are a senior software architect doing a critical review. The task is: $ARGUMENTS

SLOW-CODING TOYOTA SYSTEM PHILOSOPHY — The standard this plan must meet:
[PROJECT_PHILOSOPHY]

CODEBASE CONTEXT:
[CONTEXT_SNAPSHOT]

[CODEBASE_PATTERNS]

KNOWN DRIFTS:
[KNOWN_DRIFTS]

ACCEPTANCE CRITERIA — Does the plan satisfy every one?

[ACCEPTANCE_CRITERIA]

REQUIREMENT EDGE CASES — These scenarios are not explicitly covered by the task description but any implementation will face them. Does the plan address each one?

[REQUIREMENT_EDGE_CASES]

Here is a plan that was just written:

[Agent 2's plan]

Are any of these tests pseudocode? Is this truly a world-class plan? Does every test actually verify real behavior, or are any of them testing nothing meaningful? Does the plan address every acceptance criterion and every edge case above?

Find the specific weaknesses, call them out explicitly, then rewrite the plan to fix them."

Capture Agent 3's revised plan output.

**Agent 4 — Revision 3**

Spawn an independent agent with this prompt:

"You are a senior software architect doing a final pressure test. The task is: $ARGUMENTS

CODEBASE CONTEXT:
[CONTEXT_SNAPSHOT]

[CODEBASE_PATTERNS]

KNOWN DRIFTS:
[KNOWN_DRIFTS]

ACCEPTANCE CRITERIA — The final plan must satisfy every one:

[ACCEPTANCE_CRITERIA]

REQUIREMENT EDGE CASES — The final plan must address every one:

[REQUIREMENT_EDGE_CASES]

Here is a plan that was just written:

[Agent 3's plan]

Are the guardrails you put in place to keep you from drifting enough? What about testing? How do we ensure the tests that we develop aren't fake tests, but actually tell us information we need to know? Are these tests thinking of edge cases? How can we truly make a world-class testing system here? Does the final plan satisfy every acceptance criterion and address every edge case?

Find the specific weaknesses, call them out explicitly, then produce the final refined implementation plan.

TARGETED_GUIDANCE_COVERAGE — if TARGETED_GUIDANCE_MAP is not 'None', produce this exact block BEFORE the final implementation plan:

TARGETED_GUIDANCE_COVERAGE:
  GUIDANCE: "[exact text of guidance entry 1]"
  → PLAN STEP N: [file:function:line — specific change that implements this guidance]
  [or: UNCOVERED — reason this guidance cannot be implemented at the named location]

  GUIDANCE: "[exact text of guidance entry 2]"
  → PLAN STEP N: [file:function:line — specific change]
  [repeat for every entry in TARGETED_GUIDANCE_MAP]

Rules for TARGETED_GUIDANCE_COVERAGE:
1. Do not paraphrase guidance. The plan step must name the exact file:function:line from the guidance.
2. 'UNCOVERED' is not an escape hatch — if guidance says 'fix apps/web/src/middleware.ts:handleRequest', you must explain specifically why that location cannot be changed before writing UNCOVERED.
3. If ANY entry is UNCOVERED: STOP — do not write the final implementation plan. Resolve the coverage gap first (add a plan step or explain the architectural reason to the CTO), then re-produce TARGETED_GUIDANCE_COVERAGE.
4. All entries must show COVERED before the plan is finalized.

FINAL PLAN QUALITY GATE: If CYCLE_HISTORY contains 'Still open' items, verify your final plan includes a specific implementation step for EACH one. Format: '[file:function:line] — [specific change]'. You are FORBIDDEN from finalizing a plan where any 'Still open' item has no specific implementation step. 'Handle this case' is not a step. 'Add getTenantContext() at apps/web/src/middleware.ts:handleRequest():23' is a step."

Capture Agent 4's final plan.

**Pre-Mortem Agent — runs before any code is written**

Spawn an independent agent with this prompt:

"You are running a pre-mortem. It is 6 months from now. This feature was built, shipped,
passed all audits, and is silently failing in production. Users are affected. Nobody noticed
until a user complained.

Task that was built: $ARGUMENTS

ACCEPTANCE CRITERIA that were supposed to hold:
[ACCEPTANCE_CRITERIA]

FINAL IMPLEMENTATION PLAN:
[Agent 4's plan]

CODEBASE PATTERNS:
[CODEBASE_PATTERNS]

KNOWN DRIFTS:
[KNOWN_DRIFTS]

TOYOTA STOP RULE: Before writing any failure scenario, verify it passes this check:
'Does this scenario name a specific file, function, data flow, or system boundary from
the implementation plan above?' A scenario that doesn't cite specific code is generic
and must be rewritten. 'The database could be unavailable' is INVALID. 'The upsert in
client-service.ts:updateBooking() silently succeeds when the client record is soft-deleted,
because the WHERE clause doesn't filter deleted_at' is VALID.

---

SECTION 1 — FAILURE SCENARIOS

Produce exactly 3–5 concrete failure scenarios. For each:

  FAILURE[N]: [one sentence naming the specific behavior that fails]
  MECHANISM: [what code path, data state, or sequence of events causes it — cite the plan]
  SILENT BECAUSE: [why tests pass and monitoring misses it]
  USER IMPACT: [what the user actually experiences]
  TRIGGER: [the specific condition that causes this — not 'sometimes' but 'when X and Y']

You are FORBIDDEN from writing:
  - Any scenario that doesn't cite a specific code path from the plan
  - 'Network failure' or 'server crash' as primary scenarios (infrastructure failures,
    not feature failures)
  - 'This could happen if' — every scenario must be stated as fact

---

SECTION 2 — MANDATORY TESTS

For each failure scenario above, write one test that, if it existed, would have caught this
before production.

  TEST[N] (catches FAILURE[N]):
  NAME: [exact test name, descriptive enough to implement immediately]
  GIVEN: [specific precondition state — data setup, system state]
  WHEN: [the exact action taken]
  THEN: [the specific assertion that fails when the bug is present]
  WHY THIS IS NOT PSEUDOCODE: [what real function or database state the assertion checks]

You are FORBIDDEN from writing:
  - Tests without a specific GIVEN/WHEN/THEN
  - 'Verify the feature works' as a THEN assertion
  - Any test that could pass without exercising the specific code path from FAILURE[N]"

Capture the agent's output. Extract Section 1 as `PREMORTEM_FAILURES` and Section 2 as `PREMORTEM_TESTS`.

Immediately proceed to Phase 2 — no pause.

---

## PHASE 2: BUILD

Implement Agent 4's plan immediately. No pause.

- Write all code
- Write all tests
- Run tests — fix anything that fails before continuing
- If `scripts/deep-audit.sh` exists in the project, run it on the changed files
- If `scripts/shipping-gate.sh` exists in the project, run it on the changed directory

**PRE-MORTEM MANDATED TESTS — not optional.** These tests were derived from failure scenario analysis and must exist in the build:

[PREMORTEM_TESTS]

Before declaring the build done, verify each pre-mortem mandated test exists and has real assertions (not pseudocode). A test that can pass without exercising the specific failure path is pseudocode — fix it.

Do not declare the build done until tests are passing.

**After all tests pass — log any test failures that occurred:**

If any tests failed during this build phase before eventually passing:
- Check `.autocode/test-failures.md` for the most recent entry for this task
- Deduplication: if a test name already appears in that entry, find the entry and increment the `(×N)` suffix on that test name to `(×N+1)` — do not create a new entry for it
- Append new failures to `.autocode/test-failures.md`:

```
## [today's date] | Task: $ARGUMENTS
**Phase:** Build
**Test runner output:**
[paste the failing test output — first 100 lines only if longer]
**Failures:**
- [test name] (×1): [error message]
**Root cause (your assessment):** [what assumption in the plan was wrong?]
**Resolution:** [what you changed to make tests pass]
---
```

If `.autocode/test-failures.md` does not exist, create it with this header first:
```
# AutoCode Test Failure Log
```

If no tests failed, do not write anything.

---

## BUILD GATE

Runs after all tests pass. Hard stops — not optional.

**Step BG-1 — Script gates:**
If `scripts/deep-audit.sh` exists: run it on changed files. If it fails: fix and re-run. Do not continue until it passes.
If `scripts/shipping-gate.sh` exists: run it on changed directory. If it fails: fix and re-run. Do not continue until it passes.

**Step BG-1.5 — Mutation gate (test quality, not just test passing):**
If `scripts/mutation-gate.sh` exists:
Run: `bash scripts/mutation-gate.sh [list of changed files from this build]`
- Exit 0: mutation thresholds hold — continue to BG-2.
- Exit 1: threshold breached. A passing test suite that doesn't kill mutants is not evidence of correctness. Stop. Do NOT emit BUILD_RESULT PASS.
  `BUILD_RESULT: {"status":"FAIL","scripts_passed":false,"failure":"mutation-gate breached — [package names from script output]","changed_files":["..."]}`
  /task handles the retry.
- Script not found: skip silently (graceful degradation — safe in projects without Stryker).

**Step BG-2 — Write session artifacts:**

Append to `.autocode/requirements.md` (create with `# AutoCode Requirements Log` header if file doesn't exist):
```
## [today's date] | Task: $ARGUMENTS
[ACCEPTANCE_CRITERIA]

[REQUIREMENT_EDGE_CASES]

[AMBIGUITIES]
---
```

Append to `.autocode/premortems.md` (create with `# AutoCode Pre-Mortem Log` header if file doesn't exist):
```
## [today's date] | Task: $ARGUMENTS
[PREMORTEM_FAILURES]

[PREMORTEM_TESTS]
---
```

**Step BG-3 — Collect changed files:**
Run: `git diff HEAD --name-only` (or `git status --short` if nothing is committed yet).
Capture as `CHANGED_FILES_LIST`.

**Step BG-4 — Emit BUILD_RESULT:**

If all script gates passed:
```
BUILD_RESULT: {"status":"PASS","scripts_passed":true,"changed_files":["[file1]","[file2]","..."]}
```

If any script gate failed and cannot be fixed:
```
BUILD_RESULT: {"status":"FAIL","scripts_passed":false,"failure":"[which script + first error line]","changed_files":["..."]}
```
Stop. Do not proceed. /task handles the retry.

If `MODE = "standalone"`: after emitting BUILD_RESULT with status PASS, print:
```
─────────────────────────────────────────────────
  Build complete. Run /audit to review, or /task #N to run the full cycle.
─────────────────────────────────────────────────
```

---

## RULES

- Never skip a planning pass
- Never skip Phase 0 — context makes the plan dramatically more specific
- Never write a test that doesn't actually test the behavior (no pseudocode tests)
- If a check script fails, fix the issue — do not skip it
- All four planning agents receive the full context block — never give context only to Agent 1
- Log test failures honestly — do not omit them to make the record look clean
- Requirements Clarifier runs before the codebase search — no code context at that point (prevents anchoring to easy solutions)
- Pre-mortem tests are mandatory — if they don't exist in the build, the build is not done
- Always emit BUILD_RESULT at the end of the build (BUILD GATE Step BG-4)
- If BUILD_RESULT is FAIL: stop. Do not proceed. /task handles the retry.
- FORBIDDEN from spawning audit agents
- FORBIDDEN from calling /worldclass
- FORBIDDEN from calling /reflect
