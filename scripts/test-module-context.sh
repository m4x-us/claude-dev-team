#!/usr/bin/env bash
# TEST MODULE_CONTEXT — verifies all suite commands have MODULE_CONTEXT block,
# the .active-module fallback is wired, all required path substitutions are present,
# and no unprotected hardcoded global paths remain.
# Run from repo root. Exit 0 = pass. Exit 1 = gap found.
# Usage: bash scripts/test-module-context.sh

set -uo pipefail
FAIL=0
COMMANDS_DIR="$HOME/Projects/claude-dev-team/commands"
# TMC_STAGED_DIR lets the pre-commit hook run these checks against a mirror
# of the STAGED harness content instead of the working tree — the gate's
# claim is "staged content", so it must never read live files when set.
PROJECT_ROOT="${TMC_STAGED_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"

# Canon-only checks (files that exist only in claude-dev-team, never in the
# project) skip LOUDLY when the canonical checkout is not installed on this
# machine — never silently, and never as a failure. Project-resident files
# always hard-check.
CANON_AVAILABLE=1
[ -d "$COMMANDS_DIR" ] || CANON_AVAILABLE=0
SKIPPED=0
skip_canon() {
  echo "⚠ SKIPPED: $1 (canonical claude-dev-team copy not installed on this machine)"
  SKIPPED=$((SKIPPED+1))
}

# Per-project commands (advance/go/scan/scope) are overridden by the copy in
# .claude/commands/ — the checks must test WHAT ACTUALLY RUNS, not the mirror.
# (Before 2026-07-10 this script only tested the claude-dev-team mirror, so a
# diverged live copy passed checks it didn't satisfy.)
# One policy regex, defined once — CHECK 10 and CHECK 11 both filter their
# forbidden tiers through it. Duplicated copies drift; drift silently weakens
# one command's tier gate. Extend the denial list here, never fork it.
DENIAL_RE='NO shared|no fallback|never|hard stop|refus|incident|stale|wiped|destroy|invalid'

resolve_cmd() {
  if [ -f "$PROJECT_ROOT/.claude/commands/$1" ]; then
    echo "$PROJECT_ROOT/.claude/commands/$1"
  else
    echo "$COMMANDS_DIR/$1"
  fi
}

echo "=== MODULE_CONTEXT WIRING CHECK ==="

REQUIRED=(task.md audit.md worldclass.md autocode.md tasks.md advance.md meet.md go.md)

# CHECK 1 — MODULE_CONTEXT block exists
for cmd in "${REQUIRED[@]}"; do
  f=$(resolve_cmd "$cmd")
  if [ ! -f "$f" ]; then
    if [ "$CANON_AVAILABLE" -eq 0 ] && [ "$f" = "$COMMANDS_DIR/$cmd" ]; then
      skip_canon "$cmd"; continue
    fi
    echo "✗ MISSING FILE: $f"; FAIL=1; continue
  fi
  if ! grep -q "## MODULE_CONTEXT" "$f"; then
    echo "✗ MISSING MODULE_CONTEXT block: $cmd"
    FAIL=1
  else
    echo "✓ $cmd — MODULE_CONTEXT block present"
  fi
done

# CHECK 2 — .active-module fallback present near MODULE_CONTEXT block
# Strategy: find the line number of ## MODULE_CONTEXT, then verify active-module appears
# within the next 40 lines (the block is never longer than that).
echo ""
echo "=== .ACTIVE-MODULE FALLBACK CHECK ==="
for cmd in "${REQUIRED[@]}"; do
  f=$(resolve_cmd "$cmd")
  if [ ! -f "$f" ]; then
    [ "$CANON_AVAILABLE" -eq 0 ] && [ "$f" = "$COMMANDS_DIR/$cmd" ] && skip_canon "$cmd"
    continue
  fi
  MODULE_LINE=$(grep -n "^## MODULE_CONTEXT" "$f" | head -1 | cut -d: -f1)
  if [ -z "$MODULE_LINE" ]; then
    echo "✗ $cmd — MODULE_CONTEXT block not found (skip .active-module check)"
    FAIL=1; continue
  fi
  END_LINE=$((MODULE_LINE + 40))
  IN_BLOCK=$(awk "NR>=$MODULE_LINE && NR<=$END_LINE" "$f" | grep -c "active-module" || true)
  if [ "$IN_BLOCK" -eq 0 ]; then
    echo "✗ MODULE_CONTEXT block missing .active-module fallback (checked lines $MODULE_LINE-$END_LINE): $cmd"
    FAIL=1
  else
    echo "✓ $cmd — .active-module fallback present in MODULE_CONTEXT block"
  fi
done

# CHECK 3 — Standard 7 path substitutions present (for all non-go.md commands)
# Use line-range approach: find MODULE_CONTEXT header, check within next 60 lines
echo ""
echo "=== PATH SUBSTITUTION COMPLETENESS CHECK ==="
STANDARD_PATHS=("modules/\[MODULE\]/tasks.md" "modules/\[MODULE\]/cto.md"
  "modules/\[MODULE\]/security.md" "modules/\[MODULE\]/architect.md"
  "modules/\[MODULE\]/qa.md" "modules/\[MODULE\]/debt.md"
  "modules/\[MODULE\]/carry-forward-log.md")
