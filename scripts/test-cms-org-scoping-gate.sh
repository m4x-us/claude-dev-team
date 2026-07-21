#!/usr/bin/env bash
# ===========================================
# TEST: scripts/cms-org-scoping-gate.sh
# ===========================================
# Fixture unit tests for the CMS org-scoping gate (Task #7 — the CMS-5
# IDOR class backstop). Every fixture is a throwaway mktemp tree shaped
# like <ROOT>/apps/web/src/app/api/cms/<ns>/route.ts; the gate is invoked
# with that ROOT so this suite NEVER reads the real repo's routes —
# except the final integration test, which runs the gate against THIS
# repo's actual tree and expects green (the gate must pass out of the
# box on the post-Wave-1 tree; a failure there is a real finding).
#
# Run: bash scripts/test-cms-org-scoping-gate.sh
# ===========================================
set -uo pipefail
FAIL=0; TESTS_RUN=0; TESTS_PASS=0

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPTS_DIR/cms-org-scoping-gate.sh"
REAL_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

# Neutral chdir (same incident guard as test-commit-gates.sh): stray
# relative paths must hit a non-repo, never the caller's checkout.
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
assert_contains() {
  TESTS_RUN=$((TESTS_RUN+1))
  if echo "$1" | grep -q "$2"; then
    echo "  ✓ $3"; TESTS_PASS=$((TESTS_PASS+1))
  else
    echo "  ✗ $3 — output does not contain: '$2'"; FAIL=1
  fi
}
assert_not_contains() {
  TESTS_RUN=$((TESTS_RUN+1))
  if ! echo "$1" | grep -q "$2"; then
    echo "  ✓ $3"; TESTS_PASS=$((TESTS_PASS+1))
  else
    echo "  ✗ $3 — output unexpectedly contains: '$2'"; FAIL=1
  fi
}

# new_fixture <name> → sets FIX (ROOT) and CMS (the api/cms dir)
new_fixture() {
  FIX=$(mktemp -d)
  FIXTURES+=("$FIX")
  CMS="$FIX/apps/web/src/app/api/cms"
  mkdir -p "$CMS"
}

if [ ! -f "$GATE" ]; then
  echo "✗ gate script missing: $GATE"
  exit 1
fi

echo "=== test-cms-org-scoping-gate ==="
echo

# ─────────────────────────────────────────────
echo "--- clean fixtures must PASS ---"
new_fixture clean
mkdir -p "$CMS/good" "$CMS/varwhere" "$CMS/namedwhere" "$CMS/chain" "$CMS/public" "$CMS/pubrow" "$CMS/annotated" "$CMS/cta" "$CMS/relation" "$CMS/readcta" "$CMS/orthrowok" "$CMS/commented" "$CMS/goodcreate"

# 1. Inline org-scoped read + viewId-anchored slot write + awaited rate limit.
cat > "$CMS/good/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
import { applyRateLimit, RATE_LIMITS } from '@/lib/rate-limit';
export async function GET() {
  const { db, organization } = await getTenantContext(session);
  const limited = await applyRateLimit(key, 'cms-good', RATE_LIMITS.GENERAL);
  const view = await db.cmsView.findFirst({
    where: { id, organizationId: organization.id },
  });
  await db.cmsViewSlot.updateMany({
    where: { id: slotId, viewId: id, view: { organizationId: organization.id } },
    data: { sortOrder: 0 },
  });
}
EOF

# 2. where built as a variable well above the finder (the content/route.ts shape).
cat > "$CMS/varwhere/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db, organization } = await getTenantContext(session);
  const where: Record<string, unknown> = { organizationId: organization.id };
  if (q.type) where.contentType = q.type;
  if (q.status) where.status = q.status;
  if (q.search) {
    where.OR = [
      { title: { contains: q.search } },
      { summary: { contains: q.search } },
    ];
  }
  const [items, total] = await Promise.all([
    db.cmsArtifact.findMany({
      where,
      orderBy: { updatedAt: 'desc' },
    }),
    db.cmsArtifact.count({ where }),
  ]);
}
EOF

