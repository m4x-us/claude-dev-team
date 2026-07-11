#!/usr/bin/env bash
# ===========================================
# TEST: commit gate scripts
# ===========================================
# Fixture-repo unit tests for the commit-time gate chain:
#   scripts/classify-diff-size.sh — deletion-only commits must classify FULL,
#                                   with NO test-file exemption for deletions
#   scripts/staged-diff-hash.sh   — harness prose changes must hash, not NONE
#   .husky/pre-commit             — a deletion-only commit must NOT bypass the
#                                   FFF/WorldClass gate (the 2026-07-10
#                                   incident shape), and a staged deletion of
#                                   harness command prose must hard-block
#
# Every test runs in a throwaway mktemp fixture repo whose INDEX contains
# copies of the gate scripts under test (the hook extracts them from the
# index) — this suite NEVER touches the real repo or its index.
# Suite stdout is results only — any setup command output is redirected.
#
# Run: bash scripts/test-commit-gates.sh
# ===========================================
set -uo pipefail
FAIL=0; TESTS_RUN=0; TESTS_PASS=0

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SRC="$(cd "$SCRIPTS_DIR/.." && pwd)/.husky/pre-commit"

# Same incident guard as test-wave-worktrees.sh: chdir to a neutral mktemp
# dir so any stray git call hits a non-repo, never the caller's checkout.
NEUTRAL=$(mktemp -d)
cd "$NEUTRAL"

FIXTURES=()
cleanup_all() {
  local d
  for d in ${FIXTURES[@]+"${FIXTURES[@]}"}; do rm -rf "$d"; done
  rm -rf "$NEUTRAL"
}
trap cleanup_all EXIT

assert_eq() {
  TESTS_RUN=$((TESTS_RUN+1))
  if [ "$1" = "$2" ]; then
    echo "  ✓ $3"; TESTS_PASS=$((TESTS_PASS+1))
  else
    echo "  ✗ $3 — expected: '$2', got: '$1'"; FAIL=1
  fi
}
# WARNING: assert_false passes when the condition string is MALFORMED (typo'd
# path, unbound variable → eval fails → "false"). Prefer assert_true/assert_eq
# where possible; when asserting a refusal, ALWAYS pair assert_false with an
# assert_contains on the refusal message so a typo cannot green-light.
# Do not restructure this helper — the pairing convention is the defense.
assert_false() {
  TESTS_RUN=$((TESTS_RUN+1))
  if ! eval "$1" 2>/dev/null; then
    echo "  ✓ $2"; TESTS_PASS=$((TESTS_PASS+1))
  else
    echo "  ✗ $2 — expected false, got true: $1"; FAIL=1
  fi
}
assert_contains() {
  TESTS_RUN=$((TESTS_RUN+1))
  if echo "$1" | grep -q "$2"; then
    echo "  ✓ $3"; TESTS_PASS=$((TESTS_PASS+1))
  else
    echo "  ✗ $3 — output does not contain '$2'"; FAIL=1
  fi
}

# Fixture: a repo whose index holds the gate scripts, the hook itself, a
# source file, a test file, a gate-script stand-in, and a harness command
# stand-in. Everything is committed; each test stages exactly one change.
gate_fixture() {
  local d; d=$(mktemp -d)
  git -C "$d" init --quiet -b main
  git -C "$d" config user.email "test@gates.test"
  git -C "$d" config user.name "Gate Test"
  mkdir -p "$d/scripts" "$d/.husky" "$d/.claude/commands" "$d/src"
  cp "$SCRIPTS_DIR/classify-diff-size.sh" "$d/scripts/classify-diff-size.sh"
  cp "$SCRIPTS_DIR/staged-diff-hash.sh" "$d/scripts/staged-diff-hash.sh"
  cp "$HOOK_SRC" "$d/.husky/pre-commit"
  echo "export const x = 1;" > "$d/src/foo.ts"
  echo "test placeholder" > "$d/src/foo.test.ts"
  printf '#!/bin/sh\nexit 0\n' > "$d/scripts/foo.sh"
  printf '# /go — stand-in harness command prose\n' > "$d/.claude/commands/go.md"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m "initial" >/dev/null 2>&1
  echo "$d"
}

# run_in <dir> <cmd...> — combined stdout+stderr → $OUT, exit code → $RC.
run_in() {
  local d="$1"; shift
  OUT=$( (cd "$d" && "$@") 2>&1 )
  RC=$?
}

echo "=== commit-gate Behavioral Tests ==="

echo ""
echo "Group 1: classify-diff-size.sh deletion handling"
G1=$(gate_fixture); FIXTURES+=("$G1")

