#!/usr/bin/env bash
# ===========================================
# TEST: scripts/wave-worktrees.sh
# ===========================================
# Behavioral tests for the worktree lifecycle script. Every group runs in a
# throwaway mktemp fixture repo — this suite NEVER touches the real repo, so
# it is safe to run at any time, from any checkout, mid-wave.
#
# The fixture mirrors the production hook layout exactly: tracked
# .husky/pre-commit, gitignored .husky/_ runtime dir, core.hooksPath=.husky/_.
# The fixture hook prints HOOK-FIRED and exits $HOOK_EXIT so tests can prove
# git actually EXECUTES hooks inside worktrees (G2) — not just that files
# exist.
#
# Suite stdout is results only — any setup command output is redirected.
# Every fixture is registered in FIXTURES and removed by the EXIT trap.
#
# Run: bash scripts/test-wave-worktrees.sh
# ===========================================
set -uo pipefail
FAIL=0; TESTS_RUN=0; TESTS_PASS=0

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wave-worktrees.sh"

# ── INCIDENT GUARD (2026-07-10) ──────────────────────────────────────────────
# On this suite's first-ever red run the script under test didn't exist, every
# TSV parse returned an empty string, and `git -C "" …` resolved to THE REPO
# THE SUITE WAS LAUNCHED FROM — it staged .autocode deletions and hard-reset a
# real worktree, destroying uncommitted work. Two permanent defenses:
#   1. The suite chdirs to a neutral mktemp dir, so any stray `git -C ""`
#      hits a non-repo and dies instead of the caller's checkout.
#   2. Every parsed worktree path goes through wt_or_absent(), so destructive
#      ops on a failed parse land on a nonexistent path inside the neutral
#      dir — never on the caller's filesystem.
NEUTRAL=$(mktemp -d)
cd "$NEUTRAL"
wt_or_absent() { if [ -n "${1:-}" ]; then echo "$1"; else echo "$NEUTRAL/absent-wt"; fi; }

# Every fixture registers here; the EXIT trap removes worktrees + dirs even
# when an assertion dies mid-suite.
FIXTURES=()
cleanup_all() {
  local d wt
  for d in ${FIXTURES[@]+"${FIXTURES[@]}"}; do
    git -C "$d" worktree list --porcelain 2>/dev/null | \
      awk '$1=="worktree"{print substr($0,10)}' | tail -n +2 | while IFS= read -r wt; do
        git -C "$d" worktree remove --force "$wt" >/dev/null 2>&1
      done
    rm -rf "$d"
  done
  rm -rf "$NEUTRAL"
}
trap cleanup_all EXIT

fixture_repo() {
  local d; d=$(mktemp -d)
  git -C "$d" init --quiet -b main
  git -C "$d" config user.email "test@wave.test"
  git -C "$d" config user.name "Wave Test"
  git -C "$d" config core.hooksPath .husky/_

  # Tracked hook (production layout) — sentinel + controllable exit code.
  mkdir -p "$d/.husky"
  printf '#!/bin/sh\necho HOOK-FIRED >&2\nexit "${HOOK_EXIT:-0}"\n' > "$d/.husky/pre-commit"
  chmod +x "$d/.husky/pre-commit"

  # Gitignored runtime dir (production: .husky/_/.gitignore contains "*").
  mkdir -p "$d/.husky/_"
  printf '*\n' > "$d/.husky/_/.gitignore"
  printf '#!/bin/sh\nsh -e "$(dirname "$0")/../pre-commit" "$@"\n' > "$d/.husky/_/pre-commit"
  chmod +x "$d/.husky/_/pre-commit"

  # Tracked product + module state files.
  mkdir -p "$d/apps/web/src" "$d/.autocode/modules/m1"
  echo "original content" > "$d/apps/web/src/route.ts"
  echo "# m1 tasks" > "$d/.autocode/modules/m1/tasks.md"
  echo "packages: []" > "$d/pnpm-workspace.yaml"

  # Untracked per-checkout config files (COPY_FILES in the script).
  mkdir -p "$d/apps/worker"
  echo "WEB_ENV=1" > "$d/apps/web/.env.local"
  echo "WORKER_ENV=1" > "$d/apps/worker/.env"
  printf '.env.local\n.env\n' > "$d/.gitignore"

  git -C "$d" add -A
  git -C "$d" commit -m "initial" --quiet 2>/dev/null   # fixture hook fires HOOK-FIRED
  echo "$d"
}

