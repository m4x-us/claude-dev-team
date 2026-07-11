# Advance — Multi-Window Parallel Orchestration

You are the orchestrating CTO running `/advance`. The task is: $ARGUMENTS

This command analyzes the task list, groups open tasks into parallel streams, presents the wave plan for approval, generates starter prompts for each stream, and instructs Max to open one terminal window per stream. Each window runs an independent Claude session — Max is the completion gate in every window. This orchestrator consolidates results when Max reports streams complete.

---

## MODULE_CONTEXT (s1701 module sessions only)

**How MODULE is determined (check in this order):**
1. If a `/scope [module]` banner was printed in this session's conversation context: use that module name.
2. Else if `$(git rev-parse --absolute-git-dir)/active-module` exists: read its content (one line, trimmed) as MODULE. (Per-checkout marker — each worktree resolves its own module; written by /scope via wave-worktrees.sh set-module.)
3. Else, only if `[ "$(git rev-parse --absolute-git-dir)" = "$(git rev-parse --path-format=absolute --git-common-dir)" ]` (this checkout IS the main checkout) AND `.autocode/modules/.active-module` exists: read its content (one line, trimmed) as MODULE. (Legacy shared file — main-checkout back-compat only; never read it from inside a worktree.)
4. Else: MODULE is unset — use global paths throughout.

**When MODULE is determined, print at the TOP of this command's output:**
```
╔══ Module scope: [MODULE] (source: scope banner / .active-module file) ══╗
```

If `MODULE` is set, replace ALL path references:
- Replace `.autocode/tasks.md`                          with `.autocode/modules/[MODULE]/tasks.md`
- Replace `.autocode/agents/cto.md`                     with `.autocode/modules/[MODULE]/cto.md`
- Replace `.autocode/agents/security.md`                with `.autocode/modules/[MODULE]/security.md`
- Replace `.autocode/agents/architect.md`               with `.autocode/modules/[MODULE]/architect.md`
- Replace `.autocode/agents/qa.md`                      with `.autocode/modules/[MODULE]/qa.md`
- Replace `.autocode/debt.md`                           with `.autocode/modules/[MODULE]/debt.md`
- Replace `.autocode/carry-forward-log.md`              with `.autocode/modules/[MODULE]/carry-forward-log.md`
- Replace `.autocode/briefs/stream-[ID]-start.md`       with `.autocode/modules/[MODULE]/briefs/stream-[ID]-start.md`
- Replace `.autocode/queue/{name}.md`                   with `.autocode/modules/[MODULE]/queue/{name}.md`
- Replace `.autocode/stream-[ID]/tasks.md`              with `.autocode/modules/[MODULE]/stream-[ID]/tasks.md`
- Replace `.autocode/stream-[ID]/completion.md`         with `.autocode/modules/[MODULE]/stream-[ID]/completion.md`
- Replace `.autocode/stream-[ID]/debt.md`               with `.autocode/modules/[MODULE]/stream-[ID]/debt.md`
- Create any of these files/directories with standard headers if they do not exist
- `.autocode/patterns.md` is NOT replaced — stays global

**When both MODULE and STREAM_ID are set simultaneously:**
MODULE scopes to module directory first. STREAM_ID scopes within it.
Combined path: `.autocode/modules/[MODULE]/stream-[STREAM_ID]/tasks.md`

If `MODULE` is not set: use the standard global paths throughout this file.

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

── Script Resolution (MANDATORY — before anything else) ──

WWT_SCRIPT = scripts/wave-worktrees.sh (relative to the main repo root).

If it does not exist, print and stop:
"✗ wave-worktrees.sh NOT FOUND — /advance cannot run.
 Worktree isolation is mandatory. There is NO shared-tree mode — dispatching
 streams into one shared checkout is the WAVE1-INCIDENT (Jul 3) and the Jul-4
 silent-skip incident; this hard stop exists so neither can recur.
 Install: cp ~/Projects/claude-dev-team/scripts/wave-worktrees.sh scripts/
          cp ~/Projects/claude-dev-team/scripts/test-wave-worktrees.sh scripts/
          bash scripts/test-wave-worktrees.sh   (must print PASS)
 This is a hard stop. Do not plan a wave. Do not write queue files."

