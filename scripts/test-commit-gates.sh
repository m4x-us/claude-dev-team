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
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
HOOK_SRC="$REPO_ROOT/.husky/pre-commit"

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

assert_not_contains() {
  TESTS_RUN=$((TESTS_RUN+1))
  if echo "$1" | grep -q "$2"; then
    echo "  ✗ $3 — output unexpectedly contains '$2'"; FAIL=1
  else
    echo "  ✓ $3"; TESTS_PASS=$((TESTS_PASS+1))
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
echo "Group 6: CMS org-scoping gate wiring (Task #7)"

# A fixture whose index carries the CMS gate, the FFF-gate scripts, the hook,
# and one committed CLEAN cms route. Each test stages exactly one route
# change and drives the real hook. Kept separate from gate_fixture (whose
# comment forbids coupling it to new concerns).
cms_gate_fixture() {
  local d; d=$(mktemp -d)
  git -C "$d" init --quiet -b main
  git -C "$d" config user.email "test@gates.test"
  git -C "$d" config user.name "Gate Test"
  mkdir -p "$d/scripts" "$d/.husky" "$d/apps/web/src/app/api/cms/clean"
  cp "$SCRIPTS_DIR/classify-diff-size.sh" "$d/scripts/classify-diff-size.sh"
  cp "$SCRIPTS_DIR/staged-diff-hash.sh" "$d/scripts/staged-diff-hash.sh"
  cp "$SCRIPTS_DIR/cms-org-scoping-gate.sh" "$d/scripts/cms-org-scoping-gate.sh"
  cp "$SCRIPTS_DIR/cms-scope-check.pl" "$d/scripts/cms-scope-check.pl"
  # list-scoped-models.sh is a hard file-presence requirement of the
  # generalized gate (scripts/cms-org-scoping-gate.sh exits 1 with "analyzer
  # missing" if it's absent) — added the same day as the generalization
  # itself and never backfilled into this fixture until this WorldClass
  # review found it: every cms_gate_fixture()-based test was silently
  # hitting the pre-commit hook's OWN "ORG-SCOPING GATE MISSING FROM INDEX"
  # hard-block instead of ever reaching the real gate's PASS/FAIL output.
  cp "$SCRIPTS_DIR/list-scoped-models.sh" "$d/scripts/list-scoped-models.sh"
  cp "$HOOK_SRC" "$d/.husky/pre-commit"
  cat > "$d/apps/web/src/app/api/cms/clean/route.ts" << 'ROUTE'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db, organization } = await getTenantContext(session);
  const rows = await db.cmsArtifact.findMany({ where: { organizationId: organization.id } });
  return rows;
}
ROUTE
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m "initial" >/dev/null 2>&1
  echo "$d"
}

# C12 — staging an UNSCOPED cms route makes the hook's CMS gate fire.
# (The FFF gate also blocks on the missing artifact; we assert the CMS
# gate's own message so this proves the CMS wiring, not just any block.)
G8=$(cms_gate_fixture); FIXTURES+=("$G8")
mkdir -p "$G8/apps/web/src/app/api/cms/leak"
cat > "$G8/apps/web/src/app/api/cms/leak/route.ts" << 'ROUTE'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db } = await getTenantContext(session);
  const views = await db.cmsView.findMany({ where: { status: 'VERIFIED' } });
  return views;
}
ROUTE
git -C "$G8" add apps/web/src/app/api/cms/leak/route.ts >/dev/null 2>&1
run_in "$G8" sh -e .husky/pre-commit
assert_false "[ $RC -eq 0 ]" "C12a: hook blocks a commit staging an unscoped cms route"
assert_contains "$OUT" "ORG-SCOPING GATE FAILED" "C12b: the CMS gate names the IDOR-class failure"

# C13 — a CLEAN cms route change does NOT trip the CMS gate. The commit may
# still block on the FFF artifact, but the CMS gate's own failure line must
# be ABSENT — the gate never false-positives on scoped code.
G9=$(cms_gate_fixture); FIXTURES+=("$G9")
cat > "$G9/apps/web/src/app/api/cms/clean/route.ts" << 'ROUTE'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db, organization } = await getTenantContext(session);
  const rows = await db.cmsArtifact.findMany({ where: { organizationId: organization.id, status: 'VERIFIED' } });
  return rows;
}
ROUTE
git -C "$G9" add apps/web/src/app/api/cms/clean/route.ts >/dev/null 2>&1
run_in "$G9" sh -e .husky/pre-commit
assert_not_contains "$OUT" "ORG-SCOPING GATE FAILED" "C13: the CMS gate stays silent on a scoped route"

# C14 — CMS route staged but the gate script ABSENT from the index is a hard
# block (a swallowed security gate is a disabled one), never a silent skip.
G10=$(cms_gate_fixture); FIXTURES+=("$G10")
git -C "$G10" rm -q --cached scripts/cms-org-scoping-gate.sh >/dev/null 2>&1
mkdir -p "$G10/apps/web/src/app/api/cms/x"
printf 'export async function GET() { return 1; }\n' > "$G10/apps/web/src/app/api/cms/x/route.ts"
git -C "$G10" add apps/web/src/app/api/cms/x/route.ts >/dev/null 2>&1
run_in "$G10" sh -e .husky/pre-commit
assert_false "[ $RC -eq 0 ]" "C14a: hook blocks when the CMS gate is missing from the index"
assert_contains "$OUT" "ORG-SCOPING GATE MISSING FROM INDEX" "C14b: the block names the missing gate script"

# C15 — the where-clause analyzer absent from the index is the same hard block
# (the gate can't judge scope without it).
G10b=$(cms_gate_fixture); FIXTURES+=("$G10b")
git -C "$G10b" rm -q --cached scripts/cms-scope-check.pl >/dev/null 2>&1
mkdir -p "$G10b/apps/web/src/app/api/cms/y"
printf 'export async function GET() { return 1; }\n' > "$G10b/apps/web/src/app/api/cms/y/route.ts"
git -C "$G10b" add apps/web/src/app/api/cms/y/route.ts >/dev/null 2>&1
run_in "$G10b" sh -e .husky/pre-commit
assert_false "[ $RC -eq 0 ]" "C15a: hook blocks when the where-clause analyzer is missing from the index"
assert_contains "$OUT" "cms-scope-check.pl" "C15b: the block names the missing analyzer"

# C16 — the crux of the design: the gate judges the INDEX, not the working
# tree. Stage a clean route, then GUT the gate in the WORKING TREE; the
# index-mirrored gate must still be the real one (a clean route still passes,
# proving the working-tree copy was ignored — the inverse of the FFF gate's
# C9, applied to the CMS gate).
G11=$(cms_gate_fixture); FIXTURES+=("$G11")
mkdir -p "$G11/apps/web/src/app/api/cms/leak2"
# An UNSCOPED route staged into the index...
cat > "$G11/apps/web/src/app/api/cms/leak2/route.ts" << 'ROUTE'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db } = await getTenantContext(session);
  return db.cmsView.findMany({ where: { status: 'VERIFIED' } });
}
ROUTE
git -C "$G11" add apps/web/src/app/api/cms/leak2/route.ts >/dev/null 2>&1
# ...while the WORKING-TREE gate is neutered to always pass.
printf '#!/usr/bin/env bash\necho "GATE PASSED"\nexit 0\n' > "$G11/scripts/cms-org-scoping-gate.sh"
run_in "$G11" sh -e .husky/pre-commit
assert_false "[ $RC -eq 0 ]" "C16a: a gutted working-tree gate does not weaken the commit (index copy runs)"
assert_contains "$OUT" "ORG-SCOPING GATE FAILED" "C16b: the index-mirrored gate caught the staged IDOR"

# C17 — the trigger itself, not just the gate's internal logic: a commit
# staging ONLY a Rule-1-split TARGET file (never named route.ts) must still
# fire the whole CMS gate block. Before this fix, CMS_GATE_TRIGGER matched
# only `.*route\.ts$`, so a commit touching solely the re-exported verb file
# (where 100% of the real Prisma calls live post-split) would never even
# invoke the gate — a silent, permanent enforcement gap on every future edit
# to a split file that doesn't also touch its route.ts shell.
G12=$(cms_gate_fixture); FIXTURES+=("$G12")
mkdir -p "$G12/apps/web/src/app/api/cms/split"
cat > "$G12/apps/web/src/app/api/cms/split/route.ts" << 'ROUTE'
export { GET } from './view-get';
ROUTE
cat > "$G12/apps/web/src/app/api/cms/split/view-get.ts" << 'ROUTE'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db, organization } = await getTenantContext(session);
  const rows = await db.cmsView.findMany({ where: { organizationId: organization.id } });
  return rows;
}
ROUTE
git -C "$G12" add -A >/dev/null 2>&1
git -C "$G12" commit -q -m "add clean split route" >/dev/null 2>&1
# Now stage an UNSCOPED edit to ONLY the target file — route.ts is untouched.
cat > "$G12/apps/web/src/app/api/cms/split/view-get.ts" << 'ROUTE'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db } = await getTenantContext(session);
  const rows = await db.cmsView.findMany({ where: { status: 'VERIFIED' } });
  return rows;
}
ROUTE
git -C "$G12" add apps/web/src/app/api/cms/split/view-get.ts >/dev/null 2>&1
git -C "$G12" diff --cached --name-only | grep -qx "apps/web/src/app/api/cms/split/route.ts" \
  && { echo "C17 SETUP BUG: route.ts unexpectedly staged"; FAIL=1; }
run_in "$G12" sh -e .husky/pre-commit
assert_false "[ $RC -eq 0 ]" "C17a: a commit touching ONLY a split target file (not route.ts) still triggers the gate"
assert_contains "$OUT" "ORG-SCOPING GATE FAILED" "C17b: the gate catches the unscoped read introduced in the target-only commit"

echo ""
echo "Group K: apps/web/src/services/ trigger+mirror widening (Task #126 / ALFRED-59)"

# K1 — staging a NEW unscoped file under apps/web/src/services/ fires the
# gate at all. Proves the trigger+mirror widening itself works — before
# Task #126, CMS_GATE_TRIGGER never matched anything outside api/ or
# %5Fpublic/, so a commit touching only a service file could never invoke
# this gate no matter what it did.
K1=$(cms_gate_fixture); FIXTURES+=("$K1")
mkdir -p "$K1/apps/web/src/services/agent"
cat > "$K1/apps/web/src/services/agent/session-store.ts" << 'SVC'
export async function loadSession(db, sessionId) {
  return db.cmsView.findFirst({ where: { id: sessionId } });
}
SVC
git -C "$K1" add apps/web/src/services/agent/session-store.ts >/dev/null 2>&1
run_in "$K1" sh -e .husky/pre-commit
assert_false "[ $RC -eq 0 ]" "K1a: a commit staging an unscoped read in a NEW services/ file triggers and fails the gate"
assert_contains "$OUT" "ORG-SCOPING GATE FAILED" "K1b: the gate names the IDOR-class failure — the exact ALFRED-59 shape, via the real commit-time mirror, not just a standalone script run"

# K2 — the exact regression WorldClass Vibes review found live: an earlier
# version of this trigger was `apps/web/src/services/.*\.ts$` (`.ts`-only,
# copy-derived from the api/ clause, which is safely .ts-only because a
# Next.js route handler can never be .tsx — an assumption that does NOT
# hold for services/, since the gate script's own HELPER_FILES section
# already scans .tsx too, for a direct server-side Prisma call in a Server
# Component). A NEW .tsx file under services/ with an unscoped call
# produced an EMPTY $CMS_GATE_TRIGGER under that version — the whole
# mirror-and-scan block silently never ran. Pins the fix.
K2=$(cms_gate_fixture); FIXTURES+=("$K2")
mkdir -p "$K2/apps/web/src/services/agent"
cat > "$K2/apps/web/src/services/agent/session-panel.tsx" << 'SVC'
export default async function SessionPanel({ db, sessionId }) {
  const session = await db.cmsView.findFirst({ where: { id: sessionId } });
  return null;
}
SVC
git -C "$K2" add apps/web/src/services/agent/session-panel.tsx >/dev/null 2>&1
run_in "$K2" sh -e .husky/pre-commit
assert_false "[ $RC -eq 0 ]" "K2a: a commit staging an unscoped read in a NEW services/*.tsx file also triggers and fails the gate"
assert_contains "$OUT" "ORG-SCOPING GATE FAILED" "K2b: .tsx under services/ is not silently invisible to the trigger"

# K3 — a properly org-scoped services/ file does NOT trip the gate — proves
# K1/K2 aren't just failing every services/ commit unconditionally.
K3=$(cms_gate_fixture); FIXTURES+=("$K3")
mkdir -p "$K3/apps/web/src/services/agent"
cat > "$K3/apps/web/src/services/agent/session-store.ts" << 'SVC'
export async function loadSession(db, sessionId, organizationId) {
  return db.cmsView.findFirst({ where: { id: sessionId, organizationId } });
}
SVC
git -C "$K3" add apps/web/src/services/agent/session-store.ts >/dev/null 2>&1
run_in "$K3" sh -e .husky/pre-commit
assert_not_contains "$OUT" "ORG-SCOPING GATE FAILED" "K3: a properly org-scoped services/ file does not false-positive"

# K4 — the trigger+mirror now match the gate script's own FULL scan
# surface (apps/web/src/*, not just services/) — Max's explicit decision
# after WorldClass review found the narrower services/-only version
# reproduced philosophy.md Rule 24(b)'s named recurring bug class ("gate
# stops looking" once code moves outside the allowlisted directory),
# proven live via a real unscoped call in apps/web/src/lib/
# cms-dashboard-queries.ts that a services/-only mirror could never see.
# A NEW unscoped file under apps/web/src/lib/ (deliberately NOT services/,
# NOT api/, NOT %5Fpublic/) must still trigger and fail the real
# commit-time gate.
K4=$(cms_gate_fixture); FIXTURES+=("$K4")
mkdir -p "$K4/apps/web/src/lib"
cat > "$K4/apps/web/src/lib/dashboard-queries.ts" << 'SVC'
export async function loadDashboardData(db, id) {
  return db.cmsView.findFirst({ where: { id } });
}
SVC
git -C "$K4" add apps/web/src/lib/dashboard-queries.ts >/dev/null 2>&1
run_in "$K4" sh -e .husky/pre-commit
assert_false "[ $RC -eq 0 ]" "K4a: a commit staging an unscoped read in apps/web/src/lib/ (outside services/, api/, %5Fpublic/) still triggers and fails the gate"
assert_contains "$OUT" "ORG-SCOPING GATE FAILED" "K4b: the full-tree mirror actually sees a lib/ file, not just services/"

echo ""
echo "Group: public-surface-gate.sh trigger condition (Task #70)"

# public_surface_fixture — a minimal repo carrying scripts/public-surface-
# gate.sh + .husky/pre-commit. Since Task #70's cycle-2/3 rewrite, the
# real check logic is a TypeScript AST checker
# (packages/ordinatio-cms/scripts/public-surface-checks.ts) that needs a
# full pnpm/tsx toolchain this isolated fixture can't provide — matching
# perf_budget_fixture below exactly, these tests drive
# PUBLIC_SURFACE_CHECK_CMD (an exported env var, inherited by the hook's
# own subprocess invocation of the gate) to stand in for the real
# `pnpm exec tsx` command, proving the HOOK's trigger/mirror wiring, not
# re-testing test-public-surface-gate.sh's own test coverage of the real
# check logic against the real repo (deliberately no test count is stated
# here, for the same reason that file's own header gives — it drifts the
# moment a new fixture is added there; check that file directly).
public_surface_fixture() {
  local d; d=$(mktemp -d)
  git -C "$d" init --quiet -b main
  git -C "$d" config user.email "test@gates.test"
  git -C "$d" config user.name "Gate Test"
  mkdir -p "$d/scripts" "$d/.husky" \
    "$d/apps/web/src/middleware-utils" \
    "$d/apps/web/src/app/%5Fpublic/[[...slug]]" "$d/apps/web/src/app/%5Fpublic/sitemap.xml" \
    "$d/apps/web/src/app/robots.txt" "$d/apps/web/src/app/api/cms/assets/[id]" \
    "$d/packages/ordinatio-cms/src/templates/sections"
  cp "$SCRIPTS_DIR/classify-diff-size.sh" "$d/scripts/classify-diff-size.sh"
  cp "$SCRIPTS_DIR/staged-diff-hash.sh" "$d/scripts/staged-diff-hash.sh"
  cp "$SCRIPTS_DIR/public-surface-gate.sh" "$d/scripts/public-surface-gate.sh"
  cp "$HOOK_SRC" "$d/.husky/pre-commit"
  echo "export async function middleware(request) {}" > "$d/apps/web/src/middleware.ts"
  echo "export function applyPublicSiteSecurityHeaders(res) { return res; }" > "$d/apps/web/src/middleware-utils/security-headers.ts"
  echo "export async function GET(request) {}" > "$d/apps/web/src/app/%5Fpublic/[[...slug]]/route.ts"
  echo "export async function GET(request) {}" > "$d/apps/web/src/app/%5Fpublic/sitemap.xml/route.ts"
  echo "export function GET(request) {}" > "$d/apps/web/src/app/robots.txt/route.ts"
  echo "export async function GET(request) {}" > "$d/apps/web/src/app/api/cms/assets/[id]/route.ts"
  echo "export function renderHero(ctx) { return '<section></section>'; }" > "$d/packages/ordinatio-cms/src/templates/sections/hero.ts"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m "initial" >/dev/null 2>&1
  echo "$d"
}

