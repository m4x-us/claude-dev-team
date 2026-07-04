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

**Exact sequence (order is critical — read `.active-module` BEFORE deleting it):**
1. If `.autocode/modules/.active-module` exists: read its content → CURRENT_MODULE (trim whitespace).
2. If CURRENT_MODULE is non-empty:
   ```bash
   POOL_DIR="$(git rev-parse --show-toplevel)/.autocode/modules"
   python3 ~/.claude/scripts/worker-pool.py --pool-dir "$POOL_DIR" release [CURRENT_MODULE]
   ```
   Print the script's stdout (it confirms what was released).
3. Delete the file:
   ```bash
   rm -f .autocode/modules/.active-module
   ```
4. Print: "Module scope cleared — this session will use global paths."
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

First, write the active module file so parallel windows and long sessions can inherit MODULE:
```bash
mkdir -p .autocode/modules
echo "[module]" > .autocode/modules/.active-module
```
(Replace `[module]` with the actual module name — lowercase, no whitespace.)

Print: `  Active module file: .autocode/modules/.active-module written`

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
