# WorldClass — Quality Score Loop

You are running a world-class quality check. The task is: $ARGUMENTS

This command scores the code on two independent lenses (Architecture + Vibes), shows exactly where points are lost, and loops through remediation until the combined score reaches 95/100 or 5 cycles are exhausted.

---

## PHASE 0: SETUP

Run in the orchestrating session:

```
mkdir -p .autocode
```

Read `~/.claude/autocode/philosophy.md` in full. Capture as `PROJECT_PHILOSOPHY`.

**Invocation mode detection:**
If $ARGUMENTS starts with `Task #` (called by /task as `Task #001: description`): `MODE = "orchestrated"`. Extract TASK_NUM from the `#NNN` portion.
Otherwise: `MODE = "standalone"`. If $ARGUMENTS contains a task number (`#\d+` or bare integer): extract as TASK_NUM. If no task number found: TASK_NUM = nil.

If `scripts/deep-audit.sh` exists, run it on the changed files before scoring.
If `scripts/shipping-gate.sh` exists, run it on the changed directory before scoring.

Extract primary terms from $ARGUMENTS (nouns, verbs, domain concepts — e.g. "fix retry logic in SMS sender" → terms: retry, sms, sender).

Read `.autocode/patterns.md`. Count occurrences per category. Extract categories with 3+ occurrences and their 2 most recent descriptions. Capture as `KNOWN_DRIFTS`. If the file doesn't exist or no category reaches 3 occurrences: `KNOWN_DRIFTS = "None yet."`

Read `.autocode/reflections.md`. Search for entries whose task description contains any of the extracted terms. Take the 2 most recent matching entries verbatim. Capture as `REFLECTION_LOG`. If no matches found or file doesn't exist: `REFLECTION_LOG = "None yet."`

Read `.autocode/requirements.md`. Search for an entry whose task description matches $ARGUMENTS. If found, extract its Section 1 (Acceptance Criteria) verbatim. Capture as `ACCEPTANCE_CRITERIA`. If not found: `ACCEPTANCE_CRITERIA = "Not available."`

Read `.autocode/agents/security.md` → `MEMORY_SECURITY` (or "None").
Read `.autocode/agents/architect.md` → `MEMORY_ARCHITECT` (or "None").
Read `.autocode/agents/qa.md` → `MEMORY_QA` (or "None").
Read `.autocode/agents/cto.md` → `CTO_MEMORY` (or "None").
Extract known blind spots per agent from CTO_MEMORY as `CTO_INTELLIGENCE`.

Read `.autocode/project-profile.md` → `PROJECT_PROFILE` (or "Unknown — run /meet to detect stack.").

**Step A — FULL_DIFF (history-aware diff)**

Run: `git log --oneline -10`

Check each commit message for terms matching $ARGUMENTS.
- If 1+ commits match: note the commit hash immediately BEFORE the first matching commit.
  Run: `git diff [that-hash]..HEAD`
  Note in context: "Diff spans N commits back to [hash]."
