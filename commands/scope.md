# scope — Module Session Identity

Sets this Claude Code window's identity to a specific System 1701 module. After running, all work in this session is scoped to that module's paths, task file, and memory files.

---

## MODULE REGISTRY

```
email       apps/web/src/app/dashboard/inbox
            apps/web/src/components/email
            apps/web/src/lib/email
            apps/web/src/app/api/email
            packages/ordinatio-email

scheduling  apps/web/src/app/dashboard/scheduling
            apps/web/src/components/scheduling
            apps/web/src/app/api/scheduling
            packages/ordinatio-scheduling
            packages/ordinatio-booking-widget

clients     apps/web/src/app/dashboard/clients
            apps/web/src/app/api/clients

orders      apps/web/src/app/dashboard/orders
            apps/web/src/app/api/orders
            apps/worker/src/consumers

sms         apps/web/src/app/dashboard/texts
            apps/web/src/app/api/sms

cms         apps/web/src/app/dashboard/website
            packages/ordinatio-cms

agents      apps/web/src/app/api/agent
            packages/ordinatio-agent

auth        packages/ordinatio-auth
            packages/ordinatio-security

settings    apps/web/src/app/dashboard/settings
            packages/ordinatio-settings

worker      apps/worker/src

ui          packages/ordinatio-ui
            packages/ordinatio-errors
            packages/ordinatio-activities

tasks       packages/ordinatio-tasks
            apps/web/src/app/dashboard/tasks
            apps/web/src/app/api/tasks

automation  packages/ordinatio-jobs
            apps/web/src/app/api/automations

marketing   packages/ordinatio-marketing-core
            apps/web/src/app/dashboard/marketing
            apps/web/src/app/api/marketing

newsletter  packages/ordinatio-newsletter
            apps/web/src/app/dashboard/newsletter
            apps/web/src/app/api/newsletter

social      packages/ordinatio-social
            apps/web/src/app/dashboard/social
            apps/web/src/app/api/social

domus       packages/ordinatio-domus

realtime    packages/ordinatio-realtime
            apps/web/src/app/api/realtime

core        packages/ordinatio-core

entities    packages/ordinatio-entities
            apps/web/src/app/api/entity-knowledge

dedupe      packages/ordinatio-people-dedupe
            apps/web/src/app/dashboard/dedupe
            apps/web/src/app/api/dedupe
```

---

## ARGUMENT PARSING

Parse `$ARGUMENTS` before any other step:
```
Split $ARGUMENTS on whitespace.
First token = ACTION_OR_MODULE (the module name or "clear")
If second token exists AND is a positive integer (1-24): WORKER_COUNT = int(second token)
Else: WORKER_COUNT = 4 (default)
Examples:
  "email"    → MODULE = "email",    WORKER_COUNT = 4
  "email 6"  → MODULE = "email",    WORKER_COUNT = 6
  "clear"    → scope clear path (WORKER_COUNT ignored)
  "clear 3"  → scope clear path (count is ignored for clear)
```

---

## STEP 0 — Handle `/scope clear`

If `$ARGUMENTS` starts with "clear" (case-insensitive):

**Exact sequence (order is critical — resolve the module BEFORE deleting markers):**
1. Resolve CURRENT_MODULE:
   ```bash
   bash scripts/wave-worktrees.sh get-module
   ```
   (Falls back to the legacy `.autocode/modules/.active-module` automatically.)
2. If CURRENT_MODULE is non-empty:
   ```bash
   POOL_DIR="$(git rev-parse --show-toplevel)/.autocode/modules"
   python3 ~/.claude/scripts/worker-pool.py --pool-dir "$POOL_DIR" release [CURRENT_MODULE]
   ```
   Print the script's stdout (it confirms what was released).
3. Delete this checkout's marker; delete the legacy file only when in the main checkout:
   ```bash
   rm -f "$(git rev-parse --absolute-git-dir)/active-module"
   [ "$(git rev-parse --absolute-git-dir)" = "$(git rev-parse --path-format=absolute --git-common-dir)" ] \
     && rm -f .autocode/modules/.active-module
   ```
4. Print: "Module scope cleared — this session will use global paths.
   (The module worktree, if any, is NOT removed — worktrees are durable across
   sessions. Retiring a module branch is a merge/cleanup decision made with Max
   from the main checkout, never a side effect of /scope clear.)"
5. Stop. Do not proceed to Step 1.

---

## STEP 1 — Identify module

If `[module]` was provided as an argument, use it. If not, list the registry and ask:
```
Which module is this window working on?
  email / scheduling / clients / orders / sms / cms / agents / auth / settings / worker / ui
```

Validate the input against the registry. If not found, list available modules and ask again.

---

## STEP 1.5 — Module worktree (MANDATORY isolation)

Module windows never share the main checkout's index. This step gives this
window its own worktree, or confirms it is already in one.

