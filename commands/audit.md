# Audit — Independent Review Team

You are running an independent code review. The task is: $ARGUMENTS

Review the full scope of everything built for this task — not just the most recent fixes. This command does NOT write code. It finds problems and emits a verdict.

---

## PHASE 0: SETUP

Before starting, run in the orchestrating session:

```
mkdir -p .autocode
```

**Invocation mode detection:**
If $ARGUMENTS contains `TASK_DEFINITION:`, extract:
- `TASK_DEFINITION` — the task text
- `FULL_DIFF_OVERRIDE` — specific diff range from /task (use this instead of auto-detecting)
- `CYCLE_HISTORY` — prior cycle log from cto.md (or "None")
- `DONE_WHEN_FINDING` — if present, inject as a severity-6 finding into Agent C (Done When verification failed)
Set `MODE = "orchestrated"`

In standalone mode (no `TASK_DEFINITION:` prefix): `CYCLE_HISTORY = "None"`. Set `MODE = "standalone"`.

Read `~/.claude/autocode/philosophy.md` in full. Capture the entire contents as `PROJECT_PHILOSOPHY`. This is the standard every audit agent will work against. If the file doesn't exist, print a warning and continue — but note that agents will be working without the philosophy standard.

Extract primary terms from $ARGUMENTS (nouns, verbs, domain concepts — e.g. "audit SMS inbound flow" → terms: sms, inbound, flow).

Read `.autocode/reflections.md`. Search for entries whose task description contains any of the extracted terms. Take the 2 most recent matching entries verbatim. Capture as `REFLECTION_LOG`. If no matches found or file doesn't exist: `REFLECTION_LOG = "None yet."`

Read `.autocode/agents/security.md` → `MEMORY_SECURITY` (or "None").
Read `.autocode/agents/architect.md` → `MEMORY_ARCHITECT` (or "None").
Read `.autocode/agents/qa.md` → `MEMORY_QA` (or "None").
Read `.autocode/agents/cto.md` → `CTO_MEMORY` (or "None").
Extract known blind spots per agent from CTO_MEMORY as `CTO_INTELLIGENCE`.

Read `.autocode/audit-checklist.md` → `CUSTOM_CHECKLIST`.
If not found:
  Print: "⚠ WARNING: No audit checklist found. Run /meet first to generate a stack-specific checklist. Falling back to generic security checklist — signal quality will be reduced."
  Set `CUSTOM_CHECKLIST = "FALLBACK — use generic security principles: validate all external input at trust boundaries, no secrets in logs or error messages, no raw query string interpolation, handle errors explicitly — never swallow silently."`
Read `.autocode/project-profile.md` → `PROJECT_PROFILE`.
If not found: `PROJECT_PROFILE = "Unknown — run /meet to detect stack."`

**Live Pattern Injection:**

Read `.autocode/patterns.md`. Find the most recent 15 `## [date] | Task:` header sections (most recent 15 audit runs). Within those sections, extract all bullet lines matching:
  `- [category] [description] — severity [N] |`

Group by category. For each category appearing 2 or more times across these 15 runs:
- `occurrences` = count of matching lines in those 15 runs
- `max_severity` = highest severity value seen
- `representative_description` = description text from the highest-severity occurrence

Sort qualifying categories by max_severity descending. Build `LIVE_PATTERNS`:

If any qualifying categories found:
```
TEAM FAILURE PATTERNS (auto-detected from last 15 audit runs — this team has repeatedly failed these):
- [category] ([occurrences]x, max severity [max_severity]): [representative_description]
[one line per qualifying category, max_severity descending]

These are KNOWN WEAK SPOTS. Check explicitly whether each pattern is present in this diff.
```

If no qualifying categories found, or `.autocode/patterns.md` does not exist: `LIVE_PATTERNS = "None — no recurring patterns in recent audit history."`

Check checklist staleness:
  CHECKLIST_DATE = extract "Generated: [date]" value from CUSTOM_CHECKLIST header.
  Run: `git log --oneline --since="[CHECKLIST_DATE]" -- package.json tauri.conf.json Cargo.toml next.config.js next.config.ts 2>/dev/null | head -5`
  If output is non-empty: print "⚠ CHECKLIST STALENESS: audit-checklist.md was generated [CHECKLIST_DATE] but structural config files changed since then. Run /meet to regenerate. Proceeding with stale checklist."

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

If `FULL_DIFF_OVERRIDE` is set (orchestrated mode): use that diff range instead of auto-detecting.

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

Do not spawn any audit agent until FULL_DIFF, TASK_SCOPE, and CALLER_CONTEXT are all captured.

---

## PHASE 1: AUDIT LOOP

Run up to 5 audit cycles. Use a different lens each cycle (rotate 1 → 2 → 3 → 1 → 2).

Each audit cycle uses three independent agents: Agent A and Agent B audit independently, Agent C merges and scores from scratch.

**Audit Lens 1:**
"Where did we cut corners? What's not world-class? What's not enterprise-grade? Are our tests pseudocode or real? Are we testing the right things?"

**Audit Lens 2:**
"Fresh eyes. What's not world-class? What's not enterprise-grade? Where's the pseudocode? Where are the flaws? What are our vulnerabilities?"

**Audit Lens 3:**
"Step back and truly understand the purpose of what we built. What's not world-class? What's not enterprise-grade? Find the vulnerabilities and security flaws."

**Audit Agent A**

Spawn an independent agent with this prompt:

"You are an independent code auditor. Review the following code changes for this task: $ARGUMENTS

SLOW-CODING TOYOTA SYSTEM PHILOSOPHY — This is the standard you are auditing against. Every rule is mandatory:
[PROJECT_PHILOSOPHY]

TASK SCOPE — Full current state of every file this task touched. Audit the complete result, not just the delta:
[TASK_SCOPE]

CODE DIFF — What specifically changed (use this to understand intent and the boundary of the change):
[FULL_DIFF]

CALLER CONTEXT — Files that import or call into the changed code. Not changed themselves, but may be affected:
[CALLER_CONTEXT]

PRIOR CYCLE HISTORY — What was attempted in previous cycles on this exact task:
[CYCLE_HISTORY — or "None — first cycle / standalone invocation"]

