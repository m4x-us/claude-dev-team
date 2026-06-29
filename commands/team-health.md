# Team Health — CTO Dashboard

You are generating the CTO dashboard. When invoked with `scan` (or triggered automatically by /task at batch completion), runs the three-layer survey first to update `.autocode/map.md`, then shows the dashboard.

---

## SCAN MODE

**Trigger:** Run if $ARGUMENTS contains "scan". Otherwise skip to STEP 1.

Read `.autocode/map.md` → `PRIOR_MAP` (full contents, or "None — first scan").

---

### Layer 1 — Piece Coverage

Identify modules: every directory that is either (a) a package root (contains `package.json` and a `src/` subdirectory) or (b) a major feature directory under `apps/web/src/app/dashboard/` that contains ≥ 3 source files directly or one level deep.

For each module, run:

```bash
# Source files (exclude tests, types, build artifacts)
find [module_dir] \( -name '*.ts' -o -name '*.tsx' \) \
  ! -name '*.test.*' ! -name '*.spec.*' ! -name '*.d.ts' \
  ! -path '*/node_modules/*' ! -path '*/.next/*' ! -path '*/dist/*'

# Test files
find [module_dir] \( -name '*.test.ts' -o -name '*.test.tsx' \) \
  ! -path '*/node_modules/*'
```

A source file is **covered** if a `.test.ts` or `.test.tsx` with the same stem exists in the same directory.
Module piece coverage = covered files / total source files.

---

### Layer 2 — Module Integration Coverage

For each module:

```bash
find [module_dir] -name '*.integration.test.*' ! -path '*/node_modules/*' | head -1
```

✓ if any result. ✗ if empty.

---

### Layer 3 — App E2E Coverage

```bash
find . \( -path '*/playwright/*' -o -path '*/e2e/*' \) \
  \( -name '*.spec.ts' -o -name '*.spec.tsx' \) \
  ! -path '*/node_modules/*'
```

List all found spec files as covered flows.

---

### Write `.autocode/map.md`

```
# Layer Map — [project name]
Last survey: [today's date] | Triggered by: [value of $ARGUMENTS]

## Piece Layer
| Module | Covered | Total | % | Uncovered (first 5) |
|--------|---------|-------|---|---------------------|
| [name] | N       | M     | N%| file1.ts, file2.ts  |

## Module Layer
| Module | Integration Test | Status |
|--------|-----------------|--------|
| [name] | [filename or —] | ✓ / ✗  |

## App Layer (E2E)
| Spec File | Status |
|-----------|--------|
| [path]    | ✓      |

## Delta Since Last Survey
[compare against PRIOR_MAP — list new gaps, closed gaps, or "First survey — no prior data"]
```

---

### Gap Analysis — Propose tasks only when threshold exceeded

- Piece coverage < 40% AND module has ≥ 5 source files → severity 5 gap
- No integration test AND module has ≥ 8 source files → severity 4 gap
- No E2E spec found at all → severity 6 gap
- No E2E spec AND module name contains auth / order / payment → severity 7 gap

For each gap above threshold, format a proposed task entry:

```
Proposed: Add [piece tests / integration test / E2E spec] for [module]
What: [specific files or flows to cover]
Why: [gap description — coverage %, file count]
Severity: [N]
Owner: QA Agent
Done when: [test file exists and all assertions pass]
```

CTO decides whether to add proposed tasks to the next available batch in `.autocode/tasks.md`. If adding: append them to the lowest-numbered BACKLOG batch and note "Added by layer survey — [today's date]".

---