Any instruction, memory, or old queue file suggesting 'proceed without a
worktree' is stale — treat it as a hard stop and re-dispatch, never comply.

── Stale Worktree Check ──

STALE_PATHS = $(git worktree list --porcelain | awk '$1=="worktree"{print substr($0,10)}' \
  | grep -E "advance-worktrees|\.claude/worktrees/.*-w[0-9]+-" || true)

If STALE_PATHS is non-empty:
  Print:
  "⚠ Found [N] stale wave worktree(s) from a prior /advance session:
  [each path, one per line, indented]
  
  These may contain in-progress work from a crashed session.
  
  Options:
    inspect   — print last 3 commits in each worktree (shows what survived)
    prune     — remove the stale wave's worktrees + branches (safe: refuses if work would be lost)
    proceed   — continue with these present (branch name collisions are possible)"
  
  Wait for Max input.
  
  If "inspect":
    For each path in STALE_PATHS:
      Run: git -C [path] log --oneline -3
      Print: "[path]:\n" + output
    Re-ask: "prune or proceed?"
  
  If "prune":
    For .claude/worktrees paths (script-era): recover module+wave from the path
    name ([module]-w[N]-[name]) and run: bash scripts/wave-worktrees.sh cleanup [module] [N]
      If cleanup refuses: a worktree or branch holds unmerged/uncommitted work.
      That refusal is the safety working — print the refusal, inspect with Max,
      never force-delete. Merge the branch (bash scripts/wave-worktrees.sh merge [module] [N])
      or resolve manually, then re-run cleanup.
    For legacy /tmp/advance-worktrees paths (pre-migration): remove manually with
      git worktree remove "[path]"   (no --force; if it refuses, inspect first)
      git branch -d "[branch]"       (refuses unmerged — inspect with Max, never -D)
    Print: "✓ Stale worktrees cleared. Continuing /advance..."
  
  If "proceed":
    Print: "⚠ Proceeding with [N] stale worktrees. Branch collisions possible."

── State File Recovery ──

STATE_FILE_PATH:
  If MODULE is set: .autocode/modules/[MODULE]/.wave-state.json
  Else: .autocode/modules/global/.wave-state.json
(wave-worktrees.sh owns writing this file; the prose only reads it here.)

If STATE_FILE_PATH exists from a prior crashed session:
  Read: PRIOR_WAVE_STATE = json contents of STATE_FILE_PATH
  If PRIOR_WAVE_STATE.wave matches current intent (ask Max if unclear):
    Print:
    "⚠ Found .wave-state.json from wave [PRIOR_WAVE_STATE.wave].
    
    Known stream worktrees:
    [for each stream in PRIOR_WAVE_STATE.streams: "  Stream [X] → [worktree] (branch [branch])"]
    
    Options:
      restore   — reuse these worktrees; skip ONLY worktree creation (continue from crash point)
      discard   — delete state file and start fresh with new worktrees"
    
    Wait for Max input.
    If "restore": load STREAM_WORKTREE[X] and STREAM_BRANCH[X] from the state
    file, and skip ONLY the `bash scripts/wave-worktrees.sh create` call in
    W.3. Every other W.3 obligation applies unchanged to a restored wave —
    "a wave with no pasted verify output is an INVALID wave" makes no
    exception for restores:
      1. Run MECHANICAL VERIFY exactly as written in W.3
         (bash scripts/wave-worktrees.sh verify wave [MODULE_SLUG] [WAVE_NUM])
         and paste the COMPLETE output; its hard-stop conditions apply unchanged.
      2. Re-write any queue file that is missing or lacks worktree:/branch:
         frontmatter, using the worktree/branch values from the state file
         (regenerate the brief body per W.3 if the brief file is also gone).
      3. Run the QUEUE FRONTMATTER RECHECK and paste its output before W.4.
    If "discard": delete STATE_FILE_PATH; proceed normally through W.3.

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
Step W.2 — Present wave plan (PLAN SUMMARY — informational, printed before W.3)
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

