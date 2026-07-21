#!/usr/bin/env bash
# ===========================================
# DEEP AUDIT — Implementation Honesty Check
# ===========================================
# Run after every feature, BEFORE declaring done.
# Paste the FULL output into the conversation.
# The output IS the proof. You cannot fake what a script prints.
#
# What this audits (that the shipping gate does NOT):
#   Layer 1 — Known failure modes (incident-derived grep patterns)
#   Layer 2 — Caller completeness (all call sites found, all awaited)
#   Layer 3 — Enforcement scope (hook/gate patterns cover all callers)
#   Layer 4 — Async contract accuracy (test mocks reflect async reality)
#   Layer 5 — Production observability (every failure path logged)
#   Layer 6 — Test invariant completeness (range checks, not just type checks)
#   Layer 7 — Cleanup (dead deprecated exports, stale test helpers)
#
# Exit codes:
#   0 = all checks passed
#   1 = one or more checks FAILED (do not declare done)
#
# Usage: bash scripts/deep-audit.sh <file1> [file2] [file3] ...
# Example: bash scripts/deep-audit.sh apps/web/src/lib/rate-limit.ts \
#                                      apps/web/src/lib/scheduling-auth.ts
# ===========================================

set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "Usage: bash scripts/deep-audit.sh <file1> [file2] ..."
  echo "Pass the source files you changed in this feature."
  exit 1
fi

FILES=("$@")
FAIL_COUNT=0

echo "=== DEEP AUDIT REPORT ==="
echo "Files: ${FILES[*]}"
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# ===========================================
# LAYER 1: KNOWN FAILURE MODES
# ===========================================
# Grep patterns derived from actual production incidents.
# Each check cites its incident so future engineers know why it exists.
# New incidents → new checks added here. The database grows with history.
# ===========================================
echo "--- LAYER 1: KNOWN FAILURE MODES ---"

# INCIDENT: TWILIO_AUTH_TOKEN trailing \n (May 2026)
# A trailing newline from copy-pasting into Vercel dashboard caused every
# Twilio HMAC-SHA1 comparison to fail. Webhooks rejected for 16 days.
# Same class: any env var used in an HTTP header/auth without .trim().
L1_ENV_NO_TRIM=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  count=$(grep -n "process\.env\." "$f" 2>/dev/null \
    | grep -v "\.trim()\|NODE_ENV\|VERCEL_\|NEXT_PUBLIC_\|PORT\b\|//\|process\.env\.[A-Za-z_][A-Za-z0-9_]* =" \
    | wc -l | tr -d ' ')
  L1_ENV_NO_TRIM=$((L1_ENV_NO_TRIM + count))
  if [ "$count" != "0" ]; then
    grep -n "process\.env\." "$f" 2>/dev/null \
      | grep -v "\.trim()\|NODE_ENV\|VERCEL_\|NEXT_PUBLIC_\|PORT\b\|//\|process\.env\.[A-Za-z_][A-Za-z0-9_]* =" \
      | while IFS= read -r line; do echo "  $(basename "$f"): $line"; done
  fi
done
echo "Env vars without .trim(): $L1_ENV_NO_TRIM $([ "$L1_ENV_NO_TRIM" = "0" ] && echo '✓' \
  || echo '✗ FAIL — add .trim() at env boundary (TWILIO_AUTH_TOKEN incident, May 2026)')"
[ "$L1_ENV_NO_TRIM" != "0" ] && FAIL_COUNT=$((FAIL_COUNT + 1))