# 2b. where passed as a DIFFERENTLY-NAMED single-assignment const (the
#     ai/route.ts `where: viewsWhere` shape). Distinct from case 2's `{ where }`
#     shorthand: this exercises resolve_where_var via the `where: <namedVar>`
#     branch — the exact pattern whose false-positive once forced an inline
#     annotation. Two calls share one const; both must resolve SCOPED.
cat > "$CMS/namedwhere/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db, organization } = await getTenantContext(session);
  const viewsWhere = { status: 'VERIFIED', organizationId: organization.id };
  const [views, total] = await Promise.all([
    db.cmsView.findMany({
      where: viewsWhere,
      orderBy: { route: 'asc' },
    }),
    db.cmsView.count({ where: viewsWhere }),
  ]);
}
EOF

# 3. Chain-anchored child read after an org-verified parent (content/[id] shape).
cat > "$CMS/chain/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function PATCH() {
  const { db, organization } = await getTenantContext(session);
  const existing = await db.cmsArtifact.findFirst({ where: { id, organizationId: organization.id } });
  if (!existing) return notFound();
  const versionCount = await db.cmsArtifactVersion.count({ where: { artifactId: id } });
}
EOF

# 4. Public surface via resolvePublicCmsContext, reads still org-scoped.
cat > "$CMS/public/route.ts" << 'EOF'
import { resolvePublicCmsContext } from '@/lib/cms-public-org';
export async function GET() {
  const ctx = await resolvePublicCmsContext(request);
  const artifacts = await ctx.db.cmsArtifact.findMany({
    where: { status: 'VERIFIED', organizationId: ctx.organizationId },
  });
}
EOF

# 4b. Relation-scoped read: organizationId reached through a relation, not a
#     scalar column (cmsArtifactVersion has no org column of its own).
mkdir -p "$CMS/relation"
cat > "$CMS/relation/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db, organization } = await getTenantContext(session);
  const versions = await db.cmsArtifactVersion.findMany({
    where: { artifact: { organizationId: organization.id } },
  });
}
EOF

# 4c. Read-side check-then-act: an org-scoped parent findFirst, then a child
#     read anchored by the parent FK (the content/[id] version-count shape).
mkdir -p "$CMS/readcta"
cat > "$CMS/readcta/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function PATCH() {
  const { db, organization } = await getTenantContext(session);
  const existing = await db.cmsArtifact.findFirst({ where: { id, organizationId: organization.id } });
  if (!existing) return notFound();
  const versionCount = await db.cmsArtifactVersion.count({ where: { artifactId: id } });
}
EOF

# 4d. A SCOPED findFirstOrThrow must PASS — pins that the perl analyzer's
#     method matcher recognizes the OrThrow variants (drop them and this
#     scoped read becomes UNSCOPED → a ✗ on the clean tree).
mkdir -p "$CMS/orthrowok"
cat > "$CMS/orthrowok/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db, organization } = await getTenantContext(session);
  const view = await db.cmsView.findFirstOrThrow({ where: { id, organizationId: organization.id } });
}
EOF

# 4f. A slot create behind an org-verified cmsView find is check-then-act.
mkdir -p "$CMS/goodcreate"
cat > "$CMS/goodcreate/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function POST() {
  const { db, organization } = await getTenantContext(session);
  const view = await db.cmsView.findFirst({ where: { id, organizationId: organization.id } });
  if (!view) return notFound();
  await db.cmsViewSlot.create({ data: { viewId: id, slotName: 'x' } });
}
EOF

# 4e. A COMMENTED-OUT unscoped finder must not false-positive (dead code).
mkdir -p "$CMS/commented"
cat > "$CMS/commented/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db, organization } = await getTenantContext(session);
  // const old = await db.cmsView.findMany({ where: { status: 'X' } });
  const rows = await db.cmsView.findMany({ where: { organizationId: organization.id } });
}
EOF