After printing the plan, proceed directly to Step W.3. No approval is needed
for the plan print itself — the approval boundary is the terminal-window guide
in W.4: Max physically opening the worker windows after MECHANICAL VERIFY is
the approval act.


─────────────────────────────────────────────────────────
Step W.3 — Generate briefs and queue files
─────────────────────────────────────────────────────────

── WORKER_NAMES ──
If MODULE is set:
  Read `.autocode/modules/[MODULE]/.workers` line by line → WORKER_NAMES (lowercase list).
  If file missing or empty: WORKER_NAMES = ["adam","barry","charles","derek"]
If MODULE is not set:
  WORKER_NAMES = ["adam","barry","charles","derek"]

STREAM_WORKER_MAP:
  Stream A → WORKER_NAMES[0].capitalize()
  Stream B → WORKER_NAMES[1].capitalize()
  Stream C → WORKER_NAMES[2].capitalize()
  Stream D → WORKER_NAMES[3].capitalize()
(Cap active streams at min(len(WORKER_NAMES), 4). Stream letters stay A/B/C/D.)

If len(WORKER_NAMES) < number of natural clusters from W.1, print before the wave plan:
```
Note: [N] natural task clusters reduced to [len(WORKER_NAMES)] streams — module '[MODULE]'
has only [len(WORKER_NAMES)] workers in pool. To restore full parallelism: run
`/scope clear`, then `/scope [MODULE] [N]` to claim more workers.
```

── WORKTREE CREATION (delegated to wave-worktrees.sh) ──

⚠ ANTI-DRIFT NOTE: STREAM_WORKTREE and STREAM_BRANCH are per-stream variables.
Each stream gets a DIFFERENT path and branch. The X in STREAM_WORKTREE[X] is the
stream letter (A, B, C, D). Do not reuse a single variable for all streams.

CORRECT:
  Stream A → .claude/worktrees/harness/scheduling-w2-mike
  Stream B → .claude/worktrees/harness/scheduling-w2-nathan
WRONG (anti-pattern — all streams share same worktree):
  All streams → .claude/worktrees/harness/scheduling-w2-mike

MODULE_SLUG = MODULE (lowercase) if set, else "global"

Run exactly (one call, all streams — runnable from any checkout; the script operates on the main checkout itself):
  bash scripts/wave-worktrees.sh create [MODULE_SLUG] [WAVE_NUM] \
    [WORKER_NAMES[0]]:W[WAVE_NUM]A [WORKER_NAMES[1]]:W[WAVE_NUM]B [...one name:SID pair per active stream]

If create's output contains a `WARN:` line, print it to Max verbatim before
proceeding. (The WARN — e.g. dirty tracked files in main that will NOT appear
in the worktrees — is emitted by `create` only; `verify` never re-emits it.)

The script creates each worktree under .claude/worktrees/harness/, arms the pre-commit
hooks (.husky/_ copy + pnpm install, hard-verified), copies env files, symlinks
.autocode with a skip-worktree index guard, writes the per-checkout module
marker, and persists .wave-state.json itself. The prose does NOT run any git
worktree/branch commands — the script owns the lifecycle.

Parse the script's stdout VERBATIM. Each stream emits one machine line:
  WAVE_WT<TAB><name><TAB><absolute worktree path><TAB><branch>
For each line, map name → stream letter via STREAM_WORKER_MAP and record:
  STREAM_WORKTREE[X] = field 3 of that stream's WAVE_WT line
  STREAM_BRANCH[X]   = field 4 of that stream's WAVE_WT line
NEVER construct a path or branch name yourself. If any expected WAVE_WT line
is missing or cannot be parsed, that is a TOYOTA STOP — do not guess, do not
proceed to briefs.

