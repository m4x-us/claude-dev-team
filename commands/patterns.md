# Patterns — Health Report Generator

Read `.autocode/patterns.md`, analyze recurring findings, and generate a visual HTML health report. Then run the interactive philosophy graduation steps in the terminal.

---

## PHASE 0: READ ALL DATA (silent)

Read `.autocode/patterns.md` → `PATTERNS_RAW`. If it doesn't exist or is empty: print "No pattern data yet. Run /task on a few tasks first." Stop.

Read `.autocode/trends.md` → `TRENDS_RAW` (or "None").
Read `.autocode/worldclass-trends.md` → `WORLDCLASS_RAW` (or "None").
Read `.autocode/reflections.md` → `REFLECTIONS_RAW` (or "None").
Read `~/.claude/autocode/philosophy.md` → `PHILOSOPHY_RAW` (or "None").

---

## PHASE 1: ANALYZE (silent — build all variables before generating HTML)

**1A — Parse patterns.md:**

Parse every bullet line matching: `^-\s+(\S+)\s+(.+)—\s+severity\s+(\d+)\s*\|`

For each matching line, extract:
- `category` — first token
- `description` — text between category and the em dash
- `severity` — integer after "severity"
- `task_header` — the `## [date] | Task: [...]` header immediately above this bullet
- `cycle_index` — the sequential audit run number this entry belongs to (1-based, derived from audit_rows order in 1B)

Group by category. For each category compute:
- `occurrences` — total count of matching lines
- `cycle_indices` — set of distinct cycle_index values where this category appeared
- `unique_cycles` — count of distinct cycle_indices
- `avg_severity` — mean of all severity values
- `max_severity` — highest severity seen
- `last_seen_cycle` — highest cycle_index where it appeared
- `per_cycle_counts` — array of (cycle_index, count) for chart plotting

**Systemic pattern threshold:** A category qualifies if `occurrences >= 3` AND `unique_cycles >= 3`. Reasoning: each cycle is a fresh build attempt — if the build agent makes the same category of mistake across 3 independent cycles, the coding prompts are not catching it. A single hard task that takes 10 cycles but only generates 1 type of finding in all 10 cycles counts as unique_cycles=10, so it still qualifies after 3 cycles — that IS a prompt gap.

**1B — Parse trends.md into audit_rows:**

Parse each data row (skip header). Extract in order: date, task (first 40 chars), cycles_this_task (the Cycles column), final_severity, verdict.

Compute `cumulative_cycle_end` for each row — running sum of cycles_this_task across all rows in order:
- Row 1: cycles_this_task=2 → cumulative_cycle_end=2
- Row 2: cycles_this_task=3 → cumulative_cycle_end=5
- Row 3: cycles_this_task=1 → cumulative_cycle_end=6
- etc.

`cumulative_cycle_start` for row N = cumulative_cycle_end of row N-1 (or 0 for first row).

The X axis for all time-based charts is `cumulative_cycle_end` — NOT dates. This makes the timeline reflect actual work done, not calendar time.

Also compute:
- `total_cycles` = final cumulative_cycle_end
- `pass_rate` = PASS count / total count × 100
- `avg_severity_recent` = mean of last 5 final_severity values
- `trend_direction` = compare avg of last 3 vs prior 3 (need 6+): IMPROVING / STABLE / DEGRADING / "Not enough data"

**1C — Parse worldclass-trends.md into wc_rows:**

Parse each data row. Extract: date, task, cycles_this_task, score, verdict.

Compute `wc_cumulative_cycle_end` using the same running-total logic as 1B (use cycles_this_task column, same approach).

- `wc_trend_direction` = compare avg of last 3 vs prior 3 PASS rows: IMPROVING / STABLE / DEGRADING / "Not enough data"

**1D — Count severe findings per audit run:**

For each audit run in `audit_rows` (identified by date + task header match in patterns.md):
- Find all bullet lines in PATTERNS_RAW under the `## [date] | Task: [task]` header
- Count lines with severity >= 7 → `severe_count` for that run
- Count lines with severity >= 5 → `medium_plus_count`

Attach `severe_count` and `medium_plus_count` to each row in `audit_rows`. Use `cumulative_cycle_end` as the X coordinate.

