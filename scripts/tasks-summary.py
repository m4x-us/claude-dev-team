#!/usr/bin/env python3
"""
tasks-summary.py — fast task list formatter for the autocode skill system

Usage:
  python3 tasks-summary.py [--file PATH] [--open] [--batch N] [--debt]

Defaults: --file .autocode/tasks.md, all tasks, all batches
"""

import sys, os, re
from dataclasses import dataclass, field
from collections import defaultdict
from typing import Optional

DEFAULT_TASKS = ".autocode/tasks.md"
DEFAULT_DEBT  = ".autocode/debt.md"

# ── Box drawing ───────────────────────────────────────────────────────────────
H  = "─"; V  = "│"
TL = "┌"; TR = "┐"; BL = "└"; BR = "┘"
TM = "┬"; BM = "┴"; LM = "├"; RM = "┤"; MM = "┼"

# Column content widths (excluding 1-space padding each side)
COLS = [6, 13, 48, 18, 12]  # num, comp, title, owner, status

# Double-width terminal chars
WIDE = frozenset("⚡🔧❓↩")

def disp_w(s: str) -> int:
    return sum(2 if c in WIDE else 1 for c in s)

def pad_to(s: str, w: int) -> str:
    return s + " " * max(0, w - disp_w(s))

def trunc(s: str, w: int) -> str:
    if disp_w(s) <= w:
        return s
    buf, acc = [], 0
    for c in s:
        cw = 2 if c in WIDE else 1
        if acc + cw > w - 3:
            break
        buf.append(c); acc += cw
    return "".join(buf) + "..."

def hline(l, m, r):
    return l + m.join(H * (c + 2) for c in COLS) + r

def trow(*cells):
    parts = [" " + pad_to(trunc(str(s), w), w) + " " for s, w in zip(cells, COLS)]
    return V + V.join(parts) + V

# ── Data ──────────────────────────────────────────────────────────────────────
@dataclass
class Task:
    num:        str = ""
    title:      str = ""
    complexity: str = ""
    owner:      str = ""
    status:     str = "open"

@dataclass
class Batch:
    num:   int  = 0
    theme: str  = ""
    tasks: list = field(default_factory=list)

# ── Parsing ───────────────────────────────────────────────────────────────────
def parse_complexity(raw: str) -> str:
    r = raw.lower()
    if "direct" in r: return "⚡ Direct"
    if "full"   in r: return "🔧 Full"
    return "❓ No label"

# Field prefixes that are NOT the task title
NON_TITLE = re.compile(
    r"^\*\*(Complexity|Owner|File|Blocks|Blocked|Done|Added|Moved|Label|"
    r"Scope|Spawned|Status|Audit|World|Why|Carry|How|When|Batch)"
)

def parse_task_block(block: str) -> Optional[Task]:
    lines = block.split("\n")
    m = re.match(r"^(\d+)", lines[0])
    if not m:
        return None
    task = Task(num=f"#{m.group(1).zfill(3)}")

    # Title: first meaningful non-field line
    for ln in lines[1:]:
        s = ln.strip()
        if not s:
            continue
        # **What:** prefix → strip it
        wm = re.match(r"^\*\*What:\*?\*?\s+(.+)", s)
        if wm:
            task.title = wm.group(1).rstrip("*").strip()
            break
        # **Carry-Forward ...** → use as title (strip asterisks)
        if re.match(r"^\*\*Carry-Forward", s):
            task.title = s.strip("*").strip()
            break
        # Pure field line → skip (title comes later or stays empty)
        if NON_TITLE.match(s):
            continue
        # Plain text → title
        task.title = s
        break

    # Fields (scan whole block)
    for ln in lines:
        s = ln.strip()
        m2 = re.match(r"^\*\*Complexity[*:]+\s*(.+)", s)
        if m2:
            task.complexity = parse_complexity(m2.group(1).rstrip("*"))
        m2 = re.match(r"^\*\*Owner[*:]+\s*(.+)", s)
        if m2:
            task.owner = m2.group(1).rstrip("*").strip()
        if "**Status: COMPLETE" in s:
            task.status = "✓ Complete"
        elif "**Status: REOPEN" in s:
            task.status = "↩ Reopened"

    return task

def parse_file(path: str) -> list:
    if not os.path.exists(path):
        return []
    with open(path) as f:
        content = f.read()

    batches = []
    for section in re.split(r"^## Batch ", content, flags=re.MULTILINE)[1:]:
        m = re.match(r"^(\d+)\s*[—–-]+\s*(.+)", section)
        if not m:
            continue
        batch = Batch(num=int(m.group(1)), theme=m.group(2).strip())
        for tblock in re.split(r"^### Task #", section, flags=re.MULTILINE)[1:]:
            t = parse_task_block(tblock)
            if t:
                batch.tasks.append(t)
        batches.append(batch)
    return batches

