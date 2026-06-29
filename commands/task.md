# Task — CTO Orchestrator

You are the CTO orchestrating a complete task cycle. The task is: $ARGUMENTS

Parse TASK_NUM from $ARGUMENTS (e.g., "#003" or "3" → 3).
Execute every phase without pausing.

---

## STREAM_ID check (parallel /advance sessions only)

If `STREAM_ID` is set in the current context (set by a parent CTO via `/advance` brief):
- Replace `.autocode/tasks.md` with `.autocode/stream-[STREAM_ID]/tasks.md` for all reads/writes
- Replace `.autocode/debt.md` with `.autocode/stream-[STREAM_ID]/debt.md` for all reads/writes
- Replace `.autocode/carry-forward-log.md` with `.autocode/stream-[STREAM_ID]/carry-forward-log.md` for all reads/writes
- Create these files with their standard headers if they do not exist
- No other behavior changes — all phases proceed normally

If `STREAM_ID` is not set: use the standard paths as written throughout this file.

---

## PHASE 0: CTO CONTEXT

**Step 0.0 — Complexity check:**
Read `.autocode/tasks.md`. Find Task #TASK_NUM. Check for a `**Complexity: Direct**` line.

If `**Complexity: Direct**` found: set TASK_PATH = DIRECT. Print: "Direct task — Builder path." Proceed to Step 0.0b.
If `**Complexity: Full**` found: set TASK_PATH = FULL. Proceed to Step 0.0b silently.

If no Complexity field:
  Run COMPLEXITY_EVAL on the task description:
  DIRECT if ALL: (a) ≤ 20 words, (b) contains a cosmetic keyword (typo/comment/rename/update text/fix label/add log/remove unused/clarify/whitespace/formatting), (c) contains none of: auth/security/database/migration/schema/api route/endpoint/feature flag/implement/integrate/webhook/redis/queue/worker/payment/order/multi-file.
  FULL otherwise (default when in doubt).
  Write `**Complexity: [Direct/Full]**` to the task entry in `.autocode/tasks.md` before the `**Owner:**` line.
  If Direct: set TASK_PATH = DIRECT. Print: "Direct task — Builder path." Proceed to Step 0.0b.
  If Full: set TASK_PATH = FULL. Proceed to Step 0.0b silently.

**Step 0.0b — Debt review:**

> `debt.md` is the register of deferred WorldClass gaps. It lives at `.autocode/debt.md` and contains:
> - Severity 1-3 deductions auto-logged silently from every WorldClass run (minor, cosmetic)
> - Severity ≥ 4 deductions explicitly accepted as debt by Max (with reason)
> Each entry has a Complexity label. **Direct** items are candidates for casual batching into nearby tasks. **Full** items require their own dedicated task. Run `/tasks debt` to review the full register at any time.

Read `.autocode/debt.md`. If it doesn't exist or has no data rows: skip this step.

Find entries where EITHER:
- The Source Task's files match the current task's `**File:**` field, OR
- The category matches the current task's domain (security task → security/auth; QA task → tests/edge-case; architecture task → async/data-loss/error-handling; code task → code-quality)

Filter to Complexity: Direct entries only.

If any matching Direct entries found:
```
──────────────────────────────────────────────────────
  DEBT REVIEW — [N] related Direct item(s) in debt.md
──────────────────────────────────────────────────────
  While in this area, you could also address:
  [1] severity [N] | [category] | [description] (from Task #[source])
  [2] severity [N] | [category] | [description] (from Task #[source])
  ...
  Add to this task's scope?  [numbers, comma-separated] / no
──────────────────────────────────────────────────────
```
Wait for input.
- If numbers selected: append those items as a scope note in TASK_DEFINITION. Remove the selected rows from `.autocode/debt.md`.
- If no: proceed silently.

If no matching Direct entries: skip silently.

**TASK_PATH branch:**
If TASK_PATH = DIRECT → skip Steps 0.1–4.2. Proceed to **DIRECT TASK PATH** section below.
If TASK_PATH = FULL → continue to Step 0.1.

---

## DIRECT TASK PATH

The Builder implements. The CTO verifies and closes. No audit. No WorldClass. No carry-forward.

**Step D.1 — Read task definition:**
Read `.autocode/tasks.md`. Find Task #TASK_NUM. Extract TASK_DEFINITION, DONE_WHEN, TASK_FILES. If Status: COMPLETE: stop.

**Step D.2 — Read cycle log and memories:**
Read CYCLE_HISTORY from `.autocode/agents/cto.md` `## Task Cycle Log` for Task #TASK_NUM (or "None — first cycle").
Set AUDIT_CYCLE = 1 (resets per session).
Read MEMORY_SECURITY, MEMORY_ARCHITECT, MEMORY_QA, PROJECT_PHILOSOPHY (same as Steps 0.2–0.3).

**Step D.3 — Escalation pre-check (cap: 3 cycles):**
If AUDIT_CYCLE > 3: trigger DIRECT_ESCALATION. A Direct task needing more than 3 attempts is not actually Direct.
If any finding in CYCLE_HISTORY annotated "ESCALATE": trigger DIRECT_ESCALATION.
Otherwise proceed to Step D.4.

**Step D.4 — Pre-build scope check (Gate 1):**
Before calling the Builder, verify ALL of the following:
1. Task description contains NONE of: "refactor", "redesign", "migrate", "implement", "integrate", "rewrite", "across the codebase", "multiple files"
2. Done-when condition references only files in TASK_FILES or test names/commands — not a different file
3. TASK_FILES is a single file (or "Multiple — see What" where What is clearly bounded to cosmetic changes)

If ANY check fails:
- Print: "Task #[TASK_NUM] has scope-expanding language or a multi-file done-when. Re-classifying as Full."
- Edit `.autocode/tasks.md`: replace `**Complexity: Direct**` with `**Complexity: Full**`.
- Set TASK_PATH = FULL. Continue from Step 0.1 on the Full path.

If all checks pass: proceed to Step D.5.

**Step D.5 — Build (Gate 2 embedded):**
Call `/autocode` with the same context assembled in Step 1.1 PLUS this block at the very top:
```
DIRECT_TASK_MODE: ON
This is a Direct-complexity task. Implementation must touch only the file(s) in TASK_FILES.
If you discover that a correct fix requires touching files outside TASK_FILES, or that the
root cause is architectural (cannot be fixed in-place), output the following BEFORE your
implementation plan:
  SCOPE_ESCALATION: YES
  SCOPE_REASON: [specific description of what you found]
If no scope issue: do not include these lines. Implement directly.
```