`SEVERE_SERIES` = array of {x: cumulative_cycle_end, y: severe_count} for every audit_row.

**1E — Philosophy change annotations:**

Read PHILOSOPHY_RAW. Find the `## CHANGELOG` section. Parse each table row:
`| date | section | one-line summary | pattern info |`

For each changelog entry:
1. Find the first `audit_row` with date >= changelog_date
2. Use that row's `cumulative_cycle_end` as the annotation's cycle position
3. Translate `one-line summary` into plain English (remove jargon — write it as if explaining to a business owner what rule was added and why)

`PHILOSOPHY_ANNOTATIONS` = array of {cycle: N, label: "plain English description"} sorted by cycle ascending.

If no changelog entries found or PHILOSOPHY_RAW = "None": `PHILOSOPHY_ANNOTATIONS = []`.

**1F — Plain English translations:**

Category name mapping (apply everywhere — never show raw names to the user):
- `error-handling` → "Error Protection"
- `tests` → "Test Quality"
- `auth` → "Access Control"
- `security` → "Security"
- `data-loss` → "Data Safety"
- `feature-flag` → "Feature Switches"
- `async` → "Background Tasks"
- `edge-case` → "Edge Cases"
- `code-quality` → "Code Organization"
- `performance` → "Speed & Efficiency"
- `requirements` → "Feature Completeness"
- `documentation` → "Documentation"
- Any unmapped → title-case the raw name

Business impact per category (one sentence, plain English):
- `error-handling` → "The app may crash silently or show confusing error messages to customers."
- `tests` → "Bugs may go undetected until customers find them in production."
- `auth` → "The wrong users may be able to access data they shouldn't see."
- `security` → "The system may be exposed to outside attacks or data breaches."
- `data-loss` → "Customer data could be permanently lost or corrupted."
- `feature-flag` → "New features may not be safely controllable after launch."
- `async` → "Background tasks may fail silently or complete in the wrong order."
- `edge-case` → "The app may behave unexpectedly in unusual but real situations."
- `code-quality` → "The codebase becomes harder and slower to change over time."
- `performance` → "The app may become slow or unresponsive as usage grows."
- `requirements` → "Finished features may not fully match what was originally requested."
- `documentation` → "The team loses context and makes avoidable mistakes on existing code."

Severity badge (based on avg_severity):
- 1.0–3.4 → label: "Low Priority", color: #3b82f6
- 3.5–5.4 → label: "Worth Fixing", color: #f59e0b
- 5.5–6.9 → label: "Fix Soon", color: #f97316
- 7.0–8.4 → label: "Fix Now", color: #ef4444
- 8.5–10  → label: "Critical", color: #7f1d1d

Overall health (based on systemic pattern count):
- 0–2 systemic patterns → "HEALTHY", color: #22c55e, emoji: ✅
- 3–4 → "NEEDS ATTENTION", color: #f59e0b, emoji: ⚠️
- 5+  → "SIGNIFICANT DRIFT", color: #ef4444, emoji: 🔴

**1G — Executive summary (3 plain English sentences, no jargon):**

1. Pass rate: "Your dev team has passed [pass_rate]% of recent audits." Or "No audit history yet."
2. Most recurring issue: "The most common issue is [plain English category] — it has appeared [N] times across [N] audit cycles." Or "No recurring issues yet."
3. Trend: "Quality is [IMPROVING → getting better / STABLE → holding steady / DEGRADING → getting worse] over the last several tasks." If not enough data: "Not enough history yet to show a trend."

---

## PHASE 2: GENERATE HTML REPORT

Create directory: `mkdir -p .autocode/reports`

Generate a complete self-contained HTML file. Write to `.autocode/reports/patterns-[today's date].html`.

The file must be entirely self-contained. No external file dependencies except two CDN links: Chart.js (`https://cdn.jsdelivr.net/npm/chart.js`) and Google Fonts Inter (`https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap`). All chart data is embedded as JavaScript variables in a `<script>` block. The file must render correctly when opened directly with `open` — no server required.

---

**GLOBAL STYLE:**