# C1 — deletion-only commit of a committed .ts file classifies FULL
git -C "$G1" rm -q src/foo.ts >/dev/null 2>&1
run_in "$G1" bash scripts/classify-diff-size.sh
assert_eq "$(echo "$OUT" | head -1)" "FULL" "C1: deletion-only .ts commit classifies FULL"
git -C "$G1" reset -q --hard HEAD >/dev/null 2>&1

# C2 — deletion-only commit of a .test.ts file classifies FULL: deletions
# carry no test-file exemption (deleting tests is itself review-worthy)
git -C "$G1" rm -q src/foo.test.ts >/dev/null 2>&1
run_in "$G1" bash scripts/classify-diff-size.sh
assert_eq "$(echo "$OUT" | head -1)" "FULL" "C2: deletion-only .test.ts commit classifies FULL"
git -C "$G1" reset -q --hard HEAD >/dev/null 2>&1

# C3 — deletion of a gate/lifecycle script classifies FULL
git -C "$G1" rm -q scripts/foo.sh >/dev/null 2>&1
run_in "$G1" bash scripts/classify-diff-size.sh
assert_eq "$(echo "$OUT" | head -1)" "FULL" "C3: deletion of scripts/foo.sh classifies FULL"
git -C "$G1" reset -q --hard HEAD >/dev/null 2>&1

echo ""
echo "Group 2: staged-diff-hash.sh harness coverage"

# C4 — a commands-only .md change hashes (never NONE): harness prose edits
# must invalidate a stale gate artifact
echo "edited" >> "$G1/.claude/commands/go.md"
git -C "$G1" add .claude/commands/go.md >/dev/null 2>&1
run_in "$G1" bash scripts/staged-diff-hash.sh
assert_false "[ \"$(echo "$OUT" | head -1)\" = \"NONE\" ]" \
  "C4: commands-only .md change produces a hash, not NONE"
git -C "$G1" reset -q --hard HEAD >/dev/null 2>&1

echo ""
echo "Group 3: pre-commit hook end-to-end"

# C5 — the incident shape: a deletion-only commit with no gate artifact must
# exit 1 naming the missing gate. Deterministic: $STAGED (diff-filter=d) is
# empty for a deletion-only commit, so every other hook section no-ops
# before the gate fires.
G2=$(gate_fixture); FIXTURES+=("$G2")
git -C "$G2" rm -q src/foo.ts >/dev/null 2>&1
run_in "$G2" sh -e .husky/pre-commit
assert_false "[ $RC -eq 0 ]" "C5a: hook blocks the deletion-only commit"
assert_contains "$OUT" "FFF/WORLDCLASS GATE MISSING" "C5b: block names the missing gate artifact"

# C6 — a staged deletion of harness command prose must hard-block.
# Deterministic because test-module-context.sh is deliberately ABSENT from
# the fixture's index — the mirror-absent hard block fires before any
# canon-dependent TMC check can run. Do NOT "fix" the fixture by committing
# TMC into it: that couples this suite to the live state of
# ~/Projects/claude-dev-team.
G3=$(gate_fixture); FIXTURES+=("$G3")
git -C "$G3" rm -q .claude/commands/go.md >/dev/null 2>&1
run_in "$G3" sh -e .husky/pre-commit
assert_false "[ $RC -eq 0 ]" "C6a: hook blocks the harness-command deletion"
assert_contains "$OUT" "staged deletion of harness command" "C6b: block names the staged harness deletion"

echo ""
echo "Group 4: hook gate-script integrity (index execution)"

# C7 — GATE SCRIPT MISSING FROM INDEX must hard-block. Working-tree copy is
# left intact — proves the hook consults the INDEX, not the filesystem.
# (The fixture also lacks test-module-context.sh in its index, so the
# HARNESS STRUCTURAL GATE MISSING error co-occurs — harmless: the hook
# accumulates ERRORS and reports all of them at exit.)
G4=$(gate_fixture); FIXTURES+=("$G4")
git -C "$G4" rm -q --cached scripts/classify-diff-size.sh >/dev/null 2>&1
echo "// edit" >> "$G4/src/foo.ts"
git -C "$G4" add src/foo.ts >/dev/null 2>&1
run_in "$G4" sh -e .husky/pre-commit
assert_false "[ $RC -eq 0 ]" "C7a: hook blocks when classify is missing from the index"
assert_contains "$OUT" "GATE SCRIPT MISSING FROM INDEX" "C7b: block names the missing gate script"

