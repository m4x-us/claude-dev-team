#!/usr/bin/env bash
# ===========================================
# CLASSIFY DIFF SIZE — Direct vs Full
# ===========================================
# Classifies the currently staged diff as DIRECT or FULL, using the same
# distinction already used for task complexity labeling in /scan and /task:
#   DIRECT — 1-2 files, no package boundary, no security-sensitive path
#   FULL   — packages/ boundary, security-sensitive path, or 3+ files
#
# Used by .husky/pre-commit's FFF/WorldClass gate to decide which review
# tier a commit requires. Prints exactly one of: DIRECT | FULL
# followed by a one-line reason on the next line.
#
# Usage: bash scripts/classify-diff-size.sh
# ===========================================

set -uo pipefail

# Pathspecs below are CWD-relative — run from a subdirectory they would scope
# to that subdir and disagree with the hook's toplevel computation. Anchor to
# the repo root so the result is deterministic from any invocation directory.
# Two-step on purpose: `cd ""` is a bash success no-op, so a one-liner's
# `|| exit 1` would be dead code and an out-of-repo run would fall open.
TOP=$(git rev-parse --show-toplevel) || exit 1
cd "$TOP" || exit 1

STAGED=$(git diff --cached --no-renames --name-only --diff-filter=d 2>/dev/null || true)

# Staged DELETIONS of source or harness files also require review. STAGED
# above excludes them (--diff-filter=d), which meant a deletion-only commit
# — e.g. removing a security check or a gate script — bypassed the review
# gate entirely (hole found 2026-07-10 when a stray `git rm -r --cached
# .autocode` + commit sailed through the hook).
# Deletions carry NO test-file exemption: deleting a test silently removes
# the enforcement that some behavior keeps working — that is itself
# review-worthy, unlike editing a test alongside its source.
DELETED=$(git diff --cached --no-renames --name-only --diff-filter=D 2>/dev/null | grep -E '\.(ts|tsx|js|jsx)$|^\.claude/commands/.*\.md$|^scripts/.*\.sh$|^\.husky/' || true)
if [ -n "$DELETED" ]; then
  echo "FULL"
  echo "Staged deletion of source/harness file: $(echo "$DELETED" | head -1) — deletions always take the full review tier."
  exit 0
fi

# Harness files — command prose, ALL scripts/*.sh (deliberately conservative:
# every shell script under scripts/ is treated as enforcement infrastructure
# — gates, lifecycle, audits, tests — so none can slip to a lighter tier),
# and the pre-commit
# hook itself — always take the FULL review tier. They are enforcement
# infrastructure: an unreviewed edit there silently disables gates for every
# later commit, so they can never ride the DIRECT (or NONE) path.
#
# apps/web/scripts/check-cms-preset-write-gate.ts (Task #122 rebuild,
# 2026-10-08) is ALSO enforcement infrastructure — the real AST logic
# behind scripts/cms-preset-write-gate.sh's thin wrapper — but lives
# outside scripts/, so the pattern above would miss it on its own if
# edited alone. Added here explicitly, by exact path (not a wildcard —
# see this gate's own Rule-24 discipline about not re-growing a stale
# hand-maintained list).
#
# apps/web/scripts/lib/ts-parse.ts is ALSO added here — a post-rebuild
# independent review found this gap live (a one-line edit to it alone
# classified DIRECT, not FULL) and it is arguably MORE load-bearing than
# the checker file above: it's the SHARED fail-closed parse-diagnostics
# module BOTH check-cms-preset-write-gate.ts and check-agent-tool-routes.ts
# depend on for their entire "a file that fails to parse is a violation,
# never a silent pass" guarantee — that file's own header already warns a
# broken `parseDiagnostics` lookup would let a real broken commit through
# while only the fixture suite goes red.
#
# apps/web/scripts/lib/cms-preset-ast.ts (round-4 split, 2026-10-08) holds
# the checker's entire AST semantic-analysis logic (expand/literalNamesOf/
# receiversOf/modelsOf/collectAliases) — extracted once the checker file
# crossed ~500 lines. Added here for the identical reason as the checker
# file itself: this is where a future "one more wrapper kind" fix would
# actually land, and it must never silently classify as DIRECT-tier.
#
# DISCLOSED, NOT FIXED HERE: apps/web/scripts/check-agent-tool-routes.ts
# itself, and its other lib/ files (route-tree.ts, tool-catalog.ts,
# route-verbs.ts), have this identical latent gap today — confirmed via
# the same grep this comment is describing — and are deliberately left
# alone, out of this task's scope; a future pass should close all of
# these together rather than let each one-off addition become its own
# stale list.
# MUST match the pathspec list in scripts/staged-diff-hash.sh (see note there).
HARNESS_FILES=$(echo "$STAGED" | grep -E '^\.claude/commands/.*\.md$|^scripts/.*\.sh$|^\.husky/|^apps/web/scripts/check-cms-preset-write-gate\.ts$|^apps/web/scripts/lib/ts-parse\.ts$|^apps/web/scripts/lib/cms-preset-ast\.ts$' || true)
if [ -n "$HARNESS_FILES" ]; then
  echo "FULL"
  echo "Harness file staged: $(echo "$HARNESS_FILES" | head -1) — command prose and gate scripts always take the full review tier."
  exit 0