# C18 — staging a robots.txt edit, with the stand-in check command
# reporting failure (exit 1), blocks the commit.
G13=$(public_surface_fixture); FIXTURES+=("$G13")
echo "export function GET(request) { /* edited */ }" > "$G13/apps/web/src/app/robots.txt/route.ts"
git -C "$G13" add apps/web/src/app/robots.txt/route.ts >/dev/null 2>&1
PUBLIC_SURFACE_CHECK_CMD='echo "robots.txt: FAIL"; exit 1' run_in "$G13" sh -e .husky/pre-commit
assert_false "[ $RC -eq 0 ]" "C18a: hook blocks a commit when the public-surface check reports failure"
assert_contains "$OUT" "PUBLIC SURFACE GATE FAILED" "C18b: the public-surface gate names the failure"

# C18c — the same staged file with the stand-in reporting success (exit 0)
# does NOT trip the gate.
G13B=$(public_surface_fixture); FIXTURES+=("$G13B")
echo "export function GET(request) { /* edited */ }" > "$G13B/apps/web/src/app/robots.txt/route.ts"
git -C "$G13B" add apps/web/src/app/robots.txt/route.ts >/dev/null 2>&1
PUBLIC_SURFACE_CHECK_CMD='echo "robots.txt: OK"; exit 0' run_in "$G13B" sh -e .husky/pre-commit
assert_not_contains "$OUT" "PUBLIC SURFACE GATE FAILED" "C18c: a passing stand-in result does not fail the public-surface gate"

# C19 — an UNRELATED staged file (outside the gate's five watched
# paths) does NOT trigger the gate at all — proves the trigger condition
# is scoped, not always-on.
G14=$(public_surface_fixture); FIXTURES+=("$G14")
mkdir -p "$G14/apps/web/src/app/dashboard/unrelated"
printf 'export default function Page() { return null; }\n' > "$G14/apps/web/src/app/dashboard/unrelated/page.tsx"
git -C "$G14" add apps/web/src/app/dashboard/unrelated/page.tsx >/dev/null 2>&1
PUBLIC_SURFACE_CHECK_CMD='echo "should never run"; exit 1' run_in "$G14" sh -e .husky/pre-commit
assert_not_contains "$OUT" "PUBLIC SURFACE GATE" "C19: staging an unrelated dashboard file never even mentions the public-surface gate"

# C19b — TARGET-ONLY: staging an edit to apps/web/src/middleware-utils/*
# ALONE (middleware.ts itself untouched) still fires the gate. WorldClass
# cycle-1 finding (Task #70, Architecture severity 7): the mirror's own
# file list already included middleware-utils/* but the TRIGGER regex
# didn't, so an edit to the real CSP/host-routing implementation
# (applyPublicSiteSecurityHeaders, isPublicHostRequest, neverPublicHosts())
# never invoked the gate at all — matching the sibling CMS org-scoping
# gate's own "target-only" test for this exact class of gap.
G14B=$(public_surface_fixture); FIXTURES+=("$G14B")
cat > "$G14B/apps/web/src/middleware-utils/security-headers.ts" << 'EOF'
export function applyPublicSiteSecurityHeaders(res) { return res; }
export function applySecurityHeaders(res) { res.headers.set('X-Weakened', '1'); return res; }
EOF
git -C "$G14B" add apps/web/src/middleware-utils/security-headers.ts >/dev/null 2>&1
# Stand-in exits 1 (not 0) specifically so invocation is provable via the
# FAILED block's own text — a passing run prints nothing distinctive, so
# asserting on a plain "was it mentioned" string against exit-0 output
# would be untestable (and was a latent bug in this exact test before
# this fix: it asserted a substring that only the FAILURE path ever
# prints, but paired it with an exit-0 stand-in).
PUBLIC_SURFACE_CHECK_CMD='echo "  ✗ target-only invocation marker"; exit 1' run_in "$G14B" sh -e .husky/pre-commit
assert_contains "$OUT" "PUBLIC SURFACE GATE FAILED" "C19b: staging middleware-utils/security-headers.ts ALONE still invokes the public-surface gate"
assert_contains "$OUT" "target-only invocation marker" "C19b: the stand-in's own marker output is present, proving it (not some other path) ran"

echo ""
echo "Group: public-surface-behavioral-gate.sh trigger condition (Task #70, WorldClass cycle 23)"

# public_surface_behavioral_fixture — mirrors public_surface_fixture's
# directory shape exactly (same 5 watched paths + middleware-utils), but
# carries scripts/public-surface-behavioral-gate.sh instead of the static
# checker. This gate needs a REAL pnpm/vitest resolution to run for real,
# which an isolated `git init` fixture with no node_modules can never
# provide — so these tests drive PUBLIC_SURFACE_BEHAVIORAL_CHECK_CMD (the
# gate's own testability seam) to prove the HOOK's trigger wiring, exactly
# matching how public_surface_fixture above proves PUBLIC_SURFACE_TRIGGER's
# wiring without ever invoking a real pnpm exec tsx.
public_surface_behavioral_fixture() {
  local d; d=$(mktemp -d)
  git -C "$d" init --quiet -b main
  git -C "$d" config user.email "test@gates.test"
  git -C "$d" config user.name "Gate Test"
  mkdir -p "$d/scripts" "$d/.husky" \
    "$d/apps/web/src/middleware-utils" \
    "$d/apps/web/src/app/%5Fpublic/[[...slug]]" "$d/apps/web/src/app/%5Fpublic/sitemap.xml" \
    "$d/apps/web/src/app/robots.txt" "$d/apps/web/src/app/api/cms/assets/[id]"
  cp "$SCRIPTS_DIR/classify-diff-size.sh" "$d/scripts/classify-diff-size.sh"
  cp "$SCRIPTS_DIR/staged-diff-hash.sh" "$d/scripts/staged-diff-hash.sh"
  cp "$SCRIPTS_DIR/public-surface-behavioral-gate.sh" "$d/scripts/public-surface-behavioral-gate.sh"
  cp "$HOOK_SRC" "$d/.husky/pre-commit"
  echo "export async function middleware(request) {}" > "$d/apps/web/src/middleware.ts"
  echo "export function applyPublicSiteSecurityHeaders(res) { return res; }" > "$d/apps/web/src/middleware-utils/security-headers.ts"
  echo "export async function GET(request) {}" > "$d/apps/web/src/app/%5Fpublic/[[...slug]]/route.ts"
  echo "export async function GET(request) {}" > "$d/apps/web/src/app/%5Fpublic/sitemap.xml/route.ts"
  echo "export function GET(request) {}" > "$d/apps/web/src/app/robots.txt/route.ts"
  echo "export async function GET(request) {}" > "$d/apps/web/src/app/api/cms/assets/[id]/route.ts"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m "initial" >/dev/null 2>&1
  echo "$d"
}

# C19c/C19d — staging an edit to the BEHAVIORAL gate script itself (never
# robots.txt/route.ts — cycle-24 fix: staging any of the 5 shared production
# file paths ALSO fires PUBLIC_SURFACE_TRIGGER, and since this fixture never
# copies scripts/public-surface-gate.sh into its index, that confounds RC=1
# with an unrelated "PUBLIC SURFACE GATE MISSING" failure — demonstrated by
# a cycle-23 reviewer: with the entire behavioral block deleted from the
# fixture's hook, RC was STILL 1, meaning the old C19c "passed" regardless of
# whether the behavioral gate itself passed or failed. Staging
# scripts/public-surface-behavioral-gate.sh exclusively matches
# PUBLIC_SURFACE_BEHAVIORAL_TRIGGER's regex and NOT PUBLIC_SURFACE_TRIGGER's,
# so RC and the printed message are driven ONLY by this gate) with the stand-in
# check command reporting failure (exit 1) blocks the commit.
G19C=$(public_surface_behavioral_fixture); FIXTURES+=("$G19C")
printf '\n# C19c isolation edit\n' >> "$G19C/scripts/public-surface-behavioral-gate.sh"
git -C "$G19C" add scripts/public-surface-behavioral-gate.sh >/dev/null 2>&1
PUBLIC_SURFACE_BEHAVIORAL_CHECK_CMD='echo "behavioral gate: FAIL"; exit 1' run_in "$G19C" sh -e .husky/pre-commit
assert_false "[ $RC -eq 0 ]" "C19c: hook blocks a commit when the public-surface behavioral check reports failure (isolated — no PUBLIC_SURFACE_TRIGGER confound)"
assert_contains "$OUT" "PUBLIC SURFACE BEHAVIORAL GATE FAILED" "C19d: the public-surface behavioral gate names the failure"

# C19e — the same isolated staged file with the stand-in reporting success
# (exit 0) does NOT trip the gate. This is the discriminating half of the
# pair the old confounded version couldn't actually prove: with the isolated
# fixture, RC really does depend on the override's own exit code.
G19E=$(public_surface_behavioral_fixture); FIXTURES+=("$G19E")
printf '\n# C19e isolation edit\n' >> "$G19E/scripts/public-surface-behavioral-gate.sh"
git -C "$G19E" add scripts/public-surface-behavioral-gate.sh >/dev/null 2>&1
PUBLIC_SURFACE_BEHAVIORAL_CHECK_CMD='echo "behavioral gate: OK"; exit 0' run_in "$G19E" sh -e .husky/pre-commit
assert_not_contains "$OUT" "PUBLIC SURFACE BEHAVIORAL GATE FAILED" "C19e: a passing stand-in result does not fail the public-surface behavioral gate"

# C19f — an UNRELATED staged file (outside the gate's five watched paths)
# does NOT trigger the gate at all.
G19F=$(public_surface_behavioral_fixture); FIXTURES+=("$G19F")
mkdir -p "$G19F/apps/web/src/app/dashboard/unrelated"
printf 'export default function Page() { return null; }\n' > "$G19F/apps/web/src/app/dashboard/unrelated/page.tsx"
git -C "$G19F" add apps/web/src/app/dashboard/unrelated/page.tsx >/dev/null 2>&1
PUBLIC_SURFACE_BEHAVIORAL_CHECK_CMD='echo "should never run"; exit 1' run_in "$G19F" sh -e .husky/pre-commit
assert_not_contains "$OUT" "PUBLIC SURFACE BEHAVIORAL GATE" "C19f: staging an unrelated dashboard file never even mentions the public-surface behavioral gate"

# C19g — TARGET-ONLY: staging an edit to apps/web/src/middleware-utils/*
# ALONE (middleware.ts itself untouched) still fires the gate — this gate's
# own version of the same lesson the static gate's C19b already learned.
G19G=$(public_surface_behavioral_fixture); FIXTURES+=("$G19G")
cat > "$G19G/apps/web/src/middleware-utils/security-headers.ts" << 'EOF'
export function applyPublicSiteSecurityHeaders(res) { return res; }
export function applySecurityHeaders(res) { res.headers.set('X-Weakened', '1'); return res; }
EOF
git -C "$G19G" add apps/web/src/middleware-utils/security-headers.ts >/dev/null 2>&1
PUBLIC_SURFACE_BEHAVIORAL_CHECK_CMD='echo "  ✗ target-only invocation marker"; exit 1' run_in "$G19G" sh -e .husky/pre-commit
assert_contains "$OUT" "PUBLIC SURFACE BEHAVIORAL GATE FAILED" "C19g: staging middleware-utils/security-headers.ts ALONE still invokes the public-surface behavioral gate"
assert_contains "$OUT" "target-only invocation marker" "C19g: the stand-in's own marker output is present, proving it (not some other path) ran"

echo ""
echo "Group: perf-budget-gate.sh trigger condition (Task #70)"

# perf_budget_fixture — a minimal repo carrying scripts/perf-budget-gate.sh
# + .husky/pre-commit. The real check needs a full pnpm/tsx toolchain this
# fixture can't provide, so these tests drive PERF_BUDGET_CHECK_CMD (an
# exported env var, inherited by the hook's own subprocess invocation of
# the gate) to stand in for the real `pnpm exec tsx` command — proving the
# HOOK's trigger wiring, not re-testing perf-budget.test.ts's own coverage
# of the real measurement logic.
perf_budget_fixture() {
  local d; d=$(mktemp -d)
  git -C "$d" init --quiet -b main
  git -C "$d" config user.email "test@gates.test"
  git -C "$d" config user.name "Gate Test"
  mkdir -p "$d/scripts" "$d/.husky" "$d/packages/ordinatio-cms/src/templates"
  cp "$SCRIPTS_DIR/classify-diff-size.sh" "$d/scripts/classify-diff-size.sh"
  cp "$SCRIPTS_DIR/staged-diff-hash.sh" "$d/scripts/staged-diff-hash.sh"
  cp "$SCRIPTS_DIR/perf-budget-gate.sh" "$d/scripts/perf-budget-gate.sh"
  cp "$HOOK_SRC" "$d/.husky/pre-commit"
  echo "export const x = 1;" > "$d/packages/ordinatio-cms/src/templates/hero.ts"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m "initial" >/dev/null 2>&1
  echo "$d"
}

# C20 — staging a templates file with the stand-in check command reporting
# an over-budget failure (exit 1) fires the gate.
G15=$(perf_budget_fixture); FIXTURES+=("$G15")
echo "export const y = 2;" >> "$G15/packages/ordinatio-cms/src/templates/hero.ts"
git -C "$G15" add packages/ordinatio-cms/src/templates/hero.ts >/dev/null 2>&1
PERF_BUDGET_CHECK_CMD='echo "hub: OVER BUDGET"; exit 1' run_in "$G15" sh -e .husky/pre-commit
assert_false "[ $RC -eq 0 ]" "C20a: hook blocks a commit when the perf-budget check reports over-budget"
assert_contains "$OUT" "PERF BUDGET GATE FAILED" "C20b: the perf-budget gate names the failure"

# C21 — the same staged file with the stand-in command reporting IN-budget
# (exit 0) does NOT trip the perf-budget gate.
G16=$(perf_budget_fixture); FIXTURES+=("$G16")
echo "export const y = 2;" >> "$G16/packages/ordinatio-cms/src/templates/hero.ts"
git -C "$G16" add packages/ordinatio-cms/src/templates/hero.ts >/dev/null 2>&1
PERF_BUDGET_CHECK_CMD='echo "all templates OK"; exit 0' run_in "$G16" sh -e .husky/pre-commit
assert_not_contains "$OUT" "PERF BUDGET GATE FAILED" "C21: an in-budget stand-in result does not fail the perf-budget gate"

# C22 — an UNRELATED staged file does NOT trigger the perf-budget gate at
# all (the trigger condition is scoped to templates/**, not always-on).
G17=$(perf_budget_fixture); FIXTURES+=("$G17")
mkdir -p "$G17/apps/web/src/app/dashboard/unrelated"
printf 'export default function Page() { return null; }\n' > "$G17/apps/web/src/app/dashboard/unrelated/page.tsx"
git -C "$G17" add apps/web/src/app/dashboard/unrelated/page.tsx >/dev/null 2>&1
PERF_BUDGET_CHECK_CMD='echo "should never run"; exit 1' run_in "$G17" sh -e .husky/pre-commit
assert_not_contains "$OUT" "PERF BUDGET GATE" "C22: staging an unrelated dashboard file never even mentions the perf-budget gate"

echo ""
echo "Group: Rule 14 *.test-d.ts scoping (Task #82)"

