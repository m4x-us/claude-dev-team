#!/bin/bash
# install.sh — copy claude-dev-team skills into your local Claude Code setup

set -e

COMMANDS_SRC="$(dirname "$0")/commands"
SCRIPTS_SRC="$(dirname "$0")/scripts"
AUTOCODE_SRC="$(dirname "$0")/autocode"

COMMANDS_DEST="$HOME/.claude/commands"
SCRIPTS_DEST="$HOME/.claude/scripts"
AUTOCODE_DEST="$HOME/.claude/autocode"

mkdir -p "$COMMANDS_DEST" "$SCRIPTS_DEST" "$AUTOCODE_DEST"

echo "Installing skill commands → $COMMANDS_DEST"
cp "$COMMANDS_SRC"/*.md "$COMMANDS_DEST/"

echo "Installing scripts → $SCRIPTS_DEST"
cp "$SCRIPTS_SRC"/tasks-summary.py "$SCRIPTS_DEST/"

echo "Installing autocode → $AUTOCODE_DEST"
cp "$AUTOCODE_SRC"/philosophy.md "$AUTOCODE_DEST/"
cp "$AUTOCODE_SRC"/autocode.ts "$AUTOCODE_DEST/"
cp "$AUTOCODE_SRC"/package.json "$AUTOCODE_DEST/"
cp "$AUTOCODE_SRC"/tsconfig.json "$AUTOCODE_DEST/"

echo ""
echo "Done. Skills available in any Claude Code session:"
echo "  /meet      — onboard team to a codebase"
echo "  /task      — run a full CTO task cycle"
echo "  /advance   — parallel multi-window execution"
echo "  /go        — claim work from the queue (agent windows)"
echo "  /tasks     — view task list"
echo "  /resume    — quick session start"
echo ""
echo "To install autocode bot:"
echo "  cd $AUTOCODE_DEST && npm install && npm run build"