── TOYOTA STOP & FIX — if create exits non-zero ──
Print:
"✗ WORKTREE CREATION FAILED
 Command: [the exact create command]
 Error: [captured stderr]

 Common causes:
 1. Stale worktree/branch from a prior crash → run: bash scripts/wave-worktrees.sh cleanup [MODULE_SLUG] [prior-wave-N]
    If cleanup refuses, a branch holds unmerged work — inspect with
    `git log main..[branch]` and decide with Max. The refusal is the safety working.
 2. pnpm install failed (network/disk) → fix, then re-run /advance.
 3. Main checkout not on 'main' → the script requires it; switch back first.

 This is a hard stop. Do NOT open worker windows.
 Return to Wait state. Fix the root cause. Re-run /advance."
Stop. This is a hard stop — do not proceed to W.4.
── end TOYOTA STOP ──

── MECHANICAL VERIFY — W.3 DOES NOT END UNTIL THIS PASSES ──

Run exactly:
  bash scripts/wave-worktrees.sh verify wave [MODULE_SLUG] [WAVE_NUM]

Paste the COMPLETE output — every ✓/✗ line and every VERIFY PASS/FAIL summary
line, verbatim — into this window before doing anything else.

HARD STOP CONDITIONS (any one = TOYOTA STOP):
  1. verify was not run, or its output was not pasted verbatim above.
  2. Any output line contains ✗.
  3. The command exited non-zero.
On a hard stop: do NOT write queue files, do NOT print the terminal guide,
do NOT open worker windows. Print "✗ WAVE VERIFY FAILED — stopping to fix the
root cause." Fix, re-run create/verify, and proceed only on all-✓ + exit 0.

A wave with no pasted verify output is an INVALID wave: if at any later step
you notice the verify paste is missing from this session, stop immediately
and return here. This block exists because on Jul 4 a wave was dispatched
with the isolation steps silently skipped and nothing caught it.

Print worktree summary:
  "Worktrees created (verified):
    Stream A → [STREAM_WORKTREE[A]] (branch: [STREAM_BRANCH[A]])
    Stream B → [STREAM_WORKTREE[B]] (branch: [STREAM_BRANCH[B]])
    [etc.]"

For each STREAM W[WAVE_NUM][X]:

Determine MEMORY_CONTENT:
  Domain classification: check all tasks in stream against category keywords.
  If all tasks are security/auth → include first 150 lines of `.autocode/agents/security.md`
  If all tasks are tests/edge-case → include first 150 lines of `.autocode/agents/qa.md`
  If all tasks are async/arch/error-handling/data-loss → include first 150 lines of `.autocode/agents/architect.md`
  If stream spans multiple domains → include first 100 lines of each relevant file, each labeled:
    "## Security Agent Memory (first 100 lines)" / "## Architect Agent Memory (first 100 lines)" / etc.
    Never exceed 200 lines total across all memory files for one stream.

Create briefs directory if it doesn't exist:
- If MODULE is set: `mkdir -p .autocode/modules/[MODULE]/briefs/`
- Otherwise: `mkdir -p .autocode/briefs/`

Name mapping for streams: A→WORKER_NAMES[0], B→WORKER_NAMES[1], C→WORKER_NAMES[2], D→WORKER_NAMES[3] (resolved via STREAM_WORKER_MAP above).

Write the brief file for each stream (path depends on MODULE — see MODULE_CONTEXT above):

