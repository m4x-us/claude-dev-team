# Advance — Multi-Window Parallel Orchestration

You are the orchestrating CTO running `/advance`. The task is: $ARGUMENTS

This command analyzes the task list, groups open tasks into parallel streams, presents the wave plan for approval, generates starter prompts for each stream, and instructs Max to open one terminal window per stream. Each window runs an independent Claude session — Max is the completion gate in every window. This orchestrator consolidates results when Max reports streams complete.

---

## Initialize

Read `.autocode/tasks.md`. Find the batch section marked `[CURRENT SPRINT]`.
If not found: print "No current sprint batch found. Run /meet or /tasks to set one." Stop.

Extract BATCH_NUM: parse the `## Batch [N]` heading of the [CURRENT SPRINT] section. BATCH_NUM = N.
Count open tasks (no `**Status: COMPLETE` line) in that batch. Call this count BATCH_OPEN_TOTAL.

Set:
```
WAVE_NUM = 1
TASKS_CLOSED_THIS_SESSION = 0
WAVES_RUN = []
SESSION_FINDINGS = {}
SESSION_NOTIFIED = []
COUPLING_EDGES = []       ← populated by Pre-Wave Semantic Analysis
STREAM_HISTORY = {}       ← file → {wave, stream_name, task_titles} — built after each wave
```

Print: "Starting /advance on Batch [BATCH_NUM] — [BATCH_OPEN_TOTAL] open tasks."

─────────────────────────────────────────────────────────
Complexity Audit — runs once before the Wave Loop
─────────────────────────────────────────────────────────

Read every open task in Batch [BATCH_NUM] (no COMPLETE status).

For each task, apply the complexity rubric mechanically:

  Step 1 — FILE COUNT: Count files in `**File:**` field. "Multiple — see What" = 3+.
    3+ files → FULL (reason: "[N] files")
  Step 2 — PACKAGE BOUNDARY: Any file path containing 'packages/'?
    Yes → FULL (reason: "packages/ boundary")
  Step 3 — IMPLEMENTATION SCOPE: Does `**What:**` contain any of:
    implement, integrate, migrate, new endpoint, new route, new component,
    new feature, multi-commit, TDD sequence, refactor, extract, redesign?
    Yes → FULL (reason: "[matched word]")
  All three clear → DIRECT

A valid label looks like:
  `**Complexity:** ⚡ Direct — 1 file, no package boundary, single-scope change`
  `**Complexity:** 🔧 Full — 3 files`

A label is INVALID (treat as missing) if it has no evidence after the label word.

For each task where the current label is missing OR invalid OR doesn't match the rubric:
  Update the `**Complexity:**` line in `.autocode/tasks.md` with the correct label + evidence.
  Record: "Relabeled #N: [old or 'missing'] → [new] — [reason]"

Print:
```
Complexity audit: [N] tasks checked · [N] relabeled · [N] already correct
[one line per relabeled task: #N [old]→[new] — reason]
```

If any tasks were relabeled: re-read `.autocode/tasks.md` before continuing.

─────────────────────────────────────────────────────────
Pre-Wave Semantic Analysis — runs once before the Wave Loop
─────────────────────────────────────────────────────────

Goal: detect hidden inter-task dependencies that file-overlap cannot catch — cases where
Task B's implementation would fail or produce wrong results without Task A's changes
already in place, even when A and B touch entirely different files.