# INCIDENT: #45 rate-limiter — in-memory Map/Set, per-Vercel-instance
# Rate limit counters in a module-scope Map were invisible across instances.
# A user hitting N Vercel instances got N×limit requests through unchecked.
# Rule: stateful data at module scope is always wrong in serverless.
L1_IN_MEM=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  [[ "$f" == *".test."* ]] && continue
  # Lines preceded by a comment containing "audit-ok" are intentional read-only
  # module-init registries (not mutable per-request shared state) and are suppressed.
  count=$(grep -n "^const [a-zA-Z_]* = new Map\|^const [a-zA-Z_]* = new Set\|^export const [a-zA-Z_]* = new Map\|^export const [a-zA-Z_]* = new Set" \
    "$f" 2>/dev/null | while IFS= read -r match; do
      lineno=$(echo "$match" | cut -d: -f1)
      prevline=$(sed -n "$((lineno - 1))p" "$f" 2>/dev/null)
      echo "$prevline" | grep -q "audit-ok" || echo "$match"
    done | wc -l | tr -d ' ')
  L1_IN_MEM=$((L1_IN_MEM + count))
  if [ "$count" != "0" ]; then
    grep -n "^const [a-zA-Z_]* = new Map\|^const [a-zA-Z_]* = new Set\|^export const [a-zA-Z_]* = new Map\|^export const [a-zA-Z_]* = new Set" \
      "$f" 2>/dev/null | while IFS= read -r match; do
        lineno=$(echo "$match" | cut -d: -f1)
        prevline=$(sed -n "$((lineno - 1))p" "$f" 2>/dev/null)
        echo "$prevline" | grep -q "audit-ok" || echo "  $(basename "$f"): $match"
      done
  fi
done
echo "Module-scope Map/Set (per-instance on Vercel): $L1_IN_MEM $([ "$L1_IN_MEM" = "0" ] && echo '✓' \
  || echo '✗ FAIL — use Redis/DB for shared state (rate-limiter incident, task #45)')"
[ "$L1_IN_MEM" != "0" ] && FAIL_COUNT=$((FAIL_COUNT + 1))

# INCIDENT: #45 audit 4 — HTTP non-OK responses returned null silently
# A 503 from Upstash produced zero logs. Redis was failing open invisibly
# for the entire duration of an outage with no operational signal.
# Pattern: single-line "if (!res.ok) return null" — multi-line blocks with
# a log on the next line are fine and should not be flagged.
L1_SILENT_NOK=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  [[ "$f" == *".test."* ]] && continue
  count=$(grep -n "if.*!res\.ok.*return\|if.*!response\.ok.*return" "$f" 2>/dev/null \
    | grep -v "console\.\|logger\.\|log\.\|warn\b\|error\b\|throw\b\|//" \
    | wc -l | tr -d ' ')
  L1_SILENT_NOK=$((L1_SILENT_NOK + count))
  if [ "$count" != "0" ]; then
    grep -n "if.*!res\.ok.*return\|if.*!response\.ok.*return" "$f" 2>/dev/null \
      | grep -v "console\.\|logger\.\|log\.\|warn\b\|error\b\|throw\b\|//" \
      | while IFS= read -r line; do echo "  $(basename "$f"): $line"; done
  fi
done
echo "Silent non-OK HTTP returns (no log): $L1_SILENT_NOK $([ "$L1_SILENT_NOK" = "0" ] && echo '✓' \
  || echo '✗ FAIL — log status code before returning null (Upstash outage incident, #45 audit 4)')"
[ "$L1_SILENT_NOK" != "0" ] && FAIL_COUNT=$((FAIL_COUNT + 1))

# INCIDENT: unauthorized_client breaks sync silently (June 2026)
# A refresh token issued for an old GCP OAuth client returned unauthorized_client.
# The error fell through the TokenRevokedError guard, crashed sync, and showed no
# reconnect banner — user had no recovery path. Classification gap.
# Rule: if invalid_grant is handled as revocation, unauthorized_client must be too.
L1_OAUTH_CLASSIFY=0
for f in "${FILES[@]}"; do
  if grep -q 'invalid_grant' "$f" 2>/dev/null; then
    if ! grep -q 'unauthorized_client' "$f" 2>/dev/null; then
      echo "  ✗ $(basename "$f") handles invalid_grant but NOT unauthorized_client"
      L1_OAUTH_CLASSIFY=$((L1_OAUTH_CLASSIFY + 1))
    fi
  fi
done
echo "OAuth error classification completeness: $([ "$L1_OAUTH_CLASSIFY" = "0" ] && echo '✓' \
  || echo "✗ FAIL — $L1_OAUTH_CLASSIFY file(s) missing unauthorized_client (sync incident, June 2026)")"
[ "$L1_OAUTH_CLASSIFY" != "0" ] && FAIL_COUNT=$((FAIL_COUNT + 1))