- If no commits match OR no `.git` directory exists:
  Run: `git diff HEAD` (uncommitted changes)
  If that is empty: `git diff HEAD~1` (last commit's changes)

Capture result as `FULL_DIFF`.

**Step B — TASK_SCOPE (full task area)**

Run: `git diff [FULL_DIFF range] --name-only`
Capture as DIFF_FILES.

If `TASK_DEFINITION` includes a `File:` field, add those files to DIFF_FILES. These are task-anchored files — always included regardless of diff.

Expand DIFF_FILES to CANDIDATE_FILES by adding:

1. CO-LOCATED TESTS — for each file in DIFF_FILES, check if a test file exists alongside it:
   Run: `ls [dirname]/[basename].test.ts [dirname]/[basename].test.tsx 2>/dev/null`
   Add any found.

2. DIRECT IMPORTS WITHIN PACKAGE — for each file in DIFF_FILES, extract its import statements:
   Run: `grep -E "^import .* from '\.\." [filepath] | head -20`
   For each relative import path that resolves to a file in the same package (not node_modules): add that file. Cap at 3 imports per changed file.

Filter CANDIDATE_FILES: remove `node_modules/`, `.git/`, `dist/`, `build/`, `*.min.js`, `*.d.ts`, `*.map`.

Deduplicate. If more than 15 files remain: prioritize task-anchored files first → diff files → co-located tests → direct imports → files named after task terms.

Cap at 15 files.

For each file:
- ≤500 lines: read in full
- >500 lines: read first 300 lines + last 100 lines. Insert at the break point: `[FILE TRUNCATED — N total lines. Showing first 300 + last 100.]`

Capture as:
```
TASK_SCOPE:
=== [filepath] (N lines[, TRUNCATED]) ===
[contents]
=== [filepath] ===
[contents]
[...repeat...]
```

If FULL_DIFF is empty and no files are identified: `TASK_SCOPE = "No changed files detected."`

**Step C — CALLER_CONTEXT (files that call into the changed code)**

For each file in DIFF_FILES: extract the basename without extension (e.g., `sms-sender` from `apps/worker/src/sms-sender.ts`).

Run for each basename:
```
grep -r "from '.*[basename]'" --include="*.ts" --include="*.tsx" -l .
grep -r "require.*[basename]" --include="*.ts" --include="*.tsx" -l .
```

Exclude from results: `node_modules/`, `.git/`, `.autocode/`, the changed file itself. Take the 3 closest results per file (prefer same directory → parent → sibling directories).

Deduplicate. Cap total at 12 caller files.

For each caller file: read in full.
- ≤500 lines: read in full
- >500 lines: read first 300 lines + last 100 lines. Insert: `[FILE TRUNCATED — N total lines. Showing first 300 + last 100.]`

If no callers found: `CALLER_CONTEXT = "No direct callers identified in codebase."`

Capture as:
```
CALLER_CONTEXT:
=== [filepath] (caller of [changed-file]) ===
[contents]
[...repeat...]
```

Do not spawn any scoring agent until FULL_DIFF, TASK_SCOPE, and CALLER_CONTEXT are all captured.

---

## PHASE 1: SCORE

Spawn scoring agents simultaneously: Agent 1 (Architecture) and Agent 2 (Vibes) always run. Agent V (Acceptance Criteria) runs if `ACCEPTANCE_CRITERIA ≠ "Not available."` — if not available, set `AC_RESULT: {"met": 0, "not_met": 0, "partial": 0, "verdict": "SKIPPED"}` and proceed with two agents only.

---

**Scoring Agent 1 — Architecture (60% weight)**

Spawn an independent agent with this prompt:

"You are a senior software architect. Your job is not to run a checklist — it is to read.

Read every line of every file below, from line 1 of the first file to the last line of the last file.
Do not skim. Do not summarize sections. Read every line.

PROJECT PHILOSOPHY — the standard this codebase holds itself to:
[PROJECT_PHILOSOPHY]

PROJECT PROFILE — the stack and deployment model:
[PROJECT_PROFILE]

TASK SCOPE — full current state of every file in this task area:
[TASK_SCOPE]

CODE DIFF — what changed:
[FULL_DIFF]

CALLER CONTEXT — files that call into this code:
[CALLER_CONTEXT]

ARCHITECTURE AGENT MEMORY — prior open findings on this codebase:
[MEMORY_ARCHITECT]

KNOWN BLIND SPOTS:
[CTO_INTELLIGENCE]

PRIOR CYCLE FINDINGS:
[CYCLE_HISTORY — or 'None — first cycle / standalone']

As you read each line, ask one question: is this how a senior engineer at a world-class company would write this?

Not whether it compiles. Not whether tests pass. Whether a senior engineer reading this line would be quietly impressed or quietly disappointed.

Start at 100. Deduct for anything that falls short.

For every deduction:
- Name exactly what it is (file:function:line)
- Explain what a world-class implementation would look like instead
- Category (one of: error-handling, tests, auth, security, data-loss, feature-flag, async, edge-case, code-quality, performance)
- Points deducted and severity (1=style, 5=fragile logic, 7=real bug, 9=data loss)

FORBIDDEN: 'this looks correct', 'appears to be fine', 'seems well-implemented'.
FORBIDDEN: giving high scores to code that merely works. Working is the minimum bar.
FORBIDDEN: deducting for style preferences without a specific quality gap.
FORBIDDEN: skipping prior open findings from MEMORY_ARCHITECT without explicitly noting resolved or still open.

Be ruthless. 95+ means genuinely world-class. 80 means real problems exist. Do not round up.

Output your deductions list, then this line exactly:
ARCHITECTURE_SCORE: N"

Capture Agent 1's deductions and ARCHITECTURE_SCORE.

---

**Scoring Agent 2 — Vibes (40% weight)**

Spawn a second independent agent simultaneously with this prompt:

"You are a world-class engineer doing a gut-check. Your job is not to run a checklist — it is to read.

Read every line of every file below, from line 1 of the first file to the last line of the last file.
Do not skim. Do not summarize sections. Read every line.

TASK SCOPE — full current state of every file in this task area:
[TASK_SCOPE]

CODE DIFF — what changed:
[FULL_DIFF]

CALLER CONTEXT — files that call into this code:
[CALLER_CONTEXT]

As you read, hold one question: is this enterprise-grade?

Would this code hold up in production for 3 years, maintained by a team that didn't write it?
Would a senior engineer inheriting this be grateful or burdened?
Does every function do exactly what its name says — nothing more, nothing hidden?
Are the tests proving real behavior, or going through the motions?
Is anything written to look done rather than to be done?

Start at 100. Deduct for anything that makes you pause. If it made you pause — that is a finding.

For every deduction:
- Name exactly what it is (file:function:line)
- Explain the specific gap — not 'this could be cleaner', but what is actually wrong
- Category (one of: error-handling, tests, auth, security, data-loss, feature-flag, async, edge-case, code-quality, performance)
- Points deducted and severity (1=style, 5=fragile logic, 7=real bug, 9=data loss)

FORBIDDEN: 'looks good', 'appears correct', 'seems fine', 'probably fine in practice'.
FORBIDDEN: giving high scores to code that merely compiles and passes tests.
FORBIDDEN: skipping something that made you pause.

Be ruthless. 95+ means genuinely excellent craft. Do not be kind.

Output your deductions list, then this line exactly:
VIBES_SCORE: N"

Capture Agent 2's deductions and VIBES_SCORE.

---

**Scoring Agent V — Acceptance Criteria (independent gate)**

Skip this agent and use `AC_RESULT: {"met": 0, "not_met": 0, "partial": 0, "verdict": "SKIPPED"}` if `ACCEPTANCE_CRITERIA = "Not available."`

Otherwise, spawn a third independent agent simultaneously with this prompt:

"You are a requirements verifier. Do NOT judge code quality — other agents do that.
Your ONLY job: determine whether the built code actually satisfies the acceptance
criteria that were defined before building began.

Task: $ARGUMENTS

ACCEPTANCE CRITERIA:
[ACCEPTANCE_CRITERIA]

TASK SCOPE — full current state of built code:
[TASK_SCOPE]

CODE DIFF — what was changed:
[FULL_DIFF]

TOYOTA EVIDENCE RULE: For every acceptance criterion, your verdict MUST cite specific
evidence from the code. 'MET — looks correct' is INVALID. You must cite:
  - The file path and function/handler that implements the behavior
  - The test file path and test name that verifies the PASS CONDITION
  - The specific assertion in that test

You are FORBIDDEN from writing:
  - Any MET verdict without a file path AND a test name
  - 'The code appears to handle this'
  - 'MET — implementation looks complete'
  - Skipping any acceptance criterion

If you cannot find the code that satisfies a criterion, that criterion is NOT MET.
If you cannot find a test that verifies the PASS CONDITION, that criterion is PARTIALLY MET
at best, and you must say what test is missing.

---

For each acceptance criterion:

  AC[N]: [criterion text]
  VERDICT: MET / NOT MET / PARTIALLY MET
  IMPLEMENTATION EVIDENCE: [file:function] — [one sentence explaining what this code does]
  TEST EVIDENCE: [test-file:test-name] — [what assertion it makes that proves the PASS CONDITION]
  If NOT MET or PARTIALLY MET:
    MISSING: [exactly what implementation or test is absent]

---

Then output this line exactly:
AC_RESULT: {\"met\": N, \"not_met\": N, \"partial\": N, \"verdict\": \"PASS or FAIL\"}

verdict is PASS only if not_met = 0 AND partial = 0."

Capture Agent V's findings and AC_RESULT.

---

## PHASE 2: CALCULATE AND DECIDE

Once all scoring agents have responded, calculate in the orchestrating session:

```
COMBINED_SCORE = round((ARCHITECTURE_SCORE × 0.6) + (VIBES_SCORE × 0.4))
```

Print the full scorecard:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  WORLDCLASS SCORE — Cycle [N]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Architecture (60%):  [ARCHITECTURE_SCORE]/100
  Vibes        (40%):  [VIBES_SCORE]/100
  ─────────────────────────────────────
  Combined:            [COMBINED_SCORE]/100
  Target:              95/100
  Acceptance Criteria: [N met]/[N total] — [PASS / FAIL / SKIPPED]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Architecture deductions:
[Agent 1's full deductions list]

Vibes deductions:
[Agent 2's full deductions list]

Acceptance Criteria findings:
[Agent V's full findings, or "SKIPPED — no requirements.md entry for this task"]
```

**Log deductions to `.autocode/patterns.md`:**

After printing the scorecard, log every deduction with severity ≥ 4 from both agents:

```
## [today's date] | Task: $ARGUMENTS — WorldClass cycle [N]
- [category] [description of deduction] — severity [N] | worldclass: -[N] pts | WORLDCLASS
```

Architecture deductions use the category the agent tagged. Vibes deductions use the category the agent tagged (usually `code-quality`). If `.autocode/patterns.md` does not exist, create it with `# AutoCode Patterns Log` header first.

---

## DECISION LOGIC

**If COMBINED_SCORE ≥ 95 AND AC_RESULT verdict = PASS (or SKIPPED):**

**Write agent memory updates:**
Append to `.autocode/agents/architect.md` → `## Past Findings — Resolved`: any architecture deductions from this cycle that scored < 95 in prior cycles but are now resolved.
Append to `.autocode/agents/qa.md` → `## Past Findings — Resolved`: any QA deductions that are now resolved.
Append to `.autocode/agents/security.md` → `## Past Findings — Resolved`: any security deductions now resolved.

Run the Documentation Gate (see below).

Append to `.autocode/worldclass-trends.md`:
```
| [today's date] | [first 60 chars of $ARGUMENTS] | [N cycles] | [COMBINED_SCORE] | PASS |
```
If `.autocode/worldclass-trends.md` does not exist, create it with this header first:
```
# WorldClass Score Trends
| Date | Task | Cycles | Final Score | Verdict |
|------|------|--------|-------------|---------|
```

Print:
```
✅ World-class.
Architecture: [N]/100 | Vibes: [N]/100 | Combined: [N]/100
Acceptance Criteria: [N met]/[N total] — [PASS / SKIPPED]
Task: $ARGUMENTS
```

WORLDCLASS_RESULT: {"score":[COMBINED_SCORE],"verdict":"PASS","cycles_run":N}
Stop. Control returns to /task (or to Max if run standalone).

**If COMBINED_SCORE ≥ 95 AND AC_RESULT verdict = FAIL:**

Print:
```
⚠️ Score is world-class but acceptance criteria failed.
Combined: [COMBINED_SCORE]/100 — AC FAIL: [not_met] not met, [partial] partial
```
Trigger the Remediation Plan Loop. Pass unmet/partial AC items as `UNMET_ACCEPTANCE_CRITERIA` to the plan agents.

**If COMBINED_SCORE < 95 AND fewer than 5 cycles have run:**

Print how many points need to close and which deductions account for the largest gap. Include any AC failures in the gap summary. Then trigger the Remediation Plan Loop below.

**If 5 cycles have been reached without hitting 95:**

Append to `.autocode/worldclass-trends.md`:
```
| [today's date] | [first 60 chars of $ARGUMENTS] | 5 | [COMBINED_SCORE] | MAX_CYCLES |
```

WORLDCLASS_RESULT: {"score":[COMBINED_SCORE],"verdict":"MAX_CYCLES","cycles_run":5}

**Write escalation brief to CTO memory:**

Read `.autocode/agents/cto.md`. Append to `## Open Escalations`:
```
### [today's date] | WorldClass — Task: $ARGUMENTS
Problem: [the top deduction category preventing 95 — not "quality issues"]
Cycles: 3 (maximum reached)
Score: [COMBINED_SCORE]/100 | Gap: [95 - COMBINED_SCORE] points

Unresolved deductions:
[list deductions ≥ -3 pts from most recent scoring cycle]

Options:
A) Continue with targeted fix on [top deduction] — estimated 1 more cycle
B) Accept current score of [COMBINED_SCORE]/100 and proceed
C) Redesign [specific area] — eliminates [deduction category] permanently

Recommendation: [A/B/C] — [one sentence rationale]
Decision needed from: Max
```

Print:
```
⚠️ Max cycles reached.
Final score: [COMBINED_SCORE]/100 (target: 95)
Escalation brief written to .autocode/agents/cto.md
Run /team-health to see the full escalation queue.

Outstanding deductions:
[list the remaining deductions from the most recent scoring cycle]
```

If `MODE = "standalone"` AND TASK_NUM is set:
  Open `.autocode/tasks.md`. Find the `### Task #[TASK_NUM]` block.
  Find the line immediately after the `**Owner:**` line.
  Remove any existing `**WorldClass deductions —` block if present.
  Insert:
    `**WorldClass deductions — [today's date]** ([95 - COMBINED_SCORE] pts from 95, [N] deductions pending fix):`
    For each deduction ≥ -2 pts from the most recent scoring cycle (Architecture and Vibes combined):
    `- [category] [description] — severity [N] (-[pts] pts)`
  Print:
  ─────────────────────────────────────────────────────────────
    WorldClass: [COMBINED_SCORE]/100 (need 95). Deductions written to Task #[TASK_NUM].
    Send to the dev team to close the gap?

      yes → /task #[TASK_NUM] starts a fix cycle now
      no  → stop here, review deductions above first
  ─────────────────────────────────────────────────────────────
  Wait for user input.
  If no: stop.
  If yes: run `/task #[TASK_NUM]`. Stop.

Stop.

---

## DOCUMENTATION GATE

Triggered after a PASS verdict (COMBINED_SCORE ≥ 95 AND AC_RESULT = PASS or SKIPPED). Non-blocking — control returns to caller regardless of DOCS_RESULT.

**Significance check:** Skip this gate if FULL_DIFF touches fewer than 3 files AND adds no new route, module, or feature flag change. Small bug fixes do not require documentation updates.

If significant, spawn a single agent:

"You are a documentation auditor. Your job: verify that the project's session-startup
documentation reflects what was just built.

Task that was completed: $ARGUMENTS

WHAT WAS BUILT:
[FULL_DIFF]

CURRENT CLAUDE.md (first 300 lines):
[first 300 lines of CLAUDE.md]

CURRENT STATUS.md (first 200 lines):
[first 200 lines of docs/STATUS.md]

THE TEST: If a new Claude Code session started right now, with no context except CLAUDE.md
and STATUS.md, would it know:
  1. That this feature exists and is live?
  2. What it does and any critical constraints?
  3. Any new modules, packages, or files added by this task?
  4. Any changes to the system architecture or data flow?

Apply this test literally. Do not assume context exists that isn't in the files above.

MANDATORY FORMAT:

DOCS CHECK — CLAUDE.md:
VERDICT: CURRENT / STALE
If STALE: [exact text that should be added, and which section it belongs in]

DOCS CHECK — STATUS.md:
VERDICT: CURRENT / STALE
If STALE: [exact text that should be added, and which section it belongs in]

DOCS_RESULT: {\"status\": \"CURRENT or STALE\", \"gaps\": N}

You are FORBIDDEN from:
  - Writing CURRENT without confirming the specific feature appears in the file by name
  - Writing 'documentation appears sufficient'
  - Skipping either file"

If DOCS_RESULT status = STALE, print:

```
DOCUMENTATION WARNING: [N] documentation gap(s) found.
The code has passed all quality gates. Update before the next session:
[gaps list with exact text to add and which section]
```

Log to `.autocode/patterns.md` under `documentation` category (severity 3).

Return control to caller regardless of DOCS_RESULT. If running standalone (not called by /task), run `/reflect $ARGUMENTS`.

---

## REMEDIATION PLAN LOOP

Triggered when COMBINED_SCORE < 95. Takes both agents' deduction lists as input. Four independent agents in sequence — no pause after the fourth, go straight to writing code.

**Agent 1 — Initial Remediation Plan**

Spawn an independent agent with this prompt:

"You are a senior software architect. Here are the quality deductions that must be addressed to reach world-class (95/100):

Architecture deductions (60% weight):
[Agent 1's deductions from most recent scoring cycle]

Vibes deductions (40% weight):
[Agent 2's deductions from most recent scoring cycle]

UNMET ACCEPTANCE CRITERIA — These must also be satisfied. Address as first-priority fixes if any exist:
[AC_RESULT unmet/partial items from Agent V, or "None — AC was SKIPPED or all criteria MET"]

Current score: [COMBINED_SCORE]/100. Need: 95/100. Gap: [95 - COMBINED_SCORE] points.

SLOW-CODING TOYOTA SYSTEM PHILOSOPHY — Every fix must comply with this:
[PROJECT_PHILOSOPHY]

KNOWN DRIFTS — These categories have recurred 3+ times in previous runs on this codebase. Each fix must include a specific countermeasure — not a general acknowledgment:
[KNOWN_DRIFTS]

PAST REFLECTIONS ON RELATED TASKS — Domain-specific lessons from similar past work. Apply these directly — do not re-learn what is already known:
[REFLECTION_LOG]

Code diff for context:
[FULL_DIFF]

Put together a specific remediation plan. Prioritize deductions by point value — close the biggest gaps first. For each fix, be specific: which file, which line, exactly what to change, and why that change closes the deduction.

Do not write a theoretical plan. Write exactly what code to change so there is no room for drift.

Produce a detailed remediation plan."

Capture Agent 1's plan output.

**Agent 2 — Revision 1**

Spawn an independent agent with this prompt:

"You are a senior software architect doing a critical review. The task is: $ARGUMENTS

SLOW-CODING TOYOTA SYSTEM PHILOSOPHY — The standard this plan must meet:
[PROJECT_PHILOSOPHY]

Here is a remediation plan just written to close a quality gap:

[Agent 1's plan]

Current score: [COMBINED_SCORE]/100. Target: 95/100.

Is this plan specific enough? Does every fix actually close the deduction it claims to close? Are there any fixes that look good on paper but won't actually move the score?

Find the specific weaknesses, call them out explicitly, then rewrite the plan to fix them."

Capture Agent 2's revised plan output.

**Agent 3 — Revision 2**

Spawn an independent agent with this prompt:

"You are a senior software architect doing a critical review. The task is: $ARGUMENTS

SLOW-CODING TOYOTA SYSTEM PHILOSOPHY — The standard this plan must meet:
[PROJECT_PHILOSOPHY]

Here is a remediation plan just written:

[Agent 2's plan]

Are any of the proposed tests pseudocode? Does every proposed fix actually address the root cause, or does it just mask the symptom? Will the vibes score actually improve, or are we only fixing mechanical rule violations?

Find the specific weaknesses, call them out explicitly, then rewrite the plan to fix them."

Capture Agent 3's revised plan output.

**Agent 4 — Final Pressure Test**

Spawn an independent agent with this prompt:

"You are a senior software architect doing a final pressure test. The task is: $ARGUMENTS

SLOW-CODING TOYOTA SYSTEM PHILOSOPHY — The standard this plan must meet:
[PROJECT_PHILOSOPHY]

Here is a remediation plan just written:

[Agent 3's plan]

Current score: [COMBINED_SCORE]/100. Target: 95/100.

After every fix in this plan is applied, will the code genuinely be world-class — or will the scoring agents still find problems? Are the vibes fixes real or cosmetic? Are the architecture fixes complete or partial?

Find the specific weaknesses, call them out explicitly, then produce the final remediation plan."

Capture Agent 4's final plan. Immediately proceed to the build phase — no pause.

---

## BUILD PHASE (after Remediation Plan Loop)

Implement Agent 4's remediation plan immediately. No pause.

- Write all fixes
- Write or update tests as needed
- Run tests — fix anything that fails before continuing
- If `scripts/deep-audit.sh` exists, run it on the changed files
- If `scripts/shipping-gate.sh` exists, run it on the changed directory

Do not proceed to re-scoring until tests are passing.

After tests pass, refresh task scope before the next scoring cycle:
Re-run Steps A, B, C to refresh FULL_DIFF, TASK_SCOPE, and CALLER_CONTEXT.
The remediation changed files — scoring agents must see the current state, not the pre-fix state.
Then return to PHASE 1.

---

## RULES

- Never round up scores — a 94.6 is not a 95
- Never skip a scoring cycle — the score must be re-earned, not assumed
- Never write a fix that doesn't address a specific deduction
- Both agents must score independently — never show Agent 2's prompt to Agent 1
- The combined score formula is always (Architecture × 0.6) + (Vibes × 0.4) — never deviate
- Log test failures to `.autocode/test-failures.md` using the same format as /autocode (Phase: WorldClass cycle N)
- If the gap to 95 is entirely in Vibes, the remediation plan must include real craft improvements — not just mechanical checklist fixes
- Never score without TASK_SCOPE and CALLER_CONTEXT captured — full file context is mandatory
- After every remediation build, refresh FULL_DIFF, TASK_SCOPE, and CALLER_CONTEXT before re-scoring
- AC_RESULT is an independent hard gate — COMBINED_SCORE ≥ 95 with AC_RESULT FAIL still triggers remediation
- Agent V must produce MET / NOT MET / PARTIALLY MET for every criterion with file:function AND test evidence — never "looks implemented"
- Documentation Gate is a warning, not a blocker — return control to caller regardless of DOCS_RESULT
- ACCEPTANCE_CRITERIA not available means Agent V skips — never invent acceptance criteria that weren't written before building
- FORBIDDEN from calling /reflect (caller handles it — /task calls /reflect; standalone mode calls it directly)
- Always emit WORLDCLASS_RESULT before stopping