# Fixture: extends gate_fixture with a fake packages/ordinatio-cms/src/publisher/
# tree (the ONE verified path) and a fake packages/ordinatio-other/src/ tree
# (an UNVERIFIED path) — proves the hook's TEST_D_VERIFIED_PATHS scoping, not
# just that the regex matches ".test-d." anywhere.
test_d_fixture() {
  local d; d=$(gate_fixture)
  mkdir -p "$d/packages/ordinatio-cms/src/publisher" "$d/packages/ordinatio-other/src"
  echo "export interface Foo { x: string; }" > "$d/packages/ordinatio-cms/src/publisher/foo.ts"
  echo "// type test" > "$d/packages/ordinatio-cms/src/publisher/foo.test-d.ts"
  echo "export interface Bar { y: string; }" > "$d/packages/ordinatio-other/src/bar.ts"
  echo "// type test" > "$d/packages/ordinatio-other/src/bar.test-d.ts"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m "test-d fixtures" >/dev/null 2>&1
  echo "$d"
}

# C23 — a NEW .ts file in the VERIFIED path (packages/ordinatio-cms/src/
# publisher/) with ONLY a .test-d.ts sibling (no .test.ts) is NOT flagged —
# the whole point of Task #82's fix.
G18=$(test_d_fixture); FIXTURES+=("$G18")
echo "export interface Baz { z: string; }" > "$G18/packages/ordinatio-cms/src/publisher/baz.ts"
echo "// type test" > "$G18/packages/ordinatio-cms/src/publisher/baz.test-d.ts"
git -C "$G18" add packages/ordinatio-cms/src/publisher/baz.ts packages/ordinatio-cms/src/publisher/baz.test-d.ts >/dev/null 2>&1
run_in "$G18" sh -e .husky/pre-commit
assert_not_contains "$OUT" "baz.ts is a new source file" "C23: a .test-d.ts sibling satisfies Rule 14 in the VERIFIED path"

# C24 — the .test-d.ts file ITSELF (in the verified path) is never flagged as
# needing its OWN co-located test — it IS the test.
assert_not_contains "$OUT" "baz.test-d.ts is a new source file" "C24: a .test-d.ts file in the verified path is not itself flagged"

# C25 — the adversarial case: a NEW .ts file OUTSIDE the verified path
# (packages/ordinatio-other/src/) with ONLY a .test-d.ts sibling IS flagged —
# proves the fix does NOT create a repo-wide bypass (WorldClass adversarial
# finding, Task #82). A real .test.ts is still required here.
G19=$(test_d_fixture); FIXTURES+=("$G19")
echo "export interface Qux { w: string; }" > "$G19/packages/ordinatio-other/src/qux.ts"
echo "// fake — not actually executed by anything outside publisher/" > "$G19/packages/ordinatio-other/src/qux.test-d.ts"
git -C "$G19" add packages/ordinatio-other/src/qux.ts packages/ordinatio-other/src/qux.test-d.ts >/dev/null 2>&1
run_in "$G19" sh -e .husky/pre-commit
assert_contains "$OUT" "qux.ts is a new source file" "C25: a .test-d.ts sibling does NOT satisfy Rule 14 OUTSIDE the verified path (no repo-wide bypass)"

# C26 — twin of C23 for the .tsx form: the hook accepts EITHER .test-d.ts or
# .test-d.tsx as the sibling (.husky/pre-commit's TEST_D_OK check), but C23
# only exercised .ts. A future edit could correctly handle .ts while breaking
# the .tsx branch and this suite wouldn't notice without this test.
G20=$(test_d_fixture); FIXTURES+=("$G20")
echo "export interface Quux { v: string; }" > "$G20/packages/ordinatio-cms/src/publisher/quux.ts"
echo "// type test" > "$G20/packages/ordinatio-cms/src/publisher/quux.test-d.tsx"
git -C "$G20" add packages/ordinatio-cms/src/publisher/quux.ts packages/ordinatio-cms/src/publisher/quux.test-d.tsx >/dev/null 2>&1
run_in "$G20" sh -e .husky/pre-commit
assert_not_contains "$OUT" "quux.ts is a new source file" "C26: a .test-d.tsx sibling ALSO satisfies Rule 14 in the verified path (not just .test-d.ts)"


echo ""
echo "Group: agent tool-route drift gate trigger condition (alfred Task #3)"

# agent_tool_fixture — a fresh git-init repo carrying the hook, the agent
# tool gate's two files, and the CMS gate's three scripts (staging anything
# under api/ also fires CMS_GATE_TRIGGER; without its scripts in the index
# that block would emit its own MISSING error — harmless for these tests'
# marker-string assertions, but copying them keeps the output clean).
# These tests drive AGENT_TOOL_CHECK_CMD (the wrapper's testability seam)
# to prove the HOOK's trigger/mirror wiring — a fixture repo has no pnpm
# toolchain, so the real checker can never run here (same pattern as
# PUBLIC_SURFACE_CHECK_CMD above).
agent_tool_fixture() {
  local d; d=$(mktemp -d)
  git -C "$d" init --quiet -b main
  git -C "$d" config user.email "test@gates.test"
  git -C "$d" config user.name "Gate Test"
  mkdir -p "$d/scripts" "$d/.husky" "$d/apps/web/scripts" \
    "$d/apps/web/src/lib/agents" "$d/apps/web/src/app/api/foo" \
    "$d/packages/ordinatio-agent/src"
  cp "$SCRIPTS_DIR/classify-diff-size.sh" "$d/scripts/classify-diff-size.sh"
  cp "$SCRIPTS_DIR/staged-diff-hash.sh" "$d/scripts/staged-diff-hash.sh"
  cp "$SCRIPTS_DIR/check-agent-tools.sh" "$d/scripts/check-agent-tools.sh"
  cp "$SCRIPTS_DIR/cms-org-scoping-gate.sh" "$d/scripts/cms-org-scoping-gate.sh"
  cp "$SCRIPTS_DIR/cms-scope-check.pl" "$d/scripts/cms-scope-check.pl"
  cp "$SCRIPTS_DIR/list-scoped-models.sh" "$d/scripts/list-scoped-models.sh"
  cp "$HOOK_SRC" "$d/.husky/pre-commit"
  echo "// stand-in checker body (never executed — AGENT_TOOL_CHECK_CMD drives these tests)" \
    > "$d/apps/web/scripts/check-agent-tool-routes.ts"
  echo "export const BASIC_TOOLS = [];" > "$d/apps/web/src/lib/agents/basic-tools.ts"
  echo "export async function GET() { return null; }" > "$d/apps/web/src/app/api/foo/route.ts"
  echo "// test" > "$d/apps/web/src/app/api/foo/route.test.ts"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m "initial" >/dev/null 2>&1
  echo "$d"
}

# H1 — staging an agents catalog edit with a failing stand-in blocks the
# commit with the gate's named error.
H1=$(agent_tool_fixture); FIXTURES+=("$H1")
echo "export const BASIC_TOOLS = [1];" > "$H1/apps/web/src/lib/agents/basic-tools.ts"
git -C "$H1" add apps/web/src/lib/agents/basic-tools.ts >/dev/null 2>&1
AGENT_TOOL_CHECK_CMD='echo "  ✗ [DEAD-ENDPOINT] stand-in marker"; exit 1' run_in "$H1" sh -e .husky/pre-commit
assert_contains "$OUT" "AGENT TOOL GATE FAILED" "H1a: hook blocks an agents edit when the check reports failure"
assert_contains "$OUT" "stand-in marker" "H1b: the stand-in output (not some other path) produced the failure"

# H2 — the same staged edit with a passing stand-in does not trip the gate.
H2=$(agent_tool_fixture); FIXTURES+=("$H2")
echo "export const BASIC_TOOLS = [2];" > "$H2/apps/web/src/lib/agents/basic-tools.ts"
git -C "$H2" add apps/web/src/lib/agents/basic-tools.ts >/dev/null 2>&1
AGENT_TOOL_CHECK_CMD='echo ok; exit 0' run_in "$H2" sh -e .husky/pre-commit
assert_not_contains "$OUT" "AGENT TOOL GATE FAILED" "H2: a passing check result does not fail the agent tool gate"

# H3 — a route.ts DELETION ALONE fires the gate. The hook's STAGED variable
# uses --diff-filter=d and cannot see deletions — the trigger must union
# STAGED_DELETED, or deleting a route a tool points at (the highest-value
# drift case) commits without the gate ever running.
H3=$(agent_tool_fixture); FIXTURES+=("$H3")
git -C "$H3" rm -q apps/web/src/app/api/foo/route.ts >/dev/null 2>&1
AGENT_TOOL_CHECK_CMD='echo "  ✗ [DEAD-ENDPOINT] deletion marker"; exit 1' run_in "$H3" sh -e .husky/pre-commit
assert_contains "$OUT" "AGENT TOOL GATE FAILED" "H3a: a route.ts deletion alone fires and blocks"
assert_contains "$OUT" "deletion marker" "H3b: the stand-in ran on the deletion-only commit"

# H4 — editing either of the gate's OWN files fires the gate (Rule 24b:
# the watched paths include the gate itself).
H4=$(agent_tool_fixture); FIXTURES+=("$H4")
echo "# edited" >> "$H4/scripts/check-agent-tools.sh"
git -C "$H4" add scripts/check-agent-tools.sh >/dev/null 2>&1
AGENT_TOOL_CHECK_CMD='echo "  ✗ wrapper-edit marker"; exit 1' run_in "$H4" sh -e .husky/pre-commit
assert_contains "$OUT" "AGENT TOOL GATE FAILED" "H4a: editing the wrapper alone fires the gate"
H4B=$(agent_tool_fixture); FIXTURES+=("$H4B")
echo "// edited" >> "$H4B/apps/web/scripts/check-agent-tool-routes.ts"
git -C "$H4B" add apps/web/scripts/check-agent-tool-routes.ts >/dev/null 2>&1
AGENT_TOOL_CHECK_CMD='echo "  ✗ checker-edit marker"; exit 1' run_in "$H4B" sh -e .husky/pre-commit
assert_contains "$OUT" "AGENT TOOL GATE FAILED" "H4b: editing the checker alone fires the gate"

# H5 — an unrelated staged file never even mentions the gate.
H5=$(agent_tool_fixture); FIXTURES+=("$H5")
mkdir -p "$H5/docs"
echo "note" > "$H5/docs/note.md"
git -C "$H5" add docs/note.md >/dev/null 2>&1
AGENT_TOOL_CHECK_CMD='echo "should never run"; exit 1' run_in "$H5" sh -e .husky/pre-commit
assert_not_contains "$OUT" "AGENT TOOL GATE" "H5: an unrelated file never mentions the agent tool gate"

# H6 — an agents .test.ts edit alone does not fire (test files are not
# catalog surface; the checker excludes them from discovery too).
H6=$(agent_tool_fixture); FIXTURES+=("$H6")
echo "// test only" > "$H6/apps/web/src/lib/agents/basic-tools.test.ts"
git -C "$H6" add apps/web/src/lib/agents/basic-tools.test.ts >/dev/null 2>&1
AGENT_TOOL_CHECK_CMD='echo "should never run"; exit 1' run_in "$H6" sh -e .husky/pre-commit
assert_not_contains "$OUT" "AGENT TOOL GATE" "H6: an agents .test.ts alone does not fire the gate"

# H7 — a file merely NAMED like a route (foo-route.ts) does not fire: the
# trigger regex requires the /route.ts path segment.
H7=$(agent_tool_fixture); FIXTURES+=("$H7")
mkdir -p "$H7/apps/web/src/app/api/x"
echo "export const helper = 1;" > "$H7/apps/web/src/app/api/x/foo-route.ts"
git -C "$H7" add apps/web/src/app/api/x/foo-route.ts >/dev/null 2>&1
AGENT_TOOL_CHECK_CMD='echo "should never run"; exit 1' run_in "$H7" sh -e .husky/pre-commit
assert_not_contains "$OUT" "AGENT TOOL GATE" "H7: foo-route.ts does not match the /route.ts trigger"

# H8 — the wrapper missing from the WORKING TREE while a watched file is
# staged is a hard block (fail closed — a deleted wrapper must never
# silently disable the gate; the gate CODE runs from the working tree by
# the CMS-26/27 execution-model decision, so the working tree is what must
# be checked).
H8=$(agent_tool_fixture); FIXTURES+=("$H8")
echo "export const BASIC_TOOLS = [8];" > "$H8/apps/web/src/lib/agents/basic-tools.ts"
git -C "$H8" add apps/web/src/lib/agents/basic-tools.ts >/dev/null 2>&1
rm "$H8/scripts/check-agent-tools.sh"
AGENT_TOOL_CHECK_CMD='echo "should never run"; exit 1' run_in "$H8" sh -e .husky/pre-commit
assert_contains "$OUT" "AGENT TOOL GATE MISSING" "H8: a missing wrapper hard-blocks instead of silently skipping"

# H9 — a ROOT-LEVEL apps/web/src/app/api/route.ts fires the trigger too
# (audit finding F005: the original `.*/route\.ts$` regex required an
# intermediate slash and could never match a root route, even though the
# checker itself resolves `/api` exactly and T29b pins that shape).
H9=$(agent_tool_fixture); FIXTURES+=("$H9")
echo "export async function GET() { return null; }" > "$H9/apps/web/src/app/api/route.ts"
git -C "$H9" add apps/web/src/app/api/route.ts >/dev/null 2>&1
AGENT_TOOL_CHECK_CMD='echo "  ✗ root-route marker"; exit 1' run_in "$H9" sh -e .husky/pre-commit
assert_contains "$OUT" "AGENT TOOL GATE FAILED" "H9a: a root-level api/route.ts alone fires the gate"
assert_contains "$OUT" "root-route marker" "H9b: the stand-in ran on the root-route commit"

# H10 — a route.TSX edit alone fires the gate too (audit finding F005: the
# original trigger matched only route.ts, while the checker's own
# buildRouteTree treats route.tsx as a real route file).
H10=$(agent_tool_fixture); FIXTURES+=("$H10")
mkdir -p "$H10/apps/web/src/app/api/tsx-route"
echo "export async function GET() { return null; }" > "$H10/apps/web/src/app/api/tsx-route/route.tsx"
git -C "$H10" add apps/web/src/app/api/tsx-route/route.tsx >/dev/null 2>&1
AGENT_TOOL_CHECK_CMD='echo "  ✗ tsx-route marker"; exit 1' run_in "$H10" sh -e .husky/pre-commit
assert_contains "$OUT" "AGENT TOOL GATE FAILED" "H10a: a route.tsx edit alone fires the gate"
assert_contains "$OUT" "tsx-route marker" "H10b: the stand-in ran on the route.tsx commit"

# H11 — the AGENT_TOOL_CHECK_CMD override banner is visible on a PASSING
# run, not just a failing one (audit finding F007: the hook used to
# filter output to only ~/✗ lines, so a leftover override from a prior
# test session silently disabled the real check with zero commit-time
# signal — the exact defect class the PUBLIC SURFACE BEHAVIORAL gate
# above already fixed once in this same file).
H11=$(agent_tool_fixture); FIXTURES+=("$H11")
echo "export const BASIC_TOOLS = [11];" > "$H11/apps/web/src/lib/agents/basic-tools.ts"
git -C "$H11" add apps/web/src/lib/agents/basic-tools.ts >/dev/null 2>&1
AGENT_TOOL_CHECK_CMD='echo ok; exit 0' run_in "$H11" sh -e .husky/pre-commit
assert_contains "$OUT" "AGENT_TOOL_CHECK_CMD" "H11: the override banner is visible on the hook's PASSING path, not just its failing one"

echo ""
echo "Group I: assertApiKeyPresent anti-recurrence gate (4e, Task #10/ALFRED-19)"

# I1 — a staged local `function assertApiKeyPresent(...)` reimplementation in
# the watched file must be named in the block message.
I1=$(gate_fixture); FIXTURES+=("$I1")
mkdir -p "$I1/apps/web/src/lib/agents/providers"
cat > "$I1/apps/web/src/lib/agents/providers/openai-compatible-provider.ts" << 'EOF'
function assertApiKeyPresent(apiKey, envVarName, providerLabel) {
  if (!apiKey) throw new Error('nope');
}
EOF
git -C "$I1" add apps/web/src/lib/agents/providers/openai-compatible-provider.ts >/dev/null 2>&1
run_in "$I1" sh -e .husky/pre-commit
assert_contains "$OUT" "Local assertApiKeyPresent reimplementation" \
  "I1: staged function-form reimplementation is named in the block"

