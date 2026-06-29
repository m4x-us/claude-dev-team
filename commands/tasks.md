# Tasks — Task List Management

Manage the development team's task list. The task is: $ARGUMENTS

---

## USAGE

- `/tasks` — print the full task list
- `/tasks #N` — print a specific task with full context
- `/tasks done #N` — mark a task complete
- `/tasks reopen #N` — re-open a completed task and notify the CTO log
- `/tasks update` — regenerate the task list using existing agent memories (lighter than /meet)
- `/tasks batch N` — print all tasks in a specific batch
- `/tasks open` — print only open tasks from the current sprint
- `/tasks debt` — display the full debt register (deferred WorldClass gaps)

---

## STEP 1: DETERMINE MODE

Parse $ARGUMENTS:
- Empty → MODE = list
- Matches `#[number]` → MODE = detail, TASK_NUM = [number]
- Starts with `done #` → MODE = complete, TASK_NUM = [number after #]
- Starts with `reopen #` → MODE = reopen, TASK_NUM = [number after #]
- Equals `update` → MODE = update
- Starts with `batch` → MODE = batch, BATCH_NUM = [number]
- Equals `open` → MODE = open
- Equals `debt` → MODE = debt

---

## MODE: list

Determine FILE_ARG:
- If STREAM_ID is set: `--file .autocode/stream-[STREAM_ID]/tasks.md`
- Otherwise: (no --file flag needed)

Run: `python3 ~/.claude/scripts/tasks-summary.py [FILE_ARG]`
Print the output verbatim. Do not reformat or summarize it.

---

## MODE: detail (#N)

Read `.autocode/tasks.md`. Find the task with number matching TASK_NUM.

Also read the relevant agent memory for the task's Owner field:
- Owner = Security Agent → read `.autocode/agents/security.md`
- Owner = Architecture Agent → read `.autocode/agents/architect.md`
- Owner = QA Agent → read `.autocode/agents/qa.md`
- Owner = Docs Agent → read `.autocode/agents/docs.md`

Print:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Task #[N] — [title]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[full task block from tasks.md]

AGENT CONTEXT ([owner] memory on this area):
[extract from the agent's memory file any entries referencing the task's file or category]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Run: /autocode Task #[N]: [task description]
```

---

## MODE: complete (done #N)

Read `.autocode/tasks.md`. Find Task #TASK_NUM.

Verify the task's **Done when** condition is mechanically checkable. Ask the user to confirm it's been verified — do not silently mark done without confirmation.

Print:
```
Task #[N]: [description]
Done when: [condition]

Has this condition been verified? (confirm before marking complete)
```

If confirmed, edit `.autocode/tasks.md` to add `**Status: COMPLETE — [today's date]**` below the task's **Owner** line.

Also update CTO memory if open:
- Read `.autocode/agents/cto.md`
- Find the task in `## Open Escalations` if present and remove it
- Write updated file

---

## MODE: update

Re-generate the task list using existing agent memories. Lighter than full /meet — no fresh codebase scan, no Q&A.

Read:
1. `.autocode/agents/architect.md`, `security.md`, `qa.md` → `AGENT_MEMORIES`
2. `.autocode/tasks.md` → `EXISTING_TASKS`
3. `~/.claude/autocode/philosophy.md` → `PROJECT_PHILOSOPHY`
4. Run: `git log --oneline -20` → `GIT_LOG`

Spawn a single agent:

"You are updating a development task list. New work may have been completed since the list was generated.

PROJECT_PHILOSOPHY:
[PROJECT_PHILOSOPHY]

CURRENT TASK LIST:
[EXISTING_TASKS]

AGENT MEMORIES (open findings that may warrant new tasks):
[AGENT_MEMORIES]

RECENT GIT LOG:
[GIT_LOG]

Do the following:
1. Mark any tasks where the Done When condition is now met as COMPLETE
2. Add any new tasks for findings in AGENT_MEMORIES that have no corresponding task
3. Reorder batches if new tasks have changed the dependency graph

Produce the updated full contents of .autocode/tasks.md. Do not change task numbers for existing tasks — only add new ones sequentially."

Write updated content to `.autocode/tasks.md`.
Print: "✅ Task list updated."

---

## MODE: batch (batch N)

Determine FILE_ARG (same STREAM_ID rule as MODE: list).
Run: `python3 ~/.claude/scripts/tasks-summary.py --batch [BATCH_NUM] [FILE_ARG]`
Print the output verbatim.

---

## MODE: open

Determine FILE_ARG (same STREAM_ID rule as MODE: list).
Run: `python3 ~/.claude/scripts/tasks-summary.py --open [FILE_ARG]`
Print the output verbatim.

---

## MODE: reopen (reopen #N)

Read `.autocode/tasks.md`. Find Task #TASK_NUM.

If task is not COMPLETE: print "Task #N is not marked complete — nothing to reopen." Stop.

If task is COMPLETE:
1. Edit `.autocode/tasks.md`: change `**Status: COMPLETE — [date]**` → `**Status: REOPENED — [today's date]**`
2. Read `.autocode/agents/cto.md`
3. In `## Task Cycle Log`, find or create task header for Task #TASK_NUM. Append:
   ```
   #### Reopened — [today's date]
   Status: Reopened | Reason: Re-audit requested via /tasks reopen
   ```
4. Write updated cto.md
5. Print:
   ```
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     Task #[TASK_NUM] reopened. CTO cycle log updated.
     Run: /task #[TASK_NUM]  or  /audit #[TASK_NUM]
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   ```

---

## MODE: debt

Run: `python3 ~/.claude/scripts/tasks-summary.py --debt`
Print the output verbatim.

---

## RULES

- Never delete a task — mark it COMPLETE, never remove it
- Never change a task number once assigned
- The Done When condition is mandatory for marking complete — never skip the verification step
- /tasks update does not replace /meet — it only incorporates memory findings, not fresh scans