# SECURITY: postMessage must use window.location.origin, never '*'
# Using '*' as targetOrigin lets any origin receive sensitive message payloads.
# Rule: all window.opener.postMessage calls must specify window.location.origin.
L1_PM_WILDCARD=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  [[ "$f" == *".test."* ]] && continue
  if grep -q "postMessage(" "$f" 2>/dev/null; then
    if ! grep -q "window\.location\.origin\|BroadcastChannel" "$f" 2>/dev/null; then
      count=$(grep -c "postMessage(" "$f" 2>/dev/null || true)
      L1_PM_WILDCARD=$((L1_PM_WILDCARD + count))
      grep -n "postMessage(" "$f" | while IFS= read -r line; do echo "  $(basename "$f"): $line"; done
    fi
  fi
done
echo "postMessage without window.location.origin: $L1_PM_WILDCARD $([ "$L1_PM_WILDCARD" = "0" ] && echo '✓' \
  || echo '✗ FAIL — use window.location.origin as targetOrigin (security: cross-origin message leakage)')"
[ "$L1_PM_WILDCARD" != "0" ] && FAIL_COUNT=$((FAIL_COUNT + 1))

# INCIDENT: readDraft/writeDraft called during render body (Jun 2026)
# These functions have localStorage side effects (delete, write). Calling them during
# render means React's double-invoke in StrictMode or any re-render returns null.
# They MUST only appear inside useState(() => ...) initializers in .tsx files.
L1_DRAFT_IN_RENDER=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  [[ "$f" == *.tsx ]] || continue
  [[ "$f" == *.test.* ]] && continue
  # Check for readDraft( or writeDraft( in a const/let/var declaration NOT inside useState.
  # Multi-line initializers (e.g. useState(() =>\n  readDraft(key)\n)) are safe — the
  # continuation line doesn't start with const/let/var, so it won't be flagged.
  count=$(grep -n "readDraft(\|writeDraft(" "$f" 2>/dev/null \
    | grep -E "^[[:space:]]*[0-9]+:[[:space:]]*(const|let|var) " \
    | grep -v "useState\|import" \
    | wc -l | tr -d ' ')
  L1_DRAFT_IN_RENDER=$((L1_DRAFT_IN_RENDER + count))
  if [ "$count" != "0" ]; then
    grep -n "readDraft(\|writeDraft(" "$f" 2>/dev/null \
      | grep -E "^[[:space:]]*[0-9]+:[[:space:]]*(const|let|var) " \
      | grep -v "useState\|import" \
      | while IFS= read -r line; do echo "  $(basename "$f"): $line"; done
  fi
done
echo "readDraft/writeDraft outside useState (render side-effect): $L1_DRAFT_IN_RENDER $([ "$L1_DRAFT_IN_RENDER" = "0" ] && echo '✓' \
  || echo '✗ FAIL — wrap in useState(() => readDraft(key)) initializer (render StrictMode bug, Jun 2026)')"
[ "$L1_DRAFT_IN_RENDER" != "0" ] && FAIL_COUNT=$((FAIL_COUNT + 1))

echo ""

# ===========================================
# LAYER 2: CALLER COMPLETENESS
# ===========================================
# Auto-extracts exported function/const names from changed files.
# Greps ALL source directories — not just src/app/api/.
# The #45 mistake: grep only covered src/app/api/ and missed
# src/lib/internal-api.ts, src/lib/csrf-token.ts.
# ===========================================
echo "--- LAYER 2: CALLER COMPLETENESS ---"

# Initialize arrays — must be set before the loop to avoid unbound variable errors
# ASYNC_EXPORTS: functions that return Promises — callers MUST use await
# SYNC_EXPORTS: all exported names (for hook scope and mock checks where relevant)
ASYNC_EXPORTS=()
SYNC_EXPORTS=()