**A. Already in this module's worktree?**
```bash
git rev-parse --abbrev-ref HEAD
```
If it prints `[MODULE]-window`: print "✓ already in the [MODULE] module worktree ($(pwd))",
then verify the reused worktree is still healthy — long-lived worktrees can lose
their armed hooks or .autocode symlink between sessions, and a reused worktree
that skips verification runs the silent-zero-hooks failure this whole step exists to close:
```bash
bash scripts/wave-worktrees.sh verify module [MODULE]
```
Paste the complete output. All ✓ → skip to STEP 2. Any ✗ → run
`bash scripts/wave-worktrees.sh provision "$(pwd)" [MODULE]`, re-run verify,
paste again; still failing → hard stop (report the ✗ lines; do not proceed).
If it prints some OTHER module's `-window` branch: hard stop — this window is
scoped to a different module's worktree. Open a new window for [MODULE] instead.

**B. STAGED-WORK GUARD.** `git diff --cached` inspects the index of the
checkout this window is currently sitting in — the paste must name which
checkout that is. Run:
```bash
git rev-parse --show-toplevel   # names WHICH checkout's index is inspected
git diff --cached --name-only
```
(Step A already diverted windows on a `-window` branch, so this checkout must
be the main one. Confirm mechanically — no eyeballing paths:
```bash
[ "$(git rev-parse --absolute-git-dir)" = "$(git rev-parse --path-format=absolute --git-common-dir)" ] && echo MAIN || echo WORKTREE
```
It must print MAIN; if it prints WORKTREE, stop: this window must not run
scope from inside a worktree it did not claim via step A.)
- If any staged path is inside THIS module's registry paths → **hard stop**:
  "✗ Staged [MODULE] changes exist in the main index. A worktree branched from
  HEAD would not contain them, and the merge back is guaranteed to conflict.
  Land or unstage that work first. This is a hard stop."
- If staged paths exist but all belong to OTHER modules: print the list, name
  which module(s) they map to, and require Max to type `ack` before continuing:
  "A NEW worktree branches from HEAD (not the index), so those staged changes
  won't leak in — but a REUSED module worktree may be BEHIND main: `single`
  prints a 'behind main' warning with the exact catch-up command
  (`git -C [WT_PATH] merge main`) — run it before working. Either way this
  window must never touch the main index. Type `ack` to continue."
- If nothing is staged: continue silently.

**C. Create/enter the worktree (script-owned; missing script = hard stop):**
If `scripts/wave-worktrees.sh` does not exist, print the same "NOT FOUND" hard
stop as /advance (install from claude-dev-team, run its test suite) and stop.
```bash
bash scripts/wave-worktrees.sh single [MODULE]
```
Parse the `WAVE_WT` TSV line VERBATIM → WT_PATH (field 3). Then:
```bash
cd [WT_PATH]
pwd                                  # must print WT_PATH exactly
git rev-parse --abbrev-ref HEAD      # must print [MODULE]-window exactly
bash scripts/wave-worktrees.sh verify module [MODULE]
```
Paste all four outputs. Any mismatch, ✗ line, or VERIFY FAIL → TOYOTA hard
stop: do not proceed to STEP 2; fix the root cause (the refusal/failure output
names it) and re-run STEP 1.5.

---

## STEP 2 — Load module context

Run these commands and read these files. Capture all results.

**A. Recent git activity:**
```bash
git log --oneline -5 --format="%h %ar %s" -- [paths for this module]
```

**B. Open tasks** — if `.autocode/modules/[module]/tasks.md` exists, run:
```bash
python3 -c "
import re, sys
try:
    text = open('.autocode/modules/[module]/tasks.md').read()
    blocks = re.split(r'(?=### Task #)', text)
    open_count = sum(1 for b in blocks if '### Task #' in b and '**Status: COMPLETE' not in b)
    done_count = sum(1 for b in blocks if '### Task #' in b and '**Status: COMPLETE' in b)
    print(f'{open_count} open / {done_count} done')
except: print('—')
" 2>/dev/null || echo "—"
```
(Replace `[module]` with the actual module name in the command.)
If file doesn't exist: note "No task file yet — run /scan to generate one."

**C. Module memory files** — read each if it exists:
  - `.autocode/modules/[module]/state.md` — free-form state of the nation: history, known decisions, current status. Read this first.
  - `.autocode/modules/[module]/profile.md` — type, integrations, seam contracts, known gotchas
  - `.autocode/modules/[module]/standards.md` — module-specific quality criteria injected into /task build context
  - `.autocode/modules/[module]/security.md` — auth gaps, past security findings
  - `.autocode/modules/[module]/architect.md` — async contracts, data-loss risks, structural findings
  - `.autocode/modules/[module]/qa.md` — test coverage gaps, edge cases, known flaky tests

  For each file that exists: read the full content and incorporate into this session's context.
  For files that don't exist: note as "not yet generated."

**D. WorldClass history** — if `.autocode/modules/[module]/cto.md` exists:
  Find `WorldClass score: [N]/100` lines → average the last 3.
  If file doesn't exist: "—"

---

## STEP 3 — Write persistence file and print scope banner

First, persist this checkout's module identity (per-checkout marker — NOT the
old shared last-writer-wins file, which let one window silently clobber
another's identity):
```bash
bash scripts/wave-worktrees.sh set-module [module]
bash scripts/wave-worktrees.sh get-module
```
Paste the get-module output — it must print `[module]` exactly (read-back proof).