```markdown
# [NAME] — Stream W[WAVE_NUM][X] — Wave [WAVE_NUM] — [today's date]

IDENTITY RULE — MANDATORY: End EVERY response with exactly this line, no exceptions
(including short replies, confirmations, and one-word answers):
— [NAME] | W[WAVE_NUM][X] | [space-separated task numbers e.g. #003 #007]

[If MODULE is set, include the following block. If MODULE is not set, omit it entirely:]
## Active Module
MODULE: [MODULE]

This window is scoped to the [MODULE] module. Your worktree carries its own
per-checkout module marker: wave-worktrees.sh create wrote "[MODULE]" into
your worktree's private git dir at $(git rev-parse --absolute-git-dir)/active-module.
All suite commands (`/task`, `/audit`, `/tasks`, etc.) resolve that marker
automatically (MODULE_CONTEXT step 2) and route all writes to
`.autocode/modules/[MODULE]/`. Never read or write
`.autocode/modules/.active-module` from this worktree — that legacy file is
main-checkout back-compat only (MODULE_CONTEXT rule 3).
Nothing to set up — the marker was written when your worktree was created;
the one instruction above (leave the legacy file alone) is all there is to heed.
[End of conditional MODULE block]

## WORKING DIRECTORY — MANDATORY FIRST STEP
Your isolated git worktree (independent branch of this repo):
  Path:   [STREAM_WORKTREE[X]]   ← UNIQUE per stream
  Branch: [STREAM_BRANCH[X]]     ← UNIQUE per stream

Your FIRST action before any /task command:
  Run this in a Bash tool call: cd [STREAM_WORKTREE[X]]
  Verify: run `pwd` — it must print [STREAM_WORKTREE[X]]

Why this matters: after cd, Claude Code resolves all file paths relative to the worktree.
Your file edits land on branch [STREAM_BRANCH[X]], isolated from other streams.
The .autocode/ directory is symlinked to the main repo — suite commands (/task, /audit)
work normally from your worktree CWD.

The orchestrator merges your branch to main in W.5d after you report done.
You do not need to git push or commit to main. The orchestrator handles it.
Do not push, do not merge, do not switch branches.
If you want to preserve mid-task work:
  git add -A -- . ':!.autocode' && git commit -m "wip: [description]"
⚠ NEVER run a bare `git add -A` here — always append `-- . ':!.autocode'`.
Your .autocode is a symlink to the main repo; staging it can commit tracked-file
deletions that a later merge would sweep onto main (the merge refuses such
branches, which would strand your whole stream).

⚠ If you skip the cd step and edit files from the repo root CWD, your changes land in
the shared working tree and can be wiped by concurrent sessions. The cd is not optional.

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

After writing all brief files:

Create queue directory if it does not exist:
- If MODULE is set: `mkdir -p .autocode/modules/[MODULE]/queue/`
- Otherwise: `mkdir -p .autocode/queue/`

For each STREAM W[WAVE_NUM][X], write the queue file at the appropriate path (using WORKER_NAMES[0], WORKER_NAMES[1], etc. — lowercase — see MODULE_CONTEXT for path):

```markdown
---
status: pending
agent: {name}
stream: W{WAVE_NUM}{X}
wave: {WAVE_NUM}
worktree: {STREAM_WORKTREE[X]}
branch: {STREAM_BRANCH[X]}
---

{full brief content — identical to the stream-W[WAVE_NUM][X]-start.md content written above}
```

Print:
```
Queue files written:
  .autocode/queue/[WORKER_NAMES[0]].md  — status: pending
  .autocode/queue/[WORKER_NAMES[1]].md  — status: pending
  [etc. for each active stream]