# Next.js route handler exports are framework entry points invoked by the router —
# they have no application call sites. Including them in ASYNC_EXPORTS causes two
# false positives on every audit run:
#   Layer 2: other route files exporting the same handler names look like "call sites"
#   Layer 4: mock variables like mockGetSession contain 'Get' (case-insensitive match)
# SYNC_EXPORTS does NOT need this filter — the SYNC grep pattern is "^export function"
# (no "async" keyword), which never matches "export async function GET". A second
# grep-v "^export async" in the SYNC loop provides an additional exclusion layer.
NEXTJS_HANDLER_NAMES=( GET POST PUT DELETE PATCH HEAD OPTIONS )

for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  [[ "$f" == *".test."* ]] && continue
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [[ " ${NEXTJS_HANDLER_NAMES[*]} " == *" $name "* ]] && continue
    ASYNC_EXPORTS+=("$name")
  done < <(grep -h "^export async function\|^export const [A-Za-z].* = async " \
    "$f" 2>/dev/null \
    | grep -oE "(function|const) [A-Za-z][A-Za-z0-9_]+" \
    | awk '{print $2}' \
    | sort -u)
  while IFS= read -r name; do
    [ -n "$name" ] && SYNC_EXPORTS+=("$name")
  done < <(grep -h "^export function\|^export const [A-Za-z]" \
    "$f" 2>/dev/null \
    | grep -v "^export async\|^export const [A-Za-z].* = async " \
    | grep -oE "(function|const) [A-Za-z][A-Za-z0-9_]+" \
    | awk '{print $2}' \
    | sort -u)
done

