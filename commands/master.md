# master — Master Window (Cross-Module)

Activates the Master window identity for System 1701. This window does not work on features —
it audits seam contracts between modules, tests API boundaries, and runs cross-module health sweeps.

The mechanical seam checks live in `scripts/seam-audit.sh`. That script exits 0/1,
produces pasteable terminal output, and is the authoritative proof — not a self-report.

---

## STEP 1 — Announce identity and run the audit

Print:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  MASTER WINDOW — System 1701
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Commands:
    seam [mod1] [mod2]    — test the API boundary between two modules
    audit [module]        — all seam checks scoped to one module
    health                — full cross-module health sweep
    check sse             — SSE event type registry detail
    check stream          — worker stream action registry detail
    check activity        — activity logging fire-and-forget detail

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Then immediately run:

```bash
bash scripts/seam-audit.sh
```

Paste the full output into the conversation. This IS the seam contract report.
Do not proceed to any sub-command until the script output is in the conversation.

---

## STEP 2 — Interpret the results

**For each `✗ FAIL` finding:**
1. Identify which module owns the flagged file(s) using the module registry below
2. Write the finding to `.autocode/modules/[module]/architect.md` (append, never overwrite):
   ```markdown
   ## [today's date] — master seam audit
   SEAM [N]: [brief description] — severity [8 for FAIL]
   File: [path]
   ```
3. If `.autocode/modules/[module]/tasks.md` exists and doesn't already have a task for this gap: add one

**For each `⚠ REVIEW` or `⚠ WARN` finding:**
1. Read 5 lines of context around each flagged site
2. Categorize as: SAFE (correct pattern, false positive), RISKY (has the bad pattern), or UNPROTECTED
3. Write RISKY/UNPROTECTED findings to the module's `architect.md` (severity 5-7)
4. SAFE findings require no action

**Module path registry** (for routing findings):
```
inbox:    apps/web/src/app/api/email  apps/web/src/lib/email  packages/ordinatio-email
calendar: apps/web/src/app/api/scheduling  packages/ordinatio-scheduling  packages/ordinatio-booking-widget
clients:  apps/web/src/app/api/clients
orders:   apps/web/src/app/api/orders  apps/worker/src/consumers  apps/web/src/lib/worker
sms:      apps/web/src/app/api/sms  apps/worker/src/consumers/sms-stream-consumer.ts
website:  apps/web/src/app/api/cms  packages/ordinatio-cms
agents:   apps/web/src/app/api/agent  packages/ordinatio-agent
auth:     packages/ordinatio-auth  packages/ordinatio-security
settings: apps/web/src/app/api/settings  packages/ordinatio-settings
worker:   apps/worker/src
ui:       packages/ordinatio-ui  packages/ordinatio-errors  packages/ordinatio-activities
```

---

## STEP 3 — Ask what to do next

After interpreting the results, ask:
```
Next?
  seam [mod1] [mod2]   — deep dive on a specific boundary
  audit [module]       — all seam checks on one module
  check sse            — full SSE event registry detail
  check stream         — full stream action registry detail
  check activity       — detailed review of each flagged route
  no                   — done
```

Wait for input.

---

## COMMAND: `audit [module]`

Run the full seam audit scoped to one module's paths. This is the same script, same output.

```bash
bash scripts/seam-audit.sh
```

Paste the full output. Then manually review which findings touch the module's paths using
the module registry above. Print only the relevant findings for that module.

Write findings (severity ≥ 6) to `.autocode/modules/[module]/architect.md`.
Write auth/security findings to `.autocode/modules/[module]/security.md`.

---

## COMMAND: `seam [mod1] [mod2]`

Deep investigation of the handoff between two modules. Start by running:

```bash
bash scripts/seam-audit.sh
```

Then focus on findings that involve files from either module's paths. Read the flagged files
and determine: (1) which seam types apply to this boundary, (2) whether the failure is on the
sender side or receiver side.

Print:
```
SEAM: [mod1] ↔ [mod2]
──────────────────────────────────────────────────────────────────
Seam types checked: [list the relevant seams from the output]

Findings:
  [finding from script output] — severity [N]
──────────────────────────────────────────────────────────────────
Contract health: VERIFIED / FRAGILE / MISMATCH FOUND
```

---

## COMMAND: `health`

Same as the top-level: run `bash scripts/seam-audit.sh` and paste the full output.
The script IS the health report.

---

## COMMAND: `check sse`

Run `bash scripts/seam-audit.sh` and paste the full output. SEAM 2 in the output is the
SSE event registry check. For deeper detail on each orphaned event type, read the emitting
route and the closest UI component — find why no listener was wired.

