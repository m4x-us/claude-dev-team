# Reflect — Post-Task Honest Review

You are running a post-task reflection. The task was: $ARGUMENTS

This runs automatically after every /autocode and /audit completion. It can also be run manually at any time.

---

## STEP 1: GATHER DATA

Read these files and extract entries matching this task (match on task description in the entry header):

- `.autocode/patterns.md` — findings logged during this task
- `.autocode/test-failures.md` — test failures during this task (if the file exists)
- `.autocode/trends.md` — find this task's row for cycle count, final severity, and verdict
- `.autocode/worldclass-trends.md` — find this task's row for final worldclass score (if the file exists)

Also recall from the loop that just completed:
- How many audit cycles ran before stopping?
- What was the final severity score and verdict?
- What was the final worldclass score (if /worldclass ran)?
- Which audit categories appeared most frequently?

---

## STEP 2: WRITE THE REFLECTION

Spawn a single independent agent with this prompt:

"You are a senior engineer reflecting on a completed task. You do not write fluff. You write honest, specific assessments. Generic advice is useless — every sentence must reference something concrete from the task.

Task: $ARGUMENTS
Outcome: [PASS in N cycles / MAX_CYCLES with severity N]
Cycles taken: [N]
Final severity: [N]
WorldClass score: [N]/100 (or 'not scored' if /worldclass did not run)

Patterns logged during this task (findings from audit and worldclass):
[paste the relevant entries from patterns.md, or 'None — task passed cleanly']

Test failures during build (if any):
[paste the relevant entries from test-failures.md, or 'None — tests passed on first run']

Write a single paragraph of 4–6 sentences. Cover all four of these:
1. What did the plan get right that made implementation smooth?
2. What kept failing across audit cycles — and why did the plan not catch it before the code was written?
3. Were the audit findings predictable from the task description, or genuinely surprising?
4. What is the single most important thing to do differently on a similar task next time?

If a WorldClass score is present, the paragraph must reference it — either what specifically held the score below 95, or why the code earned it cleanly.

If no patterns or test failures exist for this task (clean first pass): reflect on the loop structure itself — given the task description and final audit findings, what in the original plan was most likely to cause problems and why wasn't it flagged earlier?

Do not be generic. 'We should handle errors better' is useless. 'The plan assumed the email service would always return a status code, but in practice it can return nothing on timeout — this should have been explicitly specced in the plan' is useful.

Write only the paragraph. No headers, no bullet points, no preamble."

Capture the paragraph.

**Quality check:** If the paragraph contains only generic advice with no specific reference to the task, reject it and ask the agent to rewrite with concrete details. A reflection that could apply to any task is not a valid reflection.

---

## STEP 3: APPEND TO JOURNAL

Ensure `.autocode/` directory exists (`mkdir -p .autocode`).

Append to `.autocode/reflections.md`:

```
## [today's date] | Task: $ARGUMENTS
**Outcome:** [PASS in N cycles / MAX_CYCLES with severity N]
**Cycles:** [N] | **Final severity:** [N] | **WorldClass:** [N]/100

[the paragraph from the agent]

---
```

If `.autocode/reflections.md` does not exist, create it with this header first:
```
# AutoCode Reflections Journal
```

---

## STEP 4: PRINT CONFIRMATION

Print:
```
✅ Reflection logged.
Task: $ARGUMENTS
Journal: .autocode/reflections.md
```

---

## RULES

- The reflection agent sees only the data you provide — do not let it invent findings that aren't in the log
- Every reflection must be specific — reject and retry if it reads as generic
- Never skip this step because the task was trivial — even clean passes have something to reflect on
- reflections.md is a permanent journal — never delete or archive it
