#!/usr/bin/env bash
# ===========================================
# COMMAND SYNC CHECK — harness drift detector
# ===========================================
# The PROJECT copies of the per-project harness commands
# (.claude/commands/{advance,go,scan,scope}.md) are CANONICAL — they are what
# actually runs in this repo (project-level overrides user-level).
# ~/Projects/claude-dev-team mirrors them; the mirror is synced AFTER work
# lands on main (canonical must never lead the project copy).
#
# Home-level (~/.claude/commands) copies of these four commands are
# COLLISIONS: shadowed in this repo, but the live drift source everywhere
# else (this is how the Jul-8 Figly rewrite created three-way ambiguity).
# Home cleanup was explicitly deferred on 2026-07-10 — collisions WARN, they
# do not fail, until that follow-up is approved.
#
# Usage: bash scripts/check-command-sync.sh [--warn]
#   default : exit 1 on any project<->claude-dev-team divergence
#   --warn  : print all findings but always exit 0. Used by the pre-commit
#             hook, where divergence is an EXPECTED intermediate state
#             between editing a command and the post-merge sync step.
# ===========================================

set -uo pipefail

MODE="${1:-strict}"
case "$MODE" in
  --warn) ;;
  strict) ;;
  *)
    echo "Usage: bash scripts/check-command-sync.sh [--warn]"
    exit 2
    ;;
esac
# SYNC_ROOT lets a caller point this check at a staged-content mirror (the
# pre-commit gate's TMC run) instead of the live working tree — without it,
# a "staged content" gate would silently diff live command files.
ROOT="${SYNC_ROOT:-$(git rev-parse --show-toplevel)}"
CANON="$HOME/Projects/claude-dev-team/commands"
CANON_SCRIPTS="$HOME/Projects/claude-dev-team/scripts"
FAIL=0

COMMANDS=(advance go scan scope)
# Harness scripts that must stay mirrored once they exist in the project.
SYNCED_SCRIPTS=(wave-worktrees.sh check-command-sync.sh test-wave-worktrees.sh test-module-context.sh classify-diff-size.sh staged-diff-hash.sh test-commit-gates.sh)

if [ ! -d "$CANON" ]; then
  echo "✗ claude-dev-team not found at $CANON — cannot check sync"
  [ "$MODE" = "--warn" ] && exit 0
  exit 1
fi

for f in "${COMMANDS[@]}"; do
  if [ ! -f "$ROOT/.claude/commands/$f.md" ]; then
    echo "✗ $f.md missing from project .claude/commands"
    FAIL=1
  elif [ ! -f "$CANON/$f.md" ]; then
    echo "✗ $f.md missing from claude-dev-team (sync after landing on main)"
    FAIL=1
  elif diff -q "$ROOT/.claude/commands/$f.md" "$CANON/$f.md" >/dev/null 2>&1; then
    echo "✓ $f.md in sync (project == claude-dev-team)"
  else
    echo "✗ $f.md DIVERGED — after landing on main: cp .claude/commands/$f.md $CANON/ && commit + push"
    FAIL=1
  fi
  if [ -f "$HOME/.claude/commands/$f.md" ]; then
    echo "⚠ COLLISION: ~/.claude/commands/$f.md exists — shadowed in this repo, drift source elsewhere (cleanup deferred 2026-07-10)"
  fi
done

for s in "${SYNCED_SCRIPTS[@]}"; do
  if [ ! -f "$ROOT/scripts/$s" ]; then
    [ -f "$CANON_SCRIPTS/$s" ] && echo "⚠ scripts/$s in canon but not adopted in this project"
    continue
  fi
  if [ ! -f "$CANON_SCRIPTS/$s" ]; then
    echo "✗ scripts/$s missing from claude-dev-team (sync after landing on main)"
    FAIL=1
  elif diff -q "$ROOT/scripts/$s" "$CANON_SCRIPTS/$s" >/dev/null 2>&1; then
    echo "✓ scripts/$s in sync"
  else
    echo "✗ scripts/$s DIVERGED — after landing on main: cp scripts/$s $CANON_SCRIPTS/ && commit + push"
    FAIL=1
  fi
done

if [ "$MODE" = "--warn" ]; then
  [ "$FAIL" -ne 0 ] && echo "(warn mode: divergence reported, not blocking — hard check runs at sync time)"
  exit 0
fi
exit $FAIL
