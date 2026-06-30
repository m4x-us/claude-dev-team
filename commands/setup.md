# Setup — Welcome to Claude Dev Team

You are welcoming a new user to the Claude Dev Team system. Print the orientation, then ask if they want to get started.

---

Print exactly this (fill in the bracketed parts):

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Welcome to Claude Dev Team
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  This system turns Claude Code into a full dev team built
  on the Toyota Production System: quality first, no shortcuts,
  every task audited before it closes.

  THE WORKFLOW
  ────────────
  1. /meet     Examine your codebase with 5 specialist agents
               (architecture, security, QA, docs, product).
               Answer 7 questions. Get a prioritized task list.

  2. /advance  Distribute the sprint across up to 4 parallel
               Claude windows. Each window runs independently
               and can't step on the others.

  3. /go       Type this in each agent window. It claims the
               next task from the queue and runs it start to
               finish — no copy-paste needed.

  When a batch is done, run /meet again. It carries forward
  open tasks, re-scans, and reorganizes based on what changed.

  OTHER COMMANDS
  ──────────────
  /task #N     Run a single task through the full CTO cycle
               (build → audit → WorldClass → carry-forward).
               Use this when you're not running /advance.

  /tasks       View the task list as a table.
  /resume      Quick session start — reads memory, skips scan.
  /team-health CTO dashboard: audit trends, open escalations,
               WorldClass scores.

  THE STANDARD
  ────────────
  Every task runs: Build → Audit → WorldClass quality check.
  Nothing closes without passing. Findings become memory that
  future audits build on. The team gets smarter every session.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Then ask:

```
Ready to start? A few options:

  yes       → I'll run /meet on your current project right now
  tour      → Walk me through a command in more detail
  no        → You're all set — type /meet when you're ready
```

Wait for their response.

**If "yes":** Run `/meet` immediately. Do not explain further — just start.

**If "tour":** Ask which command they want to understand better:
```
Which command?
  meet / advance / go / task / tasks / resume / team-health
```
Wait for their choice. Then give a 4–6 sentence explanation of how that command works in practice — concrete, not abstract. End with: "Type /setup again to return to the main menu, or /meet to get started."

**If "no":** Say: "You're all set. Type /meet in any project to get started." Stop.