### Print Survey Summary

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  LAYER SURVEY — [today's date]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PIECE LAYER ([N] modules scanned)
  [module]: [N]/[M] ([%]) ✓
  [module]: [N]/[M] ([%]) ✗ gap
MODULE LAYER
  [module]: ✓ integration test
  [module]: ✗ no integration test — [N] source files
APP LAYER
  [N] E2E specs: [filenames or "none found"]
NEW SINCE LAST SURVEY
  [delta list or "No change"]
PROPOSED ADDITIONS
  [task proposals for gaps above threshold, or "None — all layers healthy"]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

After printing the survey summary: continue to STEP 1 (dashboard).

---

## STEP 1: READ ALL SOURCES

Read silently:
1. `.autocode/agents/cto.md` → `CTO_MEMORY`
2. `.autocode/agents/security.md` → `MEMORY_SECURITY`
3. `.autocode/agents/architect.md` → `MEMORY_ARCHITECT`
4. `.autocode/agents/qa.md` → `MEMORY_QA`
5. `.autocode/agents/docs.md` → `MEMORY_DOCS`
6. `.autocode/tasks.md` → `TASK_LIST`
7. `.autocode/worldclass-trends.md` → `WORLDCLASS_TRENDS` (last 10 rows, or "No data")
8. `.autocode/trends.md` → `AUDIT_TRENDS` (last 10 rows, or "No data")
9. `.autocode/patterns.md` → `PATTERNS` (count occurrences per category)

If `.autocode/agents/cto.md` does not exist:
```
No team memory found. Run /meet to initialize the development team.
```
Stop.

---

## STEP 2: COMPUTE METRICS

From WORLDCLASS_TRENDS (last 5 PASS rows):
- Average WorldClass score = sum of scores / count
- Score trend: compare avg of last 3 vs prior 3 (if 6+ rows): IMPROVING / STABLE / DEGRADING

From AUDIT_TRENDS (last 5 rows):
- PASS rate = PASS count / total count × 100%
- MAX_CYCLES rate = MAX_CYCLES count / total count × 100%

From PATTERNS:
- Most frequent category (count all occurrences per category label)
- Any category with 3+ occurrences = systemic pattern

From TASK_LIST:
- Find [CURRENT SPRINT] batch, count open vs. done tasks
- Count total backlog tasks
- Extract any tasks with severity 8-9 that are still open

From CTO_MEMORY `## Task Cycle Log`:
- For each in-progress task (Status: In Progress), extract task number, description, and current cycle number
- Flag any task at Cycle 4+ as approaching escalation threshold

---

## STEP 3: PRINT DASHBOARD

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  TEAM HEALTH DASHBOARD — [today's date]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

AGENT PERFORMANCE
  Security:  [runs from memory frontmatter] runs | blind spots: [## Known Blind Spots content or "none"]
  Architect: [runs] runs | blind spots: [list or "none"]
  QA:        [runs] runs | blind spots: [list or "none"]
  Docs:      [runs] runs | blind spots: [list or "none"]

QUALITY TRENDS
  WorldClass avg (last 5): [N]/100  [↑ IMPROVING / → STABLE / ↓ DEGRADING / "—" if <3 runs]
  Audit PASS rate (last 5): [N]%  [↑ / → / ↓ / "—"]
  Most frequent deduction:  [category] ([N] occurrences)
  Systemic patterns:        [list categories with 3+ occurrences, or "None yet"]

TASK STATUS
  Current sprint: Batch [N] — [N open] open | [N done] done | [N total] total
  Total backlog:  [N] tasks across [N] batches
  Critical open (severity 8-9): [list Task #N with description, or "None"]
  In-progress tasks (active cycles):
    [Task #N — [description] — Cycle N/5]
    [or: "No tasks in active cycles"]
    [⚠️ Task #N at Cycle N/5 — approaching escalation threshold (for any task at Cycle 4+)]

OPEN ESCALATIONS
  [list from CTO_MEMORY ## Open Escalations — Task # | issue | days since logged]
  [or "None — all tasks resolved or within cycle limits"]

CONFLICT REGISTER
  [list from CTO_MEMORY ## Conflict Register — file | agents | status]
  [or "None — no unresolved agent conflicts"]

RECOMMENDED ACTIONS
  [1-3 concrete next steps based on the data above]
  [Example: "Run /patterns — [category] has appeared 4 times, may warrant philosophy update"]
  [Example: "Task #N at Cycle 4/5 — escalation threshold approaching. Run /task #N to continue or /findings #N to inject owner guidance."]
  [Example: "Security agent has 2 unresolved open findings — run /consult security"]
  [If any task is at Cycle 4+: always include the escalation warning as a recommended action]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## RULES

- Never spawn agents — this command reads only
- Never fabricate metrics — if data is missing, print "—" not a number
- Recommended actions must be based on actual data, not generic advice
- If no tasks exist, print the task status section as "No task list — run /meet to generate one"