**Step D.6 — Read BUILD_RESULT and check scope signal (Gate 2):**

Check for scope escalation first:
- If BUILD_RESULT contains `SCOPE_ESCALATION: YES`:
  - Print: "Builder detected scope expansion: [SCOPE_REASON]. Converting Task #[TASK_NUM] from Direct to Full."
  - Edit `.autocode/tasks.md`: replace `**Complexity: Direct**` with `**Complexity: Full**`.
  - Set TASK_PATH = FULL. Continue from Step 0.5 on the Full path (Builder's work becomes Cycle 1).

Then check build status:
- If BUILD_RESULT.status = FAIL:
  - Append abbreviated cycle log entry to `.autocode/agents/cto.md` (see format at Step D.8).
  - Increment AUDIT_CYCLE. If > 3: trigger DIRECT_ESCALATION.
  - Return to Step D.5.
- If BUILD_RESULT.status = PASS: proceed to Step D.7.

**Step D.7 — Done-when verification:**
Run DONE_WHEN mechanically:
- grep command → run it, check exit code
- test name → run test
- file state → check file
- UI behavior that cannot be verified in terminal → mark DEFERRED

If DONE_WHEN FAILS: treat as failed build. Return to Step D.5 with failure noted in context.
If DONE_WHEN PASSES or DEFERRED: proceed to Step D.7b.

**Step D.7b — Direct Spot Check:**

Spawn a single spot-check agent with the following context:

```
You are a senior engineer performing a focused review of a Direct-complexity change.
Your job: answer three questions about the diff honestly.

TASK:
[TASK_DEFINITION full block]

DONE_WHEN:
[DONE_WHEN verbatim]

TASK_FILES (only files the change was allowed to touch):
[TASK_FILES]

DIFF (exact lines changed):
[BUILD_RESULT.diff or summary of changed lines]

PROJECT PRINCIPLES:
[PROJECT_PHILOSOPHY first 100 lines, or "None"]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
QUESTION 1 — DOES IT ACTUALLY WORK?
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Evaluate whether the change solves the stated problem — not just whether
it compiles or passes a grep check.

Ask yourself:
- Does this address the root cause, or does it treat a symptom while the
  real problem remains? (A null check that hides a missing validation is a symptom fix.)
- If new tests were added: do they assert specific behavior (expected return
  value, error thrown, state change), or do they only confirm the function
  was called or a value is defined?
- Under the exact conditions described in the task, would this change produce
  the correct outcome? Reason through it.
- If the done-when condition passes but the underlying behavior is still broken
  in an adjacent scenario: call it out.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
QUESTION 2 — IS IT WORLD-CLASS?
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Apply each standard ONLY to the lines that changed. Ignore untouched code.

1. FAILURE MODES — Does any new function or block handle its failure paths
   before the happy path? Missing failure modes in new code = deduction.
2. HONEST NAMES — Do all new or renamed identifiers fully match what they do?
   A function that does more than its name promises is dishonest.
3. VALIDATE AT BOUNDARIES — Any new HTTP, DB, or external call? Is input
   validated at the entry point before it reaches logic?
4. BEHAVIOR TESTS — Any new tests? Do they fail when the behavior is broken,
   or do they pass regardless? Existence checks (toBeDefined, not.toBeNull)
   without a specific value assertion are pseudocode tests.
5. ASYNC PATHS — Any new `await`? Is there a handler for rejection?
   For timeout? For concurrent execution?
6. HONEST TYPES — Any new `as any`, type assertion, or optimistic return type
   that hides a possible null or error?
7. TRUE STATE — Any new variable or state field that could hold a stale or
   misleading value at any point in its lifecycle?
8. EARNED ABSTRACTIONS — Any new helper or wrapper that is only used in one
   place and adds indirection without hiding genuine complexity?

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
QUESTION 3 — IS IT SAFE?
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
- Any `catch {}` with no binding or logging?
- Any `dangerouslySetInnerHTML`?
- Any `eval()`?
- Did the change touch files outside TASK_FILES? (Scope drift.)
- Any hardcoded secret, credential, or environment-specific value?

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
OUTPUT FORMAT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
For each issue found, emit one line:
  [DSC-{id}|sev:{1-10}|{category}|{file}:{function}:{line}|{description}]

Categories: correctness, tests, async, types, names, safety, scope-drift, abstraction

Then emit exactly one verdict line:
  SPOT_CHECK: PASS
  SPOT_CHECK: WARN — {N} issue(s), severity 1-4 only
  SPOT_CHECK: FAIL — {N} issue(s), highest severity {N}

PASS   = no issues, or only issues with severity < 3
WARN   = issues exist but all severity ≤ 4
FAIL   = any issue with severity ≥ 5
```

Read SPOT_CHECK_RESULT from the agent output.

**If SPOT_CHECK: PASS:**
Proceed to Step D.8.

**If SPOT_CHECK: WARN:**
For each issue found:
- Run COMPLEXITY_EVAL on the description. Append silently to `.autocode/debt.md`:
  `| [today's date] | Task #[TASK_NUM] | [category] | [description] | [severity] | [Direct/Full] | auto — Direct spot check warn |`
- Also append to `.autocode/patterns.md` under today's date (same format as full audit patterns).
Print: "⚠ Direct spot check: [N] warn item(s) logged to debt.md. Proceeding to close."
Proceed to Step D.8.

**If SPOT_CHECK: FAIL:**
If AUDIT_CYCLE = 1 (first attempt):
  Print:
  ```
  ✗ Direct spot check failed — [N] issue(s), highest severity [N]
  [list each finding]
  Retrying build with findings injected.
  ```
  Inject findings as SPOT_CHECK_FINDINGS into the next D.5 build context:
  ```
  SPOT_CHECK_FINDINGS — fix all before closing:
  [finding list]
  ```
  Increment AUDIT_CYCLE. Return to Step D.5.

If AUDIT_CYCLE > 1 (already retried):
  Print: "Direct spot check failed after retry. Converting Task #[TASK_NUM] to Full."
  Edit `.autocode/tasks.md`: replace `**Complexity: Direct**` with `**Complexity: Full**`.
  Continue from Step 0.5 on the Full path — spot check findings become the first cycle's CYCLE_HISTORY.

**Step D.8 — Close:**

Append to `.autocode/agents/cto.md` `## Task Cycle Log`:
```
### Task #[TASK_NUM] | [first line of task description] | Status: COMPLETE | Cycle [AUDIT_CYCLE] | Completed: [today's date]

#### Cycle [AUDIT_CYCLE] — [today's date] — Direct Task (Builder path)
Build approach: [specific file:function:line — must be specific, never vague]
Scripts: PASS
Spot check: [PASS / WARN (N items to debt.md) / FAIL→retry / FAIL→escalated to Full]
Done-when: [PASS / DEFERRED]
Fixed this cycle: — | Still open: — | New findings: [spot check finding ids, or —] | Regression signal: NO
CTO diagnosis run: NO — Direct task
```

Ask Max:
> "Direct task #[TASK_NUM] complete. Spot check: [PASS/WARN]. Done-when: [PASS/DEFERRED]. Mark done? yes/no"

If no: stop. Task remains open.

If yes:
- Edit `.autocode/tasks.md`: add `**Status: COMPLETE — [today's date]**` below `**Owner:**` line.
- Proceed to Step 4.3 (batch completion survey).
- Proceed to Step 4.4 (post-completion triage).
- Proceed to Step 4.5 (start next task).

No carry-forward gate. No /reflect call. No agent memory writes beyond debt.md and patterns.md.

---

**DIRECT_ESCALATION:**

Print:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  DIRECT ESCALATION — Task #[TASK_NUM]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  A Direct task that needs more than 3 attempts is not actually Direct.
  Cycles run: [AUDIT_CYCLE] | Last failure: [summary from BUILD_RESULT]

  Options:
    [A] Convert to Full task — run full /task cycle with audit + WorldClass
    [B] Accept current state and close as-is
    [C] Abort — leave task open for manual review
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```
Wait for Max input.
- A → Edit `.autocode/tasks.md`: Complexity: Direct → Full. Continue from Step 0.5 on Full path.
- B → Write COMPLETE status to tasks.md. Run Steps 4.3–4.5.
- C → Stop. Task stays open.

---

**Step 0.1 — Read task definition:**
Read `.autocode/tasks.md`. Find Task #TASK_NUM.
Extract: TASK_DEFINITION (full block), DONE_WHEN ("Done when:" line), TASK_FILES ("File:" line).
If not found: "Task #N not found in .autocode/tasks.md" → stop.

If task status is COMPLETE: "Task #N is already marked complete. Run /audit #N to re-audit, or /tasks reopen #N first." Stop.

Also check the task block for a `**Audit findings —` or `**WorldClass deductions —` line. If either is found, extract all bullet lines beneath it as PENDING_FINDINGS. If both exist, combine them. These are findings from a prior standalone /audit or /worldclass run — treat them as the cycle history so the build agent knows exactly what to fix.

**Step 0.2 — Read cycle log:**
Read `.autocode/agents/cto.md`. In `## Task Cycle Log`, find entry for Task #TASK_NUM.
CYCLE_HISTORY = all cycle entries found (or "None — first cycle").
AUDIT_CYCLE = 1. (Session variable — resets to 1 every time /task is invoked. Re-running /task #N always gives a fresh 5 audit attempts regardless of prior history.)
WC_CYCLE = 0. (Session variable — resets to 0 every time /task is invoked. Re-running /task #N always gives a fresh 5 WC attempts.)
CURRENT_CYCLE = AUDIT_CYCLE.
Note: CYCLE_HISTORY is still read from cto.md for failure mode diagnosis (Step 0.5) — historical context helps the build agent avoid repeating past mistakes. But the escalation caps are per-session only.

**Step 0.3 — Read agent memories:**
MEMORY_SECURITY ← `.autocode/agents/security.md` (or "None")
MEMORY_ARCHITECT ← `.autocode/agents/architect.md` (or "None")
MEMORY_QA ← `.autocode/agents/qa.md` (or "None")
PROJECT_PHILOSOPHY ← `~/.claude/autocode/philosophy.md` (warn if missing)

**Step 0.4 — Escalation pre-check:**
If AUDIT_CYCLE > 5: trigger ESCALATION (reason: CYCLE_LIMIT_EXCEEDED). Note: WC_CYCLE is not counted here — WorldClass quality loops are uncapped.
If any finding in CYCLE_HISTORY is annotated "ESCALATE": trigger ESCALATION (reason: REPEATED_FINDING).
If severity trended UP in 3 consecutive prior cycles: trigger ESCALATION (reason: SEVERITY_ESCALATING).
If "New findings introduced" > "Fixed this cycle" for 2 consecutive prior cycles: trigger ESCALATION (reason: REGRESSION_PATTERN).
Otherwise proceed to Step 0.5.

**Step 0.5 — Failure mode diagnosis for code failures (skip if first cycle):**

If CYCLE_HISTORY = "None — first cycle": skip this step. Set `TARGETED_GUIDANCE_MAP = "None"`.

Note: "Appears To" Drift, Philosophy Drift, and Severity Rationalization are handled in /audit.md at Agent C output time — they never appear in the cycle log. This step handles only CODE-level failure modes detectable from the cycle log summary.

Parse CYCLE_HISTORY for structured finding lines. Format: `[Fid|sev:N|category|file:function:line|description|annotation]`

**For each finding whose annotation segment = `REPEATED FROM CYCLE N`** (extract N):

1. Locate the matching finding from Cycle N-1 — same `description` text (first 50 chars, case-insensitive) in the Cycle N-1 structured log.
2. Extract `file:function` from both the current entry and the Cycle N-1 entry (4th pipe-delimited segment, before the colon-separated line number).
3. Map to failure mode:

**Surface Fix** — `file` OR `function` changed between current cycle and Cycle N-1 (same description, different location → symptom moved, root cause untouched)

**Pseudocode Tests** — `category` = "tests" AND `description` segment contains any of: "toBeDefined / toBeTruthy / toBeNull / not.toBeNull / .exist( / existence" (test exists but asserts nothing real)

**For each finding in "New findings introduced:" field** (these are NEW findings in files outside TASK_FILES):
Extract `file` from `[Fid|...|file:function:line|...]` — take the portion before the first `:` in segment 4.
If that `file` is NOT in TASK_FILES → **Scope Creep Regression**

**Fallback for old-format cycle log entries** (written before this structured format was adopted):
If CYCLE_HISTORY contains no structured `[Fid|...]` lines at all, fall back to prose-scan:
- Surface Fix: same finding text but different file:line mentioned
- Pseudocode Tests: finding mentions tests + any of "defined/truthy/exist/toBeDefined"
- Scope Creep Regression: "New findings introduced" field names a file not in TASK_FILES

---

**For each Surface Fix finding** — spawn a diagnostic agent:

"You are a senior software architect. The same audit finding has appeared across multiple cycles despite developer fixes. Diagnose why.

PHILOSOPHY: [PROJECT_PHILOSOPHY]

REPEATED FINDING across N cycles: [finding text]
WHAT WAS TRIED each cycle: [build approach entries from CYCLE_HISTORY]
FILE:LINE IN PRIOR CYCLES: [extract from findings annotations if available]

Diagnose the root cause — which of these patterns applies:
- Surface Fix: symptom addressed but root cause layer missed (e.g., route-level fix for middleware-layer problem)
- Scope Miss: fix applied at wrong architectural boundary
- Pseudocode Test Fix: test file added but assertions check existence not behavior
- Regression: prior fix broke adjacent code that re-introduces the issue

Output exactly:
DIAGNOSIS: [Surface Fix | Scope Miss | Pseudocode Test Fix | Regression]
ROOT_CAUSE: [one sentence — name specific file and function if determinable]
TARGETED_GUIDANCE: [file:function:line — specific change required. If location cannot be determined, write CONFIDENCE: LOW and explain why]
CONFIDENCE: HIGH / MEDIUM / LOW"

---

**For each Pseudocode Tests finding** — spawn a diagnostic agent:

"You are a test quality specialist. An audit cycle found tests that are pseudocode — they exist but assert existence rather than behavior.

REPEATED FINDING: [finding text]
CYCLE HISTORY — what test changes were made: [build approach entries from CYCLE_HISTORY that mention tests]

For each test identified as pseudocode:
1. State the weak assertion pattern (expect(x).toBeDefined() / expect(x).toBeTruthy() / expect(x).not.toBeNull() — without asserting a specific value)
2. State what MUST be asserted instead — the specific return value, state change, error thrown, or side effect that proves the behavior works
3. Produce the corrected assertion:

PSEUDOCODE_FINDING: [test name] in [file:line]
  Weak assertion: [current assertion]
  Required behavioral assertion: [what must change]
  Corrected THEN clause: [exact assertion code — this test MUST FAIL if the behavior is broken]

TARGETED_GUIDANCE: Rewrite [test name]::[assertion] to [exact behavioral check]. This test must fail when [specific condition that represents the bug being absent]."

---

**For Scope Creep Regression** — no diagnostic agent. Inject directly into TARGETED_GUIDANCE_MAP:

```
SCOPE_LOCK_MANDATE — Prior cycle introduced regressions outside TASK_FILES. Hard lock active for this cycle.
LOCKED FILES (changes ONLY permitted here): [TASK_FILES from task definition]
Any change to a file outside LOCKED FILES requires this exact line at the TOP of the plan, before any implementation steps:
  SCOPE_EXPANSION_REQUEST: [file] — [why the finding's root cause cannot be fixed within LOCKED FILES] — [specific finding this addresses]
The CTO will evaluate scope expansions. A plan that changes files outside LOCKED FILES without this line is REJECTED.
```

---

Capture all diagnostic agent outputs as TARGETED_GUIDANCE_MAP. Each entry replaces the generic ANTI-LOOP MANDATE for its specific finding in the next build cycle.

Print:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  /task #[TASK_NUM] — Cycle [CURRENT_CYCLE]
  [TASK_DEFINITION first line]
  [If diagnoses ran]: CTO diagnosis: [N] failure modes mapped — targeted guidance ready
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## PHASE 1: BUILD

**Step 1.1 — Assemble build context and call /autocode:**
Run `/autocode` with $ARGUMENTS set to:

```
WORLDCLASS_MANDATE:
You are writing production code that must last 10 years and be maintained by people who never wrote it. These 8 standards are the lens through which you write every line — not a post-build checklist:

1. FAILURE MODES FIRST — Before any function: name its 3 failure modes. Write those handlers first, then the happy path. Bolted-on error handling is always shallow.

2. HONEST NAMES — Every function name is a promise. Does this code fully keep it? getUser() that increments a counter is lying. saveOrder() that silently returns null is lying. Rename or split until names are true.

3. VALIDATE AT BOUNDARIES — For every HTTP route, DB call, external API, queue consumer: validate at the entry point before any logic. Everything crossing a boundary is untrusted.

4. BEHAVIOR TESTS — Every test must answer: would this catch a silent regression? Test the rejection case, the null case, the concurrent case. Testing that a function was called is not a behavior test.

5. CLOSE EVERY ASYNC PATH — For every await: what happens if it rejects? Never resolves? Two run concurrently? Async with no failure path is a delayed crash.

6. HONEST TYPES — Return types must include null/error where possible. No as-any at boundaries. Optimistic typing creates silent production failures.

7. TRUE STATE — Variable names must match values at all times. isLoading: false during a fetch is a lie. error: null after swallowing an error is a lie.

8. EARN EVERY ABSTRACTION — Extract only when logic appears 3+ places or hides genuine complexity. If removing the abstraction clarifies the code, inline it.

PROJECT_PRINCIPLES:
[PROJECT_PHILOSOPHY — or "None — philosophy.md not found. Run /patterns to graduate learnings when ready."]

TASK_DEFINITION:
[TASK_DEFINITION full block]

CYCLE_HISTORY:
[If PENDING_FINDINGS exists: prepend the following before CYCLE_HISTORY]
STANDALONE AUDIT FINDINGS — fix all of these this cycle:
[PENDING_FINDINGS bullet list]
---
[CYCLE_HISTORY from cto.md — or "None — first cycle"]

DONE_WHEN:
[DONE_WHEN verbatim]

AGENT_MEMORIES:
Security: [MEMORY_SECURITY first 200 lines]
Architect: [MEMORY_ARCHITECT first 200 lines]
QA: [MEMORY_QA first 100 lines]

TARGETED_GUIDANCE_MAP:
[TARGETED_GUIDANCE_MAP entries, or "None — first cycle"]
```

**Step 1.2 — Read BUILD_RESULT:**
If BUILD_RESULT.status = "FAIL":
- Write CYCLE LOG ENTRY (see section below) with Scripts: FAIL
- Increment CURRENT_CYCLE. If > 5: trigger ESCALATION.
- Return to Step 1.1.

If BUILD_RESULT.status = "PASS": proceed to Step 1.3.

**Step 1.3 — Done When verification:**
Run DONE_WHEN mechanically:
- Contains a grep command: run it, check exit code
- References a test name: run the test
- Describes file state: check the file
- Describes UI behavior that genuinely cannot be verified in a terminal (visual layout, animation, hover state): mark DEFERRED, proceed. Note: "the feature works" is NOT UI behavior — run any grep, test, or file check that can prove it mechanically.

If DONE_WHEN FAILS: treat as severity-6 finding labeled "DONE_WHEN_FAIL: [condition] — [evidence]".
Inject into /audit via DONE_WHEN_FINDING.

If DONE_WHEN PASSES or DEFERRED: proceed to Phase 2.

---

## PHASE 2: AUDIT

**Step 2.1 — Call /audit:**
Run `/audit #[TASK_NUM]` with $ARGUMENTS set to:

```
TASK_DEFINITION:
[TASK_DEFINITION]

FULL_DIFF_OVERRIDE: [BUILD_RESULT.changed_files]

CYCLE_HISTORY:
[CYCLE_HISTORY — full prior log for this task, including this cycle's build approach]

[if Done When failed: DONE_WHEN_FINDING: DONE_WHEN_FAIL: [condition] — [evidence]]
```

**Step 2.2 — Read AUDIT_RESULT_FINAL:**
If verdict = "PASS":
- Capture as `FINAL_AUDIT_RESULT` in session context — hold this variable through Phase 3 and Phase 4 for memory writes. Do not discard it.
- Proceed to Phase 3.

If verdict = "FAIL" or "MAX_CYCLES":
- Check escalation triggers: any finding annotated "ESCALATE"? CURRENT_CYCLE ≥ 5? Severity trending UP 3 cycles? Regression pattern 2 consecutive cycles?
  → Yes to any: trigger ESCALATION.
- Write CYCLE LOG ENTRY (see section below).
- **Mid-Cycle Subtask Capture:**
  From AUDIT_RESULT_FINAL.findings, identify OUT_OF_SCOPE findings:
    condition: file NOT in TASK_FILES AND severity ≥ 5
  For each OUT_OF_SCOPE finding:
    NEXT_NUM = highest `### Task #` number across all of `.autocode/tasks.md` + 1 (increment per new task if multiple)
    Run COMPLEXITY_EVAL on the finding description (same 3-signal rubric from HARD RULE 13):
      Signal 1 FILE COUNT: 1 file → not Full on this signal
      Signal 2 PACKAGE BOUNDARY: any `packages/` path in finding.file → Full
      Signal 3 SCOPE WORDS: implement/integrate/migrate/refactor/redesign/extract → Full
      All clear → Direct
    Map category → owner:
      security / auth → Security Agent
      tests / edge-case / requirements → QA Agent
      async / error-handling / code-quality / performance / feature-flag → Architecture Agent
    Append to end of current batch in `.autocode/tasks.md` (find the `## Batch N` containing Task #[TASK_NUM], add after the last `### Task #` in that batch):
    ```
    ### Task #[NEXT_NUM]
    **What:** Fix [category] finding from Task #[TASK_NUM] audit: [finding description]
    **Why:** Severity [N] — [finding.file:function:line] — discovered out-of-scope during Task #[TASK_NUM] cycle [CURRENT_CYCLE]
    **File:** [finding.file]
    **Complexity:** [⚡ Direct — 1 file, no package boundary, single-scope fix / 🔧 Full — reason from COMPLEXITY_EVAL]
    **Blocks:** Nothing
    **Blocked by:** Nothing
    **Owner:** [mapped owner from category above]
    **Done when:** [mechanically checkable condition — grep, test name, or file state that confirms the finding is resolved]
    **Spawned from:** Task #[TASK_NUM] cycle [CURRENT_CYCLE] — out-of-scope audit finding
    ```
  If any OUT_OF_SCOPE findings were captured:
    Print: "⚡ [N] out-of-scope finding(s) captured as subtask(s): #[NUM1], #[NUM2]..."
  If no OUT_OF_SCOPE findings (all findings are in TASK_FILES or severity < 5): skip silently.

  **Minor out-of-scope findings (severity 1-4, file NOT in TASK_FILES) — silent debt logging:**
  From AUDIT_RESULT_FINAL.findings, find all findings where file NOT in TASK_FILES AND severity 1-4.
  For each: run COMPLEXITY_EVAL on the finding description. Append to `.autocode/debt.md`
  (create with header `# Accepted Technical Debt\n| Date | Source Task | Category | Description | Severity | Complexity | Reason |\n|------|------------|---------|-------------|---------|-----------|---------|` if not exists):
    `| [today's date] | Task #[TASK_NUM] | [category] | [description] | [severity] | [Direct/Full] | auto — out-of-scope mid-cycle finding |`
  No output. Silent append only. These surface at Step 0.0b when adjacent work runs.
- Increment CURRENT_CYCLE. Return to Phase 1 Step 1.1.

---

## CYCLE LOG WRITE

After each failed cycle, append to `.autocode/agents/cto.md` `## Task Cycle Log`.

Find or create task header:
```
### Task #[TASK_NUM] | [TASK_DEFINITION first line]
Status: In Progress | Cycle [CURRENT_CYCLE] | Started: [date of first cycle]
```

Compose cycle entry text:
```
#### Cycle [CURRENT_CYCLE] — [today's date]
Build approach: [specific file:function:line from /autocode planning summary — "added error handling" is REJECTED]
Scripts: [PASS / FAIL]
Audit findings (structured):
  [F{id}|sev:{severity}|{category}|{file}:{function}:{line}|{description}|{annotation}]
  [repeat one line per finding from AUDIT_RESULT_FINAL.findings — emit every finding]
Fixed this cycle: [comma-separated ids — findings from prior cycle no longer in AUDIT_RESULT_FINAL.findings, e.g. "F002, F003"]
Still open: [comma-separated ids — findings present this cycle AND in a prior cycle, e.g. "F001"]
New findings introduced: [comma-separated ids with file — findings annotated NEW whose file is NOT in TASK_FILES, e.g. "F004 (apps/web/src/lib/other.ts)"]
Regression signal: [YES if count(New findings introduced) > count(Fixed this cycle), else NO]
CTO diagnosis run: [YES with failure modes: [list], or NO — first cycle]
Naive reader findings: [naive_findings from AUDIT_RESULT_FINAL, or 'None' if field absent or empty — Agent K will verify these next cycle]
```

**Before appending to cto.md, validate the entry:**
Write the cycle entry text to `/tmp/cycle_entry_$$.txt`, then:

If `scripts/validate-cycle-log.sh` exists:
```
bash scripts/validate-cycle-log.sh /tmp/cycle_entry_$$.txt
```
- Exit 0: valid — append to cto.md.
- Exit 1: Cycle log entry is malformed. Print every `CYCLE_LOG_ERROR:` line. Fix all errors before writing. Do NOT write an invalid cycle log — an unvalidated log corrupts Step 0.5 failure mode detection in the next cycle.

If `scripts/validate-cycle-log.sh` does NOT exist: manually verify all 8 required fields are present and Build approach contains file:function before writing.

Then append the validated entry to `.autocode/agents/cto.md` `## Task Cycle Log`.

**Precision requirement:** "Build approach" MUST name specific file:function. Vague entries like "added error handling" are invalid and must be re-requested from /autocode planning output.

**Structured findings format — one line per finding:**
`[F001|sev:7|auth|apps/web/src/app/api/orders/route.ts:GET:47|Missing tenant isolation|NEW]`
Fields: id | severity with sev: prefix | category | file:function:line | description | annotation
This format is machine-parseable by Step 0.5 in the NEXT cycle. Descriptions with `|` chars were already blocked by validate-findings.sh (or prose fallback) so no escaping is needed.

---

## PHASE 3: WORLDCLASS

Run: `/worldclass Task #[TASK_NUM]: [TASK_DEFINITION first line]`
Wait for WORLDCLASS_RESULT.

If WORLDCLASS_RESULT.verdict = "PASS": proceed to Phase 4.

If WORLDCLASS_RESULT.verdict = "MAX_CYCLES":
  The task is not done. Pay the WorldClass tax now — deferring compounds debt.

  **Step 3.1 — Write deductions to tasks.md:**
  Open `.autocode/tasks.md`. Find the `### Task #[TASK_NUM]` block.
  Find the line immediately after the `**Owner:**` line.
  Remove any existing `**WorldClass deductions —` block if present.
  Insert:
    `**WorldClass deductions — [today's date]** ([95 - COMBINED_SCORE] pts from 95, [N] deductions pending fix):`
    For each unresolved deduction from the final WorldClass scoring cycle (≥ -2 pts, both Architecture and Vibes):
    `- [category] [description] — severity [N] (-[pts] pts)`

  **Step 3.2 — Inject into CYCLE_HISTORY:**
  Append to the in-session CYCLE_HISTORY variable:
  "WORLDCLASS DEDUCTIONS — fix all of these before this task can close:
  [same deduction list]"

  **Step 3.3 — Write cycle log entry:**
  Append to `.autocode/agents/cto.md` `## Task Cycle Log` under Task #[TASK_NUM]:
    `#### WC Cycle [WC_CYCLE + 1] — [today's date] — WorldClass MAX_CYCLES`
    `Build approach: WorldClass remediation — [top deduction category] was the blocking gap`
    `Scripts: PASS (audit passed; WorldClass did not reach 95)`
    `WorldClass score: [COMBINED_SCORE]/100 | Gap: [95 - COMBINED_SCORE] pts`
    `Unresolved deductions: [top 3 by point value]`
    `Fixed this cycle: — | Still open: WorldClass gap`
    `New findings introduced: — | Regression signal: NO`
    `CTO diagnosis run: NO — WorldClass quality gap, not a repeated audit finding`

  **Step 3.4 — Increment WC_CYCLE and check session cap:**
  Increment WC_CYCLE. Do NOT increment AUDIT_CYCLE.

  If WC_CYCLE >= 5:
    WorldClass has not reached 95 after 5 attempts this session. Stop looping.
    Print:
    ─────────────────────────────────────────────────────────────
      WorldClass hit 5 attempts this session. Current score: [COMBINED_SCORE]/100.
      Deductions remain on Task #[TASK_NUM] in tasks.md.

      Run /task #[TASK_NUM] again for a fresh 5 attempts.
      Or accept current score and close the task? yes / no
    ─────────────────────────────────────────────────────────────
    Wait for user input.
    If yes: proceed to Phase 4 (mark complete at current score).
    If no: stop. Task stays open. Run /task #[TASK_NUM] again when ready.

  If WC_CYCLE < 5: return to Phase 1 Step 1.1. The build agent receives the WorldClass deductions via CYCLE_HISTORY and must fix them before the audit re-runs.

---

## PHASE 4: COMPLETE

**Step 4.0 — Write agent memories (using FINAL_AUDIT_RESULT from Phase 2.2):**

Route FINAL_AUDIT_RESULT.findings to the correct memory file by `category`:
- category in ["security", "auth"] → `.autocode/agents/security.md`
- category in ["code-quality", "async", "error-handling", "feature-flag", "performance"] → `.autocode/agents/architect.md`
- category in ["tests", "requirements", "edge-case"] → `.autocode/agents/qa.md`

For each memory file M with at least one routed finding:

**If `scripts/update-memory.py` exists** (machine-enforced deduplication):

Build the JSON array of findings routed to M. Run:
```
python3 scripts/update-memory.py \
  --findings '[JSON array of findings routed to this memory file]' \
  --memory-file [M path]
```
- Exit 0: prints "OK: N added, N updated, N recurred" — memory file updated.
- Exit 1: prints MEMORY_ERROR — investigate and fix before proceeding.

**If `scripts/update-memory.py` does NOT exist** (graceful fallback):

For each finding F routed to M:
1. Read M. Search for existing entry where description[:50].lower() matches F.description[:50].lower() AND file = F.file AND function = F.function.
2. Match found (status: open) → update last-seen + increment occurrences.
3. Match found (status: resolved) → move back to open, add RECURRED note.
4. No match → append new entry.

Note: No resolved sweep. A finding absent from this audit may simply not have been in scope for this task. Automatic resolution would corrupt memory for findings from other tasks. Findings accumulate until a task explicitly confirms they are fixed across multiple audit cycles.

Print: "Agent memories updated — security ([N] open), architect ([N] open), qa ([N] open)."

**Step 4.1 — Ask Max before closing:**

Print:
─────────────────────────────────────────────────────────────
  Task #[TASK_NUM] passed audit. WorldClass: [score]/100 | Cycles: [N]
  Mark it complete and start the next task?

    yes → mark #[TASK_NUM] complete, start next task
    no  → leave #[TASK_NUM] open, stop here
─────────────────────────────────────────────────────────────

Wait for user input.

If **no**: stop. Task remains In Progress.

If **yes**:

  **Step 4.1a — Carry-Forward Gate:**

  Read the `**WorldClass deductions —**` block from the current task entry in `.autocode/tasks.md`. Extract all deduction lines with severity ≥ 4. If no such block exists, or no lines with severity ≥ 4 are found: skip this step entirely and proceed to /reflect.

  If 4 or more severity ≥ 4 deductions exist, print first:
  `⚠️ [N] carry-forwards from a single task — consider whether task scope was too broad.`

  Present to Max:
  ```
  ──────────────────────────────────────────────────────
    CARRY-FORWARD GATE — [N] gaps from Task #[TASK_NUM]
  ──────────────────────────────────────────────────────
    WorldClass score: [COMBINED_SCORE]/100

    [1] CARRY-FORWARD | severity [N] | [category]: [description] (-[N] pts)
    [2] CARRY-FORWARD | severity [N] | [category]: [description] (-[N] pts)
    ...

    All severity ≥ 4 items default to CARRY-FORWARD (added to end of Batch [N]).
    Override any item before continuing:
      debt [N] [reason]  → ACCEPTED-DEBT (logged to debt.md, requires reason)
      ok                 → accept all defaults and continue
  ──────────────────────────────────────────────────────
  ```

  Wait for input. Process overrides.

  For each CARRY-FORWARD item:
  - Determine NEXT_NUM: find the highest `### Task #` number in `.autocode/tasks.md` and increment by 1 per new task
  - Find the last `### Task #` entry in the current `## Batch [N]` section (the batch containing Task #[TASK_NUM])
  - Insert a new task block immediately after it (before any `## Batch [N+1]` header):
    ```
    ### Task #[NEXT_NUM]
    **Carry-Forward from Task #[TASK_NUM] — [original task title, first line only]**
    Resolve the [category] WorldClass gap: [exact deduction description]. Target: eliminate the -[N]pt deduction.
    **Complexity: Direct**
    **Owner:** [same owner as Task #[TASK_NUM]]
    **File:** [same file(s) as Task #[TASK_NUM]]
    **Added:** Carry-forward — [today's date] — WorldClass score was [COMBINED_SCORE]/100
    ```
  - Append to `.autocode/carry-forward-log.md` (create with header `# Carry-Forward Log\n| Date | Source Task | CF Task | Category | Description | Severity |\n|------|------------|---------|----------|-------------|---------|` if not exists):
    `| [today's date] | Task #[TASK_NUM] | Task #[NEXT_NUM] | [category] | [description] | [severity] |`

  For each ACCEPTED-DEBT item:
  - Append to `.autocode/debt.md` (create with header `# Accepted Technical Debt\n| Date | Source Task | Category | Description | Severity | Complexity | Reason |\n|------|------------|---------|-------------|---------|-----------|---------|` if not exists):
    `| [today's date] | Task #[TASK_NUM] | [category] | [description] | [severity] | [run COMPLEXITY_EVAL on description → Direct/Full] | [reason provided] |`

  **Auto-log minor deductions (severity 1-3, silent — no gate, no tasks):**
  Re-read the `**WorldClass deductions —**` block and extract all lines with severity 1-3. For each:
  - Run COMPLEXITY_EVAL on the deduction description
  - Append to `.autocode/debt.md` (same schema as above — create if not exists):
    `| [today's date] | Task #[TASK_NUM] | [category] | [description] | [severity] | [Direct/Full from COMPLEXITY_EVAL] | auto — minor WorldClass deduction |`
  No prompt. No output. Silent append only.

  Print: `✓ Carry-forward: [N] task(s) added to end of Batch [N] (#[NUM1], #[NUM2], ...) | Accepted debt: [N] item(s) logged | Minor deductions: [N] item(s) auto-logged to debt.md`

  Run: `/reflect Task #[TASK_NUM]: [TASK_DEFINITION first line]`
  Edit `.autocode/tasks.md`: add `**Status: COMPLETE — [today's date]**` below Task #TASK_NUM Owner line.
  If a `**Audit findings —` or `**WorldClass deductions —` block exists in this task: remove it — findings are resolved.
  Update cto.md Task Cycle Log: change `Status: In Progress | Cycle N` → `Status: COMPLETE | Cycle N | Completed: [today's date]`
  Proceed to Step 4.2.

**Step 4.2 — Patterns graduation check:**
If `scripts/check-patterns-threshold.sh` exists:
Run: `bash scripts/check-patterns-threshold.sh .autocode/patterns.md`
- Exit 0: no threshold crossed — task cycle complete.
- Exit 1: one or more finding categories have crossed the graduation threshold (3+ occurrences, avg severity ≥ 6).
  Print to Max:
  ```
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    PATTERNS THRESHOLD CROSSED
    [paste script output verbatim]

    Recurring findings are ready to become Rules.
    Run: /patterns   (you decide yes/no on each proposed Rule)
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ```
  Do NOT auto-run /patterns. Signal to Max, let Max decide.
- Script not found: skip silently.

**Step 4.3 — Batch completion survey:**

Read `.autocode/tasks.md`. Find which `## Batch N` section contains `Task #[TASK_NUM]`.

Count all `### Task #` entries in that batch section.
Count how many have `**Status: COMPLETE` in their block.

If ALL tasks in the batch are COMPLETE:
  Run: `/team-health scan batch-[BATCH_NUM]-complete`

  The survey updates `.autocode/map.md` with the current state of all three layers (pieces, modules, app). If the survey output includes PROPOSED ADDITIONS: review them and add any with severity ≥ 5 to the next BACKLOG batch in `.autocode/tasks.md`.

  Before writing each proposed task, run COMPLEXITY_EVAL on its description:
  DIRECT if ALL: (a) ≤ 20 words, (b) contains a cosmetic keyword (typo/comment/rename/update text/fix label/add log/remove unused/clarify/whitespace/formatting), (c) contains none of: auth/security/database/migration/schema/api route/endpoint/feature flag/implement/integrate/webhook/redis/queue/worker/payment/order/multi-file.
  FULL otherwise (default when in doubt).
  Write `**Complexity: Direct**` or `**Complexity: Full**` on each task entry before the Owner line.

  Note each added task: "Added by layer survey — Batch [N] complete — [today's date]".

  Print:
  ```
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    BATCH [N] COMPLETE — Layer survey run.
    Map updated: .autocode/map.md
    Next: /task #[next open task number]
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ```

If not all tasks in the batch are COMPLETE: skip silently — survey fires only at full batch boundaries.

**Debt threshold check (runs every task close, not just batch boundaries):**

Read `.autocode/debt.md`. Count total data rows and rows per category. If the file doesn't exist: skip.

If any category has 5 or more entries, OR total rows ≥ 15:
```
┌──────────────────────────────────────────────────────────────┐
│  DEBT THRESHOLD REACHED                                      │
│  [category]: [N] items  (threshold: 5 per category)         │
│  — and/or —                                                  │
│  Total: [N] items  (threshold: 15)                           │
│                                                              │
│  Consider adding a debt-clearing task to the next batch.     │
│  Run /tasks debt to review all items.                        │
└──────────────────────────────────────────────────────────────┘
```
Do NOT auto-create a task. Surface the warning; Max decides whether to act.

If below threshold: silent.

**Step 4.4 — Post-completion triage:**

Runs immediately after Step 4.3 — whether or not a batch just completed. Three passes over all non-COMPLETE tasks. The just-completed task's TASK_DEFINITION is the reference for Passes 1 and 2.

**Pass 1 — Label audit (mechanical):**

Scan every non-COMPLETE task in `.autocode/tasks.md`. For each:
- If no `**Complexity:**` field: run COMPLEXITY_EVAL (same rule as Step 4.3). Write `**Complexity: Direct**` or `**Complexity: Full**` before the `**Owner:**` line.
- If `**Complexity: Full**` but the description is now ≤ 20 words: re-run COMPLEXITY_EVAL. If it qualifies as Direct, update the label and add a note below `**Owner:**`: `**Label updated:** Full → Direct — [today's date] — [one-line reason]`

Do not upgrade Direct → Full based on description length alone — only downgrade.

**Pass 2 — Obsolescence and scope sweep (judgment):**

For each non-COMPLETE task, compare its description against what Task #[TASK_NUM] actually shipped:

- **Fully redundant** — the completed task shipped the same fix at the same location (same file, same function, same defect class): mark COMPLETE with `**Status: COMPLETE — [today's date] — Resolved by Task #[TASK_NUM]: [one sentence why]**`
- **Scope reduced** — the completed task addressed part of this open task (e.g., refactored the module this task was going to refactor, making the remaining work narrower): narrow the task description to only what remains, re-run COMPLEXITY_EVAL on the updated description, update the label if it changed. Add: `**Scope narrowed:** [today's date] — [what was already addressed by Task #[TASK_NUM]]`
- **Unaffected** — no overlap: leave as-is, no annotation

Print only if anything changed in Pass 1 or 2:
```
─────────────────────────────────────────────────────────────
  TRIAGE — after Task #[TASK_NUM]
  Labels written: [N] (tasks that had no Complexity field)
  Labels updated: [N] (Full → Direct)
  Resolved by completion: Task #NNN — [reason]
  Scope narrowed: Task #NNN — [what changed]
─────────────────────────────────────────────────────────────
```
If nothing changed in either pass: silent.

**Pass 3 — Priority reorder (CTO discretion):**

Read all non-COMPLETE tasks from `.autocode/tasks.md` (across all batches). Read the current survey output (from Step 4.3 if it ran, or `.autocode/map.md` if it exists), agent memories, and AUDIT_TRENDS.

**Priority reasoning — apply in this order:**

1. **Dependency lock:** A task cannot move before any task it is "Blocked by." This is a hard constraint — never violated.

2. **Elevation triggers** (move task to an earlier batch):
   - Task addresses a gap just found by the layer survey (piece, module, or E2E gap flagged this cycle)
   - Task is security or auth category AND a security finding appeared in the most recent audit
   - Task has severity ≥ 8 AND is not in the current sprint batch
   - A pattern in `.autocode/patterns.md` directly implicates this task's file or module

3. **Demotion triggers** (move task to a later batch):
   - Task has severity ≤ 3 AND nothing blocks it AND nothing depends on it
   - Task addresses a module the survey just confirmed is healthy (good coverage, integration test exists)
   - Task is a documentation or polish task when critical security or QA gaps are open

4. **Default:** If no trigger applies, leave the task where it is. Do not reorder for its own sake.

**How to reorder:**
- Move tasks by changing which `## Batch N` section they appear in within tasks.md.
- Task numbers are NEVER changed — #007 stays #007 regardless of which batch it's in.
- Batch headers (theme, dependency statement) must be updated if the composition changes significantly.
- If a task moves, add a one-line note below its `**Owner:**` line: `**Moved:** Batch [from] → Batch [to] — [one sentence reason] — [today's date]`

**Print only if anything moved:**
```
─────────────────────────────────────────────────────────────
  PRIORITY REORDER — [N] task(s) moved
  Task #NNN: Batch X → Batch Y — [reason]
  Task #NNN: Batch X → Batch Y — [reason]
─────────────────────────────────────────────────────────────
```

If nothing moved: print nothing. The reorder is silent when the list is already in the right order.

**Step 4.5 — Start next task:**

Scan `.autocode/tasks.md` top to bottom. Find the first `### Task #` block that does NOT contain `**Status: COMPLETE`. That is NEXT_TASK_NUM.

If NEXT_TASK_NUM found: run `/task #[NEXT_TASK_NUM]`.

If no open tasks remain:
─────────────────────────────────────────────────────────────
  All tasks complete. Run /team-health to see the full picture.
─────────────────────────────────────────────────────────────

---

## ESCALATION

Append to `.autocode/agents/cto.md` `## Open Escalations`:
```
### [today's date] | Task #[TASK_NUM]: [TASK_DEFINITION first line]
Trigger: [CYCLE_LIMIT_EXCEEDED / REPEATED_FINDING: "[text]" in cycles N,N-1,N-2 / SEVERITY_ESCALATING / REGRESSION_PATTERN]
Cycles run: [N]
Unresolved findings (severity ≥ 5):
[list from most recent audit]

Cycle history summary:
[one line per cycle: what was tried, what audit found]

Options:
A) Continue with focused fix on [specific blocker] — estimated N more cycles
B) Accept current state with monitoring: [specific monitoring plan for unresolved finding]
C) Redesign [specific component that unresolved finding lives in]

Recommendation: [A/B/C] — [one sentence rationale]
Decision needed from: Max
```

Print:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ESCALATION — Task #[TASK_NUM]
  Trigger: [reason]
  Cycles run: [N]
  Unresolved: [top 3 findings]

  Escalation brief written to .autocode/agents/cto.md
  Run /team-health to see the full escalation queue.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Stop. Do not call /reflect on escalated tasks.

---

## RULES

- FORBIDDEN from writing code directly — all code changes go through /autocode
- FORBIDDEN from making code quality judgments — that is /audit's job
- FORBIDDEN from skipping the BUILD GATE — BUILD_RESULT PASS required before calling /audit
- FORBIDDEN from skipping Done When verification — run it or mark DEFERRED, never omit
- FORBIDDEN from closing a cycle log without "Fixed this cycle" and "Still open" fields
- FORBIDDEN from calling /reflect on escalated tasks
- Escalate on trigger conditions — do not absorb and keep cycling
- Cycle log is permanent — write it honestly even when nothing was fixed
- "Build approach" in the cycle log MUST include specific file:function:line — reject vague entries
