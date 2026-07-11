# Go — Claim Agent Work from Queue

You are a Claude Code agent window. $ARGUMENTS is an optional agent name hint (e.g., "adam").

When `/go` is typed, you find your pending brief in `.autocode/queue/`, claim it, and execute it.

---

## MODULE_CONTEXT (s1701 module sessions only)

**How MODULE is determined — check in this order:**

**1. Worker pool lookup (primary — for child windows with a known name):**
If `$ARGUMENTS` (AGENT_HINT) is non-empty AND `.autocode/modules/.worker-pool.json` exists:
  Run: `python3 ~/.claude/scripts/worker-pool.py lookup [AGENT_HINT_lowercase]`
  - If output is non-empty and ≠ "unowned": MODULE = output, SOURCE = "worker pool — [AGENT_HINT_lowercase]"
  - If worker-pool.py not found, or output = "unowned":
    Print note in output: "Pool lookup unavailable or name unowned — falling through to .active-module"
    Proceed to step 2.

**2. Per-checkout marker (for windows already inside a worktree):**
If `$(git rev-parse --absolute-git-dir)/active-module` exists:
  MODULE = file contents (one line, trimmed), SOURCE = "checkout marker"
  (Each worktree resolves its own module — written by wave-worktrees.sh.)

**3. Active-module file (legacy fallback — main checkout back-compat):**
Only if `[ "$(git rev-parse --absolute-git-dir)" = "$(git rev-parse --path-format=absolute --git-common-dir)" ]`
(this checkout IS the main checkout) AND `.autocode/modules/.active-module` exists:
  MODULE = file contents (one line, trimmed), SOURCE = ".active-module file"
  (Never read the legacy file from inside a worktree — each worktree resolves
  its own module via the step-2 marker.)

**4. Unset:** MODULE is not set — use global `.autocode/queue/` path throughout.

**When MODULE is determined, print at the TOP of output (before any other text):**
`╔══ Module scope: [MODULE] (source: [SOURCE]) ══╗`
Examples:
  Pool case:  `╔══ Module scope: email (source: worker pool — adam) ══╗`
  File case:  `╔══ Module scope: email (source: .active-module file) ══╗`
SOURCE string is conditional — use whichever source actually resolved MODULE.
If MODULE is unset: omit this header entirely.

If MODULE is set:
- Replace `.autocode/queue/` with `.autocode/modules/[MODULE]/queue/` in ALL queue path
  references in this file (Step 1, Step 2, Step 5)

---

## Step 1 — Resolve identity

AGENT_HINT = $ARGUMENTS (may be empty, lowercase it).

**If AGENT_HINT is non-empty:**
  AGENT_NAME = AGENT_HINT (lowercase)
  QUEUE_FILE = `.autocode/queue/{AGENT_NAME}.md`
  If QUEUE_FILE does not exist:
    Print: "No queue file for '{AGENT_NAME}'. Has /advance been run for this wave?"
    Stop.

**If AGENT_HINT is empty:**
  List all `.md` files in `.autocode/queue/`. Read each (alphabetical).
  For each: look for `status: pending` in the frontmatter (between `---` markers).
  First file with `status: pending` → AGENT_NAME = filename without .md, QUEUE_FILE = that path. Break.
  If none found:
    Print:
    ```
    No pending work in .autocode/queue/.
      • /advance hasn't been run yet — run it to plan the next wave, or
      • All queue slots are in_progress or done — check .autocode/queue/*.md for status
    ```
    Stop.

---

## Step 2 — Check status

Read QUEUE_FILE. Extract from frontmatter (between the `---` markers):
  STATUS ← value of `status:` line
  STREAM ← value of `stream:` line
  WAVE_NUM ← value of `wave:` line

**If STATUS = done:**
  Print: "✓ {AGENT_NAME}'s queue is done. Waiting for the /advance window to start the next wave."
  Stop.