# I2 — the const-arrow-function form of the same reimplementation is caught
# too (the regex covers both function and const shapes).
I2=$(gate_fixture); FIXTURES+=("$I2")
mkdir -p "$I2/apps/web/src/lib/agents/providers"
cat > "$I2/apps/web/src/lib/agents/providers/openai-compatible-provider.ts" << 'EOF'
const assertApiKeyPresent = (apiKey, envVarName, providerLabel) => {
  if (!apiKey) throw new Error('nope');
};
EOF
git -C "$I2" add apps/web/src/lib/agents/providers/openai-compatible-provider.ts >/dev/null 2>&1
run_in "$I2" sh -e .husky/pre-commit
assert_contains "$OUT" "Local assertApiKeyPresent reimplementation" \
  "I2: staged const-arrow-form reimplementation is named in the block"

# I3 — the real, fixed shape (imported, not reimplemented) must NOT trigger
# this gate's message — proves the check isn't a blanket ban on the
# identifier appearing in the file (the import + call sites both mention it).
I3=$(gate_fixture); FIXTURES+=("$I3")
mkdir -p "$I3/apps/web/src/lib/agents/providers"
cat > "$I3/apps/web/src/lib/agents/providers/openai-compatible-provider.ts" << 'EOF'
import { assertApiKeyPresent } from '@ordinatio/agent';
export class OpenAICompatibleProvider {
  async chat() {
    assertApiKeyPresent(this.apiKey, this.apiKeyEnvVar, this.name);
  }
}
EOF
git -C "$I3" add apps/web/src/lib/agents/providers/openai-compatible-provider.ts >/dev/null 2>&1
run_in "$I3" sh -e .husky/pre-commit
assert_not_contains "$OUT" "Local assertApiKeyPresent reimplementation" \
  "I3: importing + calling the shared function does NOT trigger the gate"

# I4 — the same reimplementation pattern in a DIFFERENT, unwatched file must
# NOT trigger this gate (scope is this one specific file, by design — see
# ALFRED-36/37 in debt.md for the sibling files this gate deliberately
# doesn't cover yet).
I4=$(gate_fixture); FIXTURES+=("$I4")
mkdir -p "$I4/apps/web/src/lib/agents/providers"
cat > "$I4/apps/web/src/lib/agents/providers/claude-provider.ts" << 'EOF'
function assertApiKeyPresent(apiKey, envVarName, providerLabel) {
  if (!apiKey) throw new Error('nope');
}
EOF
git -C "$I4" add apps/web/src/lib/agents/providers/claude-provider.ts >/dev/null 2>&1
run_in "$I4" sh -e .husky/pre-commit
assert_not_contains "$OUT" "Local assertApiKeyPresent reimplementation" \
  "I4: the same pattern in a different, unwatched file does not trigger this gate"

echo ""
echo "Group J: SECURITY FIX EVIDENCE GATE self-deletion (Security section clause (a), 2026-08-26)"

# evidgate_fixture — same base as gate_fixture(), plus EVIDGATE's own 3
# infra files (real copies from this repo, matching the AGENT_TOOL_GATE
# fixture pattern above) and one registered security-sensitive file,
# committed as a second baseline commit specific to this group.
evidgate_fixture() {
  local d; d=$(gate_fixture)
  mkdir -p "$d/scripts" "$d/.autocode" "$d/packages/ordinatio-auth/src"
  cp "$SCRIPTS_DIR/security-fix-evidence-gate.sh" "$d/scripts/security-fix-evidence-gate.sh"
  printf '%s\n' "packages/ordinatio-auth/src/lockout.ts | auth | fixture registered file" > "$d/scripts/security-sensitive-paths.txt"
  printf '%s\n' \
    "# Security Gate Waivers" "" \
    "| Date | File(s) Touched | Why No Mechanical Check | Reviewed By |" \
    "|------|-----------------|--------------------------|-------------|" \
    > "$d/.autocode/security-gate-waivers.md"
  printf 'export function lockout() { return true; }\n' > "$d/packages/ordinatio-auth/src/lockout.ts"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m "evidgate baseline" >/dev/null 2>&1
  echo "$d"
}

# J1 — deleting all 3 EVIDGATE infra files WHILE ALSO weakening a
# registered security file, in the same commit, must HARD BLOCK — the
# exact kill-switch bypass a fifth WorldClass Architecture round found:
# with all 3 files gone, EVIDGATE_PRESENT hits neither the -eq 3 nor
# -gt 0 branch, so without the HEAD-existence check this used to be a
# silent no-op. "Existed at HEAD, gone now" must be distinguished from
# "never existed" and hard-fail.
J1=$(evidgate_fixture); FIXTURES+=("$J1")
echo "// weakening the real lockout logic" >> "$J1/packages/ordinatio-auth/src/lockout.ts"
git -C "$J1" rm -q scripts/security-fix-evidence-gate.sh scripts/security-sensitive-paths.txt .autocode/security-gate-waivers.md >/dev/null 2>&1
git -C "$J1" add -A >/dev/null 2>&1
run_in "$J1" sh -e .husky/pre-commit
assert_contains "$OUT" "SECURITY FIX EVIDENCE GATE DELETED" \
  "J1: deleting all 3 EVIDGATE files + weakening a registered file is hard-blocked, not silently skipped"
assert_contains "$OUT" "never silently disable itself" \
  "J1: block message names the self-disable risk explicitly"

# J2 — the benign counterpart: a fixture whose baseline commit NEVER
# included the 3 EVIDGATE files at all (an older worktree that hasn't
# pulled this feature yet) must NOT be blocked by EVIDGATE specifically
# — "never existed at HEAD" must stay a silent skip, not a new false
# positive introduced by J1's fix.
J2=$(gate_fixture); FIXTURES+=("$J2")
mkdir -p "$J2/packages/ordinatio-auth/src"
echo "export function lockout() { return true; }" > "$J2/packages/ordinatio-auth/src/lockout.ts"
git -C "$J2" add packages/ordinatio-auth/src/lockout.ts >/dev/null 2>&1
git -C "$J2" commit -q -m "pre-evidgate baseline, file never registered here" >/dev/null 2>&1
echo "// unrelated tweak, EVIDGATE infra never existed in this worktree" >> "$J2/packages/ordinatio-auth/src/lockout.ts"
git -C "$J2" add packages/ordinatio-auth/src/lockout.ts >/dev/null 2>&1
run_in "$J2" sh -e .husky/pre-commit
assert_not_contains "$OUT" "SECURITY FIX EVIDENCE GATE" \
  "J2: a worktree that never had EVIDGATE is not blocked by it (benign, not a false positive)"

# J3 — NARROWLY SCOPED, corrected after this test's own first version
# overclaimed what it actually proved (an eighth WorldClass Architecture
# round demonstrated the original claim — "self-tampering can't let the
# commit land silently" — is FALSE in general: it's defeated by a
# combined tamper touching .husky/pre-commit or classify-diff-size.sh
# themselves too, see GATE-1 in .autocode/debt.md). What THIS narrow
# case actually shows, and only this: a STAGED self-tampering edit to
# scripts/security-fix-evidence-gate.sh (inserting `exit 0` after the
# shebang) alongside a real weakening edit to a registered `packages/`
# file is still caught, in THIS specific fixture, because the target
# file's own path independently forces FULL tier via classify-diff-
# size.sh's PACKAGE_MATCH rule (unrelated to this gate) — NOT because
# self-tampering is generally caught. Do not read a PASS here as "the
# enforcer is tamper-resistant" — see J4 below for the actual fix this
# cycle shipped (index-execution, closing the UNSTAGED-tamper case
# specifically), and GATE-1 for what remains genuinely open.
J3=$(evidgate_fixture); FIXTURES+=("$J3")
echo "// weakening the real lockout logic" >> "$J3/packages/ordinatio-auth/src/lockout.ts"
sed -i '' '1a\
exit 0
' "$J3/scripts/security-fix-evidence-gate.sh"
git -C "$J3" add -A >/dev/null 2>&1
run_in "$J3" sh -e .husky/pre-commit
TESTS_RUN=$((TESTS_RUN+1))
if [ "$RC" -ne 0 ]; then
  echo "  ✓ J3: STAGED self-tamper + a packages/-path target is still blocked (by classify-diff-size.sh's PACKAGE_MATCH forcing FULL tier, not by EVIDGATE itself — narrow, not general)"; TESTS_PASS=$((TESTS_PASS+1))
else
  echo "  ✗ J3: staged self-tamper + a packages/-path target let the ENTIRE commit through with exit 0"; FAIL=1
fi

# J4 — the fix this cycle actually shipped: an UNSTAGED tamper to
# scripts/security-fix-evidence-gate.sh (never `git add`ed) alongside a
# registered file staged with zero evidence, where the registered file's
# own path does NOT independently force FULL tier (unlike J3's
# packages/ target) — the exact live bypass an eighth WorldClass Vibes
# round demonstrated: `.husky/pre-commit` used to run
# `bash scripts/security-fix-evidence-gate.sh` straight off the working
# tree, so an unstaged `exit 0` neutered EVIDGATE specifically while the
# rest of the commit sailed through on a legitimate DIRECT-tier gate
# artifact. Fixed by extracting and running the INDEX (staged) copy of
# this script — an unstaged edit is invisible to `git show ":path"`, so
# the real, un-tampered logic runs regardless. This is the ONE self-
# tampering variant this cycle can honestly claim to have closed — see
# J3 above and GATE-1 in .autocode/debt.md for what's still open.
J4=$(evidgate_fixture); FIXTURES+=("$J4")
mkdir -p "$J4/apps/web/src/lib"
printf 'export function x() { return true; }\n' > "$J4/apps/web/src/lib/publisher-auth.ts"
printf '%s\n' \
  "packages/ordinatio-auth/src/lockout.ts | auth | fixture registered file" \
  "apps/web/src/lib/publisher-auth.ts | auth | fixture DIRECT-tier registered file" \
  > "$J4/scripts/security-sensitive-paths.txt"
git -C "$J4" add -A >/dev/null 2>&1
git -C "$J4" commit -q -m "add a DIRECT-tier registered file" >/dev/null 2>&1
echo "// weakening the real publisher-auth logic" >> "$J4/apps/web/src/lib/publisher-auth.ts"
git -C "$J4" add apps/web/src/lib/publisher-auth.ts >/dev/null 2>&1
sed -i '' '1a\
exit 0
' "$J4/scripts/security-fix-evidence-gate.sh"
# Deliberately NOT staged — this is the unstaged-tamper case.
run_in "$J4" sh -e .husky/pre-commit
assert_contains "$OUT" "SECURITY FIX EVIDENCE GATE FAILED" \
  "J4: an UNSTAGED tamper to the gate script no longer neuters it — the index-executed copy still catches the DIRECT-tier target"

echo ""
echo "Group L: eval() check (7) — Redis-style .eval() false positive fix"
# WorldClass review of the fix that narrowed this check (originally a naive
# `eval(` substring match, false-positiving on a real
# `upstashRedis.eval(luaScript, keys, args)` Lua-script RPC call) found zero
# automated coverage existed for this specific check anywhere in this
# suite, despite the harness having a ready-made fixture pattern for it —
# closing that gap here. L1d (Task #294, confirming Batch-3 audit,
# 2026-09-17) covers the follow-up narrowing: the version this test group
# originally validated exempted EVERY `.eval(` method call (not just the
# real Redis one), so a hypothetical dangerous `.eval()`-shaped API on some
# other object would have gone completely unflagged.
L1=$(gate_fixture); FIXTURES+=("$L1")

# L1a — a genuine Redis-style `.eval(` method call must NOT be flagged.
echo 'await upstashRedis.eval(script, keys, args);' >> "$L1/src/foo.ts"
git -C "$L1" add src/foo.ts >/dev/null 2>&1
run_in "$L1" sh -e .husky/pre-commit
assert_not_contains "$OUT" "eval() found:" \
  "L1a: a real .eval() method call (Redis Lua-script RPC) is not flagged"
git -C "$L1" reset -q --hard HEAD >/dev/null 2>&1

# L1b — a bare/global eval() call must still be flagged.
echo 'const x = eval(userInput);' >> "$L1/src/foo.ts"
git -C "$L1" add src/foo.ts >/dev/null 2>&1
run_in "$L1" sh -e .husky/pre-commit
assert_contains "$OUT" "eval() found:" \
  "L1b: a bare eval(userInput) call is still flagged"
git -C "$L1" reset -q --hard HEAD >/dev/null 2>&1

# L1c — indirect-eval idioms (window./globalThis./global./self.eval) must
# still be flagged — an earlier draft of the L1a fix would have silently
# dropped this real, pre-existing coverage (caught by independent review,
# not self-discovered).
echo 'globalThis.eval(userInput);' >> "$L1/src/foo.ts"
git -C "$L1" add src/foo.ts >/dev/null 2>&1
run_in "$L1" sh -e .husky/pre-commit
assert_contains "$OUT" "eval() found:" \
  "L1c: globalThis.eval(userInput) (indirect-eval idiom) is still flagged"
git -C "$L1" reset -q --hard HEAD >/dev/null 2>&1

# L1c2/L1c3/L1c4 (WorldClass Vibes cycle-1 finding, severity 3): the header
# comment above claims all 4 indirect-eval forms — window./globalThis./
# global./self.eval — are "verified in all directions," but only
# globalThis.eval had a dedicated test (L1c above); the other 3 were
# verified by inspection only. Closing that gap for real rather than just
# softening the comment's claim.
for form in window global self; do
  echo "${form}.eval(userInput);" >> "$L1/src/foo.ts"
  git -C "$L1" add src/foo.ts >/dev/null 2>&1
  run_in "$L1" sh -e .husky/pre-commit
  assert_contains "$OUT" "eval() found:" \
    "L1c (${form}): ${form}.eval(userInput) (indirect-eval idiom) is still flagged"
  git -C "$L1" reset -q --hard HEAD >/dev/null 2>&1
done

# L1d (Task #294) — a NON-Redis `.eval()`-shaped call on some other object
# must still be flagged. Before this task's fix, the check's exemption
# covered every `.eval(` method call regardless of which object it was
# called on — this proves the narrowing to the one recognized
# `upstashRedis.eval(` form is real, not just claimed.
echo 'sandbox.eval(userSuppliedCode);' >> "$L1/src/foo.ts"
git -C "$L1" add src/foo.ts >/dev/null 2>&1
run_in "$L1" sh -e .husky/pre-commit
assert_contains "$OUT" "eval() found:" \
  "L1d: sandbox.eval(userSuppliedCode) (non-Redis .eval() call) is flagged"
git -C "$L1" reset -q --hard HEAD >/dev/null 2>&1

echo ""
echo "Group L2: eval() check sibling coverage (Task #294 cycle-2, WorldClass Architecture finding, severity 5)"
# WorldClass cycle-2 review found the 3 newly-fixed sibling eval checks
# (shipping-gate.sh, ci.yml, security-scan.yml) had zero PERMANENT
# regression-test coverage — verified only by ad hoc manual fixture runs
# during the review itself, the same "nobody would notice future drift"
# defect class that caused the original problem (these siblings silently
# drifting out of sync with .husky/pre-commit in the first place). Each
# test below PINS the real file's exact pipeline text (a drift-guard
# assertion, failing loudly if a future edit changes the logic without
# updating this test) AND separately executes the real logic against a
# fresh safe+unsafe fixture.

evalgate_fixture() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/apps/x" "$d/packages/y"
  printf 'await upstashRedis.eval(script, keys, args);\n' > "$d/apps/x/safe.ts"
  printf 'sandbox.eval(userSuppliedCode);\n' > "$d/apps/x/danger.ts"
  echo "$d"
}

# assert_pinned_line <file> <exact literal line> <label> — fixed-string
# (-F) containment check, reported via assert_eq. assert_contains's own
# grep call is NOT -F (see its definition above): a pinned pipeline
# containing literal `\(` reads as an unbalanced BRE group to plain
# `grep -q`, which fails hard ("parentheses not balanced") rather than
# just not matching — discovered by running this exact test live, not
# assumed.
#
# The 3 pinned-pipeline strings passed to this helper below are
# deliberately NOT unified into one shared constant (WorldClass cycle-2
# Vibes finding, disclosed not fixed; comment placement corrected in
# cycle-3/final review — belongs here, next to the helper that consumes
# them, not above the unrelated fixture generator): each one pins its OWN
# file's real, distinct syntax verbatim (shipping-gate.sh's parameterized
# `"$TARGET_DIR"`; ci.yml's/security-scan.yml's hardcoded `apps/ packages/`,
# different double/single-quote conventions per file). A synthetic shared
# constant would have to average across these real differences, which would
# make the pin LESS precise — a drift in any one file's exact syntax is
# exactly what these tests exist to catch, and only a byte-exact per-file
# pin can catch it.
assert_pinned_line() {
  local FOUND
  if grep -qF -- "$2" "$1" 2>/dev/null; then
    FOUND="present"
  else
    FOUND="MISSING"
  fi
  assert_eq "$FOUND" "present" "$3"
}

