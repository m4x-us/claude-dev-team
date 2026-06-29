# Resume — Session Start

You are resuming a development session. No scans. No agents. Just state recall.

This command takes under 30 seconds. It reads existing memory and prints the current state of the world so the session can start immediately without re-reading CLAUDE.md or STATUS.md manually.

---

## STEP 1: READ STATE

Read all of the following (silently — do not print raw contents):

1. `.autocode/agents/cto.md` → `CTO_MEMORY` (or "No CTO memory — run /meet first")
2. `.autocode/tasks.md` → `TASK_LIST` (first 80 lines, or "No task list — run /meet first")
3. Run: `git log --oneline -10` → `RECENT_LOG`
4. Run: `git diff HEAD~3..HEAD --name-only 2>/dev/null` → `RECENT_FILES`

If `.autocode/agents/cto.md` does not exist:
Print:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  No team memory found.
  Run /meet to onboard the dev team first.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```
Stop.

---

## STEP 2: PRINT SESSION STATE

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Session resumed — [today's date]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

RECENT COMMITS:
  [list all 10 lines from RECENT_LOG]

RECENTLY TOUCHED FILES:
  [list from RECENT_FILES, or "No recent changes"]

CURRENT SPRINT:
  [find the [CURRENT SPRINT] batch in TASK_LIST and print its tasks:
   format: Task #N | [severity] | [description] | [status: open/done] | [Cycle N/5 if in active cycle — blank if not started or complete]
   print up to 10 tasks
   Extract cycle depth per task from .autocode/agents/cto.md ## Task Cycle Log. Tasks with no cycle log entry show no cycle indicator.]

OPEN ESCALATIONS:
  [extract from CTO_MEMORY ## Open Escalations — or "None"]

QUICK COMMANDS:
  /tasks          — full task list
  /tasks #N       — specific task details
  /team-health    — CTO dashboard with quality trends
  /meet           — re-examine codebase (run after major features ship)
  /consult [role] — quick consult: security | architect | qa | docs
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## RULES

- Never spawn agents — this command reads only, no scanning
- If task list doesn't exist, suggest /meet, do not generate tasks
- If recent commits include a major feature not reflected in the task list, note it as a reminder:
  "NOTE: Recent commits may have added work not in the task list. Run /meet to update."