Collect TASK_FINGERPRINTS for every open task in Batch [BATCH_NUM]:
  { num, title, files (from **File:** field), what (first 3 lines of **What:**/**Why:**) }

Spawn a single planning agent with this prompt:

"You are analyzing a set of parallel development tasks to detect hidden semantic
dependencies that file-overlap detection cannot catch.

For each task pair (A, B), answer: if A and B ran simultaneously in separate terminal
windows with no shared context, could B's implementation fail or be wrong because it
was written without access to A's completed changes?

Look ONLY for these concrete patterns — do not flag vague or speculative connections:
1. B calls or imports a function that A is creating, renaming, or changing the signature of
2. B's fix assumes a type or interface that A is creating or modifying
3. A resolves a root-cause bug that B would encounter as a mid-task symptom
4. A changes an exported contract (API response shape, event payload, DB column, queue
   message format) that B's implementation reads or depends on
5. A creates a shared utility that B independently needs in order for its own fix to work

TASK LIST:
[For each task in TASK_FINGERPRINTS: #N — [title] — files: [list] — what: [description]]

For each confirmed dependency, output exactly one line:
COUPLING: #[A] → #[B] — [one sentence: what specifically in A does B need]

If none confirmed: output COUPLING: none

Be conservative. Only flag dependencies where B would demonstrably break or produce
incorrect results without A's changes. Stylistic preferences and loose coordination
do not qualify."

Parse agent output. For each `COUPLING: #A → #B — [reason]` line:
  Add to COUPLING_EDGES: { from: A, to: B, reason: [reason text] }

Print:
```
Semantic analysis: [N] coupling(s) detected.
[For each edge: "  #A → #B — [reason]"]
[If none: "  No semantic dependencies — all open tasks can run independently."]
```

Proceed to Wave Loop.

---

## Wave Loop

Repeat from Step W.0 until an exit condition fires.

─────────────────────────────────────────────────────────
Step W.0 — Re-read and classify remaining tasks
─────────────────────────────────────────────────────────

Re-read `.autocode/tasks.md` fresh from disk. Do not use any in-memory state from prior iterations.

Collect every task in `## Batch [BATCH_NUM]` that has NO `**Status: COMPLETE` line. Call this set REMAINING.

For each task in REMAINING:
  Read its `**Blocked by:**` field.
  If field = "Nothing" → READY.
  If every task number listed in the field has `**Status: COMPLETE` in tasks.md → READY.
  If any listed task number lacks `**Status: COMPLETE` → WAITING.

Coupling gate — apply after Blocked-by check:
  For each READY task T: check COUPLING_EDGES for any edge { from: X, to: T }
  where task X is NOT COMPLETE (still in REMAINING or not yet started).
  If any such edge exists: move T from READY to WAITING.
  Record reason: "waiting on #X (semantic coupling: [reason])"

CANDIDATES = READY tasks (passed both Blocked-by and coupling gate).
DEFERRED = WAITING tasks (blocked by either declared dependency or semantic coupling).

When printing DEFERRED in the wave plan (W.2), label the cause:
  "blocked by #X (declared)" vs "blocked by #X (semantic: [reason])"

── EXIT CONDITION 1 ── Batch complete ──────────────────
  If REMAINING is empty → go to BATCH COMPLETE. Stop loop.
────────────────────────────────────────────────────────

── EXIT CONDITION 2 ── Deadlock ────────────────────────
  If CANDIDATES is empty AND DEFERRED is non-empty:
    Print:
    "⚠ Deadlock: [N] tasks remain but all are waiting on blockers that are also open.
     Likely cause: tasks reference a blocker that was never created or was deleted.
     Affected tasks:"
    For each DEFERRED task: print "  #[N] — blocked by #[M] (status: [COMPLETE/open])"
    "Resolve manually in tasks.md, then re-run /advance."
    Stop.
────────────────────────────────────────────────────────


─────────────────────────────────────────────────────────
Step W.1 — Cluster CANDIDATES (union-find)
─────────────────────────────────────────────────────────

Run union-find on CANDIDATES only. DEFERRED tasks do not participate.

For each task in CANDIDATES:
  FILE_SET[task] = normalized filenames from `**File:**` field
    (strip :line suffix; if "Multiple — see What" → extract all filenames from `**What:**`)
  BLOCKS[task] = tasks in CANDIDATES that this task blocks (i.e., tasks where Blocked-by lists this task)
  DEPS[task] = tasks in CANDIDATES listed in this task's Blocked-by field

Step A — File conflict union:
  For every pair (X, Y) in CANDIDATES where FILE_SET[X] ∩ FILE_SET[Y] ≠ ∅ → union(X, Y)

Step B — Within-CANDIDATES dependency union:
  For every task X in CANDIDATES where X has a Blocked-by that is also in CANDIDATES → union(X, blocker)

Step C — Compute components (clusters).
  Within each cluster: topological sort by dependency edges among CANDIDATES (blockers execute first).

Cap clusters at 4. If > 4 clusters: merge the two smallest by task count.
Exception: any Full-complexity task touching > 3 files stays in its own cluster unless a dependency forces merging.

── EXIT CONDITION 3 ── Parallel work exhausted ─────────
  If cluster count = 1 → go to SEQUENTIAL HANDOFF. Stop loop.
  If |CANDIDATES| = 1 → go to SEQUENTIAL HANDOFF. Stop loop.
────────────────────────────────────────────────────────

STREAMS = clusters (each: task list in topo order, file set, STREAM_ID = W[WAVE_NUM][A/B/C/D])

Validate isolation: for every pair of STREAMS, their file sets must be disjoint.
If any overlap: merge the conflicting streams. Re-validate. Repeat until clean.


─────────────────────────────────────────────────────────
Step W.2 — Present wave plan (PLAN GATE)
─────────────────────────────────────────────────────────

Build DEFERRED_DISPLAY: for each DEFERRED task, find which STREAM (if any) contains its blocker.

Print:
```
╔═════════════════════════════════════════════════════════════════╗
║  ADVANCE — Batch [BATCH_NUM] · Wave [WAVE_NUM]                  ║
║  [If WAVE_NUM ≥ 2: Wave [WAVE_NUM-1] closed [N] tasks.]        ║
║  [N] streams · [N] tasks this wave · [N] tasks deferred         ║
║                                                                 ║
║  Stream W[N]A — [N Direct / N Full] · exec order: #N → #N → #N ║
║    Tasks: #001, #003, #007                                      ║
║    Files owned: [one file per line]                             ║
║    Isolation check: no file overlap with other streams ✓       ║
╠═════════════════════════════════════════════════════════════════╣
║  Stream W[N]B — ...                                             ║
╠═════════════════════════════════════════════════════════════════╣
║  Deferred — will re-evaluate after this wave:                   ║
║    #009 — [title]  (blocked by #003 → in stream W[N]A)         ║
║    #010 — [title]  (blocked by #009 → not yet runnable)        ║
║  — or —                                                         ║
║  No deferred tasks — all open tasks in this wave.              ║
╚═════════════════════════════════════════════════════════════════╝

Rationale:
  W[N]A: [one sentence — domain coherence + why safe to parallelize]
  W[N]B: [one sentence]

```

Rules for this output:
- Every stream must show "Isolation check: no file overlap with other streams ✓"
- If any overlap exists: do not present the plan. Merge the conflicting streams, re-validate, then present.
- Rationale is mandatory — one sentence per stream, never omit.
- The Wave [N-1] closed line only appears when WAVE_NUM ≥ 2.

After printing the plan, proceed directly to Step W.3. No approval needed.


─────────────────────────────────────────────────────────
Step W.3 — Generate briefs and queue files
─────────────────────────────────────────────────────────

For each STREAM W[WAVE_NUM][X]:

Determine MEMORY_CONTENT:
  Domain classification: check all tasks in stream against category keywords.
  If all tasks are security/auth → include first 150 lines of `.autocode/agents/security.md`
  If all tasks are tests/edge-case → include first 150 lines of `.autocode/agents/qa.md`
  If all tasks are async/arch/error-handling/data-loss → include first 150 lines of `.autocode/agents/architect.md`
  If stream spans multiple domains → include first 100 lines of each relevant file, each labeled:
    "## Security Agent Memory (first 100 lines)" / "## Architect Agent Memory (first 100 lines)" / etc.
    Never exceed 200 lines total across all memory files for one stream.

Create `.autocode/briefs/` directory if it doesn't exist.

Name mapping for streams: A→Adam, B→Barry, C→Charles, D→Derek.

Write `.autocode/briefs/stream-W[WAVE_NUM][X]-start.md` for each stream:

```markdown
# [NAME] — Stream W[WAVE_NUM][X] — Wave [WAVE_NUM] — [today's date]

IDENTITY RULE — MANDATORY: End EVERY response with exactly this line, no exceptions
(including short replies, confirmations, and one-word answers):
— [NAME] | W[WAVE_NUM][X] | [space-separated task numbers e.g. #003 #007]

You are [NAME], a CTO working on a specific set of tasks in parallel with other windows.
Work exclusively on the files listed under "Files You Own". Do not touch anything else.

## Your Tasks (run in this exact order)
1. /task #[NUM]  — [task title]
2. /task #[NUM]  — [task title]
[one line per task, topological order]

STATUS BOARD RULE — MANDATORY: After every completed /task, and before starting
the next one, print your current status board in this exact format:

[NAME] — W[WAVE_NUM][X]
[✓] #[NUM] — [task title]   ← done
[→] #[NUM] — [task title]   ← starting now
[ ] #[NUM] — [task title]

Then proceed to the next task. This lets Max glance at any window and know
exactly where you are.

## Files You Own (edit ONLY these)
[Exact file paths from task File: fields, one per line]

## Off-Limits Files (DO NOT MODIFY — owned by other windows running in parallel)
[Exact file paths from all other streams this wave, one per line]

## Task Definitions
[Full verbatim task blocks from main tasks.md for every task in this stream.]

## Agent Memories
[MEMORY_CONTENT as determined above]

[If any file in this stream's FILE_SET appears in STREAM_HISTORY, OR if any COUPLING_EDGE
{ from: X, to: T } exists where T is in this stream and X completed in a prior wave:]
## Prior Wave Changes — Read Before Starting
These files or areas you depend on were modified by a prior wave. Read this before
writing any code — your starting state is not what the repo looked like at wave start.

[For each relevant STREAM_HISTORY entry:]
  [Prior stream name] (Wave [N]) modified [file] while closing [task title(s)].
  What changed: [summary from that stream's completion.md — the specific change, not just "task closed"]

[For each relevant COUPLING_EDGE where the source task completed in a prior wave:]
  #[source task] (completed by [stream name], Wave [N]) — [coupling reason].
  Specifically: [one sentence on the API/type/function that changed and how]

## When You Finish
Write your completion summary to .autocode/stream-W[WAVE_NUM][X]/completion.md:
  Tasks closed: [list task numbers that reached COMPLETE status]
  Tasks NOT completed: [list task number + done-when condition that failed]
  Debt entries logged: [count]
  Carry-forward tasks generated: [count]

Then tell Max in this window: "[NAME] is done." (or describe what's incomplete).

— [NAME] | W[WAVE_NUM][X] | [task numbers]
```

After writing all `.autocode/briefs/stream-W[WAVE_NUM][X]-start.md` files:

Create `.autocode/queue/` directory if it does not exist.

For each STREAM W[WAVE_NUM][X], write `.autocode/queue/{name}.md` (using A→adam, B→barry, C→charles, D→derek):

```markdown
---
status: pending
agent: {name}
stream: W{WAVE_NUM}{X}
wave: {WAVE_NUM}
---

{full brief content — identical to the stream-W[WAVE_NUM][X]-start.md content written above}
```

Print:
```
Queue files written:
  .autocode/queue/adam.md  — status: pending
  .autocode/queue/barry.md — status: pending
  [etc. for each active stream]
```

Proceed to Step W.4.


─────────────────────────────────────────────────────────
Step W.4 — Launch terminal windows
─────────────────────────────────────────────────────────

Sub-step W.4a — Create stream directories:

For each STREAM W[WAVE_NUM][X]:
  Run: mkdir -p .autocode/stream-W[WAVE_NUM][X]
  Write `.autocode/stream-W[WAVE_NUM][X]/tasks.md`:
    Header line: `# Stream W[WAVE_NUM][X] Task State`
    Append the full verbatim task blocks from main tasks.md for every task in this stream.

Sub-step W.4b — Print terminal setup guide:

Name mapping: A→Adam, B→Barry, C→Charles, D→Derek.

Print:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  WAVE [WAVE_NUM] — OPEN [N] TERMINAL WINDOWS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Open [N] new terminal windows and start Claude Code in each.
In each window, type:

  /go

Each window auto-claims the next pending queue slot and starts.
(Or type /go adam, /go barry, etc. to claim a specific slot.)

Each Claude will end every response with their name so you
always know which window you're in.

Come back here when windows finish. Type:
  done          — all streams complete
  done adam     — Adam's stream done (others still running)
  done adam barry — multiple streams done
  stuck adam    — Adam hit a problem (describe it after)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Wait for Max to respond.

Sub-step W.4c — Process completion reports:

Parse Max's input:

If `done` (no name): all streams complete → read all completion.md files → proceed to W.5.

If `done [name(s)]`:
  Mark those streams as complete.
  Track which streams are still running.
  If all streams now complete: read all completion.md files → proceed to W.5.
  If some still running: print "Waiting on: [remaining names]. Type 'done [name]' when they finish."
  Wait for next input.

If `stuck [name]`:
  Print:
  ```
  [NAME] is stuck. Describe the problem briefly, then choose:
    retry   — have [NAME] try again from where they stopped
    manual  — leave affected task(s) open, skip this stream
    skip    — carry forward to next batch
  ```
  Wait for Max input.
  If "retry": print "Tell [NAME]: continue from your last task. Type 'done [name]' here when they finish."
  If "manual" or "skip": note the affected tasks, handle as current incomplete task gate. Mark stream complete.
  Wait for next done/stuck signal.

Per-Task Pattern Analysis (runs after every done report):

Initialize at session start: `SESSION_FINDINGS = {}` (category → count), `SESSION_NOTIFIED = []`.

Each time a stream is marked complete, for every task that stream closed:
  Read `.autocode/patterns.md`. Find entries under `## [today's date] | Task:` headers
  whose task description matches the completed task title or number.
  For each bullet line found, extract category. Add to SESSION_FINDINGS[category].

After updating SESSION_FINDINGS, check for new threshold crossings:
  For each category where SESSION_FINDINGS[category] >= 3
  AND category NOT IN SESSION_NOTIFIED:
    Add category to SESSION_NOTIFIED (never surface the same category twice)
    Add to PENDING_UPDATE: category + count + highest-severity finding description for that category

If PENDING_UPDATE is non-empty:
  Print:
  ```
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    SESSION UPDATE — paste into each active window
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [N] tasks complete this session. Recurring pattern:
  [for each category in PENDING_UPDATE:]
  - [category] ([N]x): [representative description from highest-severity finding]

  Check your remaining tasks for these before running /task.
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Paste into: [names of windows still running]
  ```
  Clear PENDING_UPDATE.

Sub-step W.4d — Read completion summaries:

For each completed stream W[WAVE_NUM][X], read `.autocode/stream-W[WAVE_NUM][X]/completion.md`. Print:
```
Wave [WAVE_NUM] results:
  Adam   (W[N]A) — [full content of completion.md]
  Barry  (W[N]B) — [full content of completion.md]
  [Charles / Derek if present]
```


─────────────────────────────────────────────────────────
Step W.5 — Consolidate wave state into main files
─────────────────────────────────────────────────────────

Process each stream W[WAVE_NUM][X] in sequence (not parallel — file writes must not race):

Sub-step W.5a — Extract and apply COMPLETE status updates:

Read `.autocode/stream-W[WAVE_NUM][X]/tasks.md`.
Find every line matching: `**Status: COMPLETE — [date]**`
For each: identify the task number from the `### Task #[N]` heading above it.
In main `.autocode/tasks.md`: find that task's block. Insert the same `**Status: COMPLETE — [date]**` line immediately below the `**Owner:**` line.
Count how many COMPLETE statuses were applied. Add to TASKS_CLOSED_THIS_SESSION.

Sub-step W.5b — Append debt entries:

Read `.autocode/stream-W[WAVE_NUM][X]/debt.md`.
Extract all non-header rows (rows that do not start with `#` or `|---`).
Append to main `.autocode/debt.md`. (Create with standard header if not exists.)

Sub-step W.5b.5 — Update STREAM_HISTORY:

For each stream W[WAVE_NUM][X] just consolidated:
  Read its stream tasks.md to find which task titles were closed this wave.
  For each file that stream owned (its FILE_SET from W.1):
    STREAM_HISTORY[file] = {
      wave: WAVE_NUM,
      stream_name: [Adam/Barry/Charles/Derek],
      task_titles: [list of task titles closed this wave that touched this file],
      summary: [one-line summary of what changed, extracted from completion.md]
    }

(Subsequent waves read STREAM_HISTORY in W.3 to inject prior-wave context into briefs.)

Sub-step W.5c — Extract and append carry-forward task blocks:

Read `.autocode/stream-W[WAVE_NUM][X]/tasks.md`.
Find all `### Task #` blocks that contain a `**Carry-Forward from Task #` line — these are new tasks generated by the carry-forward gate, not the original tasks pre-populated by the parent.

For each carry-forward task block found:
  NEXT_NUM = (highest `### Task #[NUM]` number found across ALL batches in main tasks.md) + 1
  Strip the child-assigned task number from the block. Replace with `### Task #[NEXT_NUM]`.
  Append the full block to the end of `## Batch [BATCH_NUM]` in main tasks.md.
  Also append a row to main `.autocode/carry-forward-log.md`:
    `| [date] | Task #[source] | Task #[NEXT_NUM] | [category] | [description] | [severity] |`
  Re-compute NEXT_NUM before each subsequent append (prevents collisions across multiple carry-forward tasks).


─────────────────────────────────────────────────────────
Step W.6 — Commit wave and loop back (COMMIT GATE)
─────────────────────────────────────────────────────────

WAVE_TASKS_CLOSED = count of COMPLETE statuses applied in Step W.5a for this wave.
WAVE_STREAMS = count of STREAMS this wave.

Print:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Wave [WAVE_NUM] complete
  Closed: [WAVE_TASKS_CLOSED] tasks across [WAVE_STREAMS] streams
  Carry-forward tasks added: [count from W.5c]
  Debt entries logged: [total rows added to debt.md this wave]
  Manual/skipped tasks: [list or "None"]

  Commit Wave [WAVE_NUM] changes? [yes / review first]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

If "review first": run `git diff --stat` (shows files changed + line counts). Print output. Ask again.

On "yes":
  Commit with message:
  ```
  /advance wave [WAVE_NUM]: close [WAVE_TASKS_CLOSED] tasks, [WAVE_STREAMS] streams (Batch [BATCH_NUM])

  Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
  ```
  After commit: run `git rev-parse --short HEAD` → SHORT_SHA

Append to WAVES_RUN:
  "Wave [WAVE_NUM]: [WAVE_TASKS_CLOSED] tasks closed · [WAVE_STREAMS] streams · [SHORT_SHA]"

Sub-step W.6b — Pattern Promotion (automatic checklist learning):

Read `.autocode/patterns.md`. Find all entries under `## [today's date] | Task:` headers
whose task description contains any task title from STREAMS in this wave.

Collect all bullet lines from those matching headers. Group by category.
For each category appearing 2 or more times in those entries:
  PROMO_ITEM = description text from the highest-severity occurrence
  PROMO_SEVERITY = max severity seen
  PROMO_COUNT = total occurrences

If any qualifying categories found:
  Read `.autocode/audit-checklist.md`. If not found: skip with print "📊 Checklist: no audit-checklist.md found — run /meet to generate one."
  Otherwise:
    Find the `## TEAM_SPECIFIC LAYER` header line.
    For each qualifying category NOT already present as a word in any line under TEAM_SPECIFIC LAYER:
      Insert immediately after the `## TEAM_SPECIFIC LAYER` header:
      `[ ] [category] auto-detected from Wave [WAVE_NUM] ([PROMO_COUNT]x, max severity [PROMO_SEVERITY]): [PROMO_ITEM] — added: [today's date]`
    Write updated `.autocode/audit-checklist.md`.
    Count of items added → ITEMS_PROMOTED

  If ITEMS_PROMOTED > 0:
    Print: "📊 Checklist: [ITEMS_PROMOTED] recurring pattern(s) from Wave [WAVE_NUM] promoted to team checklist — next wave audits will check these explicitly."
  Else:
    Print: "📊 Checklist: no new recurring patterns from Wave [WAVE_NUM] (threshold: 2+ occurrences per category)."
Else:
  Print: "📊 Checklist: no recurring patterns from Wave [WAVE_NUM] (threshold: 2+ occurrences per category)."

Increment WAVE_NUM.
Print: "Wave committed. Re-evaluating Batch [BATCH_NUM] for Wave [WAVE_NUM]..."
Return to Step W.0.

---

## Sequential Handoff

(Reached via EXIT CONDITION 3: cluster count = 1 or |CANDIDATES| = 1)

Re-read `.autocode/tasks.md` fresh from disk. Recompute REMAINING, CANDIDATES, DEFERRED one final time.

Sort DEFERRED into dependency order:
  Pass 1: tasks whose blocker is in CANDIDATES → list first
  Pass 2: tasks whose blocker is a Pass-1 DEFERRED task → list second
  Pass 3: tasks whose blocker is a Pass-2 DEFERRED task → list third
  Continue until all DEFERRED tasks are ordered.

Print:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  /ADVANCE — PARALLEL WORK EXHAUSTED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [If WAVE_NUM > 1:]
  Session: [WAVE_NUM - 1] waves · [TASKS_CLOSED_THIS_SESSION] tasks closed
  [entry from WAVES_RUN for each completed wave]

  [|REMAINING|] tasks remain in Batch [BATCH_NUM] — sequential from here:

  Run next (all unblocked, but no two can run in parallel):
    #[NUM] — [title]  ([Direct/Full])
    [list all CANDIDATES in topological order]

  [If DEFERRED is non-empty:]
  Waiting on the above to complete first:
    #[NUM] — [title]  (blocked by #[blocker num] above)       ← Pass 1
    #[NUM] — [title]  (blocked by #[blocker num] above)       ← Pass 2, 3...

  Run /task #[first CANDIDATES task number] to continue.

  After completing one or more sequential tasks, run /advance again —
  new parallel work may become available as blockers clear.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Stop. Do not auto-start /task. Max decides when to continue.

---

## Batch Complete

(Reached via EXIT CONDITION 1: REMAINING is empty)

Print:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  /ADVANCE — BATCH [BATCH_NUM] COMPLETE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [WAVE_NUM - 1] waves · [TASKS_CLOSED_THIS_SESSION] tasks closed

  Session summary:
  [each entry from WAVES_RUN, one per line]

  All tasks in Batch [BATCH_NUM] are complete.
  Run /team-health to review, or /meet to plan the next sprint.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Stop.

---

## Rules

- Never commit without Max approving the wave changes (COMMIT GATE at W.6)
- Never touch tasks outside the current sprint batch — /advance is scoped to one batch only
- Never put tasks with shared files in different streams — verify isolation mechanically in W.1
- Never declare DEFERRED empty without explicitly checking every remaining task's Blocked-by field
- Stream rationale is not optional — every stream must have one sentence explaining domain coherence
- A window that reports incomplete tasks is never silently marked complete — handle via stuck/manual/skip
- Re-read tasks.md from disk at every W.0 — never use cached task state between waves
- STREAM_IDs are wave-scoped (W[WAVE_NUM][letter]); never reuse an ID from a prior wave
- Pre-populate each stream's tasks.md with its task blocks before printing the terminal guide (W.4a)
- Carry-forward task numbers are assigned by this orchestrator during consolidation (W.5c)
- DEFERRED tasks never enter union-find — only CANDIDATES are clustered
- Every wave requires a PLAN GATE — no windows open without Max's approval
- Each wave commits independently (W.6) before looping — never accumulate changes across waves
- Sequential Handoff must list DEFERRED in dependency order (Pass 1/2/3 algorithm)
- Never auto-start /task after Sequential Handoff or Batch Complete — Max decides
- Never fork child CTOs — every Claude that writes code runs in its own terminal window with Max present