fi

# Only source files count toward classification — docs/config changes alone
# never require a fresh-eyes review.
SOURCE_FILES=$(echo "$STAGED" | grep -E '\.(ts|tsx|js|jsx)$' | grep -v '\.test\.\|\.spec\.' || true)

if [ -z "$SOURCE_FILES" ]; then
  echo "NONE"
  echo "No staged source files — gate not applicable."
  exit 0
fi

FILE_COUNT=$(echo "$SOURCE_FILES" | grep -c . || true)

# Security/money-sensitive path keywords — any match forces FULL regardless
# of file count.
SENSITIVE_MATCH=$(echo "$SOURCE_FILES" | grep -iE '(^|/)(auth|security|payment|stripe|refund|password|credential|permission|scheduling-auth|role)([-./]|$)' || true)

# API routes are a multi-tenant boundary where organizationId row-scoping is
# the ONLY isolation (all orgs share one physical DB). The keyword regex
# above does not catch them by path, so the CMS-5 slots IDOR diff classified
# DIRECT and got only a lightweight FFF pass (W1C finding). Originally scoped
# to api/cms/ only; GENERALIZED (2026-08-17, Rule 24 "Gate Completeness") to
# ALL of api/ — scripts/cms-org-scoping-gate.sh's own scan roots widened the
# same day for the identical reason (a real severity-9 marketingBrandGuide
# bug in marketing/war-room code, invisible to the old cms-only surface —
# see that script's header). Any api/ route change (any namespace, not just
# cms) is FULL-tier — the exact class this classifier exists to escalate,
# now matching the gate it exists to pair with.
CMS_API_MATCH=$(echo "$SOURCE_FILES" | grep -E '^apps/web/src/app/api/.*route\.(ts|tsx)$' || true)

PACKAGE_MATCH=$(echo "$SOURCE_FILES" | grep -E '^packages/' || true)

if [ -n "$SENSITIVE_MATCH" ]; then
  echo "FULL"
  echo "Security/money-sensitive path staged: $(echo "$SENSITIVE_MATCH" | head -1)"
  exit 0
fi

if [ -n "$CMS_API_MATCH" ]; then
  echo "FULL"
  echo "API route staged (multi-tenant boundary — see CMS-5 / Rule 24): $(echo "$CMS_API_MATCH" | head -1)"
  exit 0
fi

if [ -n "$PACKAGE_MATCH" ]; then
  echo "FULL"
  echo "Touches a packages/ boundary: $(echo "$PACKAGE_MATCH" | head -1)"
  exit 0
fi

if [ "$FILE_COUNT" -ge 3 ]; then
  echo "FULL"
  echo "$FILE_COUNT source files staged (>= 3)"
  exit 0
fi

echo "DIRECT"
echo "$FILE_COUNT source file(s), no package boundary, no security-sensitive path"