# 5. Deliberate public-row filter (assets anonymous branch shape).
cat > "$CMS/pubrow/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const asset = await prisma.cmsAsset.findFirst({ where: { id, isPublic: true } });
}
EOF

# 6. Line-scoped annotation on the line above an unscoped read.
cat > "$CMS/annotated/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  // cms-org-scoping-gate: ok — system-level maintenance read, no tenant rows
  const all = await db.cmsSchemaType.findMany({ where: { isActive: true } });
}
EOF

# 7. cmsViewSlot write by bare id, guarded by a preceding chain-verified
#    findFirst (the views/[id] check-then-act shape).
cat > "$CMS/cta/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function PATCH() {
  const { db, organization } = await getTenantContext(session);
  const slot = await db.cmsViewSlot.findFirst({
    where: { id: slotId, viewId: id, view: { organizationId: organization.id } },
  });
  if (!slot) return notFound();
  const updateData: Record<string, unknown> = {};
  await db.cmsViewSlot.update({
    where: { id: slotId },
    data: updateData,
  });
}
EOF

OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "0" "clean fixture tree exits 0"
assert_contains "$OUT" "GATE PASSED" "clean tree prints GATE PASSED"
assert_not_contains "$OUT" "✗" "clean tree emits no violation marks"
assert_contains "$OUT" "annotat" "annotated exception is REPORTED, not silent"
assert_contains "$OUT" "public-row" "isPublic allowance is REPORTED, not silent"
assert_contains "$OUT" "check-then-act" "check-then-act write/read is REPORTED, not silent"

# ─────────────────────────────────────────────
echo
echo "--- violations must FAIL, each with its own ✗ ---"