# L2 — shipping-gate.sh's own eval() count correctly narrows to the
# dangerous line only.
E1=$(evalgate_fixture); FIXTURES+=("$E1")
assert_pinned_line "$SCRIPTS_DIR/shipping-gate.sh" \
  "count=\$(grep -rEn 'eval\\(' \"\$TARGET_DIR\" --include='*.ts' --include='*.tsx' 2>/dev/null | grep -v '\\.test\\.' | sed -E 's/([^A-Za-z0-9_$]|^)upstashRedis\\.eval\\(/\\1/g' | grep -cE 'eval\\(' | tr -d ' ')" \
  "L2 drift-guard: shipping-gate.sh's real eval() pipeline still matches the pinned copy this test executes"
SHIPGATE_OUT=$(bash "$SCRIPTS_DIR/shipping-gate.sh" "$E1" 2>&1)
assert_contains "$SHIPGATE_OUT" "eval(): 1 " \
  "L2: shipping-gate.sh counts exactly 1 real eval() hit (sandbox.eval), not the safe upstashRedis.eval line"

# L3 — .github/workflows/ci.yml's eval-check `if` pipeline: pin + execute
# the real logic directly (a real GitHub Actions run can't be exercised
# from this harness). Reads via $REPO_ROOT, not a bare relative path — the
# whole suite's own CWD is a neutral mktemp dir (see NEUTRAL above), not
# this repo checkout.
assert_pinned_line "$REPO_ROOT/.github/workflows/ci.yml" \
  "if grep -rEn 'eval\\(' --include=\"*.ts\" --include=\"*.tsx\" --include=\"*.js\" apps/ packages/ 2>/dev/null | grep -v \"node_modules\" | grep -v \".test.\" | grep -v \"__mocks__\" | sed -E 's/([^A-Za-z0-9_$]|^)upstashRedis\\.eval\\(/\\1/g' | grep -qE 'eval\\('; then" \
  "L3 drift-guard: ci.yml's real eval() pipeline still matches the pinned copy this test executes"
E2=$(evalgate_fixture); FIXTURES+=("$E2")
# WorldClass cycle-3 finding: a bare boolean (matched/didn't-match) doesn't
# independently prove the "exempts the safe line" half of this test's own
# claim — a regression that flagged BOTH lines (e.g. the `sed`-based
# exclusion silently breaking) would still read as "FLAGGED" and pass.
# Matching L2/L4's stronger exact-count pattern: assert exactly 1 match AND
# that the safe line's own text never survives into the matched output.
CI_MATCHES=$(cd "$E2" && grep -rEn 'eval\(' --include="*.ts" --include="*.tsx" --include="*.js" apps/ packages/ 2>/dev/null | grep -v "node_modules" | grep -v ".test." | grep -v "__mocks__" | sed -E 's/([^A-Za-z0-9_$]|^)upstashRedis\.eval\(/\1/g' | grep -E 'eval\(')
CI_COUNT=$(echo "$CI_MATCHES" | grep -c .)
assert_eq "$CI_COUNT" "1" \
  "L3: ci.yml's real pipeline flags exactly 1 line (the dangerous sandbox.eval one) — not 0, not 2"
assert_not_contains "$CI_MATCHES" "upstashRedis" \
  "L3: ci.yml's real pipeline output never includes the safe upstashRedis.eval() line"

# L4 — .github/workflows/security-scan.yml's EVAL_COUNT pipeline: pin +
# execute the real logic directly.
assert_pinned_line "$REPO_ROOT/.github/workflows/security-scan.yml" \
  "EVAL_COUNT=\$(grep -rEn 'eval\\(' --include=\"*.ts\" --include=\"*.tsx\" --include=\"*.js\" apps/ packages/ 2>/dev/null | grep -v \"node_modules\" | grep -v \".test.\" | sed -E 's/([^A-Za-z0-9_$]|^)upstashRedis\\.eval\\(/\\1/g' | grep -cE 'eval\\(' || echo \"0\")" \
  "L4 drift-guard: security-scan.yml's real eval() pipeline still matches the pinned copy this test executes"
E3=$(evalgate_fixture); FIXTURES+=("$E3")
SECSCAN_COUNT=$( (cd "$E3" && grep -rEn 'eval\(' --include="*.ts" --include="*.tsx" --include="*.js" apps/ packages/ 2>/dev/null | grep -v "node_modules" | grep -v ".test." | sed -E 's/([^A-Za-z0-9_$]|^)upstashRedis\.eval\(/\1/g' | grep -cE 'eval\(' || echo "0") | tr -d ' ')
assert_eq "$SECSCAN_COUNT" "1" \
  "L4: security-scan.yml's real pipeline counts exactly 1 dangerous eval() hit"

echo ""
echo "Group L5: eval() check composite-line fix (Task #302, SECOND confirming Batch-3 audit, 2026-09-18)"
# Red Agent R + Agent A (second confirming round) live-reproduced a real gap:
# the OLD `grep -vE 'upstashRedis\.eval\('` exclusion discarded the WHOLE
# LINE on a match, so a single line containing BOTH the exempted Redis call
# AND a separate dangerous eval()-shaped call was silently dropped in its
# entirety — the dangerous call escaped detection. Fixed by stripping only
# the matched safe substring (via `sed`) before re-checking for a remaining
# `eval(` occurrence, instead of discarding the whole line.
#
# Task #314 (THIRD confirming Batch-3 audit, 2026-09-18, Agents K/V/B, 3x
# independently convergent, mutation-verified): this group's own header used
# to claim it "reproduces the exact composite-line case against the real
# hook and all 3 siblings, proving the fix" — false for 2 of the 4 real
# targets. `.husky/pre-commit` (the real hook) and `shipping-gate.sh` ARE
# genuinely exercised (a real `sh -e` hook run, and a real
# `bash shipping-gate.sh` invocation, respectively). But the OLD `CI_COMBO`
# assertion below re-ran a hand-typed literal copy of ci.yml's pipeline
# with NO pin tying it back to the file's real content — reverting ci.yml's
# actual fix left `CI_COMBO` green (mutation-verified: only Group L2-L4's
# OWN, separate pin caught a full revert; this group's own claim to prove
# ci.yml's fix was false in isolation). `security-scan.yml` — the 4th real
# target, not even named in the old "3 siblings" count — had ZERO
# composite-line coverage anywhere in this suite; reverting its real fix
# produced zero failures. Fixed by giving THIS group its own self-contained
# pin (not relying on Group L2-L4 running first, or existing at all) for
# BOTH ci.yml and security-scan.yml, mirroring L3/L4's own
# pin-then-execute technique, plus a new composite-line execution test for
# security-scan.yml.
#
# Disclosed residual limitation (WorldClass cycle-1 Architecture finding,
# severity 5): the pin string and the executed pipeline string below are
# two SEPARATELY hand-typed literals — the pin only proves the real file
# contains that exact text; nothing mechanically ties the pin argument to
# the executed command a few lines later, so an edit to one without the
# other could silently drift undetected. Same inherited shape as L2-L4's
# own pin-to-pin duplication (see that group's own "not unified into one
# shared constant" comment above) — not introduced here, not fixed here,
# named explicitly rather than implied by the "(pin-verified)"-style
# wording this diff originally used on the assertion labels below (now
# removed as overclaiming a stronger guarantee than the mechanism gives).
#
# Also disclosed: CI_COMBO and SECSCAN_COMBO deliberately differ in
# assertion strength (content-check vs. exact-count) — not an oversight.
# ci.yml's real pipeline output is the actual matched line text, so
# asserting the dangerous substring survived is possible; security-scan.yml's
# real pipeline collapses straight to a bare EVAL_COUNT integer, so a count
# check is the strongest assertion its real output shape allows. The old
# buggy exclusion would still produce EVAL_COUNT=0 on this composite-line
# fixture (whole line dropped); the fixed one produces 1 — genuinely
# discriminating, not weaker just because it looks different from CI_COMBO.
L5=$(gate_fixture); FIXTURES+=("$L5")
echo 'sandbox.eval(userSuppliedCode); const x = upstashRedis.eval(script, keys, args);' >> "$L5/src/foo.ts"
git -C "$L5" add src/foo.ts >/dev/null 2>&1
run_in "$L5" sh -e .husky/pre-commit
assert_contains "$OUT" "eval() found:" \
  "L5: .husky/pre-commit flags a composite line (safe upstashRedis.eval + dangerous sandbox.eval on the same line) — the exact live-reproduced Task #302 bug"
git -C "$L5" reset -q --hard HEAD >/dev/null 2>&1

E4=$(mktemp -d); FIXTURES+=("$E4")
mkdir -p "$E4/apps/x"
printf 'sandbox.eval(userSuppliedCode); const x = upstashRedis.eval(script, keys, args);\n' > "$E4/apps/x/combo.ts"
SHIPGATE_COMBO=$(bash "$SCRIPTS_DIR/shipping-gate.sh" "$E4" 2>&1)
assert_contains "$SHIPGATE_COMBO" "eval(): 1 " \
  "L5: shipping-gate.sh flags the same composite-line case (1 real hit, not 0)"

# ci.yml — SELF-CONTAINED pin (not reused from Group L2-L4 above; this
# group must prove its own claim without depending on another group's
# test running first or still existing) tying the hand-typed pipeline
# text below to ci.yml's ACTUAL real content, then SEPARATELY execute a
# hand-typed reconstruction of that same pipeline against the fixture
# (see the disclosed pin-vs-execution-string limitation above).
assert_pinned_line "$REPO_ROOT/.github/workflows/ci.yml" \
  "if grep -rEn 'eval\\(' --include=\"*.ts\" --include=\"*.tsx\" --include=\"*.js\" apps/ packages/ 2>/dev/null | grep -v \"node_modules\" | grep -v \".test.\" | grep -v \"__mocks__\" | sed -E 's/([^A-Za-z0-9_$]|^)upstashRedis\\.eval\\(/\\1/g' | grep -qE 'eval\\('; then" \
  "L5 drift-guard: ci.yml's real eval() pipeline still matches the pinned copy this group's own composite-line test executes"
CI_COMBO=$(cd "$E4" && grep -rEn 'eval\(' --include="*.ts" --include="*.tsx" --include="*.js" apps/ packages/ 2>/dev/null | grep -v "node_modules" | grep -v ".test." | grep -v "__mocks__" | sed -E 's/([^A-Za-z0-9_$]|^)upstashRedis\.eval\(/\1/g' | grep -E 'eval\(')
assert_contains "$CI_COMBO" "sandbox.eval" \
  "L5: ci.yml's real pipeline (pin checked above) flags the same composite-line case"

# security-scan.yml — the 4th real sibling this group previously named
# zero coverage for at all. Same self-contained pin-then-execute
# technique as ci.yml above.
assert_pinned_line "$REPO_ROOT/.github/workflows/security-scan.yml" \
  "EVAL_COUNT=\$(grep -rEn 'eval\\(' --include=\"*.ts\" --include=\"*.tsx\" --include=\"*.js\" apps/ packages/ 2>/dev/null | grep -v \"node_modules\" | grep -v \".test.\" | sed -E 's/([^A-Za-z0-9_$]|^)upstashRedis\\.eval\\(/\\1/g' | grep -cE 'eval\\(' || echo \"0\")" \
  "L5 drift-guard: security-scan.yml's real eval() pipeline still matches the pinned copy this group's own composite-line test executes"
SECSCAN_COMBO=$( (cd "$E4" && grep -rEn 'eval\(' --include="*.ts" --include="*.tsx" --include="*.js" apps/ packages/ 2>/dev/null | grep -v "node_modules" | grep -v ".test." | sed -E 's/([^A-Za-z0-9_$]|^)upstashRedis\.eval\(/\1/g' | grep -cE 'eval\(' || echo "0") | tr -d ' ')
assert_eq "$SECSCAN_COMBO" "1" \
  "L5: security-scan.yml's real pipeline (pin checked above) counts exactly 1 dangerous eval() hit on the composite-line case"

echo ""
echo "Group N: git-INDEX vs working-tree bypass fix (Task #313, THIRD confirming Batch-3 audit, 2026-09-18)"
# Live-reproduced bug: EVAL_HITS, CATCH_BLOCK_ERRORS, HTML_HITS, and the
# WORKER_FILES/org.findFirst check all used to read a candidate file's
# content straight off DISK (`grep ... "$f"`), never the STAGED/indexed
# content `git diff --cached` actually reports for the commit under
# review. Reproduction technique for each check below: stage dangerous
# content, then overwrite the WORKING-TREE copy with safe content WITHOUT
# re-staging (no further `git add`) — before this task's fix, the hook
# read the safe on-disk content and silently let the dangerous STAGED
# content through. Each check also gets a sanity companion proving the
# opposite direction: a working-tree-only edit that was never staged at
# all must NOT trip the gate — these checks intentionally only ever look
# at what is staged, nothing else.

# N1 — bare catch {} block bypass (CATCH_BLOCK_ERRORS)
N1=$(gate_fixture); FIXTURES+=("$N1")
printf 'function f() { try { risky(); } catch {} }\n' >> "$N1/src/foo.ts"
git -C "$N1" add src/foo.ts >/dev/null 2>&1
printf 'export const x = 1;\nfunction f() { try { risky(); } catch (e) { console.error(e); } }\n' > "$N1/src/foo.ts"
run_in "$N1" sh -e .husky/pre-commit
assert_contains "$OUT" "BARE CATCH BLOCKS" \
  "N1a: a STAGED empty catch {} is still caught even when the working-tree copy is reverted to safe content unstaged — the exact live-reproduced Task #313 bypass"
git -C "$N1" reset -q --hard HEAD >/dev/null 2>&1

printf 'function f() { try { risky(); } catch {} }\n' >> "$N1/src/foo.ts"
run_in "$N1" sh -e .husky/pre-commit
assert_not_contains "$OUT" "BARE CATCH BLOCKS" \
  "N1b: an unstaged-only empty catch {} (never staged) does not trip the gate — it only ever reads the index"
git -C "$N1" reset -q --hard HEAD >/dev/null 2>&1

# N2 — organization.findFirst in worker code bypass (WORKER_FILES/ORG_HITS)
N2=$(gate_fixture); FIXTURES+=("$N2")
mkdir -p "$N2/apps/worker/src"
printf 'export const x = 1;\n' > "$N2/apps/worker/src/thing.ts"
git -C "$N2" add apps/worker/src/thing.ts >/dev/null 2>&1
git -C "$N2" commit -q -m "add worker file" >/dev/null 2>&1
printf 'export const x = 1;\nconst org = await prisma.organization.findFirst();\n' > "$N2/apps/worker/src/thing.ts"
git -C "$N2" add apps/worker/src/thing.ts >/dev/null 2>&1
printf 'export const x = 1;\n' > "$N2/apps/worker/src/thing.ts"
run_in "$N2" sh -e .husky/pre-commit
assert_contains "$OUT" "organization.findFirst() in worker code" \
  "N2a: a STAGED organization.findFirst() in worker code is still caught even when the working-tree copy is reverted unstaged — the exact live-reproduced Task #313 bypass"
git -C "$N2" reset -q --hard HEAD >/dev/null 2>&1

printf 'export const x = 1;\nconst org = await prisma.organization.findFirst();\n' > "$N2/apps/worker/src/thing.ts"
run_in "$N2" sh -e .husky/pre-commit
assert_not_contains "$OUT" "organization.findFirst() in worker code" \
  "N2b: an unstaged-only organization.findFirst() (never staged) does not trip the gate"
git -C "$N2" reset -q --hard HEAD >/dev/null 2>&1

# N3 — dangerouslySetInnerHTML bypass (HTML_HITS)
N3=$(gate_fixture); FIXTURES+=("$N3")
printf 'export const x = 1;\n' > "$N3/src/comp.tsx"
git -C "$N3" add src/comp.tsx >/dev/null 2>&1
git -C "$N3" commit -q -m "add tsx file" >/dev/null 2>&1
printf 'export const x = 1;\nconst el = <div dangerouslySetInnerHTML={{__html: userInput}} />;\n' > "$N3/src/comp.tsx"
git -C "$N3" add src/comp.tsx >/dev/null 2>&1
printf 'export const x = 1;\n' > "$N3/src/comp.tsx"
run_in "$N3" sh -e .husky/pre-commit
assert_contains "$OUT" "dangerouslySetInnerHTML found" \
  "N3a: a STAGED dangerouslySetInnerHTML is still caught even when the working-tree copy is reverted unstaged — the exact live-reproduced Task #313 bypass"