# bash 3.2 (macOS default) treats ${empty_array[@]} as unbound with set -u.
# Guard every array expansion with an explicit length check.
if [ ${#ASYNC_EXPORTS[@]} -gt 0 ]; then
  ASYNC_EXPORTS=($(printf '%s\n' "${ASYNC_EXPORTS[@]}" | sort -u))
fi
if [ ${#SYNC_EXPORTS[@]} -gt 0 ]; then
  SYNC_EXPORTS=($(printf '%s\n' "${SYNC_EXPORTS[@]}" | sort -u))
fi
# All exports combined for scope/hook checks
ALL_EXPORTS=()
[ ${#ASYNC_EXPORTS[@]} -gt 0 ] && ALL_EXPORTS+=("${ASYNC_EXPORTS[@]}")
[ ${#SYNC_EXPORTS[@]} -gt 0 ] && ALL_EXPORTS+=("${SYNC_EXPORTS[@]}")

if [ "${#ASYNC_EXPORTS[@]}" -eq 0 ]; then
  echo "  No async exported functions detected in changed files."
  if [ ${#SYNC_EXPORTS[@]} -gt 0 ]; then
    for func in "${SYNC_EXPORTS[@]}"; do
      echo "  ${func}: sync (no await needed) ✓"
    done
  fi
else
  for func in "${ASYNC_EXPORTS[@]}"; do
    # Find all non-test, non-import call sites across the entire codebase.
    # Exclude: test files, type declarations, import lines, export declarations,
    # inline comments (//), and JSDoc comment lines (lines starting with * ).
    # NB: [[:space:]] not \s — BSD/macOS grep does not honor \s (see the
    # diagnostic-printer comment below); using \s here would silently fail to
    # exclude indented import/JSDoc lines on macOS, inflating TOTAL.
    TOTAL=$(grep -rn "${func}(" apps/web/src packages --include="*.ts" --include="*.tsx" 2>/dev/null \
      | grep -v "\.test\.\|\.d\.ts\|^[[:space:]]*import\b\|export.*function ${func}\|export const ${func}\|//.*${func}\|[[:space:]]*\*.*${func}\|${func}.*: Promise" \
      | wc -l | tr -d ' ')
    # Match both direct calls (await fn()) and method calls (await obj.fn())
    AWAITED_DIRECT=$(grep -rn "await .*${func}(" apps/web/src packages --include="*.ts" --include="*.tsx" 2>/dev/null \
      | grep -v "\.test\.\|\.d\.ts\|//\|[[:space:]]*\*" \
      | wc -l | tr -d ' ')
    # 'return asyncFn()' is also valid — the Promise is propagated to the caller.
    # Exclude ONLY lines AWAITED_DIRECT already counted — i.e. `await ...${func}(`
    # (a `return await fn()` double-counts otherwise: AWAITED > TOTAL → a
    # nonsensical negative "missing" and a false FAIL). Do NOT exclude every line
    # containing 'await': `return fn(await bar())` returns fn's promise while the
    # await belongs to a DIFFERENT call — excluding it would undercount and
    # produce the opposite false FAIL.
    RETURNED=$(grep -rn "return .*${func}(" apps/web/src packages --include="*.ts" --include="*.tsx" 2>/dev/null \
      | grep -v "\.test\.\|\.d\.ts\|//\|[[:space:]]*\*\|await .*${func}(" \
      | wc -l | tr -d ' ')
    AWAITED=$((AWAITED_DIRECT + RETURNED))

    if [ "$TOTAL" = "0" ]; then
      echo "  ${func} (async): no call sites ✓"
    elif [ "$AWAITED" -eq "$TOTAL" ]; then
      echo "  ${func} (async): $TOTAL call site(s), all awaited ✓"
    elif [ "$AWAITED" -gt "$TOTAL" ]; then
      # AWAITED should never exceed TOTAL once RETURNED excludes `await` (the
      # return-await double-count is fixed). If it still does, the async-detection
      # greps and TOTAL's exclusions disagree — treat as handled (a false FAIL is
      # worse) but SURFACE the anomaly rather than silently passing, so the
      # heuristic drift is visible instead of hidden.
      echo "  ${func} (async): $TOTAL call site(s), all awaited ✓ (anomaly: awaited-count $AWAITED > total — grep heuristics disagree; investigate deep-audit.sh, not the code)"
    else
      MISSING=$((TOTAL - AWAITED))
      echo "  ${func} (async): $TOTAL call site(s), $MISSING missing await ✗ FAIL"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      # Print the actual unhandled sites — never the function's OWN declaration.
      # The declaration is excluded with the SAME robust patterns TOTAL uses
      # (export-function / export-const / `: Promise` return type); the previous
      # `^\s*export\b` relied on \s, which BSD grep (macOS) does not honor, so
      # the `export async function <name>(...)` line leaked in and was printed
      # as if it were a missing-await call site.
      grep -rn "${func}(" apps/web/src packages --include="*.ts" --include="*.tsx" 2>/dev/null \
        | grep -v "\.test\.\|\.d\.ts\|^[[:space:]]*import\b\|export.*function ${func}\|export const ${func}\|${func}.*: Promise\|[[:space:]]*\*.*${func}\|await\|return .*${func}(\|//" \
        | head -5 | while IFS= read -r line; do echo "    $line"; done
    fi
  done
  if [ ${#SYNC_EXPORTS[@]} -gt 0 ]; then
    for func in "${SYNC_EXPORTS[@]}"; do
      echo "  ${func} (sync): no await needed ✓"
    done
  fi
fi

echo ""

# ===========================================
# LAYER 3: ENFORCEMENT SCOPE
# ===========================================
# Simulates the pre-commit hook's grep pattern against each actual caller.
# The #45 mistake: hook pattern was 'src/lib/scheduling' which matched
# scheduling-auth.ts but NOT internal-api.ts or csrf-token.ts.
# ===========================================
echo "--- LAYER 3: ENFORCEMENT SCOPE ---"

HOOK_PATTERN=$(grep "RATE_LIMIT_CALLERS=" .husky/pre-commit 2>/dev/null \
  | grep -oE "grep -E '[^']+'" | grep -oE "'[^']+'" | tr -d "'" | head -1 || true)

if [ -z "$HOOK_PATTERN" ]; then
  echo "  Rate-limit hook pattern not found — skipping scope check ⚠"
else
  echo "  Hook scope pattern: $HOOK_PATTERN"

  # Scope check applies only to rate-limit exports — the hook (#26) covers
  # checkRateLimit/applyRateLimit callers specifically. Other exports (fee calculators,
  # config, services) have their own enforcement layers and must not be scope-checked
  # against the rate-limit hook pattern, or non-rate-limit callers will false-positive.
  # Also: only search apps/web/src — packages/ paths never match web-app hook patterns,
  # causing the function's own source file to be flagged as "outside scope."
  RATE_LIMIT_FUNCS=()
  if [ ${#ALL_EXPORTS[@]} -gt 0 ]; then
    for func in "${ALL_EXPORTS[@]}"; do
      echo "$func" | grep -qiE "[Rr]ate[Ll]imit|[Cc]heck[Rr]ate|[Aa]pply[Rr]ate" \
        && RATE_LIMIT_FUNCS+=("$func")
    done
  fi

  if [ "${#RATE_LIMIT_FUNCS[@]}" -eq 0 ]; then
    echo "  No rate-limit exports in changed files — scope check not applicable ✓"
  else
    SCOPE_FAIL=0
    for func in "${RATE_LIMIT_FUNCS[@]}"; do
      while IFS= read -r caller; do
        if echo "$caller" | grep -qE "$HOOK_PATTERN"; then
          echo "  ✓ $(echo "$caller" | sed 's|.*/apps/web/src/||') — within hook scope"
        else
          echo "  ✗ $(echo "$caller" | sed 's|.*/apps/web/src/||') — OUTSIDE hook scope ✗ FAIL"
          SCOPE_FAIL=$((SCOPE_FAIL + 1))
        fi
      done < <(grep -rln "${func}(" apps/web/src --include="*.ts" 2>/dev/null \
        | grep -v "\.test\.\|\.d\.ts\|rate-limit\.ts\b" || true)
    done
    [ "$SCOPE_FAIL" != "0" ] && FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
fi

echo ""

# ===========================================
# LAYER 4: ASYNC CONTRACT ACCURACY
# ===========================================
# Scans test files for sync mocks of exported async functions.
# The #45 mistake: 58 test files used mockReturnValue instead of
# mockResolvedValue. Tests passed (await syncValue = syncValue) but
# the mocks didn't represent the async contract. A future developer
# writing const r = applyRateLimit(...) (no await) would see passing
# tests while production 429s every request.
# ===========================================
echo "--- LAYER 4: ASYNC CONTRACT ACCURACY ---"

L4_FAIL=0
if [ "${#ASYNC_EXPORTS[@]}" -eq 0 ]; then
  echo "  No async exports — sync mock check skipped ✓"
else
  for func in "${ASYNC_EXPORTS[@]}"; do
    # Direct module mock: funcName: vi.fn().mockReturnValue(...)
    DIRECT=$(grep -rhn "${func}.*mockReturnValue\|${func}:.*() =>" \
      apps/web/src --include="*.test.*" --include="*.spec.*" 2>/dev/null \
      | grep -v "mockResolvedValue\|//" | wc -l | tr -d ' ')

    # Backing variable mock: variable containing func name + .mockReturnValue
    BACKING=$(grep -rhn "\.mockReturnValue\b" \
      apps/web/src --include="*.test.*" --include="*.spec.*" 2>/dev/null \
      | grep -i "${func}" \
      | grep -v "mockResolvedValue\|//" | wc -l | tr -d ' ')

    TOTAL_SYNC=$((DIRECT + BACKING))
    echo "  ${func} (async) sync mocks: $TOTAL_SYNC $([ "$TOTAL_SYNC" = "0" ] && echo '✓' \
      || echo '✗ FAIL — use mockResolvedValue for async functions')"
    if [ "$TOTAL_SYNC" != "0" ]; then
      L4_FAIL=$((L4_FAIL + 1))
      grep -rhn "${func}.*mockReturnValue\|${func}:.*() =>" \
        apps/web/src --include="*.test.*" 2>/dev/null \
        | grep -v "mockResolvedValue\|//" | head -3 \
        | while IFS= read -r line; do echo "    $line"; done
    fi
  done
fi
[ "$L4_FAIL" != "0" ] && FAIL_COUNT=$((FAIL_COUNT + 1))

# vi.spyOn without restoreAllMocks — spy accumulates across tests
# Check test files co-located with the changed source files
SPY_NO_RESTORE=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  if [[ "$f" == *".test."* ]]; then
    test_file="$f"
  else
    test_file="${f%.ts}.test.ts"
    [ -f "$test_file" ] || test_file="${f%.tsx}.test.tsx"
  fi
  [ -f "$test_file" ] || continue
  if grep -q "vi\.spyOn" "$test_file" 2>/dev/null && \
     ! grep -q "restoreAllMocks\|vi\.restore" "$test_file" 2>/dev/null; then
    echo "  ⚠ $(basename "$test_file") — vi.spyOn without restoreAllMocks in afterEach"
    SPY_NO_RESTORE=$((SPY_NO_RESTORE + 1))
  fi
done
[ "$SPY_NO_RESTORE" = "0" ] && echo "  vi.spyOn lifecycle: ✓"

echo ""

# ===========================================
# LAYER 5: PRODUCTION OBSERVABILITY
# ===========================================
# Every failure path that swallows an error must produce an observable signal.
# Checks: bare catches, unbound catches, silent null returns after try/catch.
# The #45 audit 3 finding: catch {} with no error binding is a Rule 8 violation
# AND blocks every future commit via the pre-commit hook.
# ===========================================
echo "--- LAYER 5: PRODUCTION OBSERVABILITY ---"

L5_BARE=0
L5_SILENT_RETURN=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  [[ "$f" == *".test."* ]] && continue

  # Only flag truly empty catch bodies: `catch {}` (single-line) or `catch {\n}` (multi-line).
  # TypeScript 4+ no-binding `catch {` with a non-empty body is valid and NOT a violation.
  bare_single=$(grep -cE 'catch\s*\{\s*\}' "$f" 2>/dev/null || echo 0)
  bare_multi=$(awk '
    /catch[[:space:]]*\{[[:space:]]*$/ { in_catch=1; empty=1; next }
    in_catch && /[^[:space:]{}]/ { empty=0 }
    in_catch && /}/ { if(empty) count++; in_catch=0; empty=0 }
    END { print count+0 }
  ' "$f" 2>/dev/null || echo 0)
  bare_single=$(echo "${bare_single:-0}" | tr -d '[:space:]')
  bare_multi=$(echo "${bare_multi:-0}" | tr -d '[:space:]')
  bare=$(( bare_single + bare_multi ))
  L5_BARE=$((L5_BARE + bare))

  # catch (err) blocks — count total, bare catches already handled above
  # Informational: how many catch blocks exist (each should have visible logging)
  total_catches=$(grep -c "catch (" "$f" 2>/dev/null | head -1 | tr -d ' ' || echo 0)
  logged_catches=$(grep -A2 "catch (" "$f" 2>/dev/null \
    | grep -c "console\.\|logger\.\|warn\b\|error\b\|throw\b" 2>/dev/null | head -1 | tr -d ' ' || echo 0)
  # Guard: both must be numeric before arithmetic
  if [[ "$total_catches" =~ ^[0-9]+$ ]] && [[ "$logged_catches" =~ ^[0-9]+$ ]]; then
    unlogged=$((total_catches - logged_catches))
    [ "$unlogged" -gt 0 ] && L5_SILENT_RETURN=$((L5_SILENT_RETURN + unlogged))
  fi
done

echo "Bare catches (catch {}): $L5_BARE $([ "$L5_BARE" = "0" ] && echo '✓' \
  || echo '✗ FAIL — bind error and log (pre-commit hook will block this)')"
[ "$L5_BARE" != "0" ] && FAIL_COUNT=$((FAIL_COUNT + 1))

echo "Catches with silent return (no log): $L5_SILENT_RETURN $([ "$L5_SILENT_RETURN" = "0" ] && echo '✓' \
  || echo '⚠ REVIEW — verify each catch that returns null has a console.warn')"

echo ""

# ===========================================
# LAYER 6: TEST INVARIANT COMPLETENESS
# ===========================================
# Tests that only check "it's a number" leave bugs invisible.
# Strong invariants: "it's > 0 and <= windowMs", "it contains X but not Y".
# The #45 audit 3 finding: pipeline test never asserted TTL was > 0.
# A bug setting TTL to 0 (immediate expiry, rate limiting disabled) would pass.
# ===========================================
echo "--- LAYER 6: TEST INVARIANT COMPLETENESS ---"

L6_WEAK=0
L6_RANGE=0
# Check source files' co-located test files
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  # Determine which test file to check
  if [[ "$f" == *".test."* ]]; then
    test_file="$f"
  else
    test_file="${f%.ts}.test.ts"
    [ -f "$test_file" ] || test_file="${f%.tsx}.test.tsx"
  fi
  [ -f "$test_file" ] || continue

  weak=$(grep -cn "toBe('number')\|toBe(\"number\")\|toBeInstanceOf(Number)" \
    "$test_file" 2>/dev/null | tr -d ' ')
  L6_WEAK=$((L6_WEAK + weak))

  range=$(grep -cn "toBeGreaterThan\|toBeLessThanOrEqual\|toBeGreaterThanOrEqual\|toBeLessThan" \
    "$test_file" 2>/dev/null | tr -d ' ')
  L6_RANGE=$((L6_RANGE + range))
done

echo "Weak typeof-only assertions: $L6_WEAK $([ "$L6_WEAK" = "0" ] && echo '✓' \
  || echo '⚠ REVIEW — consider adding range check (e.g. toBeGreaterThan(0))')"
echo "Range assertions in test files: $L6_RANGE $([ "$L6_RANGE" != "0" ] && echo '✓' \
  || echo '⚠ REVIEW — numeric values should have range checks, not just type checks')"

echo ""

# ===========================================
# LAYER 7: CLEANUP
# ===========================================
# Dead deprecated exports still imported elsewhere are misleading.
# Dead test helpers (no-ops) provide false confidence.
# The #45 finding: _resetRateLimitStore called in 7 integration test files
# after it became a no-op — tests appeared to reset state but did nothing.
# ===========================================
echo "--- LAYER 7: CLEANUP ---"

L7_DEPRECATED=0
L7_DEP_CHECKED=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  # Find @deprecated exports in changed files
  while IFS= read -r func_name; do
    [ -z "$func_name" ] && continue
    L7_DEP_CHECKED=$((L7_DEP_CHECKED + 1))
    callers=$(grep -rn "${func_name}" apps/web/src --include="*.ts" 2>/dev/null \
      | grep -v "^\s*\(export\|//\|@deprecated\)" \
      | grep -v "$(basename "$f")\|\.d\.ts" \
      | wc -l | tr -d ' ')
    if [ "$callers" != "0" ]; then
      echo "  ✗ @deprecated ${func_name} still called in $callers place(s) — remove dead callers"
      L7_DEPRECATED=$((L7_DEPRECATED + callers))
    else
      echo "  ✓ @deprecated ${func_name} — no live callers"
    fi
  done < <(grep -h "@deprecated" "$f" 2>/dev/null \
    | grep -oE "function [A-Za-z_]+" | awk '{print $2}' || true)
done
[ "$L7_DEP_CHECKED" = "0" ] && echo "  @deprecated exports: none in changed files ✓"
[ "$L7_DEPRECATED" != "0" ] && FAIL_COUNT=$((FAIL_COUNT + 1))

# New settings keys / constants added to all relevant registries?
L7_SCHEMA_GAP=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  # Find string constants that look like setting keys (snake_case all-lower)
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    # Check if the key also appears in a validation schema
    IN_SCHEMA=$(grep -rn "'${key}'\|\"${key}\"" \
      packages/ordinatio-settings/src/validation.ts 2>/dev/null | wc -l | tr -d ' ')
    if [ "$IN_SCHEMA" = "0" ]; then
      echo "  ⚠ Key '${key}' found in changed files but not in SettingKeySchema — verify schema is up to date"
      L7_SCHEMA_GAP=$((L7_SCHEMA_GAP + 1))
    fi
  done < <(grep -h "'[a-z][a-z0-9_]*'" "$f" 2>/dev/null \
    | grep -oE "'[a-z][a-z0-9_]{7,}'" | tr -d "'" | grep "_" | sort -u | head -10 || true)
done
[ "$L7_SCHEMA_GAP" = "0" ] && echo "  Schema registry coverage: ✓" || true

echo ""

# ===========================================
# FINAL VERDICT
# ===========================================
echo "=== RESULT ==="
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "AUDIT FAILED: $FAIL_COUNT layer(s) failed. Fix before declaring done."
  echo "=== END REPORT ==="
  exit 1
fi

echo "AUDIT PASSED: All layers green."
echo "=== END REPORT ==="
exit 0
