# Claude Dev Team

A structured development system for Claude Code — parallel multi-agent execution, quality audits, and a CTO orchestration loop built on the Toyota Production System philosophy.

## What it is

A set of Claude Code slash commands that turn Claude into a full dev team:

- **`/meet`** — onboards the team to any codebase. Runs 5 examination agents (architecture, security, QA, docs, product), asks you 7 informed questions, generates a dependency-ordered task list, and writes agent memories that persist across sessions.
- **`/task`** — runs a complete CTO cycle on a single task: build → audit → WorldClass quality check → carry-forward gate. The CTO never writes code directly — it orchestrates the build agent and audit agent until the task meets the standard.
- **`/advance`** — distributes the current sprint batch across up to 4 parallel Claude windows (Adam/Barry/Charles/Derek). Uses union-find clustering to group non-conflicting tasks into isolated streams. Writes queue files so each window can self-assign work.
- **`/go`** — typed in each agent window. Reads the queue, claims the next pending slot, and executes the brief autonomously.
- **`/tasks`** — displays the task list as a formatted table.
- **`/resume`** — quick session start that reads memory without re-scanning the codebase.
- **`/audit`**, **`/worldclass`**, **`/reflect`**, **`/patterns`**, **`/consult`**, **`/team-health`** — supporting commands used by the orchestration loop.

## Philosophy

Built on the Toyota Production System applied to software: quality is the only priority, speed of delivery does not matter. Every task runs through a multi-agent audit loop. No code ships without passing the WorldClass standard (95/100). See `autocode/philosophy.md` for the full standard.

## Install

```bash
git clone https://github.com/m4x-us/claude-dev-team
cd claude-dev-team
chmod +x install.sh
./install.sh
```

Then open Claude Code in any project and type `/meet` to get started.

## Workflow

```
/meet          → examine codebase, generate task list
/tasks         → review what was generated
/advance       → distribute sprint tasks across parallel windows
/go            → (in each agent window) claim and execute work
                 → report done in the /advance window when finished
/meet          → re-run after a sprint to reorganize with new findings
```

## Requirements

- [Claude Code](https://claude.ai/code) CLI installed
- The autocode bot (`autocode/`) requires Node.js 22+ (`npm install && npm run build` inside `autocode/`)