git -C "$N3" reset -q --hard HEAD >/dev/null 2>&1

printf 'export const x = 1;\nconst el = <div dangerouslySetInnerHTML={{__html: userInput}} />;\n' > "$N3/src/comp.tsx"
run_in "$N3" sh -e .husky/pre-commit
assert_not_contains "$OUT" "dangerouslySetInnerHTML found" \
  "N3b: an unstaged-only dangerouslySetInnerHTML (never staged) does not trip the gate"
git -C "$N3" reset -q --hard HEAD >/dev/null 2>&1

# N4 — eval() bypass (EVAL_HITS) — the ORIGINAL live-reproduced finding
# that opened Task #313 (Agent W, independently reproduced by the
# orchestrating session with a working exploit before this task started).
N4=$(gate_fixture); FIXTURES+=("$N4")
printf 'const x = eval(userInput);\n' >> "$N4/src/foo.ts"
git -C "$N4" add src/foo.ts >/dev/null 2>&1
printf 'export const x = 1;\n' > "$N4/src/foo.ts"
run_in "$N4" sh -e .husky/pre-commit
assert_contains "$OUT" "eval() found:" \
  "N4a: a STAGED bare eval(userInput) is still caught even when the working-tree copy is reverted to safe content unstaged — the exact live-reproduced Task #313 bypass"
git -C "$N4" reset -q --hard HEAD >/dev/null 2>&1

printf 'const x = eval(userInput);\n' >> "$N4/src/foo.ts"
run_in "$N4" sh -e .husky/pre-commit
assert_not_contains "$OUT" "eval() found:" \
  "N4b: an unstaged-only eval(userInput) (never staged) does not trip the gate"
git -C "$N4" reset -q --hard HEAD >/dev/null 2>&1

echo ""
echo "Group M: GETSESSION FIELD-PARITY GATE wiring (Task #295, confirming batch-3 audit finding, 2026-09-17)"
# scripts/check-getsession-field-parity.sh (Task #288) was a real, passing
# script wired into NEITHER .husky/pre-commit NOR CI — confirmed via a
# repo-wide grep returning zero references anywhere outside its own file.
# Task #295 wires it in as an unconditional gate, matching
# security-binding-gate.sh's own proven presence-check + self-deletion-
# guard shape. These tests prove the wiring actually fires and blocks a
# real commit on a deliberately-reintroduced drift, not just that the
# standalone script behaves correctly in isolation.

# paritygate_fixture — same base as gate_fixture(), plus a minimal
# apps/web/src/lib/agent-delegation-auth.ts (all 9 fields the real file's
# JSDoc claims), one real API route reading both .role and .name off a
# session, and one bystander route that reads NEITHER (so the api/ tree
# genuinely survives deletion of the whoami route in M6 below — without
# it, deleting the only file under apps/web/src/app/api/ collapses the
# whole directory and trips the script's OWN "tree may have moved" guard
# instead of its intended "no real reader route left" failure path, a
# real bug found and fixed while building M6, live-run not assumed).
paritygate_fixture() {
  local d; d=$(gate_fixture)
  mkdir -p "$d/scripts" "$d/apps/web/src/lib" "$d/apps/web/src/app/api/whoami" "$d/apps/web/src/app/api/health"
  cp "$SCRIPTS_DIR/check-getsession-field-parity.sh" "$d/scripts/check-getsession-field-parity.sh"
  printf '%s\n' \
    'export async function resolveDelegationSession() {' \
    '  return {' \
    '    session: { session: {} },' \
    '    user: {' \
    '      id: "u1",' \
    '      email: "u1@example.com",' \
    '      emailVerified: true,' \
    '      name: "U One",' \
    '      image: null,' \
    '      role: "OWNER",' \
    '      isActive: true,' \
    '      createdAt: new Date(),' \
    '      updatedAt: new Date(),' \
    '    },' \
    '  };' \
    '}' \
    > "$d/apps/web/src/lib/agent-delegation-auth.ts"
  printf '%s\n' \
    'export async function GET() {' \
    '  const session = await getSession();' \
    '  return Response.json({ role: session?.user?.role, name: session?.user?.name });' \
    '}' \
    > "$d/apps/web/src/app/api/whoami/route.ts"
  printf '%s\n' \
    'export async function GET() {' \
    '  return Response.json({ status: "ok" });' \
    '}' \
    > "$d/apps/web/src/app/api/health/route.ts"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m "paritygate baseline" >/dev/null 2>&1
  echo "$d"
}

M1=$(paritygate_fixture); FIXTURES+=("$M1")

# M1 — baseline: both claims genuinely hold, gate must NOT fire on an
# unrelated staged file.
echo 'export const y = 2;' >> "$M1/src/foo.ts"
git -C "$M1" add src/foo.ts >/dev/null 2>&1
run_in "$M1" sh -e .husky/pre-commit
assert_not_contains "$OUT" "GETSESSION FIELD-PARITY GATE FAILED" \
  "M1: baseline (all claimed fields present, real .role/.name readers exist) does not fail the gate"
git -C "$M1" reset -q --hard HEAD >/dev/null 2>&1

# M2 — THE core proof this task's own acceptance criteria demands: a
# deliberately-reintroduced drift (dropping the `role:` field the JSDoc
# claims resolveDelegationSession populates) must make the HOOK ITSELF
# refuse the commit — not just the standalone script exit non-zero in
# isolation. `sed -i.bak` + `rm -f *.bak` (not `sed -i ''`): the latter is
# BSD-only and silently no-ops (leaving the file untouched, then failing
# both assertions with a misattributed message) under GNU sed — verified
# live against a real `gsed` 4.10 install, matching the portable idiom
# this repo's own test-rule16-gate.sh/test-war-room-redaction-gate.sh
# already established (WorldClass Architecture finding).
sed -i.bak '/role: "OWNER",/d' "$M1/apps/web/src/lib/agent-delegation-auth.ts"
rm -f "$M1/apps/web/src/lib/agent-delegation-auth.ts.bak"
git -C "$M1" add apps/web/src/lib/agent-delegation-auth.ts >/dev/null 2>&1
run_in "$M1" sh -e .husky/pre-commit
assert_contains "$OUT" "GETSESSION FIELD-PARITY GATE FAILED" \
  "M2: dropping the claimed 'role' field from resolveDelegationSession makes the HOOK refuse the commit"
assert_contains "$OUT" "no longer sets these fields" \
  "M2: the block names the real script output, not a generic message"
git -C "$M1" reset -q --hard HEAD >/dev/null 2>&1

# M3 (WorldClass Architecture finding, severity 6) — restore proof: once
# the drift is reverted AND something is genuinely staged (this gate is
# UNCONDITIONAL — it must fire even when the drift itself isn't what's
# staged), the SAME hook run on the SAME fixture passes clean again. The
# original version of this test staged nothing after the reset, so
# .husky/pre-commit's own top-level early exit (empty $STAGED and
# $STAGED_DELETED) fired before the parity gate ever ran — a vacuous pass
# that proved nothing about the gate re-evaluating the restored file,
# reproduced live before this fix (a fresh hook run with nothing staged
# exits 0 with empty output, never reaching any gate logic). Staging an
# unrelated file forces a genuine re-evaluation.
echo 'export const w = 4;' >> "$M1/src/foo.ts"
git -C "$M1" add src/foo.ts >/dev/null 2>&1
run_in "$M1" sh -e .husky/pre-commit
assert_not_contains "$OUT" "GETSESSION FIELD-PARITY GATE" \
  "M3: after reverting the drift, staging an unrelated file still passes clean (the gate genuinely re-evaluated the restored file, not an early-exit no-op)"
git -C "$M1" reset -q --hard HEAD >/dev/null 2>&1

# M4 — self-deletion guard: the script existed at HEAD but is deleted in
# this commit (with nothing else staged to mask it) must hard-block, the
# same kill-switch protection EVIDGATE/BINDGATE already have (Group J).
git -C "$M1" rm -q scripts/check-getsession-field-parity.sh >/dev/null 2>&1
run_in "$M1" sh -e .husky/pre-commit
assert_contains "$OUT" "GETSESSION FIELD-PARITY GATE DELETED" \
  "M4: deleting the gate script (existed at HEAD) hard-blocks instead of silently disabling"
git -C "$M1" reset -q --hard HEAD >/dev/null 2>&1

# M5 — a fixture that never adopted this gate (script never existed at
# HEAD, matching an older worktree) must NOT be blocked — benign skip.
M5=$(gate_fixture); FIXTURES+=("$M5")
echo 'export const z = 3;' >> "$M5/src/foo.ts"
git -C "$M5" add src/foo.ts >/dev/null 2>&1
run_in "$M5" sh -e .husky/pre-commit
assert_not_contains "$OUT" "GETSESSION FIELD-PARITY GATE" \
  "M5: a fixture that never adopted this gate is not blocked by it (benign, not a false positive)"

# M6 (WorldClass Vibes finding, severity 4) — M1-M5 only drift-test Claim 1
# (a field dropped from resolveDelegationSession). The gate's own header
# comment names BOTH of the script's claims as "the actual failure modes"
# justifying an unconditional trigger, but nothing exercised Claim 2 (the
# last real .role/.name-reading route being deleted) through the real
# hook. Closing that gap: delete the fixture's only route that reads
# session.user.role/.name — the hook itself must refuse the commit.
M6=$(paritygate_fixture); FIXTURES+=("$M6")
git -C "$M6" rm -q apps/web/src/app/api/whoami/route.ts >/dev/null 2>&1
run_in "$M6" sh -e .husky/pre-commit
assert_contains "$OUT" "GETSESSION FIELD-PARITY GATE FAILED" \
  "M6: deleting the last real .role/.name-reading route makes the HOOK refuse the commit (Claim 2, not just Claim 1)"
assert_contains "$OUT" "no real route under" \
  "M6: the block names the real Claim-2 script output, not a generic message"
git -C "$M6" reset -q --hard HEAD >/dev/null 2>&1

# M7 (Task #303, SECOND confirming Batch-3 audit, 2026-09-18) — the
# staged-vs-working-tree divergence case: both the gate SCRIPT and the
# TARGET files it reads (agent-delegation-auth.ts, the api/ route tree)
# were rewritten to read from the git INDEX, not the working tree,
# matching the FFF/WorldClass gate's own established convention. These
# tests prove that choice is load-bearing, not decorative — a case none
# of M1-M6 exercised.
M7=$(paritygate_fixture); FIXTURES+=("$M7")

# M7a — STAGE a broken version (role: field dropped), then restore the
# WORKING TREE back to the good version WITHOUT re-staging. If the gate
# read the working tree, it would see the good content and wrongly pass;
# reading the index, it must still see the staged (broken) content and
# fail.
sed -i.bak '/role: "OWNER",/d' "$M7/apps/web/src/lib/agent-delegation-auth.ts"
rm -f "$M7/apps/web/src/lib/agent-delegation-auth.ts.bak"
git -C "$M7" add apps/web/src/lib/agent-delegation-auth.ts >/dev/null 2>&1
git -C "$M7" checkout -- apps/web/src/lib/agent-delegation-auth.ts 2>/dev/null
# checkout without --staged restores the working tree from the INDEX
# (which now holds the broken version) — re-apply the good content
# directly to the working tree only, leaving the index broken.
printf '%s\n' \
  'export async function resolveDelegationSession() {' \
  '  return {' \
  '    session: { session: {} },' \
  '    user: {' \
  '      id: "u1",' \
  '      email: "u1@example.com",' \
  '      emailVerified: true,' \
  '      name: "U One",' \
  '      image: null,' \
  '      role: "OWNER",' \
  '      isActive: true,' \
  '      createdAt: new Date(),' \
  '      updatedAt: new Date(),' \
  '    },' \
  '  };' \
  '}' \
  > "$M7/apps/web/src/lib/agent-delegation-auth.ts"
run_in "$M7" sh -e .husky/pre-commit
assert_contains "$OUT" "GETSESSION FIELD-PARITY GATE FAILED" \
  "M7a: a BROKEN staged version fails the gate even though the working tree has since been restored to the good version — index wins, not working tree"
git -C "$M7" reset -q --hard HEAD >/dev/null 2>&1

# M7b — the inverse: STAGE the good version (already true at HEAD), then
# break the WORKING TREE copy only (unstaged edit, never added). If the
# gate read the working tree, it would wrongly fail on an edit that was
# never actually committed; reading the index, it must still see the
# staged (good) content and pass.
sed -i.bak '/role: "OWNER",/d' "$M7/apps/web/src/lib/agent-delegation-auth.ts"
rm -f "$M7/apps/web/src/lib/agent-delegation-auth.ts.bak"
echo 'export const w2 = 5;' >> "$M7/src/foo.ts"
git -C "$M7" add src/foo.ts >/dev/null 2>&1
run_in "$M7" sh -e .husky/pre-commit
assert_not_contains "$OUT" "GETSESSION FIELD-PARITY GATE FAILED" \
  "M7b: an UNSTAGED break to the working-tree copy does not fail the gate — the staged (good) index content is what's evaluated, matching what's actually being committed"
git -C "$M7" reset -q --hard HEAD >/dev/null 2>&1

echo ""
echo "Group O: pre-existing textual-match bypass fixes (Task #317, THIRD confirming Batch-3 audit, 2026-09-18)"
# Three real, pre-existing bypasses found convergently by Red Agent R and
# Agent S — see the header comments in check-getsession-field-parity.sh
# (Bypasses #1/#2) and .husky/pre-commit's EVAL_HITS block (Bypass #3) for
# the full rationale. Each test below reproduces the exact bypass shape
# against the real script/hook and proves it is now closed.

# O1 — Bypass #1: a dead/unused field elsewhere in the file (outside
# resolveDelegationSession's own body) used to satisfy Claim 1 without the
# real synthetic object ever setting it. This fixture's real function body
# genuinely OMITS `role:`, but an unrelated dead type declaration elsewhere
# in the same file still contains the literal text `role:` — before this
# task's fix, the whole-file grep would find it there and wrongly pass.
O1=$(paritygate_fixture); FIXTURES+=("$O1")
printf '%s\n' \
  'interface UnrelatedDeadType {' \
  '  role: string;' \
  '}' \
  '' \
  'export async function resolveDelegationSession() {' \
  '  return {' \
  '    session: { session: {} },' \
  '    user: {' \
  '      id: "u1",' \
  '      email: "u1@example.com",' \
  '      emailVerified: true,' \
  '      name: "U One",' \
  '      image: null,' \
  '      isActive: true,' \
  '      createdAt: new Date(),' \
  '      updatedAt: new Date(),' \
  '    },' \
  '  };' \
  '}' \
  > "$O1/apps/web/src/lib/agent-delegation-auth.ts"
git -C "$O1" add apps/web/src/lib/agent-delegation-auth.ts >/dev/null 2>&1
run_in "$O1" sh -e .husky/pre-commit
assert_contains "$OUT" "GETSESSION FIELD-PARITY GATE FAILED" \
  "O1a: a real role: omission is still caught even though an unrelated dead type elsewhere in the file also contains the literal text 'role:' — the exact live-reproduced Bypass #1 (Red Agent R)"
assert_contains "$OUT" "no longer sets these fields" \
  "O1b: the block names the real missing-field failure, not a generic message"
git -C "$O1" reset -q --hard HEAD >/dev/null 2>&1

# O1c/O1d (same-day WorldClass Architecture finding, severity 4): O1a/O1b
# only cover a dead field placed BEFORE resolveDelegationSession — the
# awk state machine that isolates the function body treats "before" and
# "after" as genuinely different code paths (a dead line after the
# function's own closing brace is a distinct risk: it depends on the
# extraction correctly RECOGNIZING that closing brace, not just correctly
# starting at the opening one). Closing that Rule-16 enumeration gap: the
# real function body here genuinely OMITS `role:`, and the dead type is
# placed AFTER it instead.
git -C "$O1" reset -q --hard HEAD >/dev/null 2>&1
printf '%s\n' \
  'export async function resolveDelegationSession() {' \
  '  return {' \
  '    session: { session: {} },' \
  '    user: {' \
  '      id: "u1",' \
  '      email: "u1@example.com",' \
  '      emailVerified: true,' \
  '      name: "U One",' \
  '      image: null,' \
  '      isActive: true,' \
  '      createdAt: new Date(),' \
  '      updatedAt: new Date(),' \
  '    },' \
  '  };' \
  '}' \
  '' \
  'interface UnrelatedDeadTypeAfter {' \
  '  role: string;' \
  '}' \
  > "$O1/apps/web/src/lib/agent-delegation-auth.ts"
