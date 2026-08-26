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
echo "RESULTS: $TESTS_PASS/$TESTS_RUN passed"
if [ "$FAIL" -eq 0 ]; then echo "PASS"; else echo "FAIL"; fi
exit $FAIL