assert_eq() {
  TESTS_RUN=$((TESTS_RUN+1))
  if [ "$1" = "$2" ]; then
    echo "  ✓ $3"; TESTS_PASS=$((TESTS_PASS+1))
  else
    echo "  ✗ $3 — expected: '$2', got: '$1'"; FAIL=1
  fi
}
assert_true() {
  TESTS_RUN=$((TESTS_RUN+1))
  if eval "$1" 2>/dev/null; then
    echo "  ✓ $2"; TESTS_PASS=$((TESTS_PASS+1))
  else
    echo "  ✗ $2 — condition false: $1"; FAIL=1
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
assert_not_contains() {
  TESTS_RUN=$((TESTS_RUN+1))
  if ! echo "$1" | grep -q "$2"; then
    echo "  ✓ $3"; TESTS_PASS=$((TESTS_PASS+1))
  else
    echo "  ✗ $3 — output unexpectedly contains '$2'"; FAIL=1
  fi
}

# Runs the script inside a fixture: wwt <fixture-dir> <args...>
# stdout → $OUT, stderr → $ERR (refusal reasons live there), exit code → $RC.
wwt() {
  local d="$1"; shift
  local ef="$NEUTRAL/stderr.last"
  OUT=$( (cd "$d" && WAVE_WT_NO_INSTALL=1 bash "$SCRIPT" "$@") 2>"$ef" )
  RC=$?
  ERR=$(cat "$ef" 2>/dev/null)
}

echo "=== wave-worktrees.sh Behavioral Tests ==="

# ─── GROUP 1: create — layout, TSV format, guards ────────────────────────────
echo ""
echo "Group 1: create + output format"
F1=$(fixture_repo); FIXTURES+=("$F1")
wwt "$F1" create m1 1 alice:W1A bob:W1B
CREATE_OUT="$OUT"; CREATE_RC=$RC

# T1 — create succeeds
assert_eq "$CREATE_RC" "0" "T1: create exits 0"

# T2 — machine output: exactly 2 WAVE_WT lines, each exactly 4 tab-separated fields
TSV_LINES=$(echo "$CREATE_OUT" | grep -c '^WAVE_WT	' || true)
assert_eq "$TSV_LINES" "2" "T2a: exactly 2 WAVE_WT TSV lines on stdout"
BAD_FIELDS=$(echo "$CREATE_OUT" | grep '^WAVE_WT	' | awk -F'\t' 'NF != 4' | wc -l | tr -d ' ')
assert_eq "$BAD_FIELDS" "0" "T2b: every WAVE_WT line has exactly 4 tab-separated fields"

WT_A=$(wt_or_absent "$(echo "$CREATE_OUT" | grep '^WAVE_WT	alice	' | cut -f3)")
BR_A=$(echo "$CREATE_OUT" | grep '^WAVE_WT	alice	' | cut -f4)
WT_B=$(wt_or_absent "$(echo "$CREATE_OUT" | grep '^WAVE_WT	bob	' | cut -f3)")

# T3 — worktree + branch exist; branch tip == main tip
assert_true "[ -d '$WT_A' ] && [ -d '$WT_B' ]" "T3a: both worktree dirs exist"
assert_eq "$BR_A" "advance/m1-w1-alice" "T3b: branch follows advance/<module>-w<N>-<name>"
assert_eq "$(git -C "$F1" rev-parse "$BR_A" 2>/dev/null)" "$(git -C "$F1" rev-parse main)" \
  "T3c: stream branch tip equals main tip"

# T4 — untracked env files copied into the worktree
assert_true "[ -f '$WT_A/apps/web/.env.local' ] && [ -f '$WT_A/apps/worker/.env' ]" \
  "T4: env files copied into worktree"

# T5 — .autocode is a symlink resolving to the main repo's .autocode
# (compare physical paths — on macOS mktemp returns /var/… while git
# canonicalizes to /private/var/…)
assert_true "[ -L '$WT_A/.autocode' ]" "T5a: .autocode is a symlink"
assert_eq "$(cd "$(readlink "$WT_A/.autocode")" && pwd -P)" "$(cd "$F1/.autocode" && pwd -P)" \
  "T5b: symlink targets main repo .autocode"

# T6 — index guard: no tracked .autocode path may surface as modified/deleted
# (the untracked "?? .autocode" symlink entry itself is expected and harmless)
assert_eq "$(git -C "$WT_A" status --porcelain -- .autocode | grep -v '^??')" "" \
  "T6: tracked .autocode paths invisible to git status (skip-worktree guard)"

# T7 — per-checkout module marker written into the worktree's private git dir
MARKER_A="$(git -C "$WT_A" rev-parse --absolute-git-dir)/active-module"
assert_eq "$(cat "$MARKER_A" 2>/dev/null)" "m1" "T7: module marker in worktree git dir"

# T8 — wave-state round-trips: worktree path + branch recorded exactly
WS_WT=$(python3 -c "import json;print(json.load(open('$F1/.autocode/modules/m1/.wave-state.json'))['streams']['W1A']['worktree'])" 2>/dev/null)
WS_BR=$(python3 -c "import json;print(json.load(open('$F1/.autocode/modules/m1/.wave-state.json'))['streams']['W1A']['branch'])" 2>/dev/null)
assert_eq "$WS_WT" "$WT_A" "T8a: wave-state records exact worktree path"
assert_eq "$WS_BR" "$BR_A" "T8b: wave-state records exact branch"

# T9 — stale refusal: re-running create with same args must fail loudly
wwt "$F1" create m1 1 alice:W1A bob:W1B
assert_false "[ $RC -eq 0 ]" "T9: re-create with same args refuses (stale wave)"
# T9b — message-quality assertion only: both the per-path guard and the
# state-file guard say "already exists", so this does NOT pin the new
# pre-flight. G1-state-refuse below is the pinning test.
assert_contains "$ERR" "already exists" "T9b: refusal names what already exists"

# T10 — .claude/worktrees never appears in main repo status (info/exclude ensured)
assert_not_contains "$(git -C "$F1" status --porcelain)" ".claude/worktrees" \
  "T10: worktree root excluded from main repo status"

# ─── GROUP 2: hooks actually FIRE inside the worktree ────────────────────────
echo ""
echo "Group 2: hook arming (git must execute the hook)"

# T11 — a failing hook BLOCKS a commit in the worktree, and we see the sentinel
echo "edit" > "$WT_A/apps/web/src/route.ts"
git -C "$WT_A" add apps/web/src/route.ts >/dev/null 2>&1
COMMIT_ERR=$(HOOK_EXIT=1 git -C "$WT_A" commit -m "blocked" 2>&1); COMMIT_RC=$?
assert_false "[ $COMMIT_RC -eq 0 ]" "T11a: commit blocked when hook exits 1"
assert_contains "$COMMIT_ERR" "HOOK-FIRED" "T11b: hook actually executed (sentinel on stderr)"

# T12 — a passing hook lets the commit through
COMMIT_ERR=$(HOOK_EXIT=0 git -C "$WT_A" commit -m "allowed" 2>&1); COMMIT_RC=$?
assert_eq "$COMMIT_RC" "0" "T12a: commit succeeds when hook exits 0"
assert_contains "$COMMIT_ERR" "HOOK-FIRED" "T12b: hook executed on the passing commit too"

# T13 — THE FAILURE MODE THIS SCRIPT EXISTS TO PREVENT: without .husky/_,
# git SILENTLY runs zero hooks. Documented here so it can never be forgotten.
rm -rf "$WT_B/.husky/_"
echo "edit" > "$WT_B/apps/web/src/route.ts"
git -C "$WT_B" add apps/web/src/route.ts >/dev/null 2>&1
COMMIT_ERR=$(HOOK_EXIT=1 git -C "$WT_B" commit -m "silent" 2>&1); COMMIT_RC=$?
assert_eq "$COMMIT_RC" "0" "T13a: with .husky/_ missing, a HOOK_EXIT=1 commit SUCCEEDS (silent skip)"
assert_not_contains "$COMMIT_ERR" "HOOK-FIRED" "T13b: hook never executed (no sentinel)"

# ─── GROUP 3: verify — failure modes ─────────────────────────────────────────
echo ""
echo "Group 3: verify failure modes"

# T14 — a freshly created worktree passes verify (node_modules stubbed:
# WAVE_WT_NO_INSTALL skips pnpm install, so the test provides the marker dir)
mkdir -p "$WT_B/node_modules/.pnpm"
mkdir -p "$WT_A/node_modules/.pnpm"
cp -R "$F1/.husky/_" "$WT_B/.husky/_"   # restore what T13 destroyed
wwt "$F1" verify wt "$WT_A"
assert_eq "$RC" "0" "T14a: verify wt passes on healthy worktree"
assert_contains "$OUT" "VERIFY PASS" "T14b: summary line says VERIFY PASS"

# T15 — hooks missing → ✗ + exit 1
rm -rf "$WT_A/.husky/_"
wwt "$F1" verify wt "$WT_A"
assert_false "[ $RC -eq 0 ]" "T15a: verify fails when .husky/_ missing"
assert_contains "$OUT" "✗ hooks armed" "T15b: names the hooks check"
cp -R "$F1/.husky/_" "$WT_A/.husky/_"

# T16 — broken .autocode symlink → ✗ + exit 1
ln -sfn /nonexistent "$WT_A/.autocode"
wwt "$F1" verify wt "$WT_A"
assert_false "[ $RC -eq 0 ]" "T16a: verify fails on broken .autocode symlink"
assert_contains "$OUT" "✗ .autocode symlink" "T16b: names the symlink check"
ln -sfn "$F1/.autocode" "$WT_A/.autocode"

# T17 — node_modules missing → ✗ + exit 1
rm -rf "$WT_A/node_modules"
wwt "$F1" verify wt "$WT_A"
assert_false "[ $RC -eq 0 ]" "T17a: verify fails without node_modules"
assert_contains "$OUT" "✗ node_modules" "T17b: names the node_modules check"
mkdir -p "$WT_A/node_modules/.pnpm"

# T18 — verify wave aggregates: one broken stream of two → FAIL + PASS both printed, exit 1
rm -rf "$WT_B/.husky/_"
wwt "$F1" verify wave m1 1
assert_false "[ $RC -eq 0 ]" "T18a: verify wave exits 1 when any stream fails"
assert_contains "$OUT" "VERIFY PASS alice" "T18b: healthy stream reports PASS"
assert_contains "$OUT" "VERIFY FAIL bob" "T18c: broken stream reports FAIL"
cp -R "$F1/.husky/_" "$WT_B/.husky/_"

# ─── GROUP 4: merge — guards + conflict abort ────────────────────────────────
echo ""
echo "Group 4: merge"

# T21 — staged-index guard: merge refuses while main's index holds staged work
echo "staged" > "$F1/staged-file.txt"
git -C "$F1" add staged-file.txt >/dev/null 2>&1
wwt "$F1" merge m1 1
assert_false "[ $RC -eq 0 ]" "T21: merge refuses while main index has staged changes"
assert_contains "$ERR" "staged changes" "T21b: refusal names the staged changes"
git -C "$F1" restore --staged staged-file.txt >/dev/null 2>&1 || git -C "$F1" reset --quiet staged-file.txt >/dev/null 2>&1
rm -f "$F1/staged-file.txt"

# T22 — .autocode deletion guard: a stream branch carrying .autocode deletions
# must be refused (this is the 85-tracked-deletions hazard)
git -C "$WT_B" update-index --no-skip-worktree .autocode/modules/m1/tasks.md >/dev/null 2>&1
git -C "$WT_B" rm -r -q --cached .autocode >/dev/null 2>&1
HOOK_EXIT=0 git -C "$WT_B" commit -q -m "bad: deletes .autocode" >/dev/null 2>&1
wwt "$F1" merge m1 1
assert_false "[ $RC -eq 0 ]" "T22a: merge refuses a branch that deletes tracked .autocode files"
assert_contains "$ERR" "deletes tracked .autocode" "T22c: refusal names the .autocode deletion"
assert_true "[ -f '$F1/.autocode/modules/m1/tasks.md' ]" "T22b: tracked .autocode file still on main"
# undo the poison commit so later merge tests can proceed
git -C "$WT_B" reset --hard -q HEAD~1 >/dev/null 2>&1
git -C "$WT_B" update-index --skip-worktree .autocode/modules/m1/tasks.md >/dev/null 2>&1

# T19 — clean merge lands stream content on main
wwt "$F1" merge m1 1
assert_eq "$RC" "0" "T19a: clean merge exits 0"
assert_eq "$(cat "$F1/apps/web/src/route.ts")" "edit" "T19b: stream content landed on main"

# T20 — conflict: aborted, main left clean (fresh fixture; both sides edit same file)
F2=$(fixture_repo); FIXTURES+=("$F2")
wwt "$F2" create m2 1 carol:W1A
WT_C=$(wt_or_absent "$(echo "$OUT" | grep '^WAVE_WT	carol	' | cut -f3)")
echo "stream edit" > "$WT_C/apps/web/src/route.ts"
git -C "$WT_C" add apps/web/src/route.ts >/dev/null 2>&1
HOOK_EXIT=0 git -C "$WT_C" commit -q -m "stream side" >/dev/null 2>&1
echo "main edit" > "$F2/apps/web/src/route.ts"
git -C "$F2" add apps/web/src/route.ts >/dev/null 2>&1
HOOK_EXIT=0 git -C "$F2" commit -q -m "main side" >/dev/null 2>&1
wwt "$F2" merge m2 1
assert_false "[ $RC -eq 0 ]" "T20a: conflicting merge exits non-zero"
assert_false "git -C '$F2' rev-parse -q --verify MERGE_HEAD >/dev/null" "T20b: merge was aborted (no MERGE_HEAD)"
assert_eq "$(cat "$F2/apps/web/src/route.ts")" "main edit" "T20c: main content untouched after abort"
assert_contains "$ERR" "CONFLICT" "T20d: a real content conflict is labeled CONFLICT"

# ─── GROUP 5: cleanup — refuse-if-work-lost ──────────────────────────────────
echo ""
echo "Group 5: cleanup refusals"

# T24 — unmerged branch → cleanup refuses BEFORE touching anything
wwt "$F2" cleanup m2 1
assert_false "[ $RC -eq 0 ]" "T24a: cleanup refuses while stream branch is unmerged"
assert_contains "$ERR" "unmerged work" "T24d: refusal names the unmerged work"
assert_true "[ -d '$WT_C' ]" "T24b: worktree still exists after refusal"
assert_true "git -C '$F2' rev-parse -q --verify advance/m2-w1-carol >/dev/null" "T24c: branch still exists"

# T23 — uncommitted work in worktree → cleanup refuses
# (-X theirs: T20 engineered a content conflict on this branch; resolve it
#  deliberately so the branch becomes merged and T24/T25 test what they claim)
git -C "$F2" merge --no-ff -q -X theirs -m "manual merge for T23" advance/m2-w1-carol >/dev/null 2>&1 \
  || echo "  (T23 setup: manual merge unexpectedly failed)"
echo "uncommitted" > "$WT_C/apps/web/src/new-file.ts"
wwt "$F2" cleanup m2 1
assert_false "[ $RC -eq 0 ]" "T23a: cleanup refuses on uncommitted worktree changes"
assert_contains "$ERR" "uncommitted work" "T23c: refusal names the uncommitted work"
assert_true "[ -d '$WT_C' ]" "T23b: worktree preserved"
rm -f "$WT_C/apps/web/src/new-file.ts"

# T25 — after merge + clean tree → cleanup removes everything
wwt "$F2" cleanup m2 1
assert_eq "$RC" "0" "T25a: cleanup succeeds after merge"
assert_false "[ -d '$WT_C' ]" "T25b: worktree removed"
assert_false "git -C '$F2' rev-parse -q --verify advance/m2-w1-carol >/dev/null" "T25c: branch deleted"
assert_false "[ -f '$F2/.autocode/modules/m2/.wave-state.json' ]" "T25d: wave-state deleted"

# ─── GROUP 6: per-checkout active-module ─────────────────────────────────────
echo ""
echo "Group 6: per-checkout module markers"
F3=$(fixture_repo); FIXTURES+=("$F3")
wwt "$F3" create m1 2 dave:W2A
WT_D=$(wt_or_absent "$(echo "$OUT" | grep '^WAVE_WT	dave	' | cut -f3)")

# T26 — the core last-writer-wins fix: two checkouts, two independent modules
wwt "$F3" set-module alpha
( cd "$WT_D" && WAVE_WT_NO_INSTALL=1 bash "$SCRIPT" set-module beta ) >/dev/null 2>&1
wwt "$F3" get-module
MAIN_MOD="$OUT"
WT_MOD=$( (cd "$WT_D" && bash "$SCRIPT" get-module) 2>/dev/null )
assert_eq "$MAIN_MOD" "alpha" "T26a: main checkout resolves its own module"
assert_eq "$WT_MOD" "beta" "T26b: worktree resolves its own module (no clobber)"

# T27 — legacy fallback: no marker → .autocode/modules/.active-module wins
rm -f "$F3/.git/active-module"
echo "legacy-mod" > "$F3/.autocode/modules/.active-module"
wwt "$F3" get-module
assert_eq "$OUT" "legacy-mod" "T27: legacy .active-module fallback still resolves"

# T28 — marker takes precedence over legacy
wwt "$F3" set-module fresh-mod
wwt "$F3" get-module
assert_eq "$OUT" "fresh-mod" "T28: per-checkout marker beats legacy file"

# ─── GROUP 7: single — module-window worktree, idempotent ────────────────────
echo ""
echo "Group 7: single (module windows)"
F4=$(fixture_repo); FIXTURES+=("$F4")
wwt "$F4" single cms
SINGLE_RC=$RC; SINGLE_OUT="$OUT"
WT_S=$(wt_or_absent "$(echo "$SINGLE_OUT" | grep '^WAVE_WT	cms	' | cut -f3)")

# T29 — creates the module worktree on <module>-window with marker
assert_eq "$SINGLE_RC" "0" "T29a: single exits 0"
assert_true "[ -d '$WT_S' ]" "T29b: module worktree exists"
assert_eq "$(git -C "$WT_S" rev-parse --abbrev-ref HEAD 2>/dev/null)" "cms-window" \
  "T29c: module worktree on <module>-window branch"
assert_eq "$(cat "$(git -C "$WT_S" rev-parse --absolute-git-dir)/active-module" 2>/dev/null)" "cms" \
  "T29d: module marker written"

# T30 — idempotent re-run: exit 0, and a deleted .autocode symlink is re-created
rm -f "$WT_S/.autocode"
wwt "$F4" single cms
assert_eq "$RC" "0" "T30a: second single run exits 0 (idempotent)"
assert_true "[ -L '$WT_S/.autocode' ]" "T30b: re-provision restored the .autocode symlink"

# ─── GROUP 8: atomic create, journaling, stale registrations (Phase S) ───────
echo ""
echo "Group 8: atomic create, journaling, stale registrations"

# T-warn — REGRESSION PIN (green from day one): the dirty-main WARN already
# exists at create time; this test exists so the warn can never be silently
# dropped. Not counted as Phase-S red coverage.
FW=$(fixture_repo); FIXTURES+=("$FW")
echo "dirty" >> "$FW/apps/web/src/route.ts"
wwt "$FW" create m2 1 solo:W1A
assert_contains "$ERR" "will NOT appear in the worktrees" \
  "T-warn: dirty tracked main prints the not-in-worktrees WARN"

# G1-atomic — a mid-create failure must leave a recoverable journal.
# Injection: a ref D/F collision (advance/m1-w9-bob/blocker) is invisible to
# the exact-name pre-flight rev-parse, so bob's `git branch` fails (RC=128)
# AFTER alice is fully created and bob is journaled.
F5=$(fixture_repo); FIXTURES+=("$F5")
git -C "$F5" branch advance/m1-w9-bob/blocker >/dev/null 2>&1
wwt "$F5" create m1 9 alice:W1A bob:W1B
G1_STATE="$F5/.autocode/modules/m1/.wave-state.json"
WT_A5=$(wt_or_absent "$(echo "$OUT" | grep '^WAVE_WT	alice	' | cut -f3)")
assert_false "[ $RC -eq 0 ]" "G1-atomic-a: create fails when a stream branch cannot be created"
assert_true "[ -f '$G1_STATE' ]" "G1-atomic-b: wave-state journal exists after the partial failure"
assert_eq "$(python3 -c "import json;print(json.load(open('$G1_STATE'))['wave'])" 2>/dev/null)" "9" \
  "G1-atomic-c: journal top-level wave field is 9 (full envelope, not bare streams)"
assert_true "python3 -c \"import json,sys;d=json.load(open('$G1_STATE'));sys.exit(0 if 'W1A' in d['streams'] and 'W1B' in d['streams'] else 1)\"" \
  "G1-atomic-d: journal records BOTH alice and bob (journal-first order)"
assert_contains "$ERR" "cleanup m1 9" "G1-atomic-e: failure names the exact recovery command"
assert_true "[ -d '$WT_A5' ]" "G1-atomic-f: alice's worktree exists (created before the failure)"
assert_false "git -C '$F5' rev-parse -q --verify refs/heads/advance/m1-w9-bob >/dev/null" \
  "G1-atomic-g: bob's branch was never created"
wwt "$F5" cleanup m1 9
assert_eq "$RC" "0" "G1-atomic-h: advertised recovery (cleanup m1 9) succeeds"
assert_false "[ -d '$WT_A5' ]" "G1-atomic-i: alice's worktree removed by recovery"
assert_false "git -C '$F5' rev-parse -q --verify refs/heads/advance/m1-w9-alice >/dev/null" \
  "G1-atomic-j: alice's branch removed by recovery"
assert_false "[ -f '$G1_STATE' ]" "G1-atomic-k: journal removed by recovery"
git -C "$F5" branch -D advance/m1-w9-bob/blocker >/dev/null 2>&1
wwt "$F5" create m1 9 alice:W1A bob:W1B
assert_eq "$RC" "0" "G1-atomic-l: re-create succeeds after recovery + blocker removal"

# G1-stale-reg — a crash-orphaned registration (rm -rf'd, never pruned) must
# be refused at pre-flight, before ANY artifact is created.
F6=$(fixture_repo); FIXTURES+=("$F6")
wwt "$F6" create m1 3 eve:W3A
WT_E=$(wt_or_absent "$(echo "$OUT" | grep '^WAVE_WT	eve	' | cut -f3)")
rm -rf "$WT_E"                                            # registration now stale
# branch -D refuses while the stale registration claims the branch is checked
# out — the crash simulation must delete the ref directly.
git -C "$F6" update-ref -d refs/heads/advance/m1-w3-eve >/dev/null 2>&1
rm -f "$F6/.autocode/modules/m1/.wave-state.json"
wwt "$F6" create m1 3 eve:W3A
assert_false "[ $RC -eq 0 ]" "G1-stale-reg-a: create refuses on a stale worktree registration"
assert_contains "$ERR" "stale worktree registration" "G1-stale-reg-b: refusal names the stale registration"
assert_contains "$ERR" "worktree prune" "G1-stale-reg-c: refusal names the prune recovery"
assert_false "git -C '$F6' rev-parse -q --verify refs/heads/advance/m1-w3-eve >/dev/null" \
  "G1-stale-reg-d: pre-flight refusal created no branch"
assert_false "[ -f '$F6/.autocode/modules/m1/.wave-state.json' ]" \
  "G1-stale-reg-e: pre-flight refusal created no state file"

# G1-dup — duplicate stream ids must be refused at pre-flight (last-writer-
# wins in the streams dict silently loses a stream's journal entry).
wwt "$F6" create m1 1 alice:W1A bob:W1A
assert_false "[ $RC -eq 0 ]" "G1-dup-a: duplicate SIDs refused"
assert_contains "$ERR" "duplicate stream id" "G1-dup-b: refusal names the duplicate stream id"
assert_eq "$(git -C "$F6" branch --list 'advance/m1-w1-*' | wc -l | tr -d ' ')" "0" \
  "G1-dup-c: no stream branches created"
assert_false "[ -f '$F6/.autocode/modules/m1/.wave-state.json' ]" "G1-dup-d: no state file created"

# G1-state-refuse — a second wave's paths and branches are all fresh, so ONLY
# the state-file guard can fire here: this pins the S-2 pre-flight.
wwt "$F6" create m1 1 alice:W1A bob:W1B
assert_eq "$RC" "0" "G1-state-refuse-a: fresh wave-1 create succeeds"
STATE_SUM_BEFORE=$(shasum -a 256 "$F6/.autocode/modules/m1/.wave-state.json" 2>/dev/null | cut -d' ' -f1)
wwt "$F6" create m1 2 carl:W2A
assert_false "[ $RC -eq 0 ]" "G1-state-refuse-b: second wave refused while wave-1 state exists"
assert_contains "$ERR" "already exists" "G1-state-refuse-c: refusal says the state already exists"
assert_contains "$ERR" "cleanup m1 1" "G1-state-refuse-d: refusal names the recorded-wave recovery"
assert_eq "$(shasum -a 256 "$F6/.autocode/modules/m1/.wave-state.json" 2>/dev/null | cut -d' ' -f1)" \
  "$STATE_SUM_BEFORE" "G1-state-refuse-e: wave-1 state file byte-identical after the refusal"

# G1-charset — stream names/ids feed branch names, paths, and space-delimited
# dup-checks; reject unsafe charsets at pre-flight. NOTE: the per-stream
# pre-flight loop runs BEFORE the state-file guard in cmd_create. PRE-FIX the
# create ALREADY exits non-zero — for the wrong reason (the state-file guard,
# since F6 holds wave-1 state) — so G1-charset-a is GREEN pre-fix and only
# G1-charset-b (the refusal naming the invalid stream name) is the red pin.
# POST-FIX, -b passing also pins the ordering: the charset guard fires inside
# pre-flight, before the state-file guard.
wwt "$F6" create m1 4 "bad name:W4A"
assert_false "[ $RC -eq 0 ]" "G1-charset-a: stream name with a space is refused"
assert_contains "$ERR" "invalid stream name" "G1-charset-b: refusal names the invalid stream name"

# G1-colon — a multi-colon spec must be rejected, not silently split (the
# %%/## expansions would drop the middle segment: "alice:junk:W4A" → alice/W4A).
wwt "$F6" create m1 4 "alice:junk:W4A"
assert_false "[ $RC -eq 0 ]" "G1-colon-a: multi-colon stream spec is refused"
assert_contains "$ERR" "exactly one colon" "G1-colon-b: refusal names the colon rule"

# ─── GROUP 9: merge honesty — two-pass + diagnosis (Phase S) ─────────────────
echo ""
echo "Group 9: merge honesty (two-pass + diagnosis)"

# G4-two-pass — ALL guards must run before ANY merge: a wave lands whole or
# not at all. Poisoning stream B must leave stream A's clean branch unmerged.
F7=$(fixture_repo); FIXTURES+=("$F7")
wwt "$F7" create m1 1 alice:W1A bob:W1B
WT_A7=$(wt_or_absent "$(echo "$OUT" | grep '^WAVE_WT	alice	' | cut -f3)")
WT_B7=$(wt_or_absent "$(echo "$OUT" | grep '^WAVE_WT	bob	' | cut -f3)")
echo "alice edit" > "$WT_A7/apps/web/src/route.ts"
git -C "$WT_A7" add apps/web/src/route.ts >/dev/null 2>&1
HOOK_EXIT=0 git -C "$WT_A7" commit -q -m "alice side" >/dev/null 2>&1
git -C "$WT_B7" update-index --no-skip-worktree .autocode/modules/m1/tasks.md >/dev/null 2>&1
git -C "$WT_B7" rm -r -q --cached .autocode >/dev/null 2>&1
HOOK_EXIT=0 git -C "$WT_B7" commit -q -m "bad: deletes .autocode" >/dev/null 2>&1
wwt "$F7" merge m1 1
assert_false "[ $RC -eq 0 ]" "G4-two-pass-a: merge refuses the wave when ANY stream is poisoned"
assert_false "git -C '$F7' merge-base --is-ancestor advance/m1-w1-alice main" \
  "G4-two-pass-b: alice's clean branch was NOT merged (guards run before ANY merge)"

# G4-misdiagnosis — an untracked file in main clashing with a stream's added
# path is NOT a content conflict and must not be labeled as one.
F8=$(fixture_repo); FIXTURES+=("$F8")
wwt "$F8" create m1 1 mia:W1A
WT_M8=$(wt_or_absent "$(echo "$OUT" | grep '^WAVE_WT	mia	' | cut -f3)")
echo "stream file" > "$WT_M8/apps/web/src/clash.ts"
git -C "$WT_M8" add apps/web/src/clash.ts >/dev/null 2>&1
HOOK_EXIT=0 git -C "$WT_M8" commit -q -m "adds clash.ts" >/dev/null 2>&1
echo "untracked in main" > "$F8/apps/web/src/clash.ts"    # untracked, never staged
wwt "$F8" merge m1 1
assert_false "[ $RC -eq 0 ]" "G4-misdiagnosis-a: merge fails on the untracked-file clash"
assert_not_contains "$ERR" "CONFLICT" "G4-misdiagnosis-b: failure is NOT labeled CONFLICT"
assert_contains "$ERR" "NOT a content conflict" "G4-misdiagnosis-c: failure names the honest diagnosis"

# ─── GROUP 10: get-module scoping (Phase S) ──────────────────────────────────
echo ""
echo "Group 10: get-module scoping"

# G6-legacy — the legacy shared marker resolves ONLY in the main checkout; a
# worktree reading it through the .autocode symlink would resurrect the
# last-writer-wins clobbering the per-checkout marker replaced.
# (script-created worktrees always have the marker — delete it first)
rm -f "$(git -C "$WT_M8" rev-parse --absolute-git-dir)/active-module"
echo "legacy-mod" > "$F8/.autocode/modules/.active-module"
wwt "$WT_M8" get-module
assert_eq "$OUT" "" "G6-legacy: worktree with no marker prints nothing (legacy file is main-only)"

# ─── GROUP 11: single — namespace, legacy reuse, stale registration ──────────
echo ""
echo "Group 11: single — harness namespace, legacy reuse, stale registrations"

# G7-collision — a plain non-git dir at the module's OLD path (this collision
# exists live: a foreign agent worktree shares .claude/worktrees/ today) must
# not break creation: new module worktrees live under harness/.
F9=$(fixture_repo); FIXTURES+=("$F9")
mkdir -p "$F9/.claude/worktrees/cms"
wwt "$F9" single cms
assert_eq "$RC" "0" "G7-collision-a: single succeeds despite a foreign dir at the old path"
assert_contains "$OUT" ".claude/worktrees/harness/" "G7-collision-b: TSV path is under the harness/ namespace"

# G7-behind — reusing a module worktree whose branch is behind main must warn
# with the exact catch-up command.
echo "newer" >> "$F9/apps/web/src/route.ts"
git -C "$F9" add apps/web/src/route.ts >/dev/null 2>&1
HOOK_EXIT=0 git -C "$F9" commit -q -m "main moves on" >/dev/null 2>&1
wwt "$F9" single cms
assert_eq "$RC" "0" "G7-behind-a: reuse still succeeds"
assert_contains "$ERR" "behind main" "G7-behind-b: reuse warns the branch is behind main"
assert_contains "$ERR" "merge main" "G7-behind-c: warn names the exact catch-up command"

# G7-legacy-path — a pre-namespace worktree (the live cms layout) is reused
# IN PLACE via branch-resolution; creating a second worktree would hit git's
# "already checked out" fatal.
F10=$(fixture_repo); FIXTURES+=("$F10")
git -C "$F10" branch cms-window main >/dev/null 2>&1
git -C "$F10" worktree add "$F10/.claude/worktrees/cms" cms-window >/dev/null 2>&1
wwt "$F10" single cms
WT_L=$(wt_or_absent "$(echo "$OUT" | grep '^WAVE_WT	cms	' | cut -f3)")
assert_eq "$RC" "0" "G7-legacy-path-a: single reuses the legacy-location worktree"
assert_eq "$(cd "$WT_L" 2>/dev/null && pwd -P)" "$(cd "$F10/.claude/worktrees/cms" && pwd -P)" \
  "G7-legacy-path-b: TSV path IS the existing old-root worktree (reuse in place)"
assert_not_contains "$OUT" "/harness/" "G7-legacy-path-c: no second worktree under harness/"
assert_contains "$ERR" "legacy location" "G7-legacy-path-d: reuse notes the legacy location"
mkdir -p "$WT_L/node_modules/.pnpm"
wwt "$F10" verify module cms
assert_eq "$RC" "0" "G7-legacy-path-e: verify module resolves the same legacy path and passes"

# G7-stale-reg — branch-resolution must refuse a crash-orphaned registration
# (git worktree list still reports rm-rf'd worktrees until pruned), never
# reuse a path with no directory behind it.
F11=$(fixture_repo); FIXTURES+=("$F11")
wwt "$F11" single ops
WT_O=$(wt_or_absent "$(echo "$OUT" | grep '^WAVE_WT	ops	' | cut -f3)")
rm -rf "$WT_O"                                # crash: directory gone, registration stale
wwt "$F11" single ops
assert_false "[ $RC -eq 0 ]" "G7-stale-reg-a: single refuses the stale registration"
assert_contains "$ERR" "stale worktree registration" "G7-stale-reg-b: refusal names the stale registration"
assert_contains "$ERR" "worktree prune" "G7-stale-reg-c: refusal names the prune recovery"
assert_false "[ -e '$WT_O' ]" "G7-stale-reg-d: refusal created nothing"
git -C "$F11" worktree prune >/dev/null 2>&1
wwt "$F11" single ops
WT_O=$(wt_or_absent "$(echo "$OUT" | grep '^WAVE_WT	ops	' | cut -f3)")
assert_eq "$RC" "0" "G7-stale-reg-e: after prune, single creates a fresh worktree"
assert_contains "$OUT" ".claude/worktrees/harness/" "G7-stale-reg-f: fresh worktree is under harness/"

# ─── GROUP 12: provision subcommand (Phase S) ────────────────────────────────
echo ""
echo "Group 12: provision subcommand"

# G8-provision — repairs a broken worktree from ANY CWD (including inside the
# worktree itself). Physical-path equality catches an implementation deriving
# the main root from CWD's toplevel instead of the git common dir.
mkdir -p "$WT_O/node_modules/.pnpm"
rm -f "$WT_O/.autocode"          # symlink only — break the shared-state link
rm -rf "$WT_O/.husky/_"          # break hook arming
wwt "$WT_O" provision "$WT_O"
assert_eq "$RC" "0" "G8-provision-a: provision succeeds from inside the worktree"
assert_true "[ -L '$WT_O/.autocode' ]" "G8-provision-b: .autocode symlink restored"
assert_eq "$(cd "$(readlink "$WT_O/.autocode")" 2>/dev/null && pwd -P)" "$(cd "$F11/.autocode" && pwd -P)" \
  "G8-provision-c: symlink resolves to the MAIN checkout's .autocode (physical path)"
wwt "$F11" verify wt "$WT_O"
assert_eq "$RC" "0" "G8-provision-d: verify wt passes after provision"

# G8-provision-e — the BARE `verify` form is the exact invocation go.md Step 4
# makes every worker paste (self-dispatch: TOPLEVEL resolved from inside the
# worktree). Pin it, not just the wt/module/wave forms.
wwt "$WT_O" verify
assert_eq "$RC" "0" "G8-provision-e: bare verify (worker's pasted form) passes from inside the worktree"
assert_contains "$OUT" "VERIFY PASS" "G8-provision-f: bare verify prints the PASS summary line"

# ─── GROUP 13: any-checkout lifecycle (Phase S) ──────────────────────────────
echo ""
echo "Group 13: any-checkout lifecycle"

F12=$(fixture_repo); FIXTURES+=("$F12")
wwt "$F12" single ops
WT_P12=$(wt_or_absent "$(echo "$OUT" | grep '^WAVE_WT	ops	' | cut -f3)")
wwt "$F12" create m1 1 alice:W1A
WT_A12=$(wt_or_absent "$(echo "$OUT" | grep '^WAVE_WT	alice	' | cut -f3)")
echo "g9 stream" > "$WT_A12/apps/web/src/g9.ts"
git -C "$WT_A12" add apps/web/src/g9.ts >/dev/null 2>&1
HOOK_EXIT=0 git -C "$WT_A12" commit -q -m "g9 stream side" >/dev/null 2>&1

# G9a — the honest use case: Max's module window drives the wave lifecycle;
# merge/cleanup operate on the MAIN checkout regardless of CWD.
wwt "$WT_P12" merge m1 1
assert_eq "$RC" "0" "G9a-1: merge succeeds with CWD inside a module worktree"
assert_eq "$(cat "$F12/apps/web/src/g9.ts" 2>/dev/null)" "g9 stream" \
  "G9a-2: stream content landed on the MAIN checkout"
# Re-running merge must be idempotent — advance.md's conflict-recovery flow
# ("the script skips already-merged branches, so re-running merges only the
# rest") is load-bearing prose; this pins the skip it depends on.
wwt "$WT_P12" merge m1 1
assert_eq "$RC" "0" "G9a-2b: re-run merge is idempotent"
assert_contains "$ERR" "already merged" "G9a-2c: re-run skips already-merged branches"
wwt "$WT_P12" cleanup m1 1
assert_eq "$RC" "0" "G9a-3: cleanup succeeds with CWD inside a module worktree"
assert_false "[ -d '$WT_A12' ]" "G9a-4: stream worktree removed"

# G9b — the CWD guard: git worktree remove succeeds with CWD inside the
# target (verified empirically), so cleanup must refuse to delete the
# directory under its own feet.
wwt "$F12" create m1 2 zed:W2A
WT_Z12=$(wt_or_absent "$(echo "$OUT" | grep '^WAVE_WT	zed	' | cut -f3)")
wwt "$WT_Z12" cleanup m1 2
assert_false "[ $RC -eq 0 ]" "G9b-1: cleanup refuses when CWD is inside a worktree it would remove"
assert_contains "$ERR" "inside worktree" "G9b-2: refusal names the CWD hazard"
assert_true "[ -d '$WT_Z12' ]" "G9b-3: the worktree still exists"

# ─── GROUP 14: provision must refuse the MAIN checkout ───────────────────────
echo ""
echo "Group 14: provision-against-main guard"
F13=$(fixture_repo); FIXTURES+=("$F13")
wwt "$F13" single ops          # realistic layout: one module worktree exists
# The strike: provision aimed at the MAIN checkout. What un-guarded
# provisioning does to main depends on environment:
#   IN THIS FIXTURE (WAVE_WT_NO_INSTALL=1): rm -rf's main's .husky/_ (cp -R
#     from the just-deleted source fails unguarded), then dies at the
#     "hooks NOT armed" verify — .autocode is never reached, but main's hooks
#     are already destroyed (T31f pins that).
#   IN THE REAL REPO (pnpm install re-arms hooks): the verify passes and
#     provisioning continues into rm -rf of main's REAL .autocode, a self-loop
#     symlink, and skip-worktree stamps on the MAIN index (T31c/d/e pin that
#     state as post-fix invariants).
# The B1 guard fires before EITHER mutation.
wwt "$F13" provision "$F13" m1
assert_false "[ $RC -eq 0 ]" "T31a: provision refuses the main checkout"
assert_contains "$ERR" "MAIN checkout" "T31b: refusal names the main checkout"
assert_true "[ -d '$F13/.autocode' ] && [ ! -L '$F13/.autocode' ]" \
  "T31c: main .autocode is still a real directory (not a symlink)"
assert_true "[ -f '$F13/.autocode/modules/m1/tasks.md' ]" \
  "T31d: shared module state intact after the refusal"
assert_eq "$(git -C "$F13" ls-files -v -- .autocode | grep -c '^S ' | tr -d ' ')" "0" \
  "T31e: no skip-worktree flags stamped on the main index"
assert_true "[ -x '$F13/.husky/_/pre-commit' ]" "T31f: main .husky/_ untouched"

# T31g/h — refuse-if-work-lost on a REAL .autocode dir in a WORKTREE: a broken
# symlink plus one `mkdir -p .autocode/...` materializes a real dir holding
# uncommitted state; provision must surface it, never rm -rf it (empirically,
# the unguarded version destroyed such a dir and STILL failed its run).
WT_OPS13=$(wt_or_absent "$(git -C "$F13" worktree list --porcelain | awk '$1=="worktree"{wt=substr($0,10)} $1=="branch"&&$2=="refs/heads/ops-window"{print wt}')")
rm -f "$WT_OPS13/.autocode"
mkdir -p "$WT_OPS13/.autocode/modules/m1"
echo "uncommitted worker note" > "$WT_OPS13/.autocode/modules/m1/notes.md"
wwt "$F13" provision "$WT_OPS13" ops
assert_false "[ $RC -eq 0 ]" "T31g: provision refuses to replace a real .autocode holding untracked state"
assert_contains "$ERR" "refusing to replace" "T31h: refusal names the work-loss hazard"
assert_true "[ -f '$WT_OPS13/.autocode/modules/m1/notes.md' ]" "T31i: the uncommitted state survived the refusal"
rm -rf "$WT_OPS13/.autocode"
mkdir -p "$WT_OPS13/node_modules/.pnpm"   # provision ends in verify_wt; NO_INSTALL fixtures stub the pnpm marker
wwt "$F13" provision "$WT_OPS13" ops
assert_eq "$RC" "0" "T31j: provision succeeds once the dirty dir is resolved"

# T31k/l — the guard must not trust `git status` while skip-worktree bits are
# set: provision itself stamps skip-worktree on every tracked .autocode path,
# and status/diff are BLIND to edits under that bit (empirically verified) —
# an edited tasks.md would read as "clean" and be rm -rf'd. A real dir whose
# tracked paths carry the S bit must be refused unconditionally.
rm -f "$WT_OPS13/.autocode"                              # drop the symlink provision just made
mkdir -p "$WT_OPS13/.autocode/modules/m1"
git -C "$WT_OPS13" show :.autocode/modules/m1/tasks.md > "$WT_OPS13/.autocode/modules/m1/tasks.md" 2>/dev/null
echo "uncommitted tracked edit" >> "$WT_OPS13/.autocode/modules/m1/tasks.md"   # S-bit still set from the last provision
wwt "$F13" provision "$WT_OPS13" ops
assert_false "[ $RC -eq 0 ]" "T31k: provision refuses a real .autocode whose tracked paths are skip-worktree'd"
assert_contains "$ERR" "skip-worktree" "T31l: refusal names the status-blindness cause"
assert_contains "$(cat "$WT_OPS13/.autocode/modules/m1/tasks.md" 2>/dev/null)" "uncommitted tracked edit" \
  "T31m: the invisible tracked edit survived the refusal"

# T31n — assume-unchanged (lowercase 'h' in ls-files -v) blinds git status the
# same way skip-worktree does; the guard must refuse that variant too.
git -C "$WT_OPS13" update-index --no-skip-worktree .autocode/modules/m1/tasks.md 2>/dev/null
git -C "$WT_OPS13" update-index --assume-unchanged .autocode/modules/m1/tasks.md 2>/dev/null
wwt "$F13" provision "$WT_OPS13" ops
assert_false "[ $RC -eq 0 ]" "T31n: provision refuses an assume-unchanged .autocode variant"
assert_contains "$ERR" "assume-unchanged" "T31o: refusal names the assume-unchanged blindness"
git -C "$WT_OPS13" update-index --no-assume-unchanged .autocode/modules/m1/tasks.md 2>/dev/null
git -C "$WT_OPS13" update-index --skip-worktree .autocode/modules/m1/tasks.md 2>/dev/null

# ─── GROUP 15: merge-guard rename evasion (REGRESSION PIN — green pre-fix) ───
echo ""
echo "Group 15: merge guard sees renamed-away .autocode deletions"
# Verified empirically: the guard's `-- .autocode/` pathspec excludes the
# rename DESTINATION before rename pairing, so the deletion surfaces as D
# even with git's default rename detection — the current guard already
# refuses this. This group pins that behavior permanently (a future edit that
# drops the pathspec or pipes through a rename-folding diff would go red);
# B2's --no-renames on the same line is defense-in-depth, not the fix.
F14=$(fixture_repo); FIXTURES+=("$F14")
wwt "$F14" create m1 1 nina:W1A
WT_N=$(wt_or_absent "$(echo "$OUT" | grep '^WAVE_WT	nina	' | cut -f3)")
git -C "$WT_N" update-index --no-skip-worktree .autocode/modules/m1/tasks.md >/dev/null 2>&1
git -C "$WT_N" rm -q --cached .autocode/modules/m1/tasks.md >/dev/null 2>&1
cat "$F14/.autocode/modules/m1/tasks.md" > "$WT_N/apps/web/src/tasks-copy.md"
git -C "$WT_N" add apps/web/src/tasks-copy.md >/dev/null 2>&1
HOOK_EXIT=0 git -C "$WT_N" commit -q -m "bad: renames .autocode file out" >/dev/null 2>&1
wwt "$F14" merge m1 1
assert_false "[ $RC -eq 0 ]" "T32a: merge refuses a rename-evading .autocode deletion"
assert_contains "$ERR" "deletes tracked .autocode" "T32b: refusal names the .autocode deletion"

echo ""
echo "RESULTS: $TESTS_PASS/$TESTS_RUN passed"
if [ "$FAIL" -eq 0 ]; then echo "PASS"; else echo "FAIL"; fi
exit $FAIL