git -C "$O1" add apps/web/src/lib/agent-delegation-auth.ts >/dev/null 2>&1
run_in "$O1" sh -e .husky/pre-commit
assert_contains "$OUT" "GETSESSION FIELD-PARITY GATE FAILED" \
  "O1c: a real role: omission is still caught even when the unrelated dead type sharing the literal text 'role:' is placed AFTER the function, not before"
assert_contains "$OUT" "no longer sets these fields" \
  "O1d: the block names the real missing-field failure for the after-placement case too, not a generic message"
git -C "$O1" reset -q --hard HEAD >/dev/null 2>&1

# O2 — Bypass #2: a decorative comment merely MENTIONING
# session?.user?.role used to count as a real reader. This fixture's only
# route with any occurrence of the pattern has it inside a `//` comment —
# the real code below it reads ONLY .name, never .role.
O2=$(paritygate_fixture); FIXTURES+=("$O2")
printf '%s\n' \
  'export async function GET() {' \
  '  // TODO: also check session?.user?.role once the UI needs it' \
  '  const session = await getSession();' \
  '  return Response.json({ name: session?.user?.name });' \
  '}' \
  > "$O2/apps/web/src/app/api/whoami/route.ts"
git -C "$O2" add apps/web/src/app/api/whoami/route.ts >/dev/null 2>&1
run_in "$O2" sh -e .husky/pre-commit
assert_contains "$OUT" "GETSESSION FIELD-PARITY GATE FAILED" \
  "O2a: a role: reference that exists ONLY inside a // comment is no longer treated as a real reader — the exact live-reproduced Bypass #2 (Red Agent R)"
assert_contains "$OUT" "no real route under" \
  "O2b: the block names the real Claim-2 failure (no genuine .role reader left), not a generic message"
git -C "$O2" reset -q --hard HEAD >/dev/null 2>&1

# O3 — Bypass #3: `myupstashRedis.eval(x)` used to be silently stripped
# by the substring-based `sed` exclusion (it contains "upstashRedis.eval("
# as a literal substring), leaving zero `eval(` text behind and letting a
# real dangerous call through unflagged — live-tested by Agent S. Proven
# against the real hook AND all 3 sibling copies, matching this module's
# own Rule 24(a)/(c) "verify every sibling instance" discipline.
O3=$(gate_fixture); FIXTURES+=("$O3")
echo 'const x = myupstashRedis.eval(userSuppliedCode);' >> "$O3/src/foo.ts"
git -C "$O3" add src/foo.ts >/dev/null 2>&1
run_in "$O3" sh -e .husky/pre-commit
assert_contains "$OUT" "eval() found:" \
  "O3a: .husky/pre-commit flags myupstashRedis.eval(...) — an impersonating identifier is no longer silently stripped by the safe-substring exclusion"
git -C "$O3" reset -q --hard HEAD >/dev/null 2>&1

O4=$(mktemp -d); FIXTURES+=("$O4")
mkdir -p "$O4/apps/x"
printf 'const x = myupstashRedis.eval(userSuppliedCode);\n' > "$O4/apps/x/impersonator.ts"
SHIPGATE_IMPERSONATOR=$(bash "$SCRIPTS_DIR/shipping-gate.sh" "$O4" 2>&1)
assert_contains "$SHIPGATE_IMPERSONATOR" "eval(): 1 " \
  "O3b: shipping-gate.sh flags the same myupstashRedis.eval(...) impersonator (1 real hit, not 0)"
CI_IMPERSONATOR=$(cd "$O4" && grep -rEn 'eval\(' --include="*.ts" --include="*.tsx" --include="*.js" apps/ packages/ 2>/dev/null | grep -v "node_modules" | grep -v ".test." | grep -v "__mocks__" | sed -E 's/([^A-Za-z0-9_$]|^)upstashRedis\.eval\(/\1/g' | grep -E 'eval\(')
assert_contains "$CI_IMPERSONATOR" "myupstashRedis" \
  "O3c: ci.yml's real pipeline flags the same myupstashRedis.eval(...) impersonator"
SECSCAN_IMPERSONATOR=$( (cd "$O4" && grep -rEn 'eval\(' --include="*.ts" --include="*.tsx" --include="*.js" apps/ packages/ 2>/dev/null | grep -v "node_modules" | grep -v ".test." | sed -E 's/([^A-Za-z0-9_$]|^)upstashRedis\.eval\(/\1/g' | grep -cE 'eval\(' || echo "0") | tr -d ' ')
assert_eq "$SECSCAN_IMPERSONATOR" "1" \
  "O3d: security-scan.yml's real pipeline counts exactly 1 hit for the same myupstashRedis.eval(...) impersonator"

echo ""
echo "Group P: not-found vs in-index-but-empty distinction (Task #320, THIRD confirming Batch-3 audit, 2026-09-18)"
# Agent K + Agent B, convergently: DELEGATION_CONTENT/API_FILES's old
# `[ -z "$VAR" ]` checks couldn't distinguish "path not in the index" from
# "path in the index but genuinely empty" — always reporting the generic
# "not found/tree may have moved" message either way. These tests prove a
# genuinely-tracked-but-empty case now falls through to a real, more
# specific downstream failure instead.

# P1 — a genuinely-tracked but EMPTY agent-delegation-auth.ts must fail
# via the real "function body could not be isolated" message (Task #317's
# DELEGATION_FN_BODY check), never the misleading "not found in the git
# index" one — that message would incorrectly suggest the file was deleted
# or moved, when it demonstrably still exists and is tracked.
P1=$(paritygate_fixture); FIXTURES+=("$P1")
: > "$P1/apps/web/src/lib/agent-delegation-auth.ts"
git -C "$P1" add apps/web/src/lib/agent-delegation-auth.ts >/dev/null 2>&1
run_in "$P1" sh -e .husky/pre-commit
assert_contains "$OUT" "GETSESSION FIELD-PARITY GATE FAILED" \
  "P1a: a genuinely-tracked-but-EMPTY agent-delegation-auth.ts still fails the gate"
assert_contains "$OUT" "function body could not be isolated" \
  "P1b: the failure message is the real 'function body could not be isolated' one — proving existence and content are now distinguished"
assert_not_contains "$OUT" "not found in the git index" \
  "P1c: the misleading 'not found in the git index' message is not shown for a file that genuinely exists but is empty"
git -C "$P1" reset -q --hard HEAD >/dev/null 2>&1

# P2 — an API tree that genuinely still has tracked content, but none of
# it is a non-test .ts route file, must fail via the real "has tracked
# files... but none are non-test .ts route files" message, never the
# "tree may have moved" one (which would incorrectly suggest the whole
# directory vanished).
P2=$(paritygate_fixture); FIXTURES+=("$P2")
git -C "$P2" rm -q apps/web/src/app/api/whoami/route.ts apps/web/src/app/api/health/route.ts >/dev/null 2>&1
mkdir -p "$P2/apps/web/src/app/api/only-test-file"
printf 'export const placeholder = 1;\n' > "$P2/apps/web/src/app/api/only-test-file/route.test.ts"
git -C "$P2" add -A >/dev/null 2>&1
git -C "$P2" commit -q -m "leave only a .test.ts file under api/" >/dev/null 2>&1
echo 'export const y = 2;' >> "$P2/src/foo.ts"
git -C "$P2" add src/foo.ts >/dev/null 2>&1
run_in "$P2" sh -e .husky/pre-commit
assert_contains "$OUT" "GETSESSION FIELD-PARITY GATE FAILED" \
  "P2a: an API tree with tracked content but zero non-test .ts routes still fails the gate"
assert_contains "$OUT" "none are non-test .ts route files" \
  "P2b: the failure message is the real 'has tracked files but none match the filter' one — proving existence and content are now distinguished"
# P2c (same-day WorldClass Architecture finding, severity 4): the original
# version of this assertion checked for the string "no tracked files at
# all under" — a phrase that never appeared in the PRE-Task-#320 message
# either ("no tracked .ts route files under $API_ROOT ... — tree may have
# moved"), so reverting Task #320's fix back to the old single combined
# check did NOT make the original assertion fail — a genuinely
# non-falsifiable placeholder for this specific mutation (Rule 18),
# independently confirmed by reverting the real fix and observing this
# exact assertion still pass. Fixed to check for "tree may have moved" —
# the literal phrase that DOES appear in the old buggy message for this
# exact scenario (tracked content present, none matching the .ts filter)
# and must NOT appear in the new, more specific one.
assert_not_contains "$OUT" "tree may have moved" \
  "P2c: the misleading 'tree may have moved' message is not shown when the directory genuinely still has tracked content"

echo ""
echo "Group Q: eval() identifier-boundary \$ fix (same-day WorldClass Vibes finding, severity 5, 2026-09-18)"
# \$ is a legal JS/TS identifier character (jQuery-style \$http,
# \$upstashRedis, etc.) but the Task #317 boundary fix's original character
# class ([^A-Za-z0-9_]) treated it as a "boundary" anyway, so
# \$upstashRedis.eval(x) was STILL silently stripped to nothing by the
# exclusion — the exact identity-vs-substring bypass Task #317 claims to
# close, one character class short of complete. Fixed by adding \$ to the
# identifier class the boundary excludes, applied identically across the
# real hook and all 3 sibling copies, matching this module's Rule 24(a)
# discipline.
Q1=$(gate_fixture); FIXTURES+=("$Q1")
echo 'const x = $upstashRedis.eval(dangerousCode);' >> "$Q1/src/foo.ts"
git -C "$Q1" add src/foo.ts >/dev/null 2>&1
run_in "$Q1" sh -e .husky/pre-commit
assert_contains "$OUT" "eval() found:" \
  "Q1a: .husky/pre-commit flags \$upstashRedis.eval(...) — a \$-prefixed impersonating identifier is no longer silently stripped by the safe-substring exclusion"
git -C "$Q1" reset -q --hard HEAD >/dev/null 2>&1

Q_SIBLINGS=$(mktemp -d); FIXTURES+=("$Q_SIBLINGS")
mkdir -p "$Q_SIBLINGS/apps/x"
printf 'const x = $upstashRedis.eval(dangerousCode);\n' > "$Q_SIBLINGS/apps/x/dollar-impersonator.ts"
SHIPGATE_DOLLAR=$(bash "$SCRIPTS_DIR/shipping-gate.sh" "$Q_SIBLINGS" 2>&1)
assert_contains "$SHIPGATE_DOLLAR" "eval(): 1 " \
  "Q1b: shipping-gate.sh flags the same \$upstashRedis.eval(...) impersonator (1 real hit, not 0)"
CI_DOLLAR=$(cd "$Q_SIBLINGS" && grep -rEn 'eval\(' --include="*.ts" --include="*.tsx" --include="*.js" apps/ packages/ 2>/dev/null | grep -v "node_modules" | grep -v ".test." | grep -v "__mocks__" | sed -E 's/([^A-Za-z0-9_$]|^)upstashRedis\.eval\(/\1/g' | grep -E 'eval\(')
assert_contains "$CI_DOLLAR" '$upstashRedis' \
  "Q1c: ci.yml's real pipeline flags the same \$upstashRedis.eval(...) impersonator"
SECSCAN_DOLLAR=$( (cd "$Q_SIBLINGS" && grep -rEn 'eval\(' --include="*.ts" --include="*.tsx" --include="*.js" apps/ packages/ 2>/dev/null | grep -v "node_modules" | grep -v ".test." | sed -E 's/([^A-Za-z0-9_$]|^)upstashRedis\.eval\(/\1/g' | grep -cE 'eval\(' || echo "0") | tr -d ' ')
assert_eq "$SECSCAN_DOLLAR" "1" \
  "Q1d: security-scan.yml's real pipeline counts exactly 1 hit for the same \$upstashRedis.eval(...) impersonator"

# Q2 sanity — the real, legitimate upstashRedis.eval( call (no impersonating
# prefix) must still be correctly exempted after adding \$ to the boundary
# class, proving the fix didn't overcorrect and start flagging the safe form.
# (Same-day WorldClass Architecture finding: this fixture variable was
# previously misnamed Q3 while its assertion is labeled Q2 — renamed for
# clarity, no functional change.)
Q2=$(gate_fixture); FIXTURES+=("$Q2")
echo 'await upstashRedis.eval(script, keys, args);' >> "$Q2/src/foo.ts"
git -C "$Q2" add src/foo.ts >/dev/null 2>&1
run_in "$Q2" sh -e .husky/pre-commit
assert_not_contains "$OUT" "eval() found:" \
  "Q2: the real upstashRedis.eval() call is still correctly exempted after the \$ boundary fix"
git -C "$Q2" reset -q --hard HEAD >/dev/null 2>&1

echo ""
echo "Group R: PM_HITS (postMessage) git-INDEX vs working-tree bypass fix (same-day WorldClass Architecture finding, 2026-09-18)"
# .husky/pre-commit's postMessage(targetOrigin) check was the one
# unconverted sibling directly adjacent to the 4 checks Task #313 fixed —
# still reading `"$f"` off the working tree, carrying the identical
# live-reproducible bypass. Same reproduction technique as Group N: stage
# dangerous content, revert the working-tree copy to safe content WITHOUT
# re-staging, confirm the hook still catches it (index read) plus a
# sanity companion proving an unstaged-only edit does not trip the gate.
R1=$(gate_fixture); FIXTURES+=("$R1")
printf "window.parent.postMessage(data, '*');\n" >> "$R1/src/foo.ts"
git -C "$R1" add src/foo.ts >/dev/null 2>&1
printf 'export const x = 1;\nwindow.parent.postMessage(data, window.location.origin);\n' > "$R1/src/foo.ts"
run_in "$R1" sh -e .husky/pre-commit
assert_contains "$OUT" "postMessage() must use window.location.origin" \
  "R1a: a STAGED postMessage(data, '*') is still caught even when the working-tree copy is reverted to a safe origin unstaged — the exact live-reproduced bypass"
git -C "$R1" reset -q --hard HEAD >/dev/null 2>&1

printf "window.parent.postMessage(data, '*');\n" >> "$R1/src/foo.ts"
run_in "$R1" sh -e .husky/pre-commit
assert_not_contains "$OUT" "postMessage() must use window.location.origin" \
  "R1b: an unstaged-only postMessage(data, '*') (never staged) does not trip the gate — it only ever reads the index"
git -C "$R1" reset -q --hard HEAD >/dev/null 2>&1

# R1c sanity — a real, compliant postMessage call (window.location.origin)
# must still NOT be flagged after the index-read rewrite.
R2=$(gate_fixture); FIXTURES+=("$R2")
printf 'window.parent.postMessage(data, window.location.origin);\n' >> "$R2/src/foo.ts"
git -C "$R2" add src/foo.ts >/dev/null 2>&1
run_in "$R2" sh -e .husky/pre-commit
assert_not_contains "$OUT" "postMessage() must use window.location.origin" \
  "R1c: a real, compliant postMessage(data, window.location.origin) call is still correctly exempted after the index-read rewrite"
git -C "$R2" reset -q --hard HEAD >/dev/null 2>&1

echo ""
echo "Group S: backslash-escape content robustness (CORRECTED same-day, 2026-09-18 — see check-getsession-field-parity.sh's own corrected comments)"
# Both cycle-2 reviewers (Architecture and Vibes, independently) claimed
# an echo->printf sweep in check-getsession-field-parity.sh fixed a live
# exploitable bug, reasoning "this hook runs under sh -e (dash), whose
# echo interprets backslash escapes." That reasoning was directly
# verified this same review and found WRONG for this specific file:
# check-getsession-field-parity.sh has its own `#!/usr/bin/env bash`
# shebang and is invoked via explicit `bash "$PARITY_TMP/..."` (a real,
# separate bash subprocess — see .husky/pre-commit's PARITY_TMP block),
# not sh/dash. Confirmed live both directions: a genuine `bash scriptpath`
# invocation with `\c` in piped content matches correctly whether the
# script uses `echo` or `printf` — there is no dynamic test that can
# distinguish them here, because there is no real behavioral difference
# to distinguish (an earlier version of this test claimed otherwise,
# asserting something that was never actually true — caught and corrected
# rather than shipped). What remains genuinely worth proving: a route
# file containing an ordinary backslash-escape-shaped string (common in
# error messages, regexes) doesn't break real-route detection, printf
# being kept anyway as harmless defensive practice/consistency, not an
# exploit fix.
S1=$(paritygate_fixture); FIXTURES+=("$S1")
printf '%s\n' \
  'export async function GET() {' \
  '  const pattern = "foo\cbar";' \
  '  const session = await getSession();' \
  '  return Response.json({ role: session?.user?.role, name: session?.user?.name });' \
  '}' \
  > "$S1/apps/web/src/app/api/whoami/route.ts"