---

## COMMAND: `check stream`

Run `bash scripts/seam-audit.sh` and paste the full output. SEAM 3 in the output is the
stream action registry check. For the `pull-from-outlook` dead-handler WARN: investigate
`apps/worker/src/consumers/calendar-stream-consumer.ts` and determine whether the web sender
needs to be implemented or the dead handler should be deleted.

---

## COMMAND: `check activity`

Run `bash scripts/seam-audit.sh` and paste the full output. SEAM 1 in the output lists all
`await log*Activity(...)` candidates without a same-line `.catch()`. For each:
- Read 3 lines of context around the flagged call
- Classify as: SAFE (`.catch()` is on the next line — multi-line form), RISKY (inside shared try/catch), or UNPROTECTED
- Write RISKY/UNPROTECTED findings to the owning module's `architect.md`

---

## REFERENCE: The 7 seam types (what each failure means)

These are prose descriptions of WHAT each seam failure means and why it matters.
The script finds them mechanically. The script cannot be wrong about what it finds —
only about whether a finding is a true positive or a false positive.

**SEAM 1 — Activity logging fire-and-forget**
`logSchedulingActivity` is async. If awaited inside a try/catch that also guards the DB write
and HTTP response, a logging failure returns a false 500 to the client. The DB write succeeded
but the client sees an error. The correct pattern is `.catch(e => log.warn(e))` on the same line
so logging never fails the request. Real incident: patterns.md 2026-06-30, severity 5.

**SEAM 2 — SSE event type drift (emitter vs listener)**
`emitAppointmentEvent(orgId, 'appointment.confirmed', data)` fires an event with a string type.
`useRealtime(['appointment.updated'], handler)` in the UI listens for a different string.
If the emitted type has no listener, the UI goes permanently stale on that state transition —
no error, no test failure. Real incident: `appointment.no_show` emitted, no UI listener,
agenda-view stale on no-shows. patterns.md 2026-06-27, severity 7.

**SEAM 3 — Worker stream action alignment**
`queueWorkerMessage('push-to-outlook', data)` writes to a Redis stream. Worker
`calendar-stream-consumer.ts` handles it via `switch/case`. If the web sends an action string
that has no worker case, messages pile up in the Redis PEL (pending entry list) forever —
never processed, never errored, never visible. Known dead handler: `pull-from-outlook`
(worker handles it, web never sends it — implement the sender or delete the handler).

**SEAM 4 — BullMQ job name alignment (placement queue only)**
The placement queue (`placement-automation`) dispatches on `job.name`. If the web enqueues a
job name that the processor has no `case` for, the job silently falls to the default branch.
Note: the automation queue (`automation-executions`) dispatches on `job.data.type` — its job
name is always `'execute'`, which is NOT a processor case. The script scopes to `apps/web/src/lib/worker/`
only to exclude the automation client and prevent false positives.

**SEAM 5 — Unauthenticated routes**
A route handler without `getSession()`, `getTenantContext()`, `requireSchedulingAuth()`,
or a verified external webhook secret (Stripe HMAC, Twilio HMAC, Google Channel Token) can
be called by anyone. Known legitimate auth-free routes are enumerated in the script's
`KNOWN_PUBLIC` list — any route not in that list and not using any auth pattern is a genuine gap.
Known gap: `apps/web/src/app/api/tax/plaid/webhook/route.ts` — Plaid signature verification
documented as TODO in the code.

**SEAM 6 — Transaction isolation on read-then-write**
Prisma's default `$transaction` isolation is READ_COMMITTED. A read-then-write pattern
(findUnique guard → update) under READ_COMMITTED is vulnerable to TOCTOU: two concurrent
requests both pass the guard, both commit, invariant violated. Correct fix: pass
`{ isolationLevel: 'Serializable' }`. This is WARN not FAIL — the script finds candidate
call sites, but human judgment is required to determine if the site has a read-then-write
pattern. Real incident: `updateAppointmentType` — fixed. `setWeeklyAvailability`,
`addDateOverride`, and placements route remain open. patterns.md 2026-06, severity 7.

**SEAM 7 — `@ordinatio/email` barrel import in client components**
`'use client'` files that import from `@ordinatio/email` (the barrel) pull Node.js-only
modules (googleapis, undici, http2) into the browser bundle — crashes prod on first load.
Must use `@ordinatio/email/client` subpath. Real incident: isomorphic-dompurify crash, 3×
production outage. April 2026.