Dark theme throughout. CSS variables at `:root`:
- `--bg`: #0f172a
- `--card`: #1e293b
- `--card-alt`: #243044
- `--border`: #334155
- `--text`: #f1f5f9
- `--text-muted`: #94a3b8
- `--green`: #22c55e
- `--yellow`: #f59e0b
- `--orange`: #f97316
- `--red`: #ef4444
- `--blue`: #3b82f6
- `--purple`: #a855f7

Body: background var(--bg), font Inter, color var(--text), margin 0, padding 24px.
Max-width 1200px, centered with `margin: 0 auto`.
All cards: background var(--card), border-radius 12px, border 1px solid var(--border), padding 20px 24px.

---

**SECTION 1 — HEADER:**

Full-width flex row, space-between alignment, padding-bottom 20px, border-bottom 1px solid var(--border).

Left side:
- "Codebase Health Report" — font-size 26px, font-weight 700
- "[today's date]  ·  [total_cycles] total cycles" — font-size 14px, color var(--text-muted), margin-top 4px

Right side — health badge:
- Pill shape: border-radius 999px, padding 8px 20px, border 1.5px solid [health color], background [health color] at 15% opacity
- Text: "[health emoji]  [health label]" — font-size 15px, font-weight 600, color [health color]

---

**SECTION 2 — EXECUTIVE SUMMARY ("At a Glance"):**

Section label: "AT A GLANCE" — font-size 11px, letter-spacing 0.1em, color var(--text-muted), font-weight 600, text-transform uppercase, margin-bottom 12px.

Three cards in a horizontal flex row (wrap on narrow screens), gap 16px. Each card: flex row, gap 16px, align-items center.

Left side of each card: 40×40px circle, background the card's accent color at 20% opacity, centered icon (Unicode emoji, font-size 20px).
- Card 1 icon: 📊, accent color var(--blue)
- Card 2 icon: 🔁, accent color: severity badge color of most recurring category (or var(--green) if none)
- Card 3 icon: (IMPROVING → 📈 var(--green)) (STABLE → ➡️ var(--yellow)) (DEGRADING → 📉 var(--red))

Right side: executive summary sentence in var(--text), font-size 15px.

---

**SECTION 3 — SEVERE ISSUES OVER TIME (main chart, full width):**

This is the most important chart. Give it full width and extra vertical space.

Section label: "SEVERE ISSUES OVER TIME" (same uppercase label style as Section 2).

Subtitle below label: "Findings rated 'Fix Now' or worse (severity 7+), measured in cycles. Vertical markers show when coding rules were updated — watch for drops after each change." — font-size 13px, color var(--text-muted), margin-bottom 16px.

Card containing the chart canvas (`id="severeChart"`). Canvas height: 280px.

**Chart.js configuration for severeChart:**
- Type: `line`
- Data:
  - Dataset 1 — "Severe Issues":
    - data: SEVERE_SERIES array [{x, y}]
    - borderColor: #ef4444
    - backgroundColor: rgba(239,68,68,0.12) fill
    - tension: 0.3
    - pointRadius: 5
    - pointBackgroundColor: color each point — #22c55e if y=0, #f59e0b if y=1-2, #ef4444 if y>=3
  - Dataset 2 — zero line (invisible reference):
    - data: [{x:0,y:0},{x:total_cycles,y:0}]
    - borderColor: transparent, pointRadius: 0
- Scales:
  - x: type `linear`, title "Cycle Number", min 0, max total_cycles (or 10 if no data), grid color rgba(255,255,255,0.05)
  - y: type `linear`, title "Severe Issues Found", min 0, suggestedMax 6, ticks integer only, grid color rgba(255,255,255,0.05)
- Plugins:
  - annotation plugin (load from `https://cdn.jsdelivr.net/npm/chartjs-plugin-annotation`):
    For each entry in PHILOSOPHY_ANNOTATIONS:
      - Vertical line at x = entry.cycle
      - borderColor: rgba(168,85,247,0.7) (purple), borderWidth: 2, borderDash: [6,4]
      - Label: displayed above the line, background rgba(168,85,247,0.15), color #a855f7, content: "📌 Cycle [entry.cycle]", font-size 11px
  - tooltip: custom tooltip showing "Cycle [x]: [y] severe issues"