for cmd in "${REQUIRED[@]}"; do
  f=$(resolve_cmd "$cmd")
  if [ ! -f "$f" ]; then
    [ "$CANON_AVAILABLE" -eq 0 ] && [ "$f" = "$COMMANDS_DIR/$cmd" ] && skip_canon "$cmd"
    continue
  fi
  MODULE_LINE=$(grep -n "^## MODULE_CONTEXT" "$f" | head -1 | cut -d: -f1)
  [ -z "$MODULE_LINE" ] && continue
  END_LINE=$((MODULE_LINE + 60))
  BLOCK=$(awk "NR>=$MODULE_LINE && NR<=$END_LINE" "$f")

  if [[ "$cmd" == "go.md" ]]; then
    if ! echo "$BLOCK" | grep -q "modules/\[MODULE\]/queue"; then
      echo "✗ go.md missing queue path substitution in MODULE_CONTEXT block"
      FAIL=1
    else
      echo "✓ go.md — queue path substitution present"
    fi
    if echo "$BLOCK" | grep -qi "scope banner"; then
      echo "✗ go.md MODULE_CONTEXT references scope banner — child windows cannot use this"
      FAIL=1
    fi
  else
    cmd_ok=1
    for path in "${STANDARD_PATHS[@]}"; do
      if ! echo "$BLOCK" | grep -qE "$path"; then
        echo "✗ $cmd missing path substitution: $path"
        FAIL=1; cmd_ok=0
      fi
    done
    [ "$cmd_ok" -eq 1 ] && echo "✓ $cmd — all 7 path substitutions present"
  fi
done