# 7. Route with NO tenant/public context at all.
new_fixture noctx
mkdir -p "$CMS/naked"
cat > "$CMS/naked/route.ts" << 'EOF'
import { prisma } from '@/lib/db';
export async function GET() {
  const rows = await prisma.cmsArtifact.findMany({ where: { status: 'VERIFIED' } });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "context-free route exits 1"
assert_contains "$OUT" "no tenant or public context" "context-free route named in output"
assert_contains "$OUT" "CMS-5" "failure cites the CMS-5 incident"

# 8. Unscoped cmsView read in an otherwise-contexted route.
new_fixture unscoped
mkdir -p "$CMS/leak"
cat > "$CMS/leak/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db } = await getTenantContext(session);
  const views = await db.cmsView.findMany({ where: { status: 'VERIFIED' } });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "unscoped cmsView read exits 1"
assert_contains "$OUT" "leak/route.ts" "unscoped read names the file"

# 9. organizationId ONLY in a comment must NOT satisfy the scope check.
new_fixture commtrap
mkdir -p "$CMS/trap"
cat > "$CMS/trap/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db } = await getTenantContext(session);
  // TODO: scope this by organizationId someday
  const views = await db.cmsView.findMany({ where: { status: 'VERIFIED' } });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "comment-only organizationId still exits 1 (stripping works)"

# 10. cmsViewSlot write with no viewId anchor.
new_fixture slotbare
mkdir -p "$CMS/slots"
cat > "$CMS/slots/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function DELETE() {
  const { db, organization } = await getTenantContext(session);
  const view = await db.cmsView.findFirst({ where: { id, organizationId: organization.id } });
  await db.cmsViewSlot.delete({ where: { id: slotId } });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "bare-slotId cmsViewSlot write exits 1"
assert_contains "$OUT" "no org anchor" "slot-write failure names the missing anchor"

# 11. Un-awaited applyRateLimit assignment.
new_fixture unawaited
mkdir -p "$CMS/rl"
cat > "$CMS/rl/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
import { applyRateLimit, RATE_LIMITS } from '@/lib/rate-limit';
export async function POST() {
  const { db, organization } = await getTenantContext(session);
  const limited = applyRateLimit(key, 'cms-rl', RATE_LIMITS.GENERAL);
  const rows = await db.cmsArtifact.findMany({ where: { organizationId: organization.id } });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "un-awaited applyRateLimit exits 1"
assert_contains "$OUT" "applyRateLimit" "rate-limit failure names the call"

# 12. Annotation 3+ lines away must NOT rescue (line-scoped).
new_fixture farnote
mkdir -p "$CMS/far"
cat > "$CMS/far/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  // cms-org-scoping-gate: ok — this annotation is too far away
  const { db } = await getTenantContext(session);
  const irrelevant = 1;
  const views = await db.cmsView.findMany({ where: { status: 'VERIFIED' } });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "annotation beyond the line above does not rescue (line-scoped)"

# 13. Test files are excluded from scanning.
new_fixture testskip
mkdir -p "$CMS/ok"
cat > "$CMS/ok/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db, organization } = await getTenantContext(session);
  const rows = await db.cmsArtifact.findMany({ where: { organizationId: organization.id } });
}
EOF
cat > "$CMS/ok/route.test.ts" << 'EOF'
// mocks legitimately call unscoped
const views = await db.cmsView.findMany({ where: {} });
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "0" "*.test.ts files are excluded from the scan"

# 14. Missing ROOT dir is a loud failure, never a silent pass.
OUT=$(bash "$GATE" "$NEUTRAL/definitely-missing" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "missing api/cms dir exits nonzero"
assert_contains "$OUT" "not found" "missing dir failure says so"

# ─────────────────────────────────────────────
echo
echo "--- false-negative edges the per-call analyzer must catch (WorldClass cycle 1) ---"

# FN1 — adjacency bleed: a scoped read must NOT vouch for an adjacent
#       unscoped read of a different model.
new_fixture adjacency
mkdir -p "$CMS/adj"
cat > "$CMS/adj/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db, organization } = await getTenantContext(session);
  const view = await db.cmsView.findFirst({ where: { id, organizationId: organization.id } });
  const assets = await db.cmsAsset.findMany({ where: { category: 'hero' } });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "FN1: an unscoped read adjacent to a scoped one is caught"
assert_contains "$OUT" "adj/route.ts" "FN1: names the unscoped read"

# FN2 — magic-word: a parent FK in select/orderBy (not the where) is not scope.
new_fixture magicword
mkdir -p "$CMS/mw"
cat > "$CMS/mw/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db } = await getTenantContext(session);
  const rows = await db.cmsViewSlot.findMany({
    where: { component: 'hero' },
    orderBy: { viewId: 'asc' },
    select: { id: true, viewId: true },
  });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "FN2: viewId in select/orderBy does not satisfy scope"

# FN3 — check-then-act guard must itself be org-scoped: an UNSCOPED findFirst
#       plus a stray viewId token must NOT anchor a bare-id delete.
new_fixture weakguard
mkdir -p "$CMS/wg"
cat > "$CMS/wg/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function DELETE() {
  const { db } = await getTenantContext(session);
  const slot = await db.cmsViewSlot.findFirst({ where: { id: slotId } });
  const viewId = body.viewId;
  await db.cmsViewSlot.delete({ where: { id: slotId } });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "FN3: a bare-id delete behind an UNSCOPED findFirst is caught"

# FN4 — spanning block comment: organizationId inside a /* */ opened ABOVE the
#       finder must not satisfy scope (file-wide strip, line numbers preserved).
new_fixture spancomment
mkdir -p "$CMS/sc"
cat > "$CMS/sc/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db } = await getTenantContext(session);
  /* historically this was scoped by organizationId but the filter
     was refactored out — the token lives only in this block comment */
  const rows = await db.cmsArtifact.findMany({ where: { status: 'VERIFIED' } });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "FN4: organizationId in a spanning block comment does not satisfy scope"

# FN5 — viewId in the data: object (a slot re-parent by bare id) is not a filter.
new_fixture datafield
mkdir -p "$CMS/df"
cat > "$CMS/df/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function PATCH() {
  const { db } = await getTenantContext(session);
  await db.cmsViewSlot.update({
    where: { id: slotId },
    data: { viewId: attackerControlledView },
  });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "FN5: viewId in data: does not anchor a bare-id slot write"

# FN6 — await on a sub-expression, not the applyRateLimit call itself.
new_fixture subexpr
mkdir -p "$CMS/se"
cat > "$CMS/se/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
import { applyRateLimit, RATE_LIMITS } from '@/lib/rate-limit';
export async function POST() {
  const { db, organization } = await getTenantContext(session);
  const limited = applyRateLimit(await keyPromise, 'x', RATE_LIMITS.GENERAL);
  const rows = await db.cmsArtifact.findMany({ where: { organizationId: organization.id } });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "FN6: await on a sub-expression does not count as awaiting applyRateLimit"

# FN7 — a bare unassigned applyRateLimit call whose 429 is discarded.
new_fixture barecall
mkdir -p "$CMS/bc"
cat > "$CMS/bc/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
import { applyRateLimit, RATE_LIMITS } from '@/lib/rate-limit';
export async function POST() {
  const { db, organization } = await getTenantContext(session);
  applyRateLimit(key, 'x', RATE_LIMITS.GENERAL);
  const rows = await db.cmsArtifact.findMany({ where: { organizationId: organization.id } });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "FN7: a bare unassigned applyRateLimit call is caught"

# FN8 — a `where` variable declared org-scoped then REASSIGNED to an unscoped
#       object must resolve to the reassignment (nearest-wins), not the decl.
new_fixture reassign
mkdir -p "$CMS/ra"
cat > "$CMS/ra/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db, organization } = await getTenantContext(session);
  let where = { organizationId: organization.id };
  where = { status: 'VERIFIED' };
  const rows = await db.cmsArtifact.findMany({ where });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "FN8: a where var reassigned to an unscoped object is caught (nearest-wins)"

# FN9 — a `{` inside a STRING literal in the where must not inflate brace
#       depth and let the extractor swallow a sibling organizationId (the
#       string-blindness fail-open both cycle-2 scorers reproduced).
new_fixture strbrace
mkdir -p "$CMS/sb"
cat > "$CMS/sb/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db } = await getTenantContext(session);
  const rows = await db.cmsView.findMany({
    where: { title: { contains: "{" } },
    select: { id: true, organizationId: true },
  });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "FN9: a brace inside a string literal does not let select's organizationId satisfy the where"

# FN10 — two cms reads on ONE physical line: the scoped one must not vouch
#        for the unscoped one (grep reports the line once).
new_fixture oneline
mkdir -p "$CMS/ol"
cat > "$CMS/ol/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db, organization } = await getTenantContext(session);
  const [mine, any] = await Promise.all([db.cmsView.findFirst({ where: { id, organizationId: organization.id } }), db.cmsAsset.findMany({ where: { category: 'hero' } })]);
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "FN10: an unscoped read sharing a line with a scoped one is judged independently"

# FN18 — the falsifiable partner to clean-case 2b: a DIFFERENTLY-NAMED where
#        var (the `where: <namedVar>` branch) that lacks organizationId must
#        FAIL. Proves resolve_where_var actually READS the const's contents on
#        that branch — a stub that accepted any `where: someVar` would pass 2b
#        AND leak here; only real resolution passes 2b and catches this.
new_fixture namedunscoped
mkdir -p "$CMS/nu"
cat > "$CMS/nu/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db } = await getTenantContext(session);
  const looseWhere = { status: 'VERIFIED' };
  const rows = await db.cmsArtifact.findMany({ where: looseWhere });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "FN18: a named where var lacking organizationId is caught (the branch reads contents, not just the shape)"

# FN11 — an unscoped OrThrow read is caught (pins the bash finder grep's
#        OrThrow coverage; the SCOPED-OrThrow clean fixture 4d pins perl's).
new_fixture orthrow
mkdir -p "$CMS/ot"
cat > "$CMS/ot/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db } = await getTenantContext(session);
  const view = await db.cmsView.findFirstOrThrow({ where: { status: 'VERIFIED' } });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "FN11: an unscoped findFirstOrThrow read is caught (finder grep covers OrThrow)"

# FN12 — a NESTED where (in include/select) is not the call's top-level filter:
#        a read with no top-level where reads all orgs and must be caught even
#        though a nested relation filter carries organizationId.
new_fixture nestedwhere
mkdir -p "$CMS/nw"
cat > "$CMS/nw/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db, organization } = await getTenantContext(session);
  const rows = await db.cmsView.findMany({
    include: { slots: { where: { organizationId: organization.id } } },
  });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "FN12: a nested include/select where does not scope the top-level read"

# FN13 — organizationId as a string VALUE is not a scope KEY.
new_fixture strvalue
mkdir -p "$CMS/sv"
cat > "$CMS/sv/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db } = await getTenantContext(session);
  const rows = await db.cmsView.findMany({ where: { label: "organizationId" } });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "FN13: organizationId as a string value does not satisfy scope"

# FN14 — isPublic:false is NOT a public-row pass (reads every org's private rows).
new_fixture pubfalse
mkdir -p "$CMS/pf"
cat > "$CMS/pf/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db } = await getTenantContext(session);
  const rows = await db.cmsAsset.findMany({ where: { isPublic: false } });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "FN14: isPublic:false does not pass as a public-row read (private rows leak)"

# FN15 — a cmsViewSlot.create with NO preceding org-scoped view find is an
#        unanchored cross-tenant write (attacker-controlled data.viewId).
new_fixture badcreate
mkdir -p "$CMS/bcr"
cat > "$CMS/bcr/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function POST() {
  const { db } = await getTenantContext(session);
  await db.cmsViewSlot.create({ data: { viewId: body.viewId, slotName: 'x' } });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "FN15: a slot create with no org-verified view guard is caught"

# FN16 — the BULK create variant is the same unanchored write vector.
new_fixture bulkcreate
mkdir -p "$CMS/bcm"
cat > "$CMS/bcm/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function POST() {
  const { db } = await getTenantContext(session);
  await db.cmsViewSlot.createMany({ data: body.slots });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "FN16: an unanchored cmsViewSlot.createMany is caught (bulk-create covered)"

# FN17 — isPublic:true as ONE branch of an OR does not make the read public;
#        the other branch reads every org's rows.
new_fixture orpublic
mkdir -p "$CMS/orp"
cat > "$CMS/orp/route.ts" << 'EOF'
import { getTenantContext } from '@/lib/tenant-context';
export async function GET() {
  const { db } = await getTenantContext(session);
  const rows = await db.cmsAsset.findMany({ where: { OR: [{ isPublic: true }, { category: 'hero' }] } });
}
EOF
OUT=$(bash "$GATE" "$FIX" 2>&1); EXIT=$?
assert_eq "$EXIT" "1" "FN17: isPublic:true inside an OR is not a top-level public filter"

# ─────────────────────────────────────────────
echo
echo "--- integration: the REAL repo tree must be green ---"
OUT=$(bash "$GATE" "$REAL_ROOT" 2>&1); EXIT=$?
assert_eq "$EXIT" "0" "gate passes against this repo's actual api/cms tree"
assert_contains "$OUT" "GATE PASSED" "real-tree run prints GATE PASSED"

echo
echo "=== RESULT: $TESTS_PASS/$TESTS_RUN passed ==="
[ "$FAIL" -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit "$FAIL"