- Legend: hidden (explained by annotation legend below)

**Annotation legend below the chart (outside the canvas, inside the card):**
Flex row, gap 24px, margin-top 12px, font-size 13px, color var(--text-muted):
- "● Red = 3+ severe issues  ● Yellow = 1–2  ● Green = clean"
- "┊ Purple line = coding rules updated"

**Philosophy change log — below the chart card:**

If PHILOSOPHY_ANNOTATIONS is non-empty: render a timeline list of all annotations.
Section heading: "What Changed at Each Marker" — font-size 13px, font-weight 600, color var(--text-muted), uppercase, letter-spacing, margin-bottom 10px.

For each annotation (sorted by cycle ascending):
One row: purple left border (3px solid #a855f7), padding-left 14px, margin-bottom 10px.
- "Cycle [N]" — font-size 13px, font-weight 600, color #a855f7
- plain English description — font-size 14px, color var(--text), margin-top 2px

If PHILOSOPHY_ANNOTATIONS is empty: show a muted note "No coding rule changes recorded yet. When you approve a rule in /patterns, it will appear here."

---

**SECTION 4 — CHARTS GRID (2×2):**

2-column CSS grid (1 column on narrow screens), gap 16px.

**Chart A — "Issues by Type" (horizontal bar):**
- Title: "Issues by Type" (16px, 600 weight), subtitle: "How many times each problem appeared across all cycles" (13px muted)
- Canvas `id="typeChart"`, height 240px
- Data: all categories sorted by occurrences descending. Y axis: plain English names. X axis: count.
- Bar color per category: severity badge color for avg_severity
- Show data value labels at end of each bar (white, 12px)
- If no data: placeholder text "No findings recorded yet."

**Chart B — "Audit Results" (doughnut):**
- Title: "Audit Results", subtitle: "Pass vs fail across all runs"
- Canvas `id="auditDonut"`, height 200px
- Data: PASS count (#22c55e), FAIL count (#ef4444), MAX_CYCLES count (#f97316)
- Center overlay text (absolute positioned over canvas center): "[pass_rate]%" in 28px bold, "pass rate" in 12px muted below
- If no trend data: placeholder "No audit history yet."

**Chart C — "WorldClass Scores" (line):**
- Title: "WorldClass Scores", subtitle: "Target is 95 — higher is better"
- Canvas `id="wcChart"`, height 200px
- X axis: wc_cumulative_cycle_end (integer, label "Cycle")
- Y axis: score 0–100
- Line: color #a855f7, fill rgba(168,85,247,0.08)
- Points: green if ≥95, yellow if 80–94, red if <80, radius 5
- Horizontal dashed reference line at y=95: color #22c55e, label "World-class" at right edge
- If fewer than 2 rows: placeholder "Need more runs to show trend."

**Chart D — "Audit Severity Trend" (line):**
- Title: "Audit Severity Over Time", subtitle: "Lower is better — fewer serious issues found"
- Canvas `id="severityChart"`, height 200px
- X axis: cumulative_cycle_end (integer, label "Cycle")
- Y axis: final_severity 0–10
  - Tick labels: 1="Trivial", 5="Medium", 8="Critical" (only label those three)
- Line: color #3b82f6, fill rgba(59,130,246,0.08)
- Points: green if verdict=PASS, red if FAIL, orange if MAX_CYCLES, radius 5
- Horizontal dashed line at y=5: color rgba(249,115,22,0.5), label "Concern threshold"
- If fewer than 2 rows: placeholder "Need more runs."

---

**SECTION 5 — HABITS TO FIX:**

Show only if systemic patterns exist (occurrences >= 3, unique_cycles >= 3). Section label: "HABITS TO FIX" with count badge (small pill, var(--red) background at 20%, var(--red) text).

If no systemic patterns: green card "No repeating habits yet — every issue so far has been a one-off. Keep going."

For each systemic pattern sorted by avg_severity descending, one card:
- Left border: 3px solid [severity badge color]
- Top row (flex, space-between):
  - Plain English category name (17px, 600 weight)
  - Severity badge pill: [label] in [color], border [color], background [color] at 15% opacity, border-radius 999px, padding 3px 12px, font-size 12px
- Business impact sentence (14px, var(--text-muted), margin-top 6px)
- Stats row (13px, var(--text-muted), margin-top 10px, flex gap 20px):
  - "Appeared [occurrences] times"
  - "Across [unique_cycles] audit cycles"
  - "Last seen: cycle [last_seen_cycle]"
- Sparkline (optional — small inline bar): 20 pixels tall, one bar per audit run, height proportional to count in that run, color matching severity. Show last 10 runs only.

---

**SECTION 6 — TASK HISTORY TABLE:**

Section label: "TASK HISTORY".

Table: full width, border-collapse collapse. Columns:
Task | Cycles Used | Severe Issues | Final Severity | Verdict | WorldClass

Populate from audit_rows (most recent first). For each row:
- Task: first 45 chars of task name
- Cycles Used: cycles_this_task
- Severe Issues: severe_count (color red if >0, green if 0)
- Final Severity: number (color by value — green ≤3, yellow 4–6, red ≥7)
- Verdict: pill badge — PASS #22c55e, FAIL #ef4444, MAX_CYCLES #f97316
- WorldClass: score from wc_rows (match by task name fuzzy first 40 chars), or "—"

Row alternating: var(--card) / var(--card-alt). Header row: background var(--border), font-weight 600.
If no data: "No task history yet."

---

**SECTION 7 — PHILOSOPHY CANDIDATES (if any qualify):**

Show only if any pattern meets graduation threshold: occurrences >= 3, avg_severity >= 6, unique_cycles >= 3.
Section label: "READY TO BECOME RULES".
Subtitle: "These issues have recurred enough times that the team should add them as permanent coding standards. See the terminal to approve or skip each one."

One card per qualifying pattern (plain English name, occurrence count, avg severity). No approve/skip in the HTML — that happens in the terminal.

If none qualify: omit this section entirely.

---

**SECTION 8 — TECHNICAL DETAIL (collapsed):**

`<details><summary style="cursor:pointer; color:var(--text-muted); font-size:13px;">Technical detail (for developers)</summary>`
Inside: `<pre>` containing PATTERNS_RAW verbatim, font-size 12px, color var(--text-muted), overflow-x auto, white-space pre-wrap.
Closed by default.

---

**FOOTER:**

Centered, font-size 12px, color var(--text-muted), padding-top 24px, border-top 1px solid var(--border), margin-top 32px.
"Generated by /patterns on [today's date]  ·  Saved: .autocode/reports/patterns-[date].html  ·  Previous reports in .autocode/reports/"

---

## PHASE 3: OPEN REPORT

Run: `open .autocode/reports/patterns-[today's date].html`

Print in terminal:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  HEALTH REPORT OPENED IN BROWSER
  Saved: .autocode/reports/patterns-[date].html
  Total cycles tracked: [total_cycles]
  Philosophy markers on chart: [count of PHILOSOPHY_ANNOTATIONS]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## PHASE 4: INTERACTIVE STEPS (terminal)

**Step 4A — Archive prompt:**

Ask: "Archive this batch and start fresh? (y/n)"

If yes:
1. Rename `.autocode/patterns.md` → `.autocode/patterns-archive-[today's date].md`
2. Create fresh `.autocode/patterns.md` with header `# AutoCode Patterns Log`
3. Print: "✅ Archived. Starting fresh — previous data preserved in patterns-archive-[date].md."
If no: print "Keeping current data."

Note: trends.md and reflections.md are never archived — permanent longitudinal records.

---

**Step 4B — Philosophy graduation:**

For each pattern qualifying for graduation (occurrences >= 3, avg_severity >= 6, unique_cycles >= 3):

Spawn a single independent agent:

"You are a senior software architect deciding whether a recurring code quality problem deserves a permanent place in a project's coding philosophy.

Recurring pattern: [plain English name, raw category, occurrence count, avg severity, unique_cycles]

Current philosophy document:
[full contents of ~/.claude/autocode/philosophy.md]

Propose the exact text to add to prevent this pattern from recurring. Be specific:
1. Which section it belongs in
2. Exact text — same voice and format as the existing document
3. Why this rises to the level of philosophy (not a one-time fix)

Do not suggest vague guidance. 'Handle errors properly' is useless. Cite the specific scenario, function type, or pattern.

Output:
SECTION: [which section]
TEXT TO ADD:
[exact text]
WHY PHILOSOPHY-LEVEL: [one sentence]"

Print in terminal:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PHILOSOPHY CANDIDATE: [plain English name]
  [N] occurrences · avg severity [N] · [N] cycles
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Section: [proposed section]

  [TEXT TO ADD]

  Why: [reason]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Ask: "Add this to philosophy.md? (y/n)"

If yes:
1. Read `~/.claude/autocode/philosophy.md`
2. Insert text into correct section
3. Append to `## CHANGELOG` table: `| [today's date] | [section] | [one-line summary in plain English] | [N] occurrences, avg severity [N] |`
4. Write the updated file
5. Print: "✅ Added to [section]. Will appear as a marker on the chart next time you run /patterns."

If no: print "Skipped."

Present each candidate one at a time. If none qualify: print "No patterns meet the graduation threshold yet (need 3+ occurrences at avg severity ≥ 6 across 3+ cycles)."

---

**Step 4C — Agent memory updates:**

For each systemic pattern (occurrences >= 3, severity >= 5, unique_cycles >= 3):

Category → agent file:
- error-handling, feature-flag, async, edge-case, code-quality, performance, data-loss → architect.md
- tests, requirements → qa.md
- auth, security → security.md
- documentation → docs.md

For each target `.autocode/agents/[agent].md`:
1. If file doesn't exist: skip with warning
2. Find or create `## Known Blind Spots` section
3. Add or update: `- [plain English name]: [N] occurrences, avg severity [N] across [N] cycles — [specific watch-for based on descriptions]`
   `  Last seen: cycle [last_seen_cycle] | Updated: [today's date]`

Update `.autocode/agents/cto.md` Known Blind Spots column for affected agents.

Print:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  AGENT MEMORIES UPDATED
  [list each file and what was written]
  Agents will now explicitly watch for these patterns.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

**Step 4D — Universal Elevation Check:**

Parse `~/.claude/autocode/philosophy.md` CHANGELOG table (section `## CHANGELOG`). Group rows by "Section Updated" column. Count rows per section.

If no section has 3+ rows: print `No universal candidates yet — need 3+ independent graduations of the same category.` and skip this step.

For each section with 3+ rows, spawn a single agent:

"You are a senior software architect deciding whether a recurring project-level principle deserves promotion to a universal building standard that applies to all projects.

Category that graduated independently 3+ times: [section name]
Graduation count: [N]
Graduation entries from philosophy.md CHANGELOG:
[paste all rows for this section]

Current worldclass-standard.md:
[full contents of ~/.claude/commands/worldclass-standard.md]

Does this category already have a principle in worldclass-standard.md?
- If YES: is there a meaningful strengthening based on what caused 3+ independent graduations?
- If NO: propose a new principle in the same voice and format as the existing 8.

In either case, cite the evidence: what do the graduation entries reveal that makes this universal?

Output:
ACTION: ADD NEW / STRENGTHEN EXISTING / NO CHANGE NEEDED
PRINCIPLE NUMBER: [next number if new, existing number if strengthening]
TITLE: [principle title]
RUBRIC CATEGORY: [the WorldClass deduction category this maps to]
TEXT: [exact principle text to add or replace]
EVIDENCE: [one sentence: why 3+ independent graduations proves universality]"

Print in terminal:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  UNIVERSAL CANDIDATE: [section name]
  [N] independent graduations in philosophy.md
  Action: [ADD NEW / STRENGTHEN / NO CHANGE]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [TEXT]

  Evidence: [EVIDENCE]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Ask: "Elevate to worldclass-standard.md? (y/n)"

If yes:
1. Read `~/.claude/commands/worldclass-standard.md`
2. Add new principle or strengthen existing (same voice, same format as the 8 founding principles)
3. Update Provenance table: add row with "Elevated from philosophy.md" and graduation count
4. Append to worldclass-standard.md `## CHANGELOG`: `| [today's date] | Principle [N]: [title] | [ADD NEW / STRENGTHEN EXISTING] | [N] independent graduations in philosophy.md |`
5. Write updated file
6. Print: "✅ Elevated to WorldClass Standard. Build agents will adopt this on the next cycle."

If no: print "Skipped."

Present each candidate one at a time. If none qualify: already printed above.

---

**Step 4E — Carry-Forward Pattern Analysis:**

Read `.autocode/carry-forward-log.md`. If it doesn't exist or contains no data rows (only the header): print `CF-PATTERNS: No carry-forward history yet.` and skip this step.

Parse each data row: `| date | source_task | cf_task | category | description | severity |`

Group by `category`. For any category with entries from 2 or more DIFFERENT source tasks (different values in the Source Task column): it is a systematic build gap.

For each systematic gap category:

1. Extract the relevant principle text from the WORLDCLASS_MANDATE block in `~/.claude/commands/task.md`. Find the principle whose name or focus matches the category (e.g., `tests` → "Tests prove behavior"; `async` → "Close every async path"; `code-quality` → "Earn every abstraction" or "Name the contract exactly").

2. Spawn an agent:
   "The build agent has produced carry-forward WorldClass gaps in category [CATEGORY] across [N] different tasks:
   [list each entry: Source Task | description | severity]

   The current WORLDCLASS_MANDATE principle for this category:
   [principle text from task.md WORLDCLASS_MANDATE]

   This is the exact text the build agent reads before writing any code. The carry-forward history shows it is not preventing this class of gap.

   Propose a concrete strengthening (maximum 3 sentences appended to the existing principle) that would help the build agent avoid this exact class of gap. Requirements:
   - Draw a specific negative example from the carry-forward history above
   - Name what the build agent is checking instead of what it should check
   - End with a test the builder can apply before writing the function

   Output exactly: PROPOSED_ADDITION: [text to append]"

3. Present proposal:
   ```
   ──────────────────────────────────────────────────────
     WORLDCLASS_MANDATE UPDATE — [CATEGORY]
     [N] carry-forwards across [N] tasks
   ──────────────────────────────────────────────────────
     [PROPOSED_ADDITION]
   ──────────────────────────────────────────────────────
     approve / skip
   ```
   If approved: edit `~/.claude/commands/task.md` — find the relevant WORLDCLASS_MANDATE principle and append PROPOSED_ADDITION. Copy updated task.md to `/tmp/claude-dev-team/commands/task.md` and stage for commit (commit at end of Step 4E after all approvals processed).

4. Map category to agent memory file:
   - `code-quality`, `tests`, `edge-case` → `qa.md`
   - `security`, `auth` → `security.md`
   - `async`, `data-loss`, `error-handling` → `architect.md`

   Append to `## Known Blind Spots` in `.autocode/agents/[file]`:
   `- Carry-forward pattern: [category] gap across [N] tasks — [one-line description] — [today's date]`

After processing all systematic gaps, print:
`CF-PATTERNS: [N] systematic gap(s) detected. [N] WORLDCLASS_MANDATE update(s) proposed. [N] agent blind spot(s) recorded.`

If any WORLDCLASS_MANDATE updates were approved: commit and push the updated task.md to dev-team repo.

---

## RULES

- Never fabricate data — only use what is in the log files
- Plain English translations are mandatory everywhere — never show raw category names in the HTML
- X axis on all time-based charts is cumulative cycle count, never dates
- Severe issues chart is always the first and largest chart — it is the primary signal
- Philosophy annotations must come from the actual CHANGELOG in philosophy.md — never invent markers
- The HTML file must be self-contained and open without a server
- Chart.js and chartjs-plugin-annotation from CDN are the only external script dependencies
- Charts show "Need more runs" placeholders if data is insufficient — never empty axes
- Systemic pattern threshold requires unique_cycles >= 3 (cross-cycle, not cross-task) — this measures prompt gaps, not task difficulty
- Previous report files in .autocode/reports/ are never deleted
- Philosophy updates are permanent — never propose vague or redundant additions
- Archive prompt always runs before philosophy step