# CHECK 4 — Verify all declared substitution paths are in the MODULE_CONTEXT block
# (CHECK 3 already verifies completeness; this check verifies no extra undeclared paths
# exist in the command that are not covered by the substitution table)
# NOTE: The body of commands intentionally references global paths — that's the design.
# The MODULE_CONTEXT block provides the substitution table that applies at runtime.
# We only flag paths that appear in the body but are NOT in the substitution table.
echo ""
echo "=== EXTRA UNDECLARED PATH CHECK ==="
for cmd in "${REQUIRED[@]}"; do
  f=$(resolve_cmd "$cmd")
  if [ ! -f "$f" ]; then
    [ "$CANON_AVAILABLE" -eq 0 ] && [ "$f" = "$COMMANDS_DIR/$cmd" ] && skip_canon "$cmd"
    continue
  fi
  MODULE_LINE=$(grep -n "^## MODULE_CONTEXT" "$f" | head -1 | cut -d: -f1)
  [ -z "$MODULE_LINE" ] && continue
  END_LINE=$((MODULE_LINE + 60))
  BLOCK=$(awk "NR>=$MODULE_LINE && NR<=$END_LINE" "$f")

  # Find all .autocode/agents/X.md references in the block (declared substitutions)
  DECLARED=$(echo "$BLOCK" | python3 -c "
import sys, re
for m in re.findall(r'\.autocode/agents/[a-z]+\.md', sys.stdin.read()):
    print(m)
" | sort -u)

  # Find all .autocode/agents/X.md references in the full file
  ALL_REFS=$(python3 -c "
import sys, re
with open('$f') as fh:
    for m in re.findall(r'\.autocode/agents/[a-z]+\.md', fh.read()):
        print(m)
" | sort -u)

  # Find any in ALL_REFS not in DECLARED (undeclared paths)
  undeclared=""
  while IFS= read -r ref; do
    if ! echo "$DECLARED" | grep -qF "$ref"; then
      undeclared="$undeclared $ref"
    fi
  done <<< "$ALL_REFS"

  if [ -n "$(echo "$undeclared" | tr -d ' ')" ]; then
    echo "⚠ $cmd — paths used in body but not declared in MODULE_CONTEXT:$undeclared"
    # This is a WARNING, not a failure — some paths may be intentionally not substituted
  else
    echo "✓ $cmd — all .autocode/agents/ paths are declared in MODULE_CONTEXT"
  fi
done

# CHECK 5 — Diagnostic print instruction is present (Module scope: header)
echo ""
echo "=== DIAGNOSTIC PRINT CHECK ==="
for cmd in "${REQUIRED[@]}"; do
  f=$(resolve_cmd "$cmd")
  if [ ! -f "$f" ]; then
    [ "$CANON_AVAILABLE" -eq 0 ] && [ "$f" = "$COMMANDS_DIR/$cmd" ] && skip_canon "$cmd"
    continue
  fi
  if ! grep -q "Module scope:" "$f"; then
    echo "✗ $cmd missing diagnostic print instruction (Module scope: [MODULE])"
    FAIL=1
  else
    echo "✓ $cmd — diagnostic print instruction present"
  fi
done

# CHECK 6 — worker-pool.py exists and is importable
echo ""
echo "=== WORKER POOL SCRIPT CHECK ==="
POOL_SCRIPT="$HOME/.claude/scripts/worker-pool.py"
if [ ! -f "$POOL_SCRIPT" ]; then
  # Canon not installed → the pool script legitimately doesn't exist here.
  # Canon installed → its absence means a broken install: hard fail.
  if [ "$CANON_AVAILABLE" -eq 0 ]; then
    skip_canon "worker-pool.py"
  else
    echo "✗ MISSING: $POOL_SCRIPT — run bash ~/Projects/claude-dev-team/install.sh"
    FAIL=1
  fi
else
  echo "✓ worker-pool.py found"
  python3 -m py_compile "$POOL_SCRIPT" 2>/dev/null \
    && echo "✓ worker-pool.py syntax OK" \
    || { echo "✗ worker-pool.py has syntax errors"; FAIL=1; }
  for subcmd in init claim release lookup status; do
    grep -qE "\"$subcmd\"|'$subcmd'" "$POOL_SCRIPT" \
      && echo "✓ subcommand '$subcmd' present" \
      || { echo "✗ subcommand '$subcmd' missing"; FAIL=1; }
  done
  grep -q "pool_lock\|LOCK_FILENAME" "$POOL_SCRIPT" \
    && echo "✓ worker-pool.py — stable lock file pattern present (race-free)" \
    || { echo "✗ worker-pool.py — missing pool_lock/LOCK_FILENAME (flock on data file = lost-update race)"; FAIL=1; }
fi
# NOTE: CHECK 6 only validates structure. Gate 1 (test-worker-pool.sh) validates behavior.

# CHECK 7 — go.md has pool lookup BEFORE .active-module fallback
echo ""
echo "=== GO.MD POOL LOOKUP ORDER CHECK ==="
GO_MD=$(resolve_cmd go.md)
if [ -f "$GO_MD" ]; then
  POOL_LINE=$(grep -n "worker-pool.py lookup" "$GO_MD" | head -1 | cut -d: -f1)
  FALLBACK_LINE=$(grep -n "active-module file" "$GO_MD" | head -1 | cut -d: -f1)
  if [ -z "$POOL_LINE" ]; then
    echo "✗ go.md missing 'worker-pool.py lookup' call"; FAIL=1
  elif [ -z "$FALLBACK_LINE" ]; then
    echo "✗ go.md missing '.active-module file' fallback step"; FAIL=1
  elif [ "$POOL_LINE" -lt "$FALLBACK_LINE" ]; then
    echo "✓ go.md — pool lookup (line $POOL_LINE) before .active-module fallback (line $FALLBACK_LINE)"
  else
    echo "✗ go.md — fallback (line $FALLBACK_LINE) appears before pool lookup (line $POOL_LINE)"; FAIL=1
  fi
fi

# CHECK 8 — scope.md has claim and release calls
echo ""
echo "=== SCOPE.MD POOL INTEGRATION CHECK ==="
SCOPE_MD=$(resolve_cmd scope.md)
if [ ! -f "$SCOPE_MD" ]; then
  echo "⚠ scope.md not found at expected path: $SCOPE_MD"
else
  grep -qE "worker-pool\.py.*claim" "$SCOPE_MD" \
    && echo "✓ scope.md — pool claim call present" \
    || { echo "✗ scope.md — missing worker-pool.py claim call"; FAIL=1; }
  grep -qE "worker-pool\.py.*release" "$SCOPE_MD" \
    && echo "✓ scope.md — pool release call present" \
    || { echo "✗ scope.md — missing worker-pool.py release call"; FAIL=1; }
  grep -q "\.workers" "$SCOPE_MD" \
    && echo "✓ scope.md — .workers reference present" \
    || { echo "✗ scope.md — missing .workers reference"; FAIL=1; }

  # Added 2026-07-10 — module windows get their own worktree + per-checkout
  # module marker (fixes the last-writer-wins .active-module clobber).
  for req in \
    "wave-worktrees.sh single|module-window worktree creation present" \
    "set-module|per-checkout module marker written via set-module" \
    "STAGED-WORK GUARD|staged-work guard before worktree creation" \
    "wave-worktrees.sh verify|worktree verify invocation present" \
    "names WHICH checkout|staged-work guard names which checkout's index is inspected" \
  ; do
    pat="${req%%|*}"; msg="${req#*|}"
    grep -q "$pat" "$SCOPE_MD" \
      && echo "✓ scope.md — $msg" \
      || { echo "✗ scope.md — MISSING: $msg (grep: $pat)"; FAIL=1; }
  done
fi

# CHECK 8b — scan.md Rule 16: .not.-prefixed matchers must be STRIPPED before
# allowed-list matching (`.not.toBeNull()` contains the allowed substring
# `.toBeNull(` — matching without stripping is a guaranteed false negative, so
# pseudocode assertions pass the scan). scan.md is a project-resident, synced
# harness command (check-command-sync COMMANDS) — same pin discipline as the
# other three command files.
echo ""
echo "=== SCAN.MD RULE 16 CHECK ==="
SCAN_MD=$(resolve_cmd scan.md)
if [ ! -f "$SCAN_MD" ]; then
  echo "✗ scan.md missing from project and canon"; FAIL=1
else
  grep -qF 'STRIP `.not.`-prefixed matchers' "$SCAN_MD" \
    && echo "✓ scan.md — Rule 16 strips .not. matchers before allowed-list matching" \
    || { echo "✗ scan.md — Rule 16 lacks the .not.-strip step (.not.toBeNull() satisfies the allowed list → pseudocode assertions pass the scan)"; FAIL=1; }
fi

# CHECK 8c — single-canonical MODULE REGISTRY (added 2026-08-14): the fenced
# registry lives ONLY in scope.md; scan.md and (project-only) 1701.md carry a
# run-time pointer + RETIRED refusal instead of a copy. A re-embedded copy is
# the drift class that produced the stale 11-module scan.md registry.
echo ""
echo "=== SINGLE-CANONICAL REGISTRY CHECK ==="
# REG_SENTINEL is the first registry path line. One-way canary: its PRESENCE
# in scan.md/1701.md proves an embedded copy; its absence there proves only
# that this one line is gone. The positive half of the invariant is checked
# below: scope.md itself MUST contain it (canonical body actually present).
# Renaming the email module's dashboard/inbox path requires updating this
# constant — acceptable canary cost.
REG_SENTINEL='apps/web/src/app/dashboard/inbox'
# resolve_cmd prefers the project copy (what actually runs here) and falls
# back to the claude-dev-team CANON MIRROR — while runtime slash-command
# fallback is ~/.claude/commands. The fallbacks diverging is by design: a
# stale HOME copy is invisible to this check (that residual is debt.md
# HARNESS-1, not this script's job). Fail-closed either way: a canon-resolved
# scope.md missing the CANONICAL COPY or operative-refusal pins sets FAIL=1 —
# it can never pass silently.
SCOPE_MD=$(resolve_cmd scope.md)
if [ ! -f "$SCOPE_MD" ]; then
  echo "✗ scope.md unresolvable ($SCOPE_MD) — the CANONICAL registry cannot exist; every pointer dangles"; FAIL=1
else
  N_REG=$(grep -c '^## MODULE REGISTRY' "$SCOPE_MD" || true)
  [ "${N_REG:-0}" -eq 1 ] \
    && echo "✓ scope.md — exactly one MODULE REGISTRY header" \
    || { echo "✗ scope.md — ${N_REG:-0} MODULE REGISTRY headers (need exactly 1)"; FAIL=1; }
  grep -qF "$REG_SENTINEL" "$SCOPE_MD" \
    && echo "✓ scope.md — canonical registry body present (sentinel path found)" \
    || { echo "✗ scope.md — canonical registry body GUTTED ($REG_SENTINEL absent)"; FAIL=1; }
  grep -qF 'CANONICAL COPY' "$SCOPE_MD" \
    && echo "✓ scope.md — canonical-copy declaration present" \
    || { echo "✗ scope.md — registry lacks the CANONICAL COPY declaration"; FAIL=1; }
  # 'marked RETIRED is INVALID' matches twice by design (registry header +
  # Step 1); the 'do not proceed to Step 1.5' pin anchors the operative copy.
  grep -qF 'marked RETIRED is INVALID' "$SCOPE_MD" && grep -qF 'do not proceed to Step 1.5' "$SCOPE_MD" \
    && echo "✓ scope.md — RETIRED refusal present (registry rule + operative Step 1 refusal)" \
    || { echo "✗ scope.md — RETIRED refusal missing/defanged (need the registry header rule AND Step 1's operative 'do not proceed to Step 1.5')"; FAIL=1; }
fi
SCAN_MD=$(resolve_cmd scan.md)
if [ ! -f "$SCAN_MD" ]; then
  echo "✗ scan.md missing from project and canon (registry pointer unverifiable)"; FAIL=1
else
  if grep -qF "$REG_SENTINEL" "$SCAN_MD"; then
    echo "✗ scan.md — embedded registry copy detected ($REG_SENTINEL) — must point to scope.md"; FAIL=1
  else
    echo "✓ scan.md — no embedded registry copy (sentinel)"
  fi
  if grep -qF 'packages/ordinatio-cms' "$SCAN_MD"; then
    echo "✗ scan.md — embedded registry copy detected (packages/ordinatio-cms) — must point to scope.md"; FAIL=1
  else
    echo "✓ scan.md — no embedded registry copy (second canary)"
  fi
  grep -qF 'MODULE REGISTRY in scope.md' "$SCAN_MD" && grep -qF 'HARD STOP' "$SCAN_MD" \
    && echo "✓ scan.md — registry pointer + HARD STOP present" \
    || { echo "✗ scan.md — registry pointer/HARD STOP missing"; FAIL=1; }
  grep -qF 'marked RETIRED in the registry' "$SCAN_MD" && grep -qF 'refuse, name the successor' "$SCAN_MD" \
    && echo "✓ scan.md — operative RETIRED refusal present (Step 1 refuse-and-name-successor)" \
    || { echo "✗ scan.md — operative RETIRED refusal missing (a bare RETIRED mention is not a refusal)"; FAIL=1; }
fi
S1701_MD="$PROJECT_ROOT/.claude/commands/1701.md"
if [ -f "$S1701_MD" ]; then
  if grep -qF "$REG_SENTINEL" "$S1701_MD"; then
    echo "✗ 1701.md — embedded registry copy detected ($REG_SENTINEL) — must point to scope.md"; FAIL=1
  else
    echo "✓ 1701.md — no embedded registry copy (sentinel)"
  fi
  if grep -qF 'packages/ordinatio-cms' "$S1701_MD"; then
    echo "✗ 1701.md — embedded registry copy detected (packages/ordinatio-cms) — must point to scope.md"; FAIL=1
  else
    echo "✓ 1701.md — no embedded registry copy (second canary)"
  fi
  grep -qF 'MODULE REGISTRY in scope.md' "$S1701_MD" && grep -qF 'HARD STOP' "$S1701_MD" \
    && echo "✓ 1701.md — registry pointer + HARD STOP present" \
    || { echo "✗ 1701.md — registry pointer/HARD STOP missing (dashboard would guess paths)"; FAIL=1; }
  grep -q 'non-RETIRED' "$S1701_MD" \
    && echo "✓ 1701.md — non-RETIRED iteration present" \
    || { echo "✗ 1701.md — Step 1A lacks non-RETIRED filter (path-less entry → whole-repo git log)"; FAIL=1; }
else
  echo "⚠ SKIPPED: 1701.md (project-local command; not present in this checkout)"
fi
MASTER_MD="$PROJECT_ROOT/.claude/commands/master.md"
if [ -f "$MASTER_MD" ]; then
  if grep -qF "$REG_SENTINEL" "$MASTER_MD"; then
    echo "✗ master.md — embedded registry copy detected ($REG_SENTINEL) — must point to scope.md"; FAIL=1
  else
    echo "✓ master.md — no embedded registry copy (sentinel)"
  fi
  # master's embedded copy (found 2026-08) OMITTED the sentinel path (its email line
  # carried no dashboard/inbox), so REG_SENTINEL alone would never have caught
  # it. Second canary: packages/ordinatio-cms — present in that copy's cms
  # line, absent from master.md's pointer text and seam-reference prose.
  if grep -qF 'packages/ordinatio-cms' "$MASTER_MD"; then
    echo "✗ master.md — embedded registry copy detected (packages/ordinatio-cms) — must point to scope.md"; FAIL=1
  else
    echo "✓ master.md — no embedded registry copy (second canary)"
  fi
  grep -qF 'MODULE REGISTRY in scope.md' "$MASTER_MD" && grep -qF 'HARD STOP' "$MASTER_MD" \
    && echo "✓ master.md — registry pointer + HARD STOP present" \
    || { echo "✗ master.md — registry pointer/HARD STOP missing (findings routed by guesswork)"; FAIL=1; }
  grep -qF 'INVALID routing target' "$MASTER_MD" \
    && echo "✓ master.md — RETIRED routing refusal present (route to the successor)" \
    || { echo "✗ master.md — RETIRED routing refusal missing (findings would land in a retired module's dead memory files)"; FAIL=1; }
else
  echo "⚠ SKIPPED: master.md (project-local command; not present in this checkout)"
fi

# CHECK 9 — advance.md uses WORKER_NAMES, no hardcoded A→Adam mapping
echo ""
echo "=== ADVANCE.MD DYNAMIC WORKER CHECK ==="
ADV_MD=$(resolve_cmd advance.md)
if [ -f "$ADV_MD" ]; then
  # Flag A→Adam/A→Barry sequential mappings and hardcoded /go commands.
  # Python list defaults like WORKER_NAMES = ["adam","barry",...] are intentional — exempt them.
  if grep -qE "A[→>]Adam|A[→>]adam|/go adam.*barry|done adam.*barry" "$ADV_MD"; then
    echo "✗ advance.md still has hardcoded name sequence (A→Adam etc.)"; FAIL=1
  else
    echo "✓ advance.md — hardcoded 4-name sequence absent"
  fi
  grep -qE "WORKER_NAMES|\.workers" "$ADV_MD" \
    && echo "✓ advance.md — WORKER_NAMES/\.workers reference present" \
    || { echo "✗ advance.md — missing WORKER_NAMES reference"; FAIL=1; }
  if grep -qE "queue/adam\.md|queue/barry\.md|queue/charles\.md|queue/derek\.md" "$ADV_MD"; then
    echo "✗ advance.md has hardcoded queue/adam.md style paths"; FAIL=1
  else
    echo "✓ advance.md — no hardcoded queue/[name].md paths"
  fi
fi

# CHECK 10 — advance.md delegates the worktree lifecycle to wave-worktrees.sh
# and enforces the two mandatory pastes (verify output + queue recheck).
# REWRITTEN 2026-07-10: the old check REQUIRED inline `git worktree add` /
# `branch -D` — i.e. it mandated the drift being removed. Polarity matters:
# inline git lifecycle commands and fallback language are now FORBIDDEN.
echo ""
echo "=== ADVANCE.MD WORKTREE ISOLATION CHECK ==="
ADV_MD=$(resolve_cmd advance.md)
if [ -f "$ADV_MD" ]; then
  for req in \
    "wave-worktrees.sh create|W.3 creation delegated to the script" \
    "wave-worktrees.sh verify wave|mechanical wave verify wired" \
    "wave-worktrees.sh NOT FOUND|missing-script hard stop present" \
    "WAVE_WT|TSV machine-output parsing specified" \
    "MECHANICAL VERIFY|W.3 mechanical-verify block present" \
    "Paste the COMPLETE output|verbatim paste requirement present" \
    "QUEUE FRONTMATTER RECHECK|queue recheck loop present" \
    "worktree:|'worktree:' field in queue frontmatter spec" \
    "TOYOTA STOP|Toyota Stop gate present" \
    "hard stop|'hard stop' language present" \
    "wave-state.json|.wave-state.json crash recovery present" \
    "ANTI-DRIFT NOTE|per-stream substitution warning present" \
    "STREAM_WORKTREE\[|STREAM_WORKTREE[X] per-stream notation present" \
    "skip ONLY the|restore path skips creation only (verify + queue recheck still mandatory)" \
    "substr(\$0,10)|stale-worktree scan parses paths space-safely (awk substr, not \$2)" \
  ; do
    pat="${req%%|*}"; msg="${req#*|}"
    grep -q "$pat" "$ADV_MD" \
      && echo "✓ advance.md — $msg" \
      || { echo "✗ advance.md — MISSING: $msg (grep: $pat)"; FAIL=1; }
  done

  # W.5d anchoring: the merge/cleanup delegation and the executable conflict
  # recovery must live AFTER the Sub-step W.5d header — earlier hits (the
  # stale-worktree section) must not satisfy these. A vanished header is
  # itself a failure, not a silent pass.
  W5D_LINE=$(grep -n "Sub-step W.5d" "$ADV_MD" | head -1 | cut -d: -f1)
  if [ -z "$W5D_LINE" ]; then
    echo "✗ advance.md — 'Sub-step W.5d' header missing (merge/cleanup anchoring lost)"; FAIL=1
  else
    for req in \
      "wave-worktrees.sh merge|W.5d merge delegated to the script" \
      "wave-worktrees.sh cleanup|W.5d cleanup delegated to the script" \
      "-X theirs|executable stream-over conflict resolution present" \
      "git -C \"\$MAIN_ROOT\" merge|conflict-recovery merges target the MAIN checkout" \
    ; do
      pat="${req%%|*}"; msg="${req#*|}"
      awk -v n="$W5D_LINE" 'NR>n' "$ADV_MD" | grep -q -- "$pat" \
        && echo "✓ advance.md — $msg (after Sub-step W.5d, line $W5D_LINE)" \
        || { echo "✗ advance.md — MISSING after Sub-step W.5d: $msg (grep: $pat)"; FAIL=1; }
    done
  fi

  # FORBIDDEN patterns — each of these is a documented incident vector.
  for forb in \
    "git worktree add|inline worktree creation (must go through wave-worktrees.sh)" \
    "git branch -D|force-delete of branches (script owns refuse-if-unmerged -d)" \
    "Pre-worktree-isolation|legacy shared-tree compatibility language" \
    "The file \`.autocode/modules/.active-module\`|brief template still tells workers the replaced shared-marker story" \
  ; do
    pat="${forb%%|*}"; msg="${forb#*|}"
    if grep -q "$pat" "$ADV_MD"; then
      echo "✗ advance.md — FORBIDDEN: $msg (found: $pat)"; FAIL=1
    else
      echo "✓ advance.md — forbidden pattern absent: $pat"
    fi
  done

  # Two-tier property greps (case-insensitive denial-context filter). These
  # catch REWORDED shared-tree/fallback drift that literal greps miss:
  #   Tier 1 — any shared-tree execution language must sit on a line that
  #            itself denies it (NO shared / never / hard stop / incident /…).
  #   Tier 2 — any fallback directive needs denial context OR the
  #            active-module allow-context (the one legitimate fallback).
  T1_HITS=$(grep -iE 'shared[- ](tree|checkout|working)' "$ADV_MD" | grep -ivE "$DENIAL_RE" || true)
  if [ -n "$T1_HITS" ]; then
    echo "✗ advance.md — FORBIDDEN (tier 1): shared-tree language without denial context:"
    echo "$T1_HITS" | head -3 | sed 's/^/    /'; FAIL=1
  else
    echo "✓ advance.md — no shared-tree language outside denial context (tier 1)"
  fi
  T2_HITS=$(grep -iE 'fall.?back|fallback' "$ADV_MD" | grep -ivE "$DENIAL_RE" | grep -iv 'active-module' || true)
  if [ -n "$T2_HITS" ]; then
    echo "✗ advance.md — FORBIDDEN (tier 2): fallback directive without denial/active-module context:"
    echo "$T2_HITS" | head -3 | sed 's/^/    /'; FAIL=1
  else
    echo "✓ advance.md — no fallback directives outside denial/active-module context (tier 2)"
  fi

  # Mechanical verify must appear BEFORE the terminal guide (windows must not
  # open until the wave is verified).
  VERIFY_LINE=$(grep -n "MECHANICAL VERIFY" "$ADV_MD" | head -1 | cut -d: -f1)
  TERM_LINE=$(grep -n "OPEN.*TERMINAL WINDOWS" "$ADV_MD" | head -1 | cut -d: -f1)
  if [ -n "$VERIFY_LINE" ] && [ -n "$TERM_LINE" ] && [ "$VERIFY_LINE" -lt "$TERM_LINE" ]; then
    echo "✓ advance.md — mechanical verify (line $VERIFY_LINE) before terminal guide (line $TERM_LINE)"
  else
    echo "✗ advance.md — mechanical verify must precede terminal guide"; FAIL=1
  fi

  # W.5d merge must appear before W.6 commit gate
  MERGE_LINE=$(grep -n "wave-worktrees.sh merge" "$ADV_MD" | head -1 | cut -d: -f1)
  COMMIT_LINE=$(grep -n "COMMIT GATE\|Step W\.6" "$ADV_MD" | head -1 | cut -d: -f1)
  if [ -n "$MERGE_LINE" ] && [ -n "$COMMIT_LINE" ] && [ "$MERGE_LINE" -lt "$COMMIT_LINE" ]; then
    echo "✓ advance.md — merge (line $MERGE_LINE) before commit gate (line $COMMIT_LINE)"
  else
    echo "✗ advance.md — merge must precede commit gate"; FAIL=1
  fi
fi

# CHECK 11 — go.md hard-stops without worktree frontmatter and verifies isolation
# REWRITTEN 2026-07-10 with INVERTED POLARITY: the old check REQUIRED the
# soft "pre-worktree-isolation" fallback — the exact branch that executed the
# Jul-4 shared-tree dispatch. That fallback text now FAILS this check.
echo ""
echo "=== GO.MD WORKTREE NAVIGATION CHECK ==="
GO_MD=$(resolve_cmd go.md)
if [ -f "$GO_MD" ]; then
  for req in \
    "QUEUE FILE HAS NO WORKTREE|missing-frontmatter HARD STOP present" \
    "WORKTREE NOT FOUND|worktree-not-found stop present" \
    "back to \`pending\`|claim reverted to pending on hard stop" \
    "cd \[WORKTREE_PATH\]|cd-to-worktree instruction present" \
    "wave-worktrees.sh verify|isolation verify invocation present" \
    "rev-parse --abbrev-ref HEAD|branch identity check present" \
    "hard stop|'hard stop' language present" \
    "lost the claim race|NOT_PENDING branches on in_progress (race loss) instead of prescribing a revert" \
  ; do
    pat="${req%%|*}"; msg="${req#*|}"
    grep -q "$pat" "$GO_MD" \
      && echo "✓ go.md — $msg" \
      || { echo "✗ go.md — MISSING: $msg (grep: $pat)"; FAIL=1; }
  done

  # Every hard stop AFTER a successful claim must revert it — one revert site
  # (the original frontmatter-absent stop) is not enough. P-2 creates four:
  # frontmatter-absent, WORKTREE NOT FOUND, provision-failure, ISOLATION
  # VERIFY failure. The literal phrase pairs mechanically with the prose —
  # paraphrasing a revert line breaks this gate on purpose.
  REVERT_COUNT=$(grep -c 'back to `pending`' "$GO_MD" || true)
  if [ "${REVERT_COUNT:-0}" -ge 3 ]; then
    echo "✓ go.md — claim revert sites: $REVERT_COUNT (>= 3)"
  else
    echo "✗ go.md — only ${REVERT_COUNT:-0} 'back to \`pending\`' revert site(s); every post-claim hard stop must revert (need >= 3)"; FAIL=1
  fi

  # The mutex block self-binds q (one bind site) — that alone must not
  # satisfy this pin. The stale-sidecar snippet is a SEPARATE Bash tool call
  # (fresh shell) and must self-bind q too: require >= 2 bind sites.
  Q_BIND_COUNT=$(grep -cF 'q="[QUEUE_FILE]"' "$GO_MD" || true)
  if [ "${Q_BIND_COUNT:-0}" -ge 2 ]; then
    echo "✓ go.md — every standalone snippet self-binds q ($Q_BIND_COUNT bind sites)"
  else
    echo "✗ go.md — only ${Q_BIND_COUNT:-0} 'q=\"[QUEUE_FILE]\"' bind site(s); the stale-sidecar snippet must self-bind q (each Bash call is a fresh shell)"; FAIL=1
  fi
  # $q is bound only inside Bash code blocks that bind it themselves. Exactly
  # 4 'rm -f "$q.claiming"' references — NOT_PENDING, both FLIP_FAILED release
  # paths, and the CLAIMED cleanup — all inside the single claim-mutex call.
  # MORE than 4 = a dead $q reference in a satellite snippet; FEWER = a mutex
  # release site was deleted (a held sidecar deadlocks every later claim).
  Q_RM_COUNT=$(grep -c 'rm -f "\$q\.claiming"' "$GO_MD" || true)
  if [ "${Q_RM_COUNT:-0}" -eq 4 ]; then
    echo "✓ go.md — exactly 4 \$q rm sites, all inside the claim-mutex Bash call"
  else
    echo "✗ go.md — ${Q_RM_COUNT:-0} 'rm -f \"\$q.claiming\"' sites (need exactly 4, inside the mutex call); satellites must use the [QUEUE_FILE].claiming placeholder"; FAIL=1
  fi
  grep -q 'FLIP_FAILED' "$GO_MD" \
    && echo "✓ go.md — flip failure is a named outcome (python exit + read-back proven before CLAIMED)" \
    || { echo "✗ go.md — mutex lacks FLIP_FAILED handling (an unchecked flip prints CLAIMED on a still-pending file → double claim)"; FAIL=1; }

  for forb in \
    "Pre-worktree-isolation|legacy soft-fallback language" \
    "backward-compat|backward-compat fallback language" \
  ; do
    pat="${forb%%|*}"; msg="${forb#*|}"
    if grep -q "$pat" "$GO_MD"; then
      echo "✗ go.md — FORBIDDEN: $msg (found: $pat)"; FAIL=1
    else
      echo "✓ go.md — forbidden pattern absent: $pat"
    fi
  done

  # Two-tier property greps — same tiers as CHECK 10; the old literal
  # 'shared working directory' grep is subsumed by tier 1 (strictly broader).
  # The 'backward-compat' literal above is KEPT — tier 2 does not subsume it.
  T1_HITS=$(grep -iE 'shared[- ](tree|checkout|working)' "$GO_MD" | grep -ivE "$DENIAL_RE" || true)
  if [ -n "$T1_HITS" ]; then
    echo "✗ go.md — FORBIDDEN (tier 1): shared-tree language without denial context:"
    echo "$T1_HITS" | head -3 | sed 's/^/    /'; FAIL=1
  else
    echo "✓ go.md — no shared-tree language outside denial context (tier 1)"
  fi
  T2_HITS=$(grep -iE 'fall.?back|fallback' "$GO_MD" | grep -ivE "$DENIAL_RE" | grep -iv 'active-module' || true)
  if [ -n "$T2_HITS" ]; then
    echo "✗ go.md — FORBIDDEN (tier 2): fallback directive without denial/active-module context:"
    echo "$T2_HITS" | head -3 | sed 's/^/    /'; FAIL=1
  else
    echo "✓ go.md — no fallback directives outside denial/active-module context (tier 2)"
  fi
fi

# CHECK 12 — audit.md has finding promotion and advance approval gate
echo ""
echo "=== AUDIT.MD FINDING PROMOTION CHECK ==="
AUDIT_MD="$COMMANDS_DIR/audit.md"
if [ ! -f "$AUDIT_MD" ]; then
  if [ "$CANON_AVAILABLE" -eq 0 ]; then
    skip_canon "audit.md"
  else
    echo "✗ audit.md missing from canon: $AUDIT_MD (broken claude-dev-team install)"; FAIL=1
  fi
else
  grep -q "PROMOTE FINDINGS TO BATCH TASKS" "$AUDIT_MD" \
    && echo "✓ audit.md — finding promotion block present" \
    || { echo "✗ audit.md — missing promotion block (findings never become tasks)"; FAIL=1; }

  grep -q "DEDUP_KEY\|EXISTING_AUDIT_KEYS" "$AUDIT_MD" \
    && echo "✓ audit.md — deduplication logic present (prevents duplicate tasks)" \
    || { echo "✗ audit.md — missing deduplication (every audit run appends duplicates)"; FAIL=1; }

  grep -q "missing required\|malformed finding\|TOYOTA STOP.*validat" "$AUDIT_MD" \
    && echo "✓ audit.md — malformed finding validation present" \
    || { echo "✗ audit.md — missing field validation (malformed findings write broken tasks)"; FAIL=1; }

  grep -q "Run /advance now" "$AUDIT_MD" \
    && echo "✓ audit.md — /advance approval gate present (standalone mode)" \
    || { echo "✗ audit.md — missing approval gate (would auto-run /advance without Max's say)"; FAIL=1; }

  grep -q "yes.*affirmative\|affirmative\|yes/y/yeah" "$AUDIT_MD" \
    && echo "✓ audit.md — flexible affirmative matching (yes/y/yeah/go/proceed)" \
    || { echo "✗ audit.md — only matches exact 'yes' string (fragile approval gate)"; FAIL=1; }

  grep -q "Unrecognized response\|still unrecognized\|default to no" "$AUDIT_MD" \
    && echo "✓ audit.md — unrecognized input re-prompt present (safe default: no)" \
    || { echo "✗ audit.md — missing re-prompt for unrecognized input (gate may hang or accept garbage)"; FAIL=1; }

  grep -q "MODE.*orchestrated.*stop\|orchestrated.*Orchestrator will pick" "$AUDIT_MD" \
    && echo "✓ audit.md — orchestrated mode suppresses /advance prompt (correct)" \
    || { echo "✗ audit.md — orchestrated mode may prompt for /advance (worker can't run it)"; FAIL=1; }

  grep -q "BATCH_NUM\|Batch.*tasks.md" "$AUDIT_MD" \
    && echo "✓ audit.md — batch number detection present" \
    || { echo "✗ audit.md — missing batch detection (tasks appended to wrong section)"; FAIL=1; }

  grep -q "OPEN_AUDIT_TASK_COUNT\|prior audit tasks still open\|No outstanding audit tasks" "$AUDIT_MD" \
    && echo "✓ audit.md — PASS verdict open audit task check present" \
    || { echo "✗ audit.md — missing PASS verdict open audit task check (stale audit tasks invisible on PASS)"; FAIL=1; }

  # Verify promotion block appears BEFORE the standalone mode dispatch
  # Uses "Print the findings list (as before)" — unique marker inside the standalone section
  PROMOTE_LINE=$(grep -n "PROMOTE FINDINGS TO BATCH TASKS" "$AUDIT_MD" | head -1 | cut -d: -f1)
  STANDALONE_LINE=$(grep -n "Print the findings list (as before)" "$AUDIT_MD" | head -1 | cut -d: -f1)
  if [ -n "$PROMOTE_LINE" ] && [ -n "$STANDALONE_LINE" ] && [ "$PROMOTE_LINE" -lt "$STANDALONE_LINE" ]; then
    echo "✓ audit.md — promotion runs before standalone mode dispatch (correct order)"
  else
    echo "✗ audit.md — promotion order wrong (must run before MODE dispatch)"; FAIL=1
  fi
fi

# CHECK 13 — command-sync drift surfaced (informational here; strict exit-1
# mode runs at sync time, and the SessionStart hook in .claude/settings.json
# surfaces drift at every session start — non-blocking there via `|| true`,
# so a diverged mirror informs rather than bricks sessions). Divergence is
# an EXPECTED state between editing a command and the post-merge sync, so it
# must not fail structural checks — but a missing/broken detector must.)
# This is the ONLY --warn invocation in the commit path (the hook's direct
# call was removed — this check covers it). SYNC_ROOT pins the sync check to
# the same root these checks resolved (the staged mirror when TMC_STAGED_DIR
# is set) — without it the mirrored run would diff LIVE command files.
echo ""
echo "=== COMMAND SYNC DRIFT CHECK ==="
SYNC_SCRIPT="$PROJECT_ROOT/scripts/check-command-sync.sh"
if [ ! -f "$SYNC_SCRIPT" ]; then
  echo "✗ scripts/check-command-sync.sh missing — drift detector not installed"; FAIL=1
elif ! bash -n "$SYNC_SCRIPT" 2>/dev/null; then
  echo "✗ check-command-sync.sh fails bash -n — drift detector is broken"; FAIL=1
else
  SYNC_ROOT="$PROJECT_ROOT" bash "$SYNC_SCRIPT" --warn || { echo "✗ check-command-sync.sh crashed in --warn mode"; FAIL=1; }
  grep -qF 'scripts/$s in canon but not adopted' "$SYNC_SCRIPT" \
    && echo "✓ check-command-sync.sh — canon-only scripts surface as 'not adopted' (no silent skip)" \
    || { echo "✗ check-command-sync.sh — silently skips scripts absent from the project (canon-only scripts invisible)"; FAIL=1; }
fi

# CHECK 14 — pre-commit hook head contract: deletion-only commits must not
# bypass the hook. STAGED_DELETED must be computed, and the early-exit must
# require BOTH lists empty. Resolved against the staged mirror when
# TMC_STAGED_DIR is set, else the project hook file.
echo ""
echo "=== PRE-COMMIT HOOK HEAD CONTRACT CHECK ==="
HOOK_FILE="$PROJECT_ROOT/.husky/pre-commit"
if [ ! -f "$HOOK_FILE" ]; then
  echo "✗ .husky/pre-commit missing at $HOOK_FILE"; FAIL=1
else
  grep -q "STAGED_DELETED=" "$HOOK_FILE" \
    && echo "✓ pre-commit — STAGED_DELETED computed" \
    || { echo "✗ pre-commit — STAGED_DELETED= missing (deletion-only commits bypass every gate)"; FAIL=1; }
  grep -qF 'if [ -z "$STAGED" ] && [ -z "$STAGED_DELETED" ]; then' "$HOOK_FILE" \
    && echo "✓ pre-commit — combined early-exit (exits only when BOTH lists are empty)" \
    || { echo "✗ pre-commit — combined early-exit missing (must require both STAGED and STAGED_DELETED empty)"; FAIL=1; }
  grep -qE 'git diff (--cached )?--no-renames' "$HOOK_FILE" \
    && echo "✓ pre-commit — --no-renames on staged-diff computations (rename evasion closed)" \
    || { echo "✗ pre-commit — missing 'git diff --cached --no-renames' (git mv folds D+A into R and slips past --diff-filter=D)"; FAIL=1; }
  grep -qF 'MIRROR_PS=("${PIPESTATUS[@]}")' "$HOOK_FILE" \
    && echo "✓ pre-commit — mirror pipeline exit codes captured (PIPESTATUS array copy)" \
    || { echo "✗ pre-commit — missing 'MIRROR_PS=(\"\${PIPESTATUS[@]}\")' (checkout-index mirror failure not captured → silent canon fallback)"; FAIL=1; }
  grep -qF 'HARNESS MIRROR FAILED (ls-files=${MIRROR_PS[0]}' "$HOOK_FILE" \
    && echo "✓ pre-commit — captured mirror failure is a HARD BLOCK (HARNESS MIRROR FAILED)" \
    || { echo "✗ pre-commit — no 'HARNESS MIRROR FAILED' hard block consuming MIRROR_PS (a captured-but-unconsumed exit code lets a failed mirror fall through silently)"; FAIL=1; }
  grep -qF "DIVERGED|missing from claude-dev-team|COLLISION" "$HOOK_FILE" \
    && echo "✓ pre-commit — sync-drift lines echoed on every harness commit" \
    || { echo "✗ pre-commit — drift lines from the mirrored TMC run are discarded on TMC success"; FAIL=1; }
  for gf in "scripts/classify-diff-size.sh" "scripts/staged-diff-hash.sh"; do
    if [ ! -f "$PROJECT_ROOT/$gf" ]; then
      echo "⚠ SKIPPED: $gf not present in this project (hook's GATE SCRIPT MISSING block covers absence at commit time)"
    elif grep -q 'git diff --cached --no-renames' "$PROJECT_ROOT/$gf"; then
      echo "✓ $gf — --no-renames present on the staged-diff command"
    else
      echo "✗ $gf — missing 'git diff --cached --no-renames' (rename evasion open)"; FAIL=1
    fi
  done
fi

echo ""
echo "Checks skipped (canon unavailable): $SKIPPED"
if [ "$FAIL" -eq 0 ]; then
  echo "=== RESULT: PASS — MODULE_CONTEXT wired correctly in all commands ==="
  exit 0
else
  echo "=== RESULT: FAIL — issue(s) found. Fix before Phase 2. ==="
  exit 1
fi