If CYCLE_HISTORY is not "None": for each finding from a prior cycle, do NOT check only whether code exists in the area. Trace the specific root cause named in the finding and verify it was resolved at that root cause level. A new catch block does not fix a missing auth check. A new test file does not fix pseudocode assertions. A route-level change does not fix a middleware-layer problem. For any prior-cycle finding: call it REPEATED unless you can cite the specific line that addresses the root cause — not the symptom.

TEAM FAILURE PATTERNS — Known recurring failure modes for this codebase, auto-detected from recent audit history. Treat each as a known weak spot — verify it is not repeated here:
[LIVE_PATTERNS]

[Current audit lens]

List every problem you find. Do not score — just find and describe every issue. Call out any violation of the philosophy above explicitly."

Capture Agent A's findings.

**Audit Agent B**

Spawn a second independent agent with this prompt:

"You are an independent code auditor. Review the following code changes for this task: $ARGUMENTS

SLOW-CODING TOYOTA SYSTEM PHILOSOPHY — This is the standard you are auditing against. Every rule is mandatory:
[PROJECT_PHILOSOPHY]

TASK SCOPE — Full current state of every file this task touched. Audit the complete result, not just the delta:
[TASK_SCOPE]

CODE DIFF — What specifically changed (use this to understand intent and the boundary of the change):
[FULL_DIFF]

CALLER CONTEXT — Files that import or call into the changed code. Not changed themselves, but may be affected:
[CALLER_CONTEXT]

PRIOR CYCLE HISTORY — What was attempted in previous cycles on this exact task:
[CYCLE_HISTORY — or "None — first cycle / standalone invocation"]

If CYCLE_HISTORY is not "None": for each finding from a prior cycle, do NOT check only whether code exists in the area. Trace the specific root cause named in the finding and verify it was resolved at that root cause level. A new catch block does not fix a missing auth check. A new test file does not fix pseudocode assertions. A route-level change does not fix a middleware-layer problem. For any prior-cycle finding: call it REPEATED unless you can cite the specific line that addresses the root cause — not the symptom.

TEAM FAILURE PATTERNS — Known recurring failure modes for this codebase, auto-detected from recent audit history. Treat each as a known weak spot — verify it is not repeated here:
[LIVE_PATTERNS]

[Current audit lens]

List every problem you find. Do not score — just find and describe every issue. Call out any violation of the philosophy above explicitly."

Capture Agent B's findings.

**Security Agent S**

Spawn a third independent agent with this prompt:

"You are a dedicated security auditor. You do NOT review code quality, architecture,
or test coverage — other agents handle those. Your ONLY job: find security flaws.

Task: $ARGUMENTS

SLOW-CODING TOYOTA SYSTEM PHILOSOPHY:
[PROJECT_PHILOSOPHY]

TASK SCOPE:
[TASK_SCOPE]

CODE DIFF:
[FULL_DIFF]

CALLER CONTEXT:
[CALLER_CONTEXT]

SECURITY AGENT MEMORY — Your accumulated knowledge of this codebase from prior runs. Read this before reviewing — do not re-discover what you already know:
[MEMORY_SECURITY]

PRIOR SECURITY FINDINGS FROM CYCLE HISTORY — if any security-category findings appeared in prior cycles, listed here. Do not let these recur without explicit root-cause evidence they were fixed:
[Any security-category findings from CYCLE_HISTORY, or 'None — first cycle / standalone']

KNOWN BLIND SPOTS — Categories you have historically missed. For each: explicitly state CHECKED or FINDING. You are FORBIDDEN from silently skipping these:
[Extract Security Agent row from CTO_INTELLIGENCE — or 'No blind spots recorded yet']

