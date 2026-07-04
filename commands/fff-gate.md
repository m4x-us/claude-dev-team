# fff-gate — Five Forcing Functions / WorldClass Commit Gate

Produces the gate artifact that `.husky/pre-commit` requires before it will
allow a commit touching source files. This is the mechanical enforcement
point for the Five Forcing Functions: the commit is physically blocked
without it, hash-paired to the exact staged diff.

Run this any time before `git commit` when source files are staged. If you
try to commit without it, the pre-commit hook will tell you to run this.

---

## STEP 1 — Compute hash and classify

```bash
HASH=$(bash scripts/staged-diff-hash.sh)
```

If `HASH` = `NONE`: print "No staged source diff — gate not required." and stop.

```bash
read SIZE REASON <<< "$(bash scripts/classify-diff-size.sh)"
```

(`SIZE` is the first line of output: `DIRECT` or `FULL`. `REASON` is the second line.)

Print:
```
Gate check — staged diff hash: [HASH]
Classification: [SIZE] — [REASON]
```

---

## STEP 2A — If SIZE = FULL

Print:
```
This diff is FULL-tier (packages/ boundary, security/money-sensitive path,
or 3+ files) — it requires a full WorldClass pass, not the lightweight
FFF gate.
```

Invoke the `worldclass` skill/command now, passing a description of what's
staged as its argument (derive from `git diff --cached --stat` and the
commit you're about to make — do not skip this by describing it vaguely,
be specific about what changed).

`/worldclass`'s own PASS branch writes the gate artifact
(`.autocode/reviews/gate/[HASH].json`) directly — once it reaches
COMBINED_SCORE ≥ 95 with AC_RESULT PASS or SKIPPED, the commit gate is
satisfied automatically. If WorldClass hits MAX_CYCLES without reaching 95,
the gate remains unsatisfied — do not write a gate artifact by hand to
route around this. Either close the gap for real, or take the escalation
brief WorldClass wrote to `.autocode/agents/cto.md` (or the module's
`cto.md`) to Max for an explicit decision before committing.

Stop here — control passes to `/worldclass`.

---

## STEP 2B — If SIZE = DIRECT

Capture:
```bash
git diff --cached --stat
git diff --cached
```
as `STAGED_DIFF`. Capture `git diff --cached --name-only` as `STAGED_FILES`.

Spawn ONE independent subagent (Agent tool, `subagent_type` anything OTHER
than `fork` — a fork inherits this session's full context and therefore
shares its blind spots, which defeats the purpose of a fresh-eyes pass).
Use this exact prompt:

```
You are doing an independent Five Forcing Functions review of a code change
you did NOT write and have no context on beyond what's given here. Do not
assume good intent — actively look for what's wrong.

STAGED FILES:
[STAGED_FILES]

FULL DIFF:
[STAGED_DIFF]

Answer these five questions about this exact diff — not in general, about
these specific files and lines:

FFF-1 (Easy vs Right): Where does this diff choose the easy path over the
right one? Name a specific file:line for each instance found, or state
explicitly "No easy-over-right shortcuts found" if genuinely none exist —
but you must show you looked (name what you checked).

FFF-2 (Best-Engineer Critique): If you showed this diff to the best
engineer you know, what would they criticize? Be specific — file:line,
not a general impression.

FFF-3 (User vs Reader): Is this code built for the person who USES it or
the person who READS it? Name any place naming, structure, or comments
favor one over the other at the expense of clarity or correctness.

FFF-4 (Does It Do What It Claims): Pick the 2 most consequential functions
or branches changed in this diff. Does each one actually do what its name/
docstring/comment claims, with no hidden side effects or silent failure
paths? Cite file:line for each.

FFF-5 (10-Year Durability): If this diff shipped unchanged and ran for 10
years, what's the first thing that would break, drift, or become a trap
for whoever touches it next? Be specific, not generic ("tech debt accrues"
is not an answer).

FORBIDDEN: "looks fine", "appears correct", "no issues found", "N/A",
"seems reasonable" as a complete answer to any question. Every answer must
reference at least one specific file:line from the diff above, even when
concluding there's no problem in that dimension — show your work.

Format your response as exactly five sections:
### FFF-1
[answer, 3+ sentences, at least one file:line reference]
### FFF-2
[answer, 3+ sentences, at least one file:line reference]
### FFF-3
[answer, 3+ sentences, at least one file:line reference]
### FFF-4
[answer, 3+ sentences, at least one file:line reference]
### FFF-5
[answer, 3+ sentences, at least one file:line reference]
```

**Validate the response yourself before writing the gate artifact** — do
not trust the subagent's format compliance blindly:
- All 5 `### FFF-N` sections present
- Each section has a real file:line reference (a path from STAGED_FILES,
  or a plausible path within the diff, followed by a line number or
  function name)
- No section is a single forbidden-phrase non-answer
- Each section is substantive (roughly 3+ sentences)

**If validation fails:** print exactly what's missing or too thin, and stop
— do NOT write the gate artifact. The commit stays blocked until this is
re-run and passes.

**If validation passes:** if any FFF-1 through FFF-5 answer surfaced a real,
fixable problem (not just "nothing found, here's what I checked"), fix it
now before writing the artifact — the gate exists to catch and close gaps,
not to catalog them and ship anyway. Re-run from Step 1 after fixing (the
hash will have changed).

Once the diff is clean and all 5 sections pass validation, write:

`.autocode/reviews/gate/[HASH].json`:
```json
{
  "mode": "fff",
  "diffHash": "[HASH]",
  "timestamp": "[ISO timestamp]",
  "verdict": "PASS",
  "findings": {
    "fff1": "[FFF-1 answer]",
    "fff2": "[FFF-2 answer]",
    "fff3": "[FFF-3 answer]",
    "fff4": "[FFF-4 answer]",
    "fff5": "[FFF-5 answer]"
  }
}
```

Print:
```
✓ FFF gate satisfied for diff [HASH]. Commit is now unblocked.
```
