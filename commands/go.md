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

**2. Active-module file (fallback — for /go with no argument, or when pool unavailable):**
If `.autocode/modules/.active-module` exists:
  MODULE = file contents (one line, trimmed), SOURCE = ".active-module file"

**3. Unset:** MODULE is not set — use global `.autocode/queue/` path throughout.

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
  (If yes: proceed to Step 3.)

**If STATUS = pending:**
  Proceed to Step 3.

---

## Step 3 — Claim

Edit QUEUE_FILE: change the line `status: pending` → `status: in_progress` in the frontmatter.

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
         If /advance is still in W.3: wait for it to finish, then retry /go [AGENT_NAME]
         If /advance crashed: re-run it — the stale check offers to prune and recreate"
      Stop.

  Step 2 — Verify .autocode symlink:
    Run Bash: [ -L "[WORKTREE_PATH]/.autocode" ] || [ -d "[WORKTREE_PATH]/.autocode" ]
    If neither:
      Print: "⚠ .autocode symlink missing in worktree — suite commands won't find task files.
      Fix (run this Bash): rm -rf [WORKTREE_PATH]/.autocode && ln -sf $(git rev-parse --show-toplevel)/.autocode [WORKTREE_PATH]/.autocode"
      (Print warning but do not stop — symlink can be recreated before first /task)

  Print:
  "╔══ Worktree isolation active ══════════════════════╗
   ║  Path:    [WORKTREE_PATH]
   ║  Branch:  [WORKTREE_BRANCH]
   ║  .autocode → main repo symlink verified ✓
   ╠═══════════════════════════════════════════════════╣
   ║  FIRST ACTION: cd [WORKTREE_PATH]
   ║  Then run your tasks as normal.
   ╚═══════════════════════════════════════════════════╝"

Else:
  Print: "⚠ No 'worktree:' field in queue file — running in shared working directory.
  (Pre-worktree-isolation format. No file isolation. Edits can be wiped by concurrent sessions.)"

---

## Step 4 — Execute brief

If WORKTREE_PATH is non-empty:
  Print:
  "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    ISOLATION REMINDER — before your first /task:
    1. cd [WORKTREE_PATH]   (sets CWD; routes all file edits to your worktree)
    2. pwd                  (verify — must print [WORKTREE_PATH])
    3. Then run /task normally
    Skipping the cd means your edits land in the shared working tree and can be
    wiped by a concurrent session. The cd is not optional.
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

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

Then follow the "When You Finish" instructions from the brief (print the done message to notify Max).