# C8 — GATE SCRIPT CRASHED, proven from the INDEX: a broken classify is
# STAGED while the WORKING-TREE copy is restored to healthy. If the hook
# (wrongly) executed the working-tree copy, classification would succeed and
# no CRASHED block would fire — so this one fixture proves the crash block
# AND index-execution simultaneously.
G5=$(gate_fixture); FIXTURES+=("$G5")
printf '#!/usr/bin/env bash\necho "BOOM-STDERR" >&2\nexit 3\n' > "$G5/scripts/classify-diff-size.sh"
git -C "$G5" add scripts/classify-diff-size.sh >/dev/null 2>&1
cp "$SCRIPTS_DIR/classify-diff-size.sh" "$G5/scripts/classify-diff-size.sh"   # tree healthy; index still broken
echo "// edit" >> "$G5/src/foo.ts"
git -C "$G5" add src/foo.ts >/dev/null 2>&1
run_in "$G5" sh -e .husky/pre-commit
assert_false "[ $RC -eq 0 ]" "C8a: hook blocks when the STAGED classify crashes"
assert_contains "$OUT" "GATE SCRIPT CRASHED: scripts/classify-diff-size.sh" "C8b: block names the crashed script"
assert_contains "$OUT" "BOOM-STDERR" "C8c: the staged script's stderr is printed, not discarded"

# C8d — twin of C8 for the hasher: broken staged-diff-hash.sh is STAGED,
# working tree restored healthy. Staging a scripts/*.sh file makes the
# (healthy, index-run) classify say FULL, so the hook reaches the hasher.
# Catches a builder who wires stderr capture for classify but leaves the
# hasher's 2>/dev/null in place — B12.5 changes BOTH sites.
G5b=$(gate_fixture); FIXTURES+=("$G5b")
printf '#!/usr/bin/env bash\necho "HASH-STDERR" >&2\nexit 3\n' > "$G5b/scripts/staged-diff-hash.sh"
git -C "$G5b" add scripts/staged-diff-hash.sh >/dev/null 2>&1
cp "$SCRIPTS_DIR/staged-diff-hash.sh" "$G5b/scripts/staged-diff-hash.sh"   # tree healthy; index still broken
run_in "$G5b" sh -e .husky/pre-commit
assert_false "[ $RC -eq 0 ]" "C8d-a: hook blocks when the STAGED hasher crashes"
assert_contains "$OUT" "GATE SCRIPT CRASHED: scripts/staged-diff-hash.sh" "C8d-b: block names the crashed hasher"
assert_contains "$OUT" "HASH-STDERR" "C8d-c: the staged hasher's stderr is printed, not discarded"

# C9 — index-not-working-tree property: gutting the WORKING-TREE classifier
# (unstaged) must not weaken the gate for the very commit under review.
G6=$(gate_fixture); FIXTURES+=("$G6")
printf '#!/usr/bin/env bash\necho NONE\necho "gutted classifier"\n' > "$G6/scripts/classify-diff-size.sh"   # NOT staged
echo "// edit" >> "$G6/src/foo.ts"
git -C "$G6" add src/foo.ts >/dev/null 2>&1
run_in "$G6" sh -e .husky/pre-commit
assert_false "[ $RC -eq 0 ]" "C9a: gutted unstaged classifier does not weaken the gate"
assert_contains "$OUT" "FFF/WORLDCLASS GATE MISSING" "C9b: index copy classified the diff and demanded the artifact"

echo ""
echo "Group 5: rename evasion (--no-renames)"

# C10 — `git mv x.md x.txt` folds D+A into R100; --diff-filter=D without
# --no-renames sees nothing → classify NONE → FFF gate skipped. (Unlike the
# wave merge guard, classify has NO pathspec on its git diff — the rename
# destination is present, so the fold really happens here.) The deletion
# must surface and classify FULL.
G7=$(gate_fixture); FIXTURES+=("$G7")
git -C "$G7" mv .claude/commands/go.md .claude/commands/go.txt >/dev/null 2>&1
run_in "$G7" bash scripts/classify-diff-size.sh
assert_eq "$(echo "$OUT" | head -1)" "FULL" "C10: rename of harness prose classifies FULL (deletion surfaced)"

# C11 — hook end-to-end on the same rename: must hard-block, never exit 0.
run_in "$G7" sh -e .husky/pre-commit
assert_false "[ $RC -eq 0 ]" "C11a: hook blocks the harness-command rename"
assert_contains "$OUT" "staged deletion of harness command" "C11b: rename surfaces as the harness-deletion hard block"

echo ""
echo "RESULTS: $TESTS_PASS/$TESTS_RUN passed"
if [ "$FAIL" -eq 0 ]; then echo "PASS"; else echo "FAIL"; fi
exit $FAIL
