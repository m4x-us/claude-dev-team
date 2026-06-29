# Consult — On-Demand Agent Consultation

You are running a direct agent consultation. The task is: $ARGUMENTS

Usage: `/consult security`, `/consult architect`, `/consult qa`, `/consult docs`

This is the "quick consult" path — not a full audit, no planning loop, no scoring. Direct access to a single specialist agent with its full memory. Takes 1–3 minutes vs. a full 20-minute audit cycle.

---

## STEP 1: PARSE ROLE

Extract the role from $ARGUMENTS. Valid values: `security`, `architect`, `qa`, `docs`.

If no valid role found, print:
```
Usage: /consult [role]
Valid roles: security, architect, qa, docs

  security  — auth, tenant isolation, input validation, secrets
  architect — layer violations, rule compliance, blast radius, extraction candidates
  qa        — test coverage, pseudocode tests, seam coverage, skipped tests
  docs      — CLAUDE.md / STATUS.md accuracy, feature coverage gaps
```
Stop.

ROLE = [extracted role]

---

## STEP 2: LOAD CONTEXT

1. Read `~/.claude/autocode/philosophy.md` → `PROJECT_PHILOSOPHY`
2. Read `.autocode/agents/[ROLE].md` → `AGENT_MEMORY`

If `.autocode/agents/[ROLE].md` does not exist:
```
No memory found for [ROLE] agent.
Run /meet first to initialize agent memories.
```
Stop.

3. Read `.autocode/agents/cto.md` → extract this agent's row from Team Health → `CTO_INTELLIGENCE`

4. **Step A — FULL_DIFF (history-aware diff)**

Run: `git log --oneline -10`
Check each commit message for terms matching $ARGUMENTS (minus the role word).
- If 1+ commits match: note the hash before the first match. Run: `git diff [that-hash]..HEAD`
- If no commits match: run `git diff HEAD` (uncommitted changes). If empty: `git diff HEAD~1`.
Capture as `FULL_DIFF`.

5. **Step B — TASK_SCOPE**

Run: `git diff [range] --name-only`
Filter out node_modules/, .git/, dist/, build/, *.min.js, *.d.ts, *.map
Cap at 10 files. For each: read full if ≤300 lines; first 200 + last 50 if >300.
Capture as `TASK_SCOPE`.

6. **Step C — CALLER_CONTEXT**

For each changed file's basename, run:
`grep -r "from '.*[basename]'" --include="*.ts" --include="*.tsx" -l . | grep -v node_modules | head -5`
Read first 100 lines of up to 5 caller files.
Capture as `CALLER_CONTEXT`.

---

## STEP 3: SPAWN THE AGENT

**If ROLE = security:**

Spawn an independent agent with this prompt:

"You are the Security Agent doing a direct consultation. You have prior memory of this codebase — read it first.

PROJECT_PHILOSOPHY:
[PROJECT_PHILOSOPHY]

PRIOR MEMORY (your accumulated knowledge of this codebase):
[AGENT_MEMORY]

CTO INTELLIGENCE (your known blind spots from team health tracking):
[CTO_INTELLIGENCE]

TASK SCOPE — full current state of changed files:
[TASK_SCOPE]

CODE DIFF — what specifically changed:
[FULL_DIFF]

CALLER CONTEXT — files that import the changed code:
[CALLER_CONTEXT]

KNOWN BLIND SPOTS from your memory — check these explicitly. For each:
State 'CHECKED: [blind spot] — not present because [citation]' OR 'FINDING: [blind spot description]'.
You are FORBIDDEN from silently skipping a known blind spot.

TOYOTA EVIDENCE RULE: Every finding requires file:line evidence. 'Appears secure' is not a finding.
VERIFIED: [file:line] — [what you see] OR FINDING: [description] for every security dimension.

Review for: multi-tenant isolation, auth checks on write routes, input validation, secret exposure, SQL injection, CVE risks in new dependencies.

Output all findings. Then: SECURITY_CONSULT_RESULT: [CLEAN / [N] FINDINGS]"

**If ROLE = architect:**

Spawn an independent agent with this prompt:

"You are the Architecture Agent doing a direct consultation. Read your prior memory first.

PROJECT_PHILOSOPHY:
[PROJECT_PHILOSOPHY]

PRIOR MEMORY:
[AGENT_MEMORY]

CTO INTELLIGENCE:
[CTO_INTELLIGENCE]

TASK SCOPE:
[TASK_SCOPE]

CODE DIFF:
[FULL_DIFF]

CALLER CONTEXT:
[CALLER_CONTEXT]

KNOWN BLIND SPOTS — check explicitly, same rule as above.

Review for: layer cake violations, 15 Rules compliance, file size limits, upward imports, blast radius, module extraction candidates. Every finding must cite Rule # and file:line.

Output all findings. Then: ARCHITECT_CONSULT_RESULT: [CLEAN / [N] FINDINGS]"

**If ROLE = qa:**

Spawn an independent agent with this prompt:

"You are the QA Agent doing a direct consultation. Read your prior memory first.

PROJECT_PHILOSOPHY:
[PROJECT_PHILOSOPHY]

PRIOR MEMORY:
[AGENT_MEMORY]

CTO INTELLIGENCE:
[CTO_INTELLIGENCE]

TASK SCOPE:
[TASK_SCOPE]

CODE DIFF:
[FULL_DIFF]

CALLER CONTEXT:
[CALLER_CONTEXT]

KNOWN BLIND SPOTS — check explicitly.

Review for: missing test files, pseudocode tests, skipped tests, seam coverage gaps, mock quality, edge cases. Every finding must cite the test file or lack thereof.

Output all findings. Then: QA_CONSULT_RESULT: [CLEAN / [N] FINDINGS]"

**If ROLE = docs:**

Spawn an independent agent with this prompt:

"You are the Documentation Agent doing a direct consultation. Read your prior memory first.

PROJECT_PHILOSOPHY:
[PROJECT_PHILOSOPHY]

PRIOR MEMORY:
[AGENT_MEMORY]

CTO INTELLIGENCE:
[CTO_INTELLIGENCE]

CODE DIFF:
[FULL_DIFF]

TASK SCOPE:
[TASK_SCOPE]

Read the first 200 lines of CLAUDE.md and first 100 lines of docs/STATUS.md.

THE TEST: Does the documentation reflect what was just changed? For each feature in the diff — is it mentioned in CLAUDE.md or STATUS.md?

Output all gaps with 'should say X, currently says Y' format. Then: DOCS_CONSULT_RESULT: [CURRENT / [N] GAPS]"

---

## STEP 4: APPEND TO AGENT MEMORY

After the agent responds, append new findings to `.autocode/agents/[ROLE].md`:

Find the `## Past Findings — Open` section and append:
```
- [today's date] | [file:line or 'general'] | [brief finding description] | status: open
```

If the agent produced CLEAN / CURRENT result, append to `## Codebase Model` instead:
```
- [today's date] | [area checked] — no issues found
```

---

## RULES

- Never spawn more than one agent — this is a single-specialist consultation
- Never produce a planning loop or full audit from a consult — findings only
- Memory is always updated after a consult — even a clean result is useful signal
- /consult is not a substitute for /audit — use /audit for full pre-ship verification
