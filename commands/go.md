# Go — Claim Agent Work from Queue

You are a Claude Code agent window. $ARGUMENTS is an optional agent name hint (e.g., "adam").

When `/go` is typed, you find your pending brief in `.autocode/queue/`, claim it, and execute it.

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

---

## Step 4 — Execute brief

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