Back-compat: ONLY if this session is somehow still in the main checkout
(STEP 1.5 normally prevents this), also write the legacy file so older
commands keep resolving:
```bash
[ "$(git rev-parse --absolute-git-dir)" = "$(git rev-parse --path-format=absolute --git-common-dir)" ] \
  && mkdir -p .autocode/modules && echo "[module]" > .autocode/modules/.active-module || true
```
Never write the legacy `.autocode/modules/.active-module` from inside a module
worktree — that is the exact clobber this design removes.

Print: `  Module marker written: $(git rev-parse --absolute-git-dir)/active-module`

── Pool Integration ──

POOL_DIR="$(git rev-parse --show-toplevel)/.autocode/modules"

**1. Initialize pool if needed (check file existence, not status exit code):**
```bash
[ -f "$POOL_DIR/.worker-pool.json" ] || python3 ~/.claude/scripts/worker-pool.py --pool-dir "$POOL_DIR" init
```
If `init` ran: print its output.

**2. Claim workers:**
```bash
python3 ~/.claude/scripts/worker-pool.py --pool-dir "$POOL_DIR" claim [MODULE] [WORKER_COUNT]
```
Capture all stdout → CLAIM_OUTPUT.
- WORKER_NAMES = lines of CLAIM_OUTPUT that do NOT start with `#` (the actual names, lowercase)
- WARNINGS = lines of CLAIM_OUTPUT that start with `#`
- If WARNINGS non-empty: print each warning line (user must see pool exhaustion / partial warnings)
- WORKER_COUNT_ACTUAL = len(WORKER_NAMES)
(The script already wrote `.autocode/modules/[MODULE]/.workers`)

To compute N_REMAINING: run `python3 ~/.claude/scripts/worker-pool.py --pool-dir "$POOL_DIR" status` and parse the `Available: [N]` line, extracting the integer N.

Then print the scope banner:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SCOPE: [MODULE UPPERCASE] — System 1701
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Paths:
    [each path on its own indented line]

  Tasks:       [N open / N done]   (or "run /scan to generate")
  WC Avg:      [N/100]             (or "—")
  Last commit: [relative time + short subject from git log]

  Memory:
    [✓ state.md]      (or [· not yet written])
    [✓ profile.md]    (or [· not yet generated])
    [✓ standards.md]  (or [· not yet generated — run /scan to generate])
    [✓ security.md]   (or [· not yet generated])
    [✓ architect.md]  (or [· not yet generated])
    [✓ qa.md]         (or [· not yet generated])

  Workers:  [WORKER_NAMES joined with ", "]  ([WORKER_COUNT_ACTUAL] claimed · [N_REMAINING] remaining in pool)
            Run in child windows:  [for each name: /go [name], space-separated]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  This window is now the [MODULE] window.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

If WORKER_COUNT_ACTUAL = 0, replace the Workers line with:
`  Workers:  NONE — pool exhausted. Run \`/scope clear\` in another session to release workers.`

---

## STEP 4 — Establish session rules

For the remainder of this session:

1. **Task file:** All task tracking uses `.autocode/modules/[module]/tasks.md` — not the global `.autocode/tasks.md`
2. **Paths:** All audits, scans, tests, and code changes are limited to the module paths above
3. **Memory routing:** Write findings to the module's own memory files:
   - Security/auth findings → `.autocode/modules/[module]/security.md`
   - Async, architecture, data-loss → `.autocode/modules/[module]/architect.md`
   - Tests, coverage, edge cases → `.autocode/modules/[module]/qa.md`
   - WorldClass scores → `.autocode/modules/[module]/cto.md`
4. **Scope enforcement:** If asked to change something outside these paths, flag it:
   > "That file is outside the [module] scope. Want me to handle it here anyway, or should you open a new window for that module?"

---

## STEP 5 — If no task file exists, offer to generate one

If `.autocode/modules/[module]/tasks.md` does not exist, print:
```
No task file found for [module].

  /scan      — examine this module now and generate a task list
  skip       — start working without a task list
```

If `/scan` is chosen: run a full examination of the module paths (like /meet but scoped). Write output to `.autocode/modules/[module]/tasks.md`. Then continue to Step 6.

If `skip` is chosen: continue to Step 6 immediately.

---

## STEP 6 — Ask what to do

```
What would you like to work on?
  /tasks        — view the task list for this module
  /task [N]     — work on task #N
  /scan         — re-examine this module and refresh the task list
  tell me       — describe what you need
```

Wait for input and proceed accordingly.

**If `/task [N]`:** Run the full CTO cycle (build → audit → WorldClass) on that task, scoped to the module paths. Route all findings to the module memory files.

**If `/tasks`:** Print the task list from `.autocode/modules/[module]/tasks.md` as a formatted table. Mark open vs complete.

**If `/scan`:** Run a scoped examination of the module paths. Write the updated task list to `.autocode/modules/[module]/tasks.md`. Print a summary of findings.

**If `tell me`:** Listen to what the user needs, then decide whether it maps to an existing task or is new work. If new: add it to the task file and start work.