**If STATUS = in_progress:**
  Print:
  ```
  ⚠ {AGENT_NAME}'s queue is already in_progress.
  Another window may be working on it, or a previous run crashed.
  Force-claim and restart? yes / no
  ```
  Wait for input. If no: stop.
  If yes — force-claim of an in_progress file does NOT run the Step-3 mutex:
  there is no `status: pending` line to flip, so the mutex would emit
  NOT_PENDING forever. Instead: run `rm -f [QUEUE_FILE].claiming` (clear any
  crashed claimer's sidecar), keep `status: in_progress` as-is, and proceed
  DIRECTLY to the Worktree Navigation block in Step 3 (skip the claim mutex).

**If STATUS = pending:**
  Proceed to Step 3.

---

## Step 3 — Claim

── Claim mutex (ONE Bash tool call — both entry modes) ──

The ENTIRE critical section below is ONE Bash tool call, including the exact
flip. Never substitute an Edit-tool call for the flip, and never a `sed -i`
variant (BSD and GNU `sed -i` syntax differ; the python flip below is
portable and races cannot split it — the sidecar is held around it).

```bash
q="[QUEUE_FILE]"
( set -C; : > "$q.claiming" ) 2>/dev/null || { echo CLAIM_LOST; exit 0; }
grep -q '^status: pending$' "$q" || { rm -f "$q.claiming"; echo NOT_PENDING; exit 0; }
python3 - "$q" <<'PY' || { rm -f "$q.claiming" "$q.flip"; echo FLIP_FAILED; exit 0; }
import re, sys, os
p = sys.argv[1]; s = open(p).read()
t = p + ".flip"
open(t, "w").write(re.sub(r'^status: pending$', 'status: in_progress', s, count=1, flags=re.M))
os.replace(t, p)   # atomic: a write failure leaves the original file intact
PY
grep -q '^status: in_progress$' "$q" || { rm -f "$q.claiming" "$q.flip"; echo FLIP_FAILED; exit 0; }
rm -f "$q.claiming"; echo CLAIMED
```

(python's text-mode read gives universal newlines, so a CRLF file matches and
is rewritten LF — harmless; grep and python agree on every line-ending
variant tested. The temp-file + os.replace write means a failure can never
truncate the queue file, and the read-back grep means CLAIMED is printed only
when the flip PROVABLY landed — the same read-back discipline set-module and
the skip-worktree guard use.)

Outcomes — ALL FOUR are handled in BOTH entry modes:

- `CLAIMED` → proceed below.
- `FLIP_FAILED` (either mode): hard stop — python failed or the read-back
  found no `status: in_progress` line. The brief was NOT claimed (the sidecar
  was released; the file is intact). Print the mutex output and the file's
  frontmatter verbatim, report in this window, and return to Wait state. Do
  not retry automatically — a failing flip means disk/permissions/frontmatter
  trouble a human should see.
- Bare `/go` (no name): on `CLAIM_LOST` or `NOT_PENDING`, move to the next
  pending candidate file (return to the Step-1 scan loop and continue from
  the next file alphabetically).
- Named `/go [name]`:
  - On `CLAIM_LOST`: print "another window claimed [AGENT_NAME]'s brief just
    now — nothing to do here" and stop.
  - On `NOT_PENDING`: print the file's actual `status:` line verbatim, then
    branch on that verbatim value — never edit the file before branching:
    - `status: in_progress` → you lost the claim race: another window flipped
      this brief between your Step-2 read and the mutex (or a claimer is
      mid-run). Do NOT touch the frontmatter — reverting it would re-claim
      work another window is executing. Print "lost the claim race —
      [AGENT_NAME]'s brief is already claimed. If no window is actually
      working it, re-run /go [AGENT_NAME] and use the Step-2 in_progress
      force-claim path." Stop.
    - `status: done` → the work already completed. Print "[AGENT_NAME]'s
      brief is already done — nothing to do." Stop.
    - Anything else (trailing whitespace, wrong case, a hand-edited variant
      that was INTENDED to be pending): "Step 2 read this as pending but the
      exact line `status: pending` is absent — trailing whitespace or
      hand-editing is the usual cause. Fix the frontmatter to the exact line
      `status: pending`, then re-run /go [AGENT_NAME]." Never loosen the
      mutex regex to paper over drifted frontmatter — fix the file.

── Stale sidecar recovery ──

The sidecar is held only inside the one Bash call above (<1 second). If
`CLAIM_LOST` repeats AND the file's status is still `pending` AND the sidecar
is older than 10 minutes:
```bash
q="[QUEUE_FILE]"
[ -f "$q.claiming" ] && [ $(( $(date +%s) - $(stat -f %m "$q.claiming") )) -gt 600 ] && echo STALE_SIDECAR
```
(BSD `stat -f %m` — this harness is darwin-only. Each Bash tool call is a
fresh shell — $q from the claim-mutex call does not survive; every satellite
snippet self-binds it.)
STALE_SIDECAR over a still-pending file means a claimer crashed mid-flip.
Print the finding to Max and offer force-claim: run `rm -f "[QUEUE_FILE].claiming"`,
then re-run the claim mutex above (status is still pending → it flips normally).

Print:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  {AGENT_NAME.toUpperCase()} — Stream {STREAM} — Wave {WAVE_NUM}
  Brief claimed. Starting tasks...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

── Worktree Navigation ──

Read from QUEUE_FILE frontmatter:
  WORKTREE_PATH ← value of `worktree:` line (empty string if field is absent)
  WORKTREE_BRANCH ← value of `branch:` line (empty string if field is absent)

If WORKTREE_PATH is non-empty:

  Step 1 — Verify path exists:
    Run Bash: [ -d "[WORKTREE_PATH]" ]
    If path does NOT exist:
      Print:
      "✗ WORKTREE NOT FOUND: [WORKTREE_PATH]
       
       /advance creates this in W.3 before sending workers.
       
       This is a hard stop. Do not run /task until the worktree exists.
       Return to Wait state.
       
       Recovery:
         First, revert the claim back to `pending`: edit QUEUE_FILE, change
           `status: in_progress` → `status: pending`, and run rm -f "[QUEUE_FILE].claiming"
           (another window can then claim this brief once the worktree exists)
         If /advance is still in W.3: wait for it to finish, then retry /go [AGENT_NAME]
         If /advance crashed: re-run it — the stale check offers to prune and recreate"
      Stop.

  Step 2 — Verify worktree provisioning (script-owned repair — never inline fixes):
    Run Bash: bash scripts/wave-worktrees.sh verify wt [WORKTREE_PATH]
    If it fails (any ✗ line, VERIFY FAIL, or non-zero exit):
      Run: bash scripts/wave-worktrees.sh provision "[WORKTREE_PATH]" [MODULE]
      (Omit [MODULE] if MODULE is unset — the script infers it from the
      worktree's marker, and dies with a named error if it cannot; pass it
      explicitly in that case.)
      Then re-verify: bash scripts/wave-worktrees.sh verify wt [WORKTREE_PATH]
      If STILL failing:
        Revert the claim back to `pending`: edit QUEUE_FILE, change
        `status: in_progress` → `status: pending`, and run rm -f "[QUEUE_FILE].claiming".
        Print: "✗ WORKTREE PROVISIONING BROKEN — verify still fails after a
        script-owned provision repair. Suite commands would read and write the
        WRONG task files. This is a hard stop. Report the verify output in
        this window and return to Wait state."
        Stop.

  Print:
  "╔══ Worktree isolation active ══════════════════════╗
   ║  Path:    [WORKTREE_PATH]
   ║  Branch:  [WORKTREE_BRANCH]
   ║  .autocode → main repo symlink verified ✓
   ╠═══════════════════════════════════════════════════╣
   ║  FIRST ACTION: cd [WORKTREE_PATH]
   ║  Then run your tasks as normal.
   ╚═══════════════════════════════════════════════════╝"

Else (worktree: field absent or empty):
  Revert the claim back to `pending`: edit QUEUE_FILE, change
  `status: in_progress` → `status: pending`, and run rm -f "[QUEUE_FILE].claiming".
  Print:
  "✗ QUEUE FILE HAS NO WORKTREE — refusing to run.
   [QUEUE_FILE] has no worktree:/branch: frontmatter, which means the dispatching
   /advance skipped W.3 (wave-worktrees.sh create + verify). The brief is invalid.
   There is NO shared-tree mode — executing this brief in the shared checkout can
   destroy concurrent work (this exact failure shipped the Jul-4 incident: 3 of 4
   workers' changes were wiped by interleaved git operations).
   Recovery: in the orchestrator window, re-run /advance so it re-dispatches this
   wave through W.3 and rewrites the queue files with worktree/branch fields.
   This is a hard stop. Return to Wait state."
  Stop.

---

## Step 4 — Execute brief

── ISOLATION VERIFY (MANDATORY — run and paste ALL FOUR outputs before the first /task) ──

  1. cd [WORKTREE_PATH]                      (sets CWD; routes all file edits to your worktree)
  2. pwd                                     → must print [WORKTREE_PATH] exactly
  3. git rev-parse --abbrev-ref HEAD         → must print [WORKTREE_BRANCH] exactly
  4. bash scripts/wave-worktrees.sh verify   → every line ✓, final line VERIFY PASS, exit 0

  Paste the complete output of all four commands into this window.
  Any mismatch, any ✗ line, or a VERIFY FAIL summary is a hard stop: do NOT
  run /task. Revert the claim back to `pending`: edit QUEUE_FILE, change
  `status: in_progress` → `status: pending`, and run rm -f "[QUEUE_FILE].claiming";
  then report the output in this window and return to Wait state.
  Skipping the cd means your edits land in the shared working tree and can be wiped by a concurrent session.
  The cd is not optional, and neither is the paste
  — a brief executed without a pasted PASS is invalid.

Read QUEUE_FILE again. Extract the brief body: everything after the closing `---` of the frontmatter (skip the frontmatter block entirely).

The brief body is your complete set of instructions — treat it as if Max had typed it directly. It contains:

- **IDENTITY RULE** — end every response with the signature line specified in the brief (no exceptions)
- **Your Tasks** — run each `/task #N` in the listed order
- **STATUS BOARD RULE** — print your status board after each completed task
- **Files You Own** — edit only these files
- **Off-Limits Files** — do not touch these
- **Task Definitions** — full task blocks for context
- **Agent Memories** — read before starting
- **Prior Wave Changes** — read before writing any code if present
- **When You Finish** — write `completion.md` and print "[NAME] is done."

Execute every instruction in the brief fully and in order.

---

## Step 5 — Mark done

After all tasks are complete and `completion.md` is written:
  Edit QUEUE_FILE: change `status: in_progress` → `status: done` in the frontmatter.
  Also run `rm -f [QUEUE_FILE].claiming` (idempotent — clears any stray sidecar).

Then follow the "When You Finish" instructions from the brief (print the done message to notify Max).