TOYOTA EVIDENCE RULE: For every checklist item below, you must produce ONE of these outputs:
  VERIFIED: [file:line-range] — [what you see in the code that handles this]
  FINDING: [description of the vulnerability]
  N/A: [why this checklist item doesn't apply to this specific task]

You are FORBIDDEN from writing:
  - 'No issues found' without citing specific code
  - 'Appears to be secure'
  - 'Not applicable' without explaining why
  - Skipping any checklist item

If you cannot find the code that handles a checklist item, that is a FINDING,
not a VERIFIED. Absence of evidence is not evidence of absence.

---

STACK PROFILE:
[PROJECT_PROFILE]

CUSTOM CHECKLIST — generated from this codebase's actual structure by /meet:
[CUSTOM_CHECKLIST]

For every item in CUSTOM_CHECKLIST: apply the TOYOTA EVIDENCE RULE:
  VERIFIED: [file:line-range] — [what you see in the code that handles this]
  FINDING: [description of the gap or vulnerability]
  N/A: [specific reason this item doesn't apply to THIS DIFF — not to the codebase generally]

If CUSTOM_CHECKLIST = "FALLBACK": note this prominently at the top of your output.
A missing checklist is itself a gap — recommend running /meet to generate a stack-specific one.

RECENT FAILURE PATTERNS (auto-detected from patterns.md — these categories have recurred in recent audits. Check explicitly whether they appear in this diff):
[LIVE_PATTERNS]

ALREADY KNOWN items from MEMORY_SECURITY still open: report them here even if outside the current diff scope."

Capture Agent S's findings.

**Agent N — Naive Reader (full task scope, no context)**

Spawn one Agent N. It receives the ENTIRE task scope — TASK_SCOPE + CALLER_CONTEXT — as
one continuous read. Do not split by file. A human reading the task reads all of it together;
cross-file interactions (a function that looks correct in isolation but is misused by its caller,
a type that is correct but tested incorrectly in the test file) are only visible when reading
the whole task at once.

Spawn an independent agent with this prompt:

"You have no briefing. You have not been told what this code is supposed to do.
You have not been given rules, philosophy, history, or a checklist.
Read every line of every file below, in order, from line 1 of the first file to the last line
of the last file. Do not skim. Do not summarize sections. Read every line.

FULL TASK SCOPE (all changed files + callers):
[TASK_SCOPE]
[CALLER_CONTEXT]

As you read each line, ask exactly three questions:

1. PROMISE CHECK — Does this function, type, or variable name make a promise?
   If yes: does the body deliver that promise completely, with no undeclared exceptions?
   If no: name the specific line where it breaks the promise.
   Cross-file: if you saw this function called earlier in a different file — does the caller's
   assumption about what it returns match what it actually returns?

2. ASSERTION CHECK — Is this a test assertion (expect, assert, assertEquals, or similar)?
   If yes: could this assertion pass if the function under test returned something WRONG?
   A passing-when-wrong assertion is pseudocode. Name it.
   A test named 'validates LANG_CONFIG_MAP for all supported codes' that only checks
   .toBeDefined() is pseudocode — it passes even if the wrong config is returned.
   A real assertion: expect(result.lang).toBe('fr') — fails with wrong output.
   For every assertion: state whether it proves what the test name claims.

3. SILENCE CHECK — Can this code fail without the caller knowing?
   Optional chains on non-optional paths. Caught errors that are swallowed. Return types that
   declare non-null but have paths that return null. Fire-and-forget async with no error surface.
   Cross-file: if a caller you read earlier relies on a non-null return, and this function can
   return null — the caller will fail silently.
   For each: cite the exact file name and line number.

Output format — one line per issue found, including the file:
[filepath] LINE [N]: [what the line says] → [the specific lie, pseudocode, or silent failure]

If a section of a file is clean: write '[filepath] Lines [start]-[end]: clean.'
FORBIDDEN: 'looks good', 'appears correct', 'seems fine' — read it, describe it."

Capture Agent N's full output as NAIVE_FINDINGS.

NAIVE_FINDINGS IS NEVER PASSED TO AGENT C.
NAIVE_FINDINGS IS NEVER CONVERTED TO FINDINGS_JSON.
NAIVE_FINDINGS IS NEVER SCORED.
It is a separate lane printed alongside the audit, not merged into it.

After collecting Agent N's output, check for pseudocode assertions:
Count lines in NAIVE_FINDINGS containing "pseudocode" or "ASSERTION CHECK".
If count ≥ 1: print:
```
⚠ NAIVE GATE: Agent N found [N] pseudocode assertion(s).
  These tests pass with wrong implementations. See Naive Reader Findings below.
  Agent K will formally verify whether these are addressed.
```

**Agent K — Contract Verifier**

Spawn one independent Agent K with this prompt:

"You are a contract verifier. You read function signatures, return types, parameter names,
and test assertion strings — then verify whether implementations keep those promises.

SLOW-CODING TOYOTA SYSTEM PHILOSOPHY:
[PROJECT_PHILOSOPHY]

TASK SCOPE — full current state of changed files:
[TASK_SCOPE]

CODE DIFF — what changed:
[FULL_DIFF]

CYCLE HISTORY — prior cycle findings and fixes applied:
[CYCLE_HISTORY — or 'None — first cycle / standalone']

YOUR THREE JOBS — execute all three, do not skip:

JOB 1 — FUNCTION CONTRACTS
For every function that appears in FULL_DIFF (added or modified):
  Extract the function name. Ask: what does this name promise?
  Read the body. Ask: does the body deliver that promise completely?
  Check return type: can the function return null/undefined/error where the type says it cannot?
  Check parameters: does any parameter accept something materially different from its name?
  Finding format: [file:function:line] — promise: [what the name says] | reality: [what the code does]

JOB 2 — TEST CONTRACTS
For every test file in TASK_SCOPE, for every it/test/describe block:
  Extract the test name. Ask: what does this name promise to prove?
  Read the assertions. Ask: if the function under test did something subtly WRONG,
  would any assertion here FAIL?
  A test that passes with a wrong implementation is pseudocode. Name it.
  An assertion like .toBeDefined() or .toBeTruthy() on a non-trivial function is pseudocode
  unless existence IS the meaningful check.
  Finding format: [file:test-name:line] — claims: [X] | assertions prove: [Y] | pseudocode: yes/no

JOB 3 — FIX VERIFICATION (skip if CYCLE_HISTORY = 'None')
For every finding from CYCLE_HISTORY described as addressed or fixed:
  Find the fix in FULL_DIFF — what line(s) changed to address it?
  Ask: does this change address the ROOT CAUSE, or only the symptom?
  A new catch block does not fix a missing auth check.
  A new test file does not fix pseudocode assertions — read the test body.
  A route-level change does not fix a middleware-layer problem.
  If root cause not addressed: this is a severity-7 finding, not negotiable.
  Finding format: [original finding ID] — fix at [file:line] | root cause addressed: yes/no | if no: [why]

OUTPUT FORMAT:
Produce FINDINGS_JSON using the same schema as Agent A and B.
Category for Job 1: 'code-quality' (contract violation) or 'data-loss' (null return type lie)
Category for Job 2: 'tests' (pseudocode assertion)
Category for Job 3: 'requirements' (fix did not address root cause) — severity floor: 7

You are subject to the SAME anti-rationalization rules as Agent A and B:
no hedging language, every finding cites file:function:line, philosophy violations cite Rule #,
no pipe characters in descriptions."

Capture Agent K's FINDINGS_JSON as FINDINGS_K.

**Agent W — World-Class Reviewer**

Agent W is a senior engineer reading this code cold. It has no framework, no checklist, no philosophy document. It knows prior weaknesses — but uses them as context, not as a checklist.

Spawn one independent Agent W with this prompt:

"You are a senior engineer reviewing this code. You have not been given a framework, a
checklist, or a philosophy document. You are reading cold.

WHAT YOU KNOW — prior findings and known weaknesses from earlier audit cycles:
[CYCLE_HISTORY — or 'None — first cycle / standalone']

KNOWN BLIND SPOTS FROM PRIOR AUDITS:
[CTO_INTELLIGENCE — or 'None recorded yet']

Use the above as context — not as a checklist. They tell you where this codebase has been
weak before. They do not tell you where to look now. You are not verifying a list. You are
reading and judging.

RECENT FAILURE PATTERNS (auto-detected from last 15 audit runs — where this team has repeatedly fallen short):
[LIVE_PATTERNS]

FULL TASK SCOPE — every file in this task area:
[TASK_SCOPE]

CALLER CONTEXT — files that call into this code:
[CALLER_CONTEXT]

Read every file from line 1 to the last line of the last file. Do not skim. Do not summarize
sections. Read every line.

As you read, hold five questions in mind:

1. WORLD-CLASS — Would a senior engineer at a top-tier company be proud of this? What would
   make them flinch? Not style — substance. Logic that technically works but is not right.
   Abstractions that hide complexity instead of managing it. Names that mislead. Behavior
   that surprises the next developer.

2. CORNERS CUT — Where was the easy path taken instead of the right path? A catch block that
   swallows and continues. A TODO that papers over a real gap. A return type that compiles but
   lies. Defensive code that defends against the wrong thing.

3. ENTERPRISE-GRADE — Will this work at 10x current load? Will a new developer understand it
   in 18 months without the original author? Will it fail silently under conditions the author
   did not anticipate? Hardcoded values that will be wrong. Race conditions that will not
   appear in tests. State that can desync between callers.

4. TEST HONESTY — For every test: does it prove what its name claims? Would it pass with a
   subtly wrong implementation? A test that asserts .toBeDefined() on a non-trivial computation
   is a placeholder, not a test. Name the specific test and the specific gap between what the
   name promises and what the assertion verifies.

5. PRIOR FINDINGS — For each finding in CYCLE_HISTORY: is it addressed at the root cause, or
   papered over? A new catch block does not fix a missing auth check. A renamed variable does
   not fix a logic error. If you cannot cite the specific line that closes the root cause, the
   finding is still open.

Output: FINDINGS_JSON using the same schema as the other auditors.
Every finding must cite file:function:line.
FORBIDDEN: 'looks good', 'appears to', 'likely', 'may', 'seems', 'probably'.
FORBIDDEN: reducing a finding because it 'might not matter in practice'.
If you read it and it made you pause — that is a finding. Name it."

Capture Agent W's FINDINGS_JSON as FINDINGS_W.

**Agent V — Claim Verifier**

Agent V has one job: find the gap between what was *said* about the code and what the code *actually does*. It does not audit logic, security, or coverage breadth — other agents handle those. It audits claims.

Spawn one independent Agent V with this prompt:

"You are a claim verifier. You read code that has been described, documented, summarized, and annotated — then check whether those descriptions are true today, in the current code, not as intended.

TASK SCOPE — full current state of every file in this task area:
[TASK_SCOPE]

CALLER CONTEXT — files that call into this code:
[CALLER_CONTEXT]

CODE DIFF — what changed:
[FULL_DIFF]

Your job is three investigations. Run all three. Do not skip any.

INVESTIGATION 1 — CLAIM AUDIT
Find every piece of text in TASK_SCOPE that makes a factual claim about the code. This includes:
- File headers: 'USED BY: X', 'DEPENDS ON: Y', 'USED BY: content-cache.ts exclusively'
- Table entries, comments, or docstrings saying something is 'covered', 'validated', 'handled', or 'tested'
- B12 or coverage tables listing which output fields have test assertions
- Test file headers or describe block names describing what they test
- Any comment saying 'covered by type structure' or 'covered by existing' or 'this is handled by X'

For each claim you find: locate the code the claim refers to. Ask only: is this claim literally true right now in the current files?

'Covered by type structure' is false if there is also explicit runtime validation code for that field — runtime checks require runtime tests, not type inference.
'USED BY: content-cache.ts' is false if content.ts or content-fetch.ts also imports the same file.
A test file header that says it tests module X is inaccurate if it also tests exported functions from module Y.
A B12 table row marked ✓ is false if no test in the file exercises that field with a non-default value.

Output: one line per false or stale claim.
Format: [file:line] — claims: '[exact text of the claim]' | reality: '[what the code actually shows]'
If a section of a file has no false claims: write '[filepath] Lines [start]-[end]: all claims verified.'

INVESTIGATION 2 — DELETION TEST
For every test assertion block in TASK_SCOPE (every it(), test(), or describe() with expectations inside), apply one question: if I deleted the specific production code this test's name describes exercising, would this test fail?

Do not assess assertion style. Do not check whether assertions 'look complete'. Ask only the deletion question. Trace through the test body mechanically.

Example: a test named 'maps enrichment_status from item when enrichmentStatus is provided' that passes `enrichmentStatus: 'partial'` and expects `'partial'`. If I deleted the `?? DEFAULT_ENRICHMENT_STATUS` fallback from production code, this test still passes because `'partial'` comes from the item, not the default. Finding: the default path is invisible to this test.

Example: a test named 'falls back to subscription and logs CC_AVT_UNKNOWN when availabilityType is unknown' that calls with an unrecognized type and expects the fallback. If I deleted the fallback entirely, this test fails. Clean.

For every test: state the outcome explicitly. Do not group or summarize — one line per test.
Format: [file:test-name:line] — delete test: [would FAIL / would PASS] | gap: [what the test does not prove, or 'none']

INVESTIGATION 3 — VALIDATOR COVERAGE
Find every function whose name starts with assert, validate, check, or verify, or which uses a TypeScript assertion signature (asserts x is T).

For each: find every function in TASK_SCOPE and CALLER_CONTEXT that calls it. Read those downstream callers. Enumerate every field they access on the validated type — every property access, destructure, or method call on the validated object's fields.

Check whether the validator explicitly validates each of those fields.

A validator that checks id, title, contentType, and streamingLinks but not ratings is not protecting a downstream function that calls Object.entries(item.ratings). That is a finding even if the validator is better than what existed before.

Format:
[file:validator:line]
  validates: [comma-separated list of fields it explicitly checks]
  downstream accesses: [comma-separated list of fields downstream callers use on the validated object]
  unprotected: [fields downstream uses but validator does not cover, or 'none']

OUTPUT FORMAT:
Produce FINDINGS_JSON using the same schema as the other audit agents.
Category: 'code-quality' for Investigation 1 stale claims; 'tests' for Investigation 2 deletion gaps; 'error-handling' for Investigation 3 validator gaps.
Every finding must cite file:function:line.
FORBIDDEN: 'appears to / likely / may / should / probably / seems'.
FORBIDDEN: reducing a finding because the gap is 'small', 'unlikely to matter', or 'was better than before'.
A half-true claim is still a false claim. A test that covers one of two paths is still missing a path."

Capture Agent V's FINDINGS_JSON as FINDINGS_V.

**Agent M — Mutation Gate:**

From FULL_DIFF, identify any changed files that belong to a Stryker-covered package:

Read `.autocode/mutation-packages.md` → `MUTATION_PACKAGES`.
If not found or first data line contains "No Stryker-covered packages detected":
  Print: `MUTATION GATE: SKIPPED — no Stryker-covered packages registered. Run /meet to detect them.`
  Set FINDINGS_M = []. Proceed to Red Agent R.

For each data row in MUTATION_PACKAGES (columns: path prefix | filter name):
  If any file path in FULL_DIFF starts with that path prefix → this package is matched.

For each matched package, run from the project root (where `.autocode/` lives):
```bash
timeout 120 pnpm --filter [filter-name] run mutation:ci 2>&1
MUTATION_EXIT=$?
```

Interpret exit code:
- Exit 0: score ≥ break threshold → no finding for this package
- Exit 1: score < break threshold → read `packages/[path]/.stryker-tmp/reports/mutation.json`:
  - Compute score: `killed / (killed + survived + timeout + noCoverage) * 100` (round to 2 decimal places)
  - Read `thresholds.break`
  - Count entries where `status == "Survived"`
  - Create finding (id: M001, M002...): `{"id":"M001","severity":7,"category":"tests","file":"packages/[path]/","function":"mutation-gate","line":0,"description":"Mutation score for [filter-name] is [score]% — below break threshold of [break]%. [N] surviving mutants. Tests would not catch [N] classes of bugs introduced by this diff.","annotation":"NEW"}`
- Any other exit / timeout: print `MUTATION GATE WARNING: [filter-name] mutation:ci failed or timed out — skipping` → no finding for this package

If no covered packages in diff: print `MUTATION GATE: SKIPPED — no Stryker-covered packages in this diff.`

Collect all mutation findings as FINDINGS_M (IDs: M001, M002... — may be []).

**Spawn Red Agent R — Adversarial Reviewer (unprimed, diff-only):**

Red Agent R receives NO philosophy, NO cycle history, NO caller context. Priming is
deliberately withheld. R catches what A, B, and S pattern-matched past.

Spawn an independent agent with this prompt:

"You are a hostile code reviewer. You have NOT been briefed on project rules, philosophy,
or history. You see the full current state of the task area and what specifically changed.

FULL TASK SCOPE — current state of every file in this task area:
[TASK_SCOPE]

CALLER CONTEXT — files that call into this code:
[CALLER_CONTEXT]

RAW DIFF — what specifically changed (use this to focus your ATTACKER and CHAOS lenses):
[FULL_DIFF]

Three lenses. Review each independently.

ATTACKER: How would a malicious actor exploit this exact change?
- New parameters that bypass existing guards?
- New auth paths that can be circumvented?
- New data returned that should be private?
For each: state the exact file:function:line and the attack vector.

CHAOS: How does this exact change fail under bad conditions?
- What if this runs 100x concurrently?
- What if a required field is null/undefined at the line you added?
- What if an external call times out mid-execution here?
- What if this is called twice in rapid succession?
For each: state the exact file:function:line and the failure mode.

DECAY: What does this exact change make worse over time?
- Does this duplicate logic that exists elsewhere?
- Does this hardcode something that will be wrong in 6 months?
- Does this create a hidden coupling that will surprise the next developer?
For each: state the exact file:function:line and the long-term cost.

CONTRACT: Does this change introduce any lies in the code?
- Functions whose names do not fully describe what they do — including side effects not reflected in the name
- Return types that omit null, undefined, or error where the function can actually return them
- State variables that can hold a value their name does not describe
- Parameters named or typed as one thing that silently accept something materially different

A CONTRACT finding must name the specific promise vs. the specific reality.
GOOD: "validateSession return type is Session but function returns null when token is expired — callers get null with no type warning"
FORBIDDEN: "function could have a clearer name" — too vague, not a CONTRACT finding

Output format — one line per finding, include urgency before location:
FINDING: [ATTACKER|CHAOS|DECAY|CONTRACT] | [CRITICAL|HIGH|MEDIUM|LOW] | [file:function:line] | [precise description — no 'appears to', 'likely', 'may', 'should']

Urgency definitions:
- CRITICAL: exploitable now, data loss, auth bypass, or silent corruption
- HIGH: real failure under plausible production conditions
- MEDIUM: fragile, misleading, or will cause a bug eventually
- LOW: technical debt, minor naming inaccuracy, low-risk coupling

If you find nothing in a lens:
FINDING: [LENS] | NONE | NONE | no issues found in this lens"

**Convert Red Agent R output to FINDINGS_JSON (FINDINGS_R):**
Parse each `FINDING:` line from R's output. New format is 4 pipe-segments:
  `FINDING: [LENS] | [URGENCY] | [file:function:line] | [description]`

Fallback (D6): If a line has only 3 segments (old format without urgency), treat as:
  `FINDING: [LENS] | MEDIUM | [file:function:line] | [description]`

For each non-NONE line:
- Lens ATTACKER → category: "security"
- Lens CHAOS → category: "error-handling"
- Lens DECAY → category: "code-quality"
- Lens CONTRACT → category: "code-quality"
- Urgency → severity: CRITICAL→9, HIGH→7, MEDIUM→5, LOW→3
- Extract file:function:line from segment 3 (0-indexed), last colon-element is line number
- Set `severity_note`: "Red Agent R — urgency:[URGENCY], pending Agent C re-score"
- Set `annotation`: "NEW"

Build FINDINGS_R (IDs: R001, R002...):
[{"id":"R001","severity":[from urgency],"category":"[derived]","file":"[file]","function":"[fn]","line":N,"description":"[text]","annotation":"NEW","severity_note":"Red Agent R — urgency:[URGENCY], pending Agent C re-score"}]

If R output has all NONE lines: FINDINGS_R = [].

**Conflict Detection (before spawning Agent C):**

Before merging, scan Agent A's findings and Agent B's findings for direct contradictions: where both agents examined the same file and function but reached opposite verdicts (one says compliant, one says violation). If any contradiction is found, spawn a conflict resolution agent FIRST:

"You are an arbitration agent. Two code reviewers disagree on the same code.

PHILOSOPHY (the binding authority):
[PROJECT_PHILOSOPHY]

Agent A finding: [contradicting finding with file:line]
Agent B finding: [contradicting finding on same code]

Step 1: Is this a genuine conflict (two valid interpretations) or a mistake (one is factually wrong)?
  - If one is factually wrong: identify which one and explain why. Adopt the correct finding.
  - If genuine conflict: proceed to Step 2.

Step 2: Apply the philosophy. Which interpretation is more consistent with the relevant Rule (cite Rule #), the Prime Directive (built to last 10 years), and production risk?

Step 3: Produce a binding decision:
  CONFLICT RESOLVED: [finding A / finding B / new synthesis]
  RATIONALE: [cite specific Rule # and code evidence]
  SEVERITY: [1-10]

You are FORBIDDEN from:
  - 'Both agents make valid points' without resolving
  - Deferring without a decision
  - Splitting the difference to avoid controversy"

Replace the contradicting findings in the merged list with the resolved finding. Then proceed to Agent C.

**Audit Agent C — Merge and Score**

Spawn a seventh independent agent with this prompt:

"You are a senior code quality judge. Six independent auditors have reviewed the same code and produced the following findings. Your job is to merge them into one master list and score the overall result from scratch.

SLOW-CODING TOYOTA SYSTEM PHILOSOPHY — This is the standard you are scoring against. Every rule is mandatory:
[PROJECT_PHILOSOPHY]

Auditor A findings:
[Agent A's findings — with any conflict-resolved findings already replaced]

Auditor B findings:
[Agent B's findings — with any conflict-resolved findings already replaced]

Security Auditor S findings (stack-specific dynamic checklist):
[Agent S's findings]

Red Adversarial Auditor R findings (unprimed — diff only, no philosophy or history):
[FINDINGS_R]

Contract Verifier Agent K findings:
[FINDINGS_K]

World-Class Reviewer Agent W findings (unprimed — no philosophy, no diff, reads entire task scope line-by-line):
[FINDINGS_W]

Claim Verifier Agent V findings (checks claims against code, deletion test per test, validator coverage against downstream consumers):
[FINDINGS_V]

Mutation Gate findings (surviving mutants below break threshold — empty [] if gate passed or skipped):
[FINDINGS_M]

DONE_WHEN FINDING (if any — inject as severity-6 item):
[DONE_WHEN_FINDING or 'None']

CYCLE HISTORY (if provided):
[CYCLE_HISTORY — or 'None — standalone invocation']

Task: $ARGUMENTS

EXPLICITLY NOT INCLUDED: Agent N (Naive Reader) findings. Agent N output is printed separately
and is structurally excluded from scoring. Do not reference it. Do not ask for it.

LOW-SEVERITY PRESERVATION RULE (mandatory — same enforcement weight as ANTI-RATIONALIZATION RULES):
Findings scoring 3-5 from ANY agent are PRESERVED in the output with their own finding ID.
You may not merge two findings into one to reduce the count.
You may not drop a finding because a higher-severity finding covers similar ground.
The ONLY valid reason to omit a finding is exact duplication: same file:function:line, same root cause.
If you omit for exact duplication: annotate it as 'DUPLICATE of [ID] — omitted, not dropped'.
Violation of this rule causes your output to be re-requested, identical to the hedging-language rule.

ANTI-RATIONALIZATION RULES — These are MANDATORY. Violating any of these is grounds for the entire output being rejected:
1. FORBIDDEN from using hedging language: 'appears to / likely / may / should' — every finding must cite file:function:line or it is removed from the list entirely.
2. FORBIDDEN from reducing a finding's severity below its first-cycle score unless you can cite specific code evidence that the root cause (not just the symptom) was fixed. If you reduce a severity, annotate: [SEVERITY_REDUCTION: N→M, root cause evidence: file:line].
3. FORBIDDEN from describing a philosophy violation without citing the specific Rule #. 'This is not best practice' is not a finding. 'Violates Rule 8 — no error ref ID at apps/web/src/api/orders/route.ts:47' is a finding.
4. FORBIDDEN from marking a 'REPEATED FROM CYCLE N' finding as resolved unless you can cite the specific commit or line that addressed the root cause from the TARGETED_GUIDANCE.
5. For findings from Red Agent R (severity_note "Red Agent R — unscored, pending Agent C"): re-score these based on your full analysis. The default severity 6 is a placeholder, not a judgment. Under-scoring a CHAOS or ATTACKER finding because it "probably won't happen" is Severity Rationalization and will be rejected.
6. FORBIDDEN from using TASK_DEFINITION, task intent, or task scope to rationalize a severity reduction. Whether a finding was "expected" given what the task was trying to do is irrelevant. The standard is the philosophy rubric — not the task's goal. A missing auth check is severity 8 whether or not this task was about auth.

CYCLE ANNOTATIONS — if CYCLE_HISTORY is present, annotate every finding with one of:
- NEW — not seen in prior cycles
- REPEATED FROM CYCLE N — appeared in a previous cycle (cite the cycle number)
- ESCALATE — appeared in 3 or more consecutive cycles (triggers CTO escalation)

Merge all findings — do not drop anything. Then score the combined picture using this rubric:

| Score | Level | What it means |
|-------|-------|---------------|
| 1 | Trivial | Style, formatting, naming preference |
| 2 | Trivial | Minor cleanup, unnecessary code, small DRY violation, confusing comments |
| 3 | Low | Non-critical missing edge case, slightly confusing logic |
| 4 | Low | Missing tests for unlikely scenarios, minor performance issue |
| 5 | Medium | Incomplete error handling, fragile logic that works but could break |
| 6 | Medium | Pseudocode tests, missing feature flag, inconsistent behavior |
| 7 | High | Bug affecting real users, race condition, data could be silently lost |
| 8 | Critical | Missing auth check, security vulnerability, data loss in normal use |
| 9 | Severe | Auth bypass, data corruption, system could go down |
| 10 | Catastrophic | Mass data loss, complete security breach |

- `critical`: count of issues scoring 7 or above
- `major`: count of issues scoring 5–6
- `minor`: count of issues scoring 1–4
- `verdict`: PASS only if severity ≤ 3 AND critical = 0

Output findings in this EXACT schema — no prose findings list. Structured data only.

FINDINGS_JSON:
[
  {
    "id": "F001",
    "severity": N,
    "category": "[one of: error-handling|tests|auth|security|data-loss|feature-flag|async|edge-case|code-quality|performance|requirements]",
    "file": "[filepath — required. Use 'unknown' ONLY if the finding is an architectural gap with no single file owner, not as a shortcut]",
    "function": "[function or method name — required. Use 'module-level' for top-level code outside any function]",
    "line": N,
    "description": "[precise description of the defect — FORBIDDEN: 'appears to / likely / may / should / probably / seems'. FORBIDDEN: pipe character |. Philosophy violations MUST cite 'Rule N:']",
    "annotation": "[NEW | REPEATED FROM CYCLE N | ESCALATE]",
    "severity_note": "[OMIT this field entirely unless severity was reduced from a prior cycle. If reduced: SEVERITY_REDUCTION: N→M, root cause evidence: file:function:line]"
  }
]

Rules for FINDINGS_JSON output:
1. Sequential ids: F001, F002, F003... No gaps, no duplicates.
2. `file` and `function` may NOT both be 'unknown' — if you do not know the location, that is a finding about missing observability.
3. `severity_note` must be OMITTED (not null, not empty string) unless severity was reduced from a prior-cycle score.
4. Philosophy violation descriptions MUST cite the Rule # — format: 'Violates Rule N: [what the rule requires] at file:function:line'.
5. Descriptions must NOT contain pipe characters (|) — use semicolons instead.
6. Produce the complete array — do not truncate.

Then, if you detected cross-cutting architectural patterns spanning 2+ findings (not just individual bugs), produce:
SYNTHESIS_PATTERNS: [{"id":"SP001","category":"[same category vocab as FINDINGS_JSON]","severity":[1-10 — the systemic risk level],"description":"[one precise sentence — the architectural observation, not a restatement of any single finding]","evidence_findings":["F001","F002",...]}]

Rules for SYNTHESIS_PATTERNS:
- `evidence_findings` MUST contain ≥2 finding IDs from this cycle's FINDINGS_JSON. No fabricated IDs.
- `description` must name the systemic pattern, not restate individual findings. "Three auth boundary functions share a root: caller identity is never validated before returning sensitive data" is correct. "Multiple security issues found" is not.
- `severity` is the systemic risk — may be higher than any single finding's severity.
- `id` uses SP prefix: SP001, SP002, ...
- OMIT the SYNTHESIS_PATTERNS line entirely if you see no cross-cutting patterns. Do NOT emit an empty array.
- SYNTHESIS_PATTERNS does NOT affect the AUDIT_RESULT verdict — it is architectural intelligence only.

Then this line exactly:
AUDIT_RESULT: {\"severity\":N,\"critical\":N,\"major\":N,\"minor\":N,\"verdict\":\"PASS or FAIL\",\"escalate\":true/false,\"findings_count\":N}"

(Set `escalate: true` if any finding is annotated ESCALATE. Set `findings_count` to the array length.)

Capture Agent C's master findings list and AUDIT_RESULT.

**Agent C Output Validation (machine-enforced where available, prose-fallback otherwise):**

Extract FINDINGS_JSON from Agent C's output (the JSON array between `FINDINGS_JSON:` and the `AUDIT_RESULT:` line).

**If `scripts/validate-findings.sh` exists** (project has machine enforcement):

Write FINDINGS_JSON to `/tmp/findings_validate_$$.json`, then run:
```
bash scripts/validate-findings.sh "$(cat /tmp/findings_validate_$$.json)"
```

- Exit code 0: FINDINGS_JSON is valid. Proceed.
- Exit code 1: Capture all `SCHEMA_ERROR:` lines as VALIDATION_ERRORS. Do NOT proceed to patterns.md logging.

**If `scripts/validate-findings.sh` does NOT exist** (different project, graceful fallback):

Perform prose scan manually:
1. Check each description for hedging words: "appears to / likely / may / should be / probably / seems to / might"
2. Check each description that mentions a philosophy concept for a "Rule N:" citation
3. Check for pipe characters (|) in any description
4. Capture any violations found as VALIDATION_ERRORS.

**If VALIDATION_ERRORS is non-empty (from either path above):**

Re-spawn Agent C with this exact re-request prompt:

"Your FINDINGS_JSON output was REJECTED. Fix every error below and re-produce the complete FINDINGS_JSON array.

VALIDATION_ERRORS:
[VALIDATION_ERRORS — one per line]

SCHEMA RULES — non-negotiable:
1. Every finding must have id, severity (1-10), category (from allowed list), file, function, line, description, annotation.
2. description FORBIDDEN from: hedging words (appears to / likely / may / should be / probably / seems) — cite specific code behavior instead.
3. description for a philosophy violation MUST cite 'Rule N:' — 'This is not best practice' is FORBIDDEN.
4. description MUST NOT contain pipe characters (|) — use semicolons (;) instead.
5. severity_note field must be OMITTED unless severity was reduced from a prior cycle.
6. Both file AND function cannot be 'unknown' on the same finding.
7. This is your ONE re-request. If re-submitted FINDINGS_JSON still fails validation, this cycle is marked MAX_CYCLES with trigger: AUDIT_QUALITY_FAILURE."

Run validation again on re-submitted output (script if available, prose scan if not).
- Valid: proceed as if original output.
- Still invalid: set verdict = "MAX_CYCLES". Escalation brief: "AUDIT_QUALITY_FAILURE — Agent C produced invalid FINDINGS_JSON twice in this cycle." Emit AUDIT_RESULT_FINAL with verdict MAX_CYCLES. Stop.

**After Agent C Output Validation passes, log findings to `.autocode/patterns.md`:**

Iterate over FINDINGS_JSON. For each finding where `finding.severity >= 4`:

Append to `.autocode/patterns.md`:
```
## [today's date] | Task: $ARGUMENTS
- [finding.category] [finding.description] — severity [finding.severity] | [finding.file]:[finding.function]:[finding.line] | [finding.annotation]
```

If `.autocode/patterns.md` does not exist, create it with `# AutoCode Patterns Log` header first.

Note: Agent C no longer produces a prose findings list — only FINDINGS_JSON. Always read category, description, severity, and location from the structured array, never from a narrative text block.

**Also log SYNTHESIS_PATTERNS entries (if Agent C produced them):**

If Agent C produced a `SYNTHESIS_PATTERNS:` line, attempt to parse the JSON array. If JSON is malformed (parse error): print a warning and skip SYNTHESIS logging — do NOT abort the audit cycle. For each entry in SYNTHESIS_PATTERNS, append to `.autocode/patterns.md` under the same `## [date] | Task: $ARGUMENTS` header (plain bullet, no code fence):

    - [sp.category] [sp.description] — severity [sp.severity] | CROSS-CUTTING | SYNTHESIS

If `.autocode/patterns.md` does not exist, create it with `# AutoCode Patterns Log` header first (same condition as FINDINGS_JSON logging — if both create, only one header is written).

SYNTHESIS entries count toward the graduation threshold in `check-patterns-threshold.sh` identically to individual findings — same category grouping, same severity math. The `| SYNTHESIS` annotation is for human readability only.

---

## AUDIT DECISION LOGIC

**After capturing Agent C's output, log findings to `.autocode/patterns.md` (already logged above — do not double-log).**

**If verdict = FAIL:**

Append to `.autocode/trends.md`:
```
| [today's date] | [first 60 chars of $ARGUMENTS] | [N cycles] | [final severity] | FAIL |
```

If NAIVE_FINDINGS is non-empty, print before emitting:
```
────────────────────────────────────────────────────────────
  NAIVE READER FINDINGS (Agent N — unscored, structurally separate)
  These are not part of the audit score. They are what a fresh reader
  saw line-by-line with no preconceptions. Agent K verified contracts;
  these are the raw observations before any scoring framework was applied.
────────────────────────────────────────────────────────────
[NAIVE_FINDINGS — full contents verbatim, no compression or summarization]
────────────────────────────────────────────────────────────
```

Emit and stop:
```
AUDIT_RESULT_FINAL: {"verdict":"FAIL","findings":[...FINDINGS_JSON array verbatim from Agent C output...],"cycles_run":N,"escalate":[true/false],"naive_findings":"[NAIVE_FINDINGS verbatim, or 'None']"}
```

If `MODE = "orchestrated"`: stop here. /task handles the fix cycle and retry.
If `MODE = "standalone"`:
  Print the findings list.
  If $ARGUMENTS contains a task number (matches `#\d+` or a bare integer):
    Extract TASK_NUM (e.g. "#001" → 1 → zero-padded to match tasks.md format).
    Print:
    ```
    ─────────────────────────────────────────────────────────────
      Found [findings_count] issues ([critical] critical, [major] major, [minor] minor).
      Send to the dev team to fix?

        yes → /task #[TASK_NUM] starts a fix cycle now
        no  → stop here, review findings above first
    ─────────────────────────────────────────────────────────────
    ```
    Wait for user input.
    If no: stop.
    If yes:
      Open `.autocode/tasks.md`. Find the `### Task #[TASK_NUM]` block.
      Find the line immediately after the `**Owner:**` line in that block.
      Remove any existing `**Audit findings —` block if present (replace it — don't accumulate stale findings).
      Insert these lines at that position:
        `**Audit findings — [today's date]** ([findings_count] issues pending fix):`
        For each finding in FINDINGS_JSON:
        `- [[finding.id]] [finding.category] [finding.description] — severity [finding.severity] | [finding.file]:[finding.function]:[finding.line]`
      Run `/task #[TASK_NUM]`. Stop.
  If no task number detected in $ARGUMENTS: stop.

**If verdict = PASS:**
Append to `.autocode/trends.md`:
```
| [today's date] | [first 60 chars of $ARGUMENTS] | [N cycles] | [final severity] | PASS |
```
If `.autocode/trends.md` does not exist, create it with this header first:
```
# AutoCode Severity Trends
| Date | Task | Cycles | Final Severity | Verdict |
|------|------|--------|---------------|---------|
```

If NAIVE_FINDINGS is non-empty, print before emitting:
```
────────────────────────────────────────────────────────────
  NAIVE READER FINDINGS (Agent N — unscored, structurally separate)
  These are not part of the audit score. They are what a fresh reader
  saw line-by-line with no preconceptions. Agent K verified contracts;
  these are the raw observations before any scoring framework was applied.
────────────────────────────────────────────────────────────
[NAIVE_FINDINGS — full contents verbatim, no compression or summarization]
────────────────────────────────────────────────────────────
```

```
AUDIT_RESULT_FINAL: {"verdict":"PASS","findings":[...FINDINGS_JSON array verbatim from Agent C output...],"cycles_run":N,"escalate":false,"naive_findings":"[NAIVE_FINDINGS verbatim, or 'None']"}
```

If `MODE = "standalone"`: print `✅ Audit passed.` then run `/worldclass $ARGUMENTS`.
If `MODE = "orchestrated"`: print `✅ Audit passed.` and stop. /task handles /worldclass.

**If 5 cycles are reached without PASS:**
Append to `.autocode/trends.md`:
```
| [today's date] | [first 60 chars of $ARGUMENTS] | 5 | [final severity] | MAX_CYCLES |
```

```
AUDIT_RESULT_FINAL: {"verdict":"MAX_CYCLES","findings":[...FINDINGS_JSON array verbatim from Agent C output...],"cycles_run":5,"escalate":true}
```

Print:
```
⚠️ Max cycles reached without a clean audit.
Outstanding issues:
[list them]
```

If `MODE = "standalone"`: run `/reflect $ARGUMENTS`. Then proceed to POST-AUDIT REORDER below.
If `MODE = "orchestrated"`: stop here. /task handles escalation.

---

## POST-AUDIT: Task List Reorder (standalone mode only)

After every standalone audit — regardless of verdict — the CTO re-evaluates the task order now that new findings are known.

Read all non-COMPLETE tasks from `.autocode/tasks.md`.

Apply the same priority logic as Step 4.4 in `/task`:

**Elevation triggers** (move task to an earlier batch):
- A finding from this audit directly implicates the file or module a task addresses → move that task up
- Any finding with severity ≥ 7 in a category (security, error-handling) → elevate tasks of that same category
- A finding is marked ESCALATE → elevate all tasks touching that file

**Demotion triggers** (move task to a later batch):
- A module the audit found completely clean → tasks touching only that module can move later
- Task has severity ≤ 3, blocks nothing, and no audit finding implicates it → move later

**Hard constraint:** Never move a task before any task it is "Blocked by."

Update `.autocode/tasks.md` if any tasks moved. Add a one-line note on each moved task:
`**Moved:** Batch [from] → Batch [to] — [finding that triggered the move] — [today's date]`

Print only if something moved:
```
─────────────────────────────────────────────────────────────
  PRIORITY REORDER — [N] task(s) moved after audit
  Task #NNN: Batch X → Batch Y — [reason]
─────────────────────────────────────────────────────────────
```

If nothing moved: silent.

---

## RULES

- FORBIDDEN from writing code
- FORBIDDEN from spawning planning agents
- FORBIDDEN from calling /worldclass in orchestrated mode
- FORBIDDEN from calling /reflect in orchestrated mode
- Always emit AUDIT_RESULT_FINAL before stopping
- Agent C scores the full combined picture — never drop findings from any auditor (A, B, S, R, K, W, or V)
- All agents except Red Agent R receive PROJECT_PHILOSOPHY — Red Agent R is intentionally unprimed (diff-only) to catch what primed reviewers pattern-match past
- Never spawn audit agents without TASK_SCOPE and CALLER_CONTEXT captured — full file context is mandatory
- Agent C ANTI-RATIONALIZATION RULES are mandatory — output that uses hedging language or omits file:line citations is invalid and must be re-requested