# ── Task table ────────────────────────────────────────────────────────────────
def print_table(batch: Batch, tasks: list):
    if not tasks:
        return
    print(f"\nBatch {batch.num} — {batch.theme}")
    print(hline(TL, TM, TR))
    print(trow("#", "Complexity", "Title", "Owner", "Status"))
    print(hline(LM, MM, RM))
    for t in tasks:
        print(trow(t.num, t.complexity or "❓ No label", t.title, t.owner, t.status))
    print(hline(BL, BM, BR))

# ── Debt table ────────────────────────────────────────────────────────────────
def print_debt(path: str):
    if not os.path.exists(path):
        print("No debt items recorded yet.")
        print("Debt items are auto-logged when WorldClass deductions appear — severity 1-3 silently,")
        print("severity ≥ 4 when explicitly accepted at the carry-forward gate.")
        return

    with open(path) as f:
        lines = f.readlines()

    rows = []
    for ln in lines:
        ln = ln.strip()
        if not ln or ln.startswith("#") or ln.startswith("| Date") or set(ln) <= set("|-: "):
            continue
        cols = [c.strip() for c in ln.split("|") if c.strip()]
        if len(cols) >= 7:
            rows.append(cols)

    if not rows:
        print("No debt items recorded yet.")
        return

    # Debt columns: Date | Source Task | Category | Description | Severity | Complexity | Reason
    DW = [10, 12, 13, 40, 8, 11, 28]
    HDRS = ["Date", "Source Task", "Category", "Description", "Severity", "Complexity", "Reason"]

    def dhline(l, m, r):
        return l + m.join(H * (w + 2) for w in DW) + r

    def drow(*cells):
        parts = [" " + pad_to(trunc(str(s), w), w) + " " for s, w in zip(cells, DW)]
        return V + V.join(parts) + V

    print(f"\nDebt Register — {len(rows)} item(s)")
    print(dhline(TL, TM, TR))
    print(drow(*HDRS))
    print(dhline(LM, MM, RM))
    for r in rows:
        print(drow(*r[:7]))
    print(dhline(BL, BM, BR))

    cats = defaultdict(list)
    for r in rows:
        try:
            cats[r[2]].append(int(r[4]))
        except (IndexError, ValueError):
            pass
    print("\nBy category:")
    for cat, sevs in sorted(cats.items()):
        print(f"  {cat}: {len(sevs)} item(s) · avg severity {sum(sevs)/len(sevs):.1f}")

    direct_n = sum(1 for r in rows if len(r) > 5 and "Direct" in r[5])
    full_n   = sum(1 for r in rows if len(r) > 5 and "Full"   in r[5])
    print(f"\n⚡ Direct items: {direct_n}  (batchable into nearby tasks — surfaced automatically at Step 0.0b)")
    print(f"🔧 Full items: {full_n}   (require a dedicated task — consider adding to the next batch)")

# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    args = sys.argv[1:]
    mode       = "all"
    batch_num  = None
    tasks_file = DEFAULT_TASKS

    i = 0
    while i < len(args):
        a = args[i]
        if a == "--open":
            mode = "open"
        elif a == "--debt":
            mode = "debt"
        elif a == "--batch" and i + 1 < len(args):
            mode = "batch"; batch_num = int(args[i + 1]); i += 1
        elif a == "--file" and i + 1 < len(args):
            tasks_file = args[i + 1]; i += 1
        i += 1

    if mode == "debt":
        print_debt(DEFAULT_DEBT)
        return

    batches = parse_file(tasks_file)
    if not batches:
        print("No task list found. Run /meet to generate one.")
        return

    total = total_open = total_complete = no_label = 0

    for batch in batches:
        if mode == "batch" and batch.num != batch_num:
            continue
        tasks = batch.tasks if mode != "open" else [t for t in batch.tasks if t.status == "open"]

        for t in tasks:
            total += 1
            if   t.status == "open":      total_open    += 1
            else:                          total_complete += 1
            if not t.complexity:           no_label      += 1

        print_table(batch, tasks)

    print(f"\n{total_open} open · {total_complete} complete · {total} total")
    if no_label:
        print(f"{no_label} task(s) missing Complexity label — run /task #N to classify")

if __name__ == "__main__":
    main()
