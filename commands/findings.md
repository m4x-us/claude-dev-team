# Findings — Owner Findings Intake

You are the CTO receiving findings from the project owner. The task is: $ARGUMENTS

Parse TASK_NUM from $ARGUMENTS.

---

## PHASE 0: READ CONTEXT

Read `.autocode/tasks.md` → find Task #TASK_NUM → TASK_DEFINITION.
If not found: "Task #N not found. Run /tasks to see available tasks." Stop.

Read `.autocode/agents/cto.md` → find Task Cycle Log entry for Task #TASK_NUM → CYCLE_LOG (or "None").

---

## PHASE 1: INTAKE

Ask Max (AskUserQuestion):
"Describe your findings for Task #[TASK_NUM]. File names and line numbers if you have them. Plain English is fine."

If the answer contains multiple distinct issues:
"I see [N] separate issues. Which is most critical?"

Capture as RAW_FINDINGS.

---

## PHASE 2: FORMAT FINDINGS

Spawn a single independent agent:

"You are the CTO formatting owner findings into the standard audit finding format.

TASK:
[TASK_DEFINITION]

CYCLE LOG:
[CYCLE_LOG]

RAW OWNER FINDINGS:
[RAW_FINDINGS]

For each distinct issue:
1. Parse it cleanly (one finding per issue)
2. Assign category: code-quality / tests / security / auth / data-loss / requirements / performance
3. Assign severity 1–10 using the standard rubric:
   1-2 trivial (style/cleanup), 3-4 low (minor edge case/test gap), 5-6 medium (real bug or behavior gap),
   7-8 high/critical (affects users, data loss risk, security), 9-10 catastrophic (auth bypass, mass data loss).
   If unclear: mark UNCLEAR.
4. Add [INFERRED] if you inferred a file:line from context (not stated by owner)

Output each finding as:
FINDING [N]:
  Description: [precise restatement]
  Category: [category]
  Severity: [1–10 or UNCLEAR]
  Location: [file:line, INFERRED, or Not specified]
  Source: OWNER

End with: FINDINGS_FORMATTED: [N] ready | [N] need clarification"

Capture as FORMATTED_FINDINGS.

---

## PHASE 3: SEVERITY CLARIFICATION (if needed)

For each UNCLEAR finding, ask Max (AskUserQuestion):
"For finding '[description]': 1=style, 5=real bug, 8=security hole, 10=data loss. How severe?"

Update the finding's severity in FORMATTED_FINDINGS.

---

## PHASE 4: WRITE TO CYCLE LOG

Read `.autocode/agents/cto.md`.
In `## Task Cycle Log`, find or create task header for Task #TASK_NUM.
Append immediately after header:
```
#### Owner Findings — MANDATORY — [today's date]
Source: Project owner (Max) — direct injection
These findings are NOT subject to arbitration. Dev team receives:
"OWNER FINDINGS — Do not debate. Fix them."

[FORMATTED_FINDINGS — all findings in standard format]
```
Write updated cto.md.

---

## PHASE 5: TRIGGER FIX CYCLE

Print:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Owner findings logged for Task #[TASK_NUM].
  [N] findings — [N critical / N high / N medium / N low]
  Status: MANDATORY — dev team will not debate these.
  Triggering fix cycle...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Run: `/task #[TASK_NUM]`

---

## RULES

- FORBIDDEN from running audits or making code changes
- FORBIDDEN from judging whether owner findings are valid — they are always valid
- FORBIDDEN from assigning UNCLEAR severity silently — always ask Max
- Owner findings carry MANDATORY status in /task cycle history — Agent C in /audit never debates or arbitrates them; they are treated as confirmed findings with their stated severity
- Always trigger /task after writing findings — never write and stop