git -C "$S1" add apps/web/src/app/api/whoami/route.ts >/dev/null 2>&1
run_in "$S1" sh -e .husky/pre-commit
assert_not_contains "$OUT" "GETSESSION FIELD-PARITY GATE FAILED" \
  "S1: a real .role/.name read sitting after an ordinary backslash-escape-shaped string on an earlier line is still correctly detected (a genuine robustness check — NOT an echo-vs-printf security distinction, which doesn't apply to this bash-invoked script)"
git -C "$S1" reset -q --hard HEAD >/dev/null 2>&1

echo ""
echo ""
echo "Group T: check-getsession-field-parity.sh performance regression (Task #315, THIRD confirming Batch-3 audit, 2026-09-18)"
# The old per-file `git show ":$f"` loop over every tracked API route file
# (~400 in the real repo) was measured independently by 2 agents at
# 10.4s/7.4-16.5s versus a 0.04s O(1) baseline — running UNCONDITIONALLY
# on every single commit to this repo. Real wall-time measurement against
# the ACTUAL repo, not a synthetic fixture, before/after this task's fix
# (3 runs each, `/usr/bin/time -p`): BEFORE ~13.0-13.5s, AFTER ~1.0-1.05s
# — a ~13x reduction. This test proves the fix scales sub-linearly with
# file count using a fixture matching the real repo's own ~400-file
# scale (an earlier 150-file version of this fixture was tried first and
# found NOT to distinguish old-vs-new at any reasonable time bound — the
# old per-file loop's cost scales roughly linearly with file count, so
# 150 files only cost it ~5s, comfortably under a bound generous enough
# to avoid CI flakiness; mutation-tested directly before landing on 400)
# rather than trusting the real-repo measurement alone to hold
# indefinitely as the repo grows.
paritygate_perf_fixture() {
  local d; d=$(gate_fixture)
  mkdir -p "$d/scripts" "$d/apps/web/src/lib"
  cp "$SCRIPTS_DIR/check-getsession-field-parity.sh" "$d/scripts/check-getsession-field-parity.sh"
  printf '%s\n' \
    'export async function resolveDelegationSession() {' \
    '  return {' \
    '    session: { session: {} },' \
    '    user: {' \
    '      id: "u1",' \
    '      email: "u1@example.com",' \
    '      emailVerified: true,' \
    '      name: "U One",' \
    '      image: null,' \
    '      role: "OWNER",' \
    '      isActive: true,' \
    '      createdAt: new Date(),' \
    '      updatedAt: new Date(),' \
    '    },' \
    '  };' \
    '}' \
    > "$d/apps/web/src/lib/agent-delegation-auth.ts"
  local i
  for i in $(seq 1 400); do
    mkdir -p "$d/apps/web/src/app/api/route$i"
    if [ "$i" -eq 1 ]; then
      printf '%s\n' \
        'export async function GET() {' \
        '  const session = await getSession();' \
        '  return Response.json({ role: session?.user?.role, name: session?.user?.name });' \
        '}' \
        > "$d/apps/web/src/app/api/route$i/route.ts"
    else
      printf '%s\n' \
        'export async function GET() {' \
        "  return Response.json({ id: $i });" \
        '}' \
        > "$d/apps/web/src/app/api/route$i/route.ts"
    fi
  done
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m "perf fixture: 400 API route files (matches the real repo's own ~400-file scale)" >/dev/null 2>&1
  echo "$d"
}
T1=$(paritygate_perf_fixture); FIXTURES+=("$T1")
echo 'export const trigger = 1;' >> "$T1/src/foo.ts"
git -C "$T1" add src/foo.ts >/dev/null 2>&1
T1_START=$(date +%s)
run_in "$T1" sh -e .husky/pre-commit
T1_END=$(date +%s)
T1_ELAPSED=$((T1_END - T1_START))
assert_not_contains "$OUT" "GETSESSION FIELD-PARITY GATE FAILED" \
  "T1a: the real hook still correctly passes against a 400-real-route fixture (correctness preserved, not just speed)"
# Bound calibrated between the two real measured numbers above (NEW
# ~1.0-1.05s, OLD ~13.0-13.5s against the real repo's own ~400 files) —
# 8s sits with a comfortable margin on both sides: high enough that the
# new bulk-materialization version (consistently ~1-4s against this
# fixture) won't flake on a slower/loaded CI runner, low enough that the
# old per-file loop (~13s at this same file count, confirmed by directly
# mutation-testing this exact assertion against the old code) cannot
# possibly pass by chance.
assert_false "[ $T1_ELAPSED -gt 8 ]" \
  "T1b: a 400-file fixture completes in $T1_ELAPSED s (bound: 8s) — proves the fix does not regress back to per-file subprocess-spawn scaling"
git -C "$T1" reset -q --hard HEAD >/dev/null 2>&1

# T1c — same staged-vs-working-tree correctness M7a/M7b already prove,
# now exercised through the NEW bulk-materialization code path: stage a
# change to a route file WITHOUT committing it, confirm the bulk
# `git checkout-index --stdin` correctly picks up the STAGED content, not
# the prior committed one — the exact property this rewrite could have
# silently regressed (Task #315's own correctness note: `git archive
# HEAD` would have read the wrong tree; `checkout-index --stdin` must
# read the index).
T2=$(paritygate_perf_fixture); FIXTURES+=("$T2")
# route2 currently has no real .role/.name read — stage one now, without
# committing, and confirm Claim 2 sees it (the ONLY real reader is this
# newly-staged one, since route1 already has a committed real reader —
# remove that dependency by using a fixture variant where NO committed
# route reads .role, only this staged one does).
git -C "$T2" rm -q apps/web/src/app/api/route1/route.ts >/dev/null 2>&1
git -C "$T2" commit -q -m "remove the only real reader" >/dev/null 2>&1
printf '%s\n' \
  'export async function GET() {' \
  '  const session = await getSession();' \
  '  return Response.json({ role: session?.user?.role, name: session?.user?.name });' \
  '}' \
  > "$T2/apps/web/src/app/api/route2/route.ts"
git -C "$T2" add apps/web/src/app/api/route2/route.ts >/dev/null 2>&1
run_in "$T2" sh -e .husky/pre-commit
assert_not_contains "$OUT" "GETSESSION FIELD-PARITY GATE FAILED" \
  "T1c: a STAGED-but-uncommitted real .role/.name read is picked up by the new bulk-materialization code path — index, not HEAD"
git -C "$T2" reset -q --hard HEAD >/dev/null 2>&1

# T1d (same-day WorldClass Architecture finding): T1c alone only proves
# "reads something newer than the last commit" — it can't distinguish
# `git checkout-index --stdin` (reads the INDEX) from a hypothetical
# regression that read the raw WORKING-TREE file directly, because in
# T1c the staged and working-tree copies of route2 are byte-identical.
# This test makes that distinction real: STAGE a safe version (no real
# .role/.name read) of route2, then make a FURTHER UNSTAGED edit that
# reintroduces a real reader — a regression reading the working tree
# would see the dangerous unstaged edit and wrongly PASS; the real
# index-based implementation must still see only the safe staged content
# and correctly FAIL (no real reader exists in the index for this
# fixture, matching T1's own established "remove the only real reader"
# pattern).
T3=$(paritygate_perf_fixture); FIXTURES+=("$T3")
git -C "$T3" rm -q apps/web/src/app/api/route1/route.ts >/dev/null 2>&1
git -C "$T3" commit -q -m "remove the only real reader" >/dev/null 2>&1
printf '%s\n' \
  'export async function GET() {' \
  '  return Response.json({ status: "ok" });' \
  '}' \
  > "$T3/apps/web/src/app/api/route2/route.ts"
git -C "$T3" add apps/web/src/app/api/route2/route.ts >/dev/null 2>&1
# Now dirty the WORKING TREE only, without re-staging — this is the exact
# divergence T1c's own weaker version could never exercise.
printf '%s\n' \
  'export async function GET() {' \
  '  const session = await getSession();' \
  '  return Response.json({ role: session?.user?.role, name: session?.user?.name });' \
  '}' \
  > "$T3/apps/web/src/app/api/route2/route.ts"
run_in "$T3" sh -e .husky/pre-commit
assert_contains "$OUT" "GETSESSION FIELD-PARITY GATE FAILED" \
  "T1d: a STAGED safe version still correctly fails Claim 2 even though the working tree has since been dirtied with an unstaged real .role/.name read — proves the gate follows the INDEX, not the working tree, a distinction T1c alone could not make"
git -C "$T3" reset -q --hard HEAD >/dev/null 2>&1

echo ""
echo "Group: PRESET WRITE GATE wiring (Task #122 rebuild, 2026-10-08)"
# A real pre-existing gap, closed here: this .husky/pre-commit block has
# existed since Task #122 first shipped, but this suite never carried a
# single wiring test for it (confirmed via grep before this addition —
# zero matches). These drive CMS_PRESET_WRITE_GATE_CHECK_CMD (the
# wrapper's own testability seam, mirroring AGENT_TOOL_CHECK_CMD above) —
# a fixture repo has no pnpm toolchain, so the real tsx-based checker can
# never run here.
preset_gate_fixture() {
  local d; d=$(mktemp -d)
  git -C "$d" init --quiet -b main
  git -C "$d" config user.email "test@gates.test"
  git -C "$d" config user.name "Gate Test"
  mkdir -p "$d/scripts" "$d/.husky" "$d/apps/web/scripts"
  cp "$SCRIPTS_DIR/classify-diff-size.sh" "$d/scripts/classify-diff-size.sh"
  cp "$SCRIPTS_DIR/staged-diff-hash.sh" "$d/scripts/staged-diff-hash.sh"
  cp "$SCRIPTS_DIR/cms-preset-write-gate.sh" "$d/scripts/cms-preset-write-gate.sh"
  cp "$HOOK_SRC" "$d/.husky/pre-commit"
  echo "// stand-in checker body (never executed — CMS_PRESET_WRITE_GATE_CHECK_CMD drives these tests)" \
    > "$d/apps/web/scripts/check-cms-preset-write-gate.ts"
  echo "console.log('hello');" > "$d/scripts/placeholder.ts"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m "initial" >/dev/null 2>&1
  echo "$d"
}

# I1 — a failing stand-in blocks the commit with the gate's named error.
I1=$(preset_gate_fixture); FIXTURES+=("$I1")
echo "console.log('new');" > "$I1/scripts/new-file.ts"
git -C "$I1" add scripts/new-file.ts >/dev/null 2>&1
CMS_PRESET_WRITE_GATE_CHECK_CMD='echo "  ✗ stand-in marker"; exit 1' run_in "$I1" sh -e .husky/pre-commit
assert_contains "$OUT" "PRESET WRITE GATE FAILED" "I1a: hook blocks a commit when the check reports failure"
assert_contains "$OUT" "stand-in marker" "I1b: the stand-in output (not some other path) produced the failure"

# I2 — a passing stand-in does not trip the gate.
I2=$(preset_gate_fixture); FIXTURES+=("$I2")
echo "console.log('new');" > "$I2/scripts/new-file.ts"
git -C "$I2" add scripts/new-file.ts >/dev/null 2>&1
CMS_PRESET_WRITE_GATE_CHECK_CMD='echo ok; exit 0' run_in "$I2" sh -e .husky/pre-commit
assert_not_contains "$OUT" "PRESET WRITE GATE FAILED" "I2: a passing check result does not fail the preset write gate"

# I3 — the gate is unconditional (no separate trigger regex, per the
# hook block's own header): it still runs, and can still block, even on a
# commit that stages nothing resembling a new script at all.
I3=$(preset_gate_fixture); FIXTURES+=("$I3")
echo "# unrelated doc change" > "$I3/README.md"
git -C "$I3" add README.md >/dev/null 2>&1
CMS_PRESET_WRITE_GATE_CHECK_CMD='echo "  ✗ unconditional marker"; exit 1' run_in "$I3" sh -e .husky/pre-commit
assert_contains "$OUT" "PRESET WRITE GATE FAILED" "I3a: the gate runs and can block even on a commit with no new script-like files"
assert_contains "$OUT" "unconditional marker" "I3b: the stand-in genuinely ran (not short-circuited by a trigger regex this hook doesn't have)"

echo ""
echo "Group: COMMENT HYGIENE GATE wiring"
# COMMENT_HYGIENE_CHECK_CMD stands in for the real checker. A fixture repo has no tsx.
comment_gate_fixture() {
  local d; d=$(mktemp -d)
  git -C "$d" init --quiet -b main
  git -C "$d" config user.email "test@gates.test"
  git -C "$d" config user.name "Gate Test"
  mkdir -p "$d/scripts" "$d/.husky" "$d/apps/web/scripts"
  cp "$SCRIPTS_DIR/classify-diff-size.sh" "$d/scripts/classify-diff-size.sh"
  cp "$SCRIPTS_DIR/staged-diff-hash.sh" "$d/scripts/staged-diff-hash.sh"
  cp "$SCRIPTS_DIR/comment-hygiene-gate.sh" "$d/scripts/comment-hygiene-gate.sh"
  cp "$HOOK_SRC" "$d/.husky/pre-commit"
  echo "// stand-in checker body" > "$d/apps/web/scripts/check-comment-hygiene.ts"
  echo "console.log('hello');" > "$d/scripts/placeholder.ts"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m "initial" >/dev/null 2>&1
  echo "$d"
}

J1=$(comment_gate_fixture); FIXTURES+=("$J1")
echo "console.log('new');" > "$J1/scripts/new-file.ts"
git -C "$J1" add scripts/new-file.ts >/dev/null 2>&1
COMMENT_HYGIENE_CHECK_CMD='echo "  ✗ comment stand-in marker"; exit 1' run_in "$J1" sh -e .husky/pre-commit
assert_contains "$OUT" "COMMENT HYGIENE GATE FAILED" "J1a: hook blocks a commit when the comment check fails"
assert_contains "$OUT" "comment stand-in marker" "J1b: the stand-in output produced the failure"

J2=$(comment_gate_fixture); FIXTURES+=("$J2")
echo "console.log('new');" > "$J2/scripts/new-file.ts"
git -C "$J2" add scripts/new-file.ts >/dev/null 2>&1
COMMENT_HYGIENE_CHECK_CMD='echo ok; exit 0' run_in "$J2" sh -e .husky/pre-commit
assert_not_contains "$OUT" "COMMENT HYGIENE GATE FAILED" "J2: a passing comment check does not fail the hook"

# J3 — the real wrapper (no stand-in) cannot find tsx in a fixture; the hook must show WHY it blocked.
J3=$(comment_gate_fixture); FIXTURES+=("$J3")
echo "console.log('new');" > "$J3/scripts/new-file.ts"
git -C "$J3" add scripts/new-file.ts >/dev/null 2>&1
run_in "$J3" sh -e .husky/pre-commit
assert_contains "$OUT" "COMMENT HYGIENE GATE FAILED" "J3a: a checker that cannot run blocks the commit"
assert_contains "$OUT" "tsx not found" "J3b: the hook shows the real reason, not an empty list"

# J4 — a checker that dies with no output (for example out of memory) still gets a visible reason in the hook.
J4=$(comment_gate_fixture); FIXTURES+=("$J4")
echo "console.log('new');" > "$J4/scripts/new-file.ts"
git -C "$J4" add scripts/new-file.ts >/dev/null 2>&1
mkdir -p "$J4/node_modules/.bin" && printf '#!/bin/sh\nexit 1\n' > "$J4/node_modules/.bin/tsx" && chmod +x "$J4/node_modules/.bin/tsx"
run_in "$J4" sh -e .husky/pre-commit
assert_contains "$OUT" "COMMENT HYGIENE GATE FAILED" "J4a: a silent failing checker blocks the commit"
assert_contains "$OUT" "checker printed no reason" "J4b: the hook says there was no reason"

echo ""
echo "RESULTS: $TESTS_PASS/$TESTS_RUN passed"
if [ "$FAIL" -eq 0 ]; then echo "PASS"; else echo "FAIL"; fi
exit $FAIL