```

── QUEUE FRONTMATTER RECHECK (MANDATORY — before W.4) ──

Run exactly (QUEUE_DIR = the queue directory used above; iterate ONLY this
wave's workers — a stale pre-migration file for an idle worker is not this
wave's problem and its "fix from WAVE_WT values" recovery would not apply):
  for name in [the worker name of each ACTIVE stream this wave, space-separated
  — NOT the full roster: streams can be fewer than workers, and an idle
  worker has no queue file this wave]; do q="[QUEUE_DIR]/$name.md"; printf '%s: ' "$q"; \
    grep -q '^worktree: /' "$q" && grep -q '^branch: ' "$q" && echo OK || echo MISSING; done

Paste the full output. Any MISSING line is a TOYOTA STOP: rewrite that queue
file's frontmatter from the parsed WAVE_WT values and re-run this recheck.
Never print the terminal guide while any queue file lacks worktree:/branch:.
This recheck exists because on Jul 4 a wave was dispatched with
prose-specified-but-never-written frontmatter and nothing caught it — /go now
hard-stops on such files, so a wave that skips this recheck strands every worker.

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

Worker names for this session (from STREAM_WORKER_MAP):

Print:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  WAVE [WAVE_NUM] — OPEN [N] TERMINAL WINDOWS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Open [N] new terminal windows and start Claude Code in each.
In each window, type:

  /go

Each window auto-claims the next pending queue slot and starts.
(Or type /go [WORKER_NAMES[0]], /go [WORKER_NAMES[1]], etc. to claim a specific slot.
Worker names for this wave: Stream A → /go [WORKER_NAMES[0]]  Stream B → /go [WORKER_NAMES[1]]  ...)

Each Claude will end every response with their name so you
always know which window you're in.

Come back here when windows finish. Type:
  done          — all streams complete
  done [WORKER_NAMES[0]]                    — that stream done (others still running)
  done [WORKER_NAMES[0]] [WORKER_NAMES[1]]  — multiple streams done
  stuck [WORKER_NAMES[0]]                   — that stream hit a problem (describe it after)

After receiving `done [names]`, cross-check each name against WORKER_NAMES.
If a name is not in WORKER_NAMES, print: "Unknown worker name: [x]. Expected one of: [WORKER_NAMES]. Did you mean [closest]?" Never silently ignore unrecognized names.
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
  [STREAM_WORKER_MAP[A]]  (W[N]A) — [full content of completion.md]
  [STREAM_WORKER_MAP[B]]  (W[N]B) — [full content of completion.md]
  [STREAM_WORKER_MAP[C/D] if present]
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
      stream_name: STREAM_WORKER_MAP[X],  ← e.g. "Adam", "Eric", whatever was assigned this wave
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
Sub-step W.5d — Merge stream branches and remove worktrees
─────────────────────────────────────────────────────────

Context: W.5a-c already applied COMPLETE statuses, debt, and carry-forwards from
.autocode/ (which landed in the main repo via the .autocode/ symlink during the wave).
This step merges the actual source code changes from each stream's git branch, then cleans up.
The merge/cleanup script calls below are runnable from ANY checkout, including
this window's module worktree — the script operates on the main checkout itself.

Load STREAM_WORKTREE[X] and STREAM_BRANCH[X]:
  If in-memory values are set (no session interruption): use them.
  Else: read from STATE_FILE_PATH (the .wave-state.json written by the script in W.3).
    If STATE_FILE_PATH is also missing: print:
    "✗ Cannot find stream state (.wave-state.json missing and in-memory state lost).
     Cannot merge stream branches. Streams may have uncommitted work at the paths
     listed in the 'worktree' fields of each queue file.
     Check .autocode/modules/[MODULE]/queue/*.md for worktree paths, then merge
     with: bash scripts/wave-worktrees.sh merge [MODULE_SLUG] [WAVE_NUM] once state is restored."
    Skip W.5d. Continue to W.6 (the commit will include only .autocode/ changes).

  Step 1 — Commit each stream's uncommitted work (in sequence):
    For each STREAM W[WAVE_NUM][X] with a worktree record:
      Run: git -C "[STREAM_WORKTREE[X]]" status --porcelain
      If any output:
        git -C "[STREAM_WORKTREE[X]]" add -A -- . ':!.autocode'
        git -C "[STREAM_WORKTREE[X]]" commit -m "advance: stream [X] wave [WAVE_NUM] final commit"
        Print: "✓ Stream [X]: committed remaining uncommitted work"
      Else:
        Print: "✓ Stream [X]: worktree clean (nothing to commit)"
      Then check: git -C "[STREAM_WORKTREE[X]]" status --porcelain -- .autocode | grep -v '^??'
      If non-empty: TOYOTA STOP — tracked .autocode paths are staged/modified in
      this worktree. Do NOT merge; a branch carrying .autocode deletions would
      destroy shared module state (the script's merge guard refuses it anyway).
      Fix the index (git -C ... restore --staged .autocode) and re-run Step 1.

  Step 2 — Merge all stream branches (script-owned; guards included):
    Run exactly: bash scripts/wave-worktrees.sh merge [MODULE_SLUG] [WAVE_NUM]
    Paste the COMPLETE output.
    The script is two-pass: Pass 1 runs ALL guards before touching anything —
    the staged-index guard on main, then EVERY stream's tracked-.autocode-deletion
    guard — and dies before a single branch is merged if any guard fails.
    Pass 2 merges each branch --no-ff, skips already-merged branches, and on a
    true content conflict AUTO-ABORTS (it never auto-resolves); a failure that
    is not a content conflict is labeled "NOT a content conflict" with main
    left unchanged.

    ── TOYOTA STOP & FIX — if merge exits non-zero ──
    If the failure is a CONFLICT (the script has already auto-aborted the merge;
    main is clean; nothing is in progress):
    Print:
    "✗ MERGE CONFLICT — wave [WAVE_NUM] (script aborted the merge; main is clean)
     
     Root cause: W.1 should have ensured streams own disjoint files. A conflict means
     either (a) a worker edited a file outside their File: field, or (b) a carry-forward
     from a prior wave modified a file this stream also owns.
     
     All resolution commands run against the MAIN checkout. This window sits in a
     module worktree (scope.md requires it) — a bare `git merge` here would merge the
     stream branch into [MODULE]-window, NOT main. Bind MAIN_ROOT and run the chosen
     merge in the SAME Bash tool call (each Bash call is a fresh shell — a binding
     from an earlier call does not survive):
       MAIN_ROOT=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")

     Resolution options (each names the exact command — run only what Max picks):
       resolve stream-over — git -C "$MAIN_ROOT" merge --no-ff -X theirs [STREAM_BRANCH[X]] -m 'advance: wave [WAVE_NUM] stream [X] merge (stream-over)'
                             (keeps the stream's side for conflicting hunks;
                              non-conflicting changes from BOTH sides land)
       resolve main-over   — git -C "$MAIN_ROOT" merge --no-ff -X ours [STREAM_BRANCH[X]] -m 'advance: wave [WAVE_NUM] stream [X] merge (main-over)'
                             (keeps main's side for conflicting hunks ONLY;
                              the stream's non-conflicting changes still land)
       manual              — git -C "$MAIN_ROOT" merge --no-ff [STREAM_BRANCH[X]], then edit each
                             conflicted file under $MAIN_ROOT, `git -C "$MAIN_ROOT" add` each
                             resolved file, and finish with `git -C "$MAIN_ROOT" commit --no-edit`
     Never offer or run `-s ours`: it records a merge while discarding EVERY
     change on the stream branch — wholesale stream abandonment is a cleanup
     decision made with Max, not a merge option.
     
     This is a hard stop. Do not merge the next stream until this one resolves.
     Return to Wait state."
    Wait for Max input. Run exactly the chosen command, then re-run:
    bash scripts/wave-worktrees.sh merge [MODULE_SLUG] [WAVE_NUM]
    (the script skips already-merged branches, so re-running merges only the rest).
    If the failure is the staged-index guard or the .autocode-deletion guard:
    that refusal is the safety working — print it, resolve the underlying state
    with Max, never work around the guard.
    If the failure is labeled "NOT a content conflict": main is unchanged and no
    merge is in progress — read the git output above the label, fix the named
    condition, and re-run the merge command.
    ── end TOYOTA STOP ──
    
    Print: "✓ All wave [WAVE_NUM] stream branches merged."

  Step 3 — Remove worktrees and delete branches (script-owned; refuse-if-work-lost):
    Run exactly: bash scripts/wave-worktrees.sh cleanup [MODULE_SLUG] [WAVE_NUM]
    Paste the COMPLETE output.
    Branch deletion uses refuse-if-unmerged semantics (never force-delete). If
    cleanup refuses, a worktree holds uncommitted work or a branch holds unmerged
    commits — that refusal is the safety working: inspect with Max
    (git log main..[branch]), merge or recover the work, then re-run cleanup.
    The script also deletes the state file and prints the remaining worktree list;
    verify only the main checkout and module windows remain.

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

  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
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
- Every wave prints a PLAN SUMMARY before W.3 (informational); the approval boundary is the terminal-window guide — no work starts until Max physically opens the worker windows after MECHANICAL VERIFY
- Each wave commits independently (W.6) before looping — never accumulate changes across waves
- Sequential Handoff must list DEFERRED in dependency order (Pass 1/2/3 algorithm)
- Never auto-start /task after Sequential Handoff or Batch Complete — Max decides
- Never fork child CTOs — every Claude that writes code runs in its own terminal window with Max present
