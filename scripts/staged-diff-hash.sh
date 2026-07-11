#!/usr/bin/env bash
# ===========================================
# STAGED DIFF HASH
# ===========================================
# Computes a stable hash of the staged source diff. Used to pair a gate
# artifact (.autocode/reviews/gate/<hash>.json) to the EXACT code it was
# reviewed against — any further staged edit changes the hash and
# invalidates the pairing, forcing a fresh review.
#
# Source diff content (.ts/.tsx/.js/.jsx) AND harness files are hashed:
# command prose (.claude/commands/*.md), gate/lifecycle scripts (scripts/*.sh),
# and the pre-commit hook itself (.husky/*). Harness files are enforcement
# infrastructure — an unreviewed edit there disables gates for everything
# else. Doc/config-only edits outside these paths don't invalidate a review.
#
# MUST change in lockstep with scripts/classify-diff-size.sh — if classify
# says FULL while this prints NONE, the pre-commit gate looks for
# .autocode/reviews/gate/NONE.json and blocks every commit forever.
#
# Usage: bash scripts/staged-diff-hash.sh
# Prints a 12-character hex hash, or "NONE" if no source diff is staged.
# ===========================================

set -uo pipefail

# Pathspecs below are CWD-relative — run from a subdirectory they would scope
# to that subdir and disagree with the hook's toplevel computation. Anchor to
# the repo root so the result is deterministic from any invocation directory.
# Two-step on purpose: `cd ""` is a bash success no-op, so a one-liner's
# `|| exit 1` would be dead code and an out-of-repo run would fall open.
TOP=$(git rev-parse --show-toplevel) || exit 1
cd "$TOP" || exit 1

DIFF=$(git diff --cached --no-renames -- '*.ts' '*.tsx' '*.js' '*.jsx' '.claude/commands/*.md' 'scripts/*.sh' '.husky/*' 2>/dev/null || true)

if [ -z "$DIFF" ]; then
  echo "NONE"
  exit 0
fi

echo "$DIFF" | shasum -a 256 | cut -c1-12
