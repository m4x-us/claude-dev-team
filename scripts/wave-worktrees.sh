#!/usr/bin/env bash
# ===========================================
# WAVE WORKTREES — harness worktree lifecycle
# ===========================================
# Gives every parallel Claude window its own git worktree + branch so that:
#   (1) no shared git index — concurrent add/commit/reset in different
#       windows cannot sweep or destroy each other's work (the Jul-3
#       WAVE1-INCIDENT and the Jul-10 shared-index near-miss),
#   (2) pre-commit quality gates actually run in every worktree (.husky/_
#       is gitignored; a fresh `git worktree add` has hooks pointing at
#       nothing and git SILENTLY skips them),
#   (3) shared module state (.autocode) is symlinked, guarded against
#       accidental staged deletion, and each checkout resolves its own
#       active module (no last-writer-wins .active-module clobbering).
#
# There is NO shared-tree fallback anywhere in this script or its callers.
# A refusal from merge/cleanup is the safety working — never force it.
#
# Usage — runnable from ANY checkout of this repo: create/single/merge/cleanup
#   operate on the main checkout ($MAIN_ROOT) via git -C. Requirements: the
#   main checkout is on 'main', and cleanup's CWD is outside the worktrees
#   being removed.
#   scripts/wave-worktrees.sh create  <module> <waveN> <name>:<SID> ...
#   scripts/wave-worktrees.sh single  <module>
#   scripts/wave-worktrees.sh verify  [wave <module> <N> | wt <path> | module <module>]
#   scripts/wave-worktrees.sh merge   <module> <waveN>
#   scripts/wave-worktrees.sh cleanup <module> <waveN>
#   scripts/wave-worktrees.sh provision <worktree-path> [module]
#   scripts/wave-worktrees.sh list
#   scripts/wave-worktrees.sh set-module <module>
#   scripts/wave-worktrees.sh get-module
#
# stdout is MACHINE OUTPUT ONLY:
#   create/single → one TSV line per worktree:  WAVE_WT\t<name>\t<path>\t<branch>
#   verify/provision → ✓/✗ check lines + final "VERIFY PASS|FAIL <name> <p>/<n> head=<sha> at=<utc>"
#   get-module    → the resolved module name
# Human progress goes to stderr. /advance and /go parse stdout verbatim.
#
# Env: WAVE_WT_NO_INSTALL=1  skip pnpm install (test fixtures; hook-arming
#      via .husky/_ copy still runs).
# Exit codes: 0 success / all-✓ · 1 failure / any-✗ · 2 usage error.
# Tests: scripts/test-wave-worktrees.sh (fixture repos only — safe anytime).
# ===========================================

set -uo pipefail

COPY_FILES=( "apps/web/.env.local" "apps/worker/.env" )

die()       { echo "ERROR: $*" >&2; exit 1; }
usage_die() { echo "usage: $*" >&2; exit 2; }

TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir)
MAIN_ROOT=$(dirname "$COMMON_DIR")
# Namespaced under harness/ — .claude/worktrees/ is shared with foreign agent
# worktrees; module worktrees created before the namespace are reused in
# place via branch-resolution (see cmd_single), never moved.
WT_ROOT="$MAIN_ROOT/.claude/worktrees/harness"

require_main_ready() {
  # The main checkout must be on 'main'; the caller's CWD is irrelevant —
  # every mutation runs against $MAIN_ROOT via git -C.
  local branch; branch=$(git -C "$MAIN_ROOT" rev-parse --abbrev-ref HEAD)
  [ "$branch" = "main" ] || die "main checkout must be on 'main' (currently: $branch)"
}

ensure_exclude() {
  mkdir -p "$COMMON_DIR/info"
  grep -qxF '**/.claude/worktrees/' "$COMMON_DIR/info/exclude" 2>/dev/null || \
    echo '**/.claude/worktrees/' >> "$COMMON_DIR/info/exclude"
}

# Which worktree (if any) has $1 checked out — path on stdout, empty if none.
# substr($0,10) not $2: $2 truncates paths containing spaces. A printed path
# may be a stale registration (worktree list reports rm-rf'd worktrees until
# pruned) — callers must handle the directory-missing case.
worktree_of_branch() { # $1 = branch
  git -C "$MAIN_ROOT" worktree list --porcelain | \
    awk -v b="refs/heads/$1" '$1=="worktree"{wt=substr($0,10)} $1=="branch"&&$2==b{print wt}'
}

hook_path_of() { # $1 = checkout root → absolute path of the pre-commit git would run
  local wt="$1" hp
  hp=$(git -C "$wt" config core.hooksPath 2>/dev/null || true)
  [ -n "$hp" ] || { echo ""; return; }
  case "$hp" in
    /*) echo "$hp/pre-commit" ;;
    *)  echo "$wt/$hp/pre-commit" ;;
  esac
}

# Provision (or re-provision — idempotent) a worktree: configs, hooks,
# .autocode symlink + index guard, module marker. Dies loudly on any gap.
provision_worktree() { # $1 = worktree path, $2 = module
  local wt="$1" module="$2" f
  # NEVER provision the MAIN checkout. Main PASSES the common-dir identity
  # check in cmd_provision (it IS a checkout of this repo), but aimed here
  # this function would destroy main's .husky/_ hook runtime, then (once
  # hooks re-arm via pnpm) rm -rf main's REAL .autocode, replace it with a
  # self-loop symlink, and stamp skip-worktree on the MAIN index — hiding
  # the destruction. Same git-dir identity test as verify_wt's is_main branch.
  [ "$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" != "$COMMON_DIR" ] || \
    die "refusing to provision the MAIN checkout ($wt) — provisioning is worktree-only (it would destroy main's hook runtime and replace main's real .autocode with a self-loop symlink)"
  for f in "${COPY_FILES[@]}"; do
    if [ -e "$MAIN_ROOT/$f" ]; then
      mkdir -p "$wt/$(dirname "$f")"
      cp "$MAIN_ROOT/$f" "$wt/$f" || die "cp of $f into $wt failed — worktree NOT provisioned"
      echo "  copied $f" >&2
    else
      echo "  WARN: $f missing in main checkout — not copied" >&2
    fi
  done

  # Hook arming, layer 1: copy the gitignored runtime dir (deterministic, no network).
  if [ -d "$MAIN_ROOT/.husky/_" ]; then
    rm -rf "$wt/.husky/_"
    cp -R "$MAIN_ROOT/.husky/_" "$wt/.husky/_" || \
      die "cp of .husky/_ into $wt failed — hooks NOT armed; worktree NOT provisioned"
  fi
  # Hook arming, layer 2 + node_modules: pnpm install (prepare script re-arms husky).
  if [ -z "${WAVE_WT_NO_INSTALL:-}" ]; then
    echo "  pnpm install (node_modules + hook re-arm) in $wt ..." >&2
    ( cd "$wt" && pnpm install --prefer-offline --silent ) || \
      die "pnpm install failed in $wt — worktree NOT provisioned"
  fi
  # Hard verify the exact executable git will run. Without this a worktree
  # silently runs ZERO quality gates.
  local hook; hook=$(hook_path_of "$wt")
  [ -n "$hook" ] && [ -x "$hook" ] || \
    die "hooks NOT armed in $wt (expected executable: ${hook:-<core.hooksPath unset>})"

  # Shared module state: symlink .autocode to the main repo...
  # Refuse-if-work-lost first: a REAL .autocode directory here may hold
  # uncommitted module state (a broken symlink plus one suite command's
  # `mkdir -p .autocode/...` materializes exactly that). Replace it only when
  # git confirms it carries no local changes or untracked files — never
  # silently destroy what a worker session may still need.
  if [ -e "$wt/.autocode" ] && [ ! -L "$wt/.autocode" ]; then
    # git status/diff are BLIND to paths carrying the skip-worktree bit — and
    # provisioning stamps that bit on every tracked .autocode path. A real dir
    # here whose tracked paths are S-flagged cannot be trusted to a status
    # check at all: an edited tasks.md reads as "clean" and would be rm -rf'd.
    # Refuse unconditionally in that state.
    local ac_skipped ac_dirty
    # ^(S|[a-z]) — uppercase S is skip-worktree; ANY lowercase tag (h, s, …)
    # is assume-unchanged (alone or combined), and every one of these blinds
    # git status the same way.
    ac_skipped=$(git -C "$wt" ls-files -v -- .autocode 2>/dev/null | grep -E '^(S|[a-z]) ' || true)
    [ -z "$ac_skipped" ] || die "refusing to replace $wt/.autocode — it is a real directory and its tracked paths carry skip-worktree/assume-unchanged bits, which make git status BLIND to local edits there. Clear the bits and inspect before re-provisioning:
  git -C $wt ls-files -- .autocode | tr '\\n' '\\0' | xargs -0 git -C $wt update-index --no-skip-worktree --
  git -C $wt status -- .autocode"
    ac_dirty=$(git -C "$wt" status --porcelain -- .autocode 2>/dev/null || true)
    [ -z "$ac_dirty" ] || die "refusing to replace $wt/.autocode — it is a real directory with local changes or untracked files (move them into the main repo's .autocode first):
$ac_dirty"
  fi
  mkdir -p "$MAIN_ROOT/.autocode"
  rm -rf "$wt/.autocode"
  ln -sfn "$MAIN_ROOT/.autocode" "$wt/.autocode"
  # ...and guard the index: tracked .autocode paths are skip-worktree so the
  # symlink shadow can never be staged as 85 deletions and merged onto main.
  # Per-path, dying loudly — a silent gap here IS the 85-deletions hazard.
  local guard_paths p
  guard_paths=$(git -C "$wt" ls-files -- .autocode 2>/dev/null)
  if [ -n "$guard_paths" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      git -C "$wt" update-index --skip-worktree -- "$p" || \
        die "update-index --skip-worktree failed for $p in $wt"
    done <<< "$guard_paths"
  fi
  # Read-back proof: every tracked .autocode path must carry the S flag.
  [ -z "$(git -C "$wt" ls-files -v -- .autocode 2>/dev/null | grep -v '^S ')" ] || \
    die "skip-worktree guard incomplete in $wt — tracked .autocode paths still stageable"

  # Per-checkout module identity (replaces last-writer-wins .active-module).
  echo "$module" > "$(git -C "$wt" rev-parse --absolute-git-dir)/active-module"
}

# In-loop create failures leave a valid journal behind — say so FIRST, then die.
create_fail() { # $1 = module, $2 = wave, $3... = message
  local module="$1" wave="$2"; shift 2
  echo "partial wave state saved — recover with: bash scripts/wave-worktrees.sh cleanup $module $wave" >&2
  die "$*"
}

# Append one stream to the wave-state journal (read-modify-write).
state_add_stream() { # $1 = state-file, $2 = sid, $3 = name, $4 = worktree, $5 = branch
  python3 - "$@" <<'PY'
import json, sys
sf, sid, name, wt, br = sys.argv[1:6]
data = json.load(open(sf))
if sid in data["streams"]:
    sys.stderr.write(f"ERROR: stream id {sid} already recorded in {sf}\n")
    sys.exit(1)
data["streams"][sid] = {"name": name, "worktree": wt, "branch": br}
with open(sf, "w") as fh:
    json.dump(data, fh, indent=2)
PY
}

cmd_create() {
  [ $# -ge 3 ] || usage_die "create <module> <waveN> <name>:<SID> ..."
  local module="$1" wave="$2"; shift 2
  require_module "$module"; require_wave "$wave"
  require_main_ready
  if [ -n "$(git -C "$MAIN_ROOT" status --porcelain=v1 --untracked-files=no)" ]; then
    echo "WARN: main checkout has uncommitted tracked changes; they will NOT appear in the worktrees." >&2
  fi
  ensure_exclude
  local sf; sf=$(wave_state_file "$module")

  # Pre-flight — completes for ALL streams before ANYTHING is touched (no
  # interleaving). A failed pre-flight leaves no state file, no branch, no dir.
  local pair name sid branch wt seen_sids=" " seen_names=" "
  for pair in "$@"; do
    case "$pair" in *:*:*) die "bad stream spec '$pair' (exactly one colon: <name>:<STREAMID>)";; esac
    case "$pair" in *:*) ;; *) die "bad stream spec '$pair' (want <name>:<STREAMID>)";; esac
    name=${pair%%:*}; sid=${pair##*:}
    # Charset guard: makes the space-delimited token dup-checks below exact
    # (no substring false-positives) and keeps branch/dir names shell-safe.
    case "$name" in (""|*[!A-Za-z0-9_-]*) die "invalid stream name '$name' — allowed charset: A-Za-z0-9_-";; esac
    case "$sid"  in (""|*[!A-Za-z0-9_-]*) die "invalid stream id '$sid' — allowed charset: A-Za-z0-9_-";; esac
    case "$seen_sids" in *" $sid "*) die "duplicate stream id '$sid' — every stream needs a unique SID";; esac
    case "$seen_names" in *" $name "*) die "duplicate stream name '$name' — every stream needs a unique name";; esac
    seen_sids="$seen_sids$sid "; seen_names="$seen_names$name "
    branch="advance/${module}-w${wave}-${name}"
    wt="$WT_ROOT/${module}-w${wave}-${name}"
    [ -e "$wt" ] && die "worktree $wt already exists — a prior wave was not cleaned up (run: cleanup $module <prior-wave>)"
    # A crash-orphaned (rm -rf'd, unpruned) worktree stays registered and
    # would make `git worktree add` fail mid-loop — refuse it up front.
    if git -C "$MAIN_ROOT" worktree list --porcelain | grep -Fxq "worktree $wt"; then
      die "stale worktree registration: $wt is registered but the directory is gone — run: git -C $MAIN_ROOT worktree prune (after confirming the directory is truly gone), or: cleanup $module <prior-wave>"
    fi
    git -C "$MAIN_ROOT" rev-parse -q --verify "refs/heads/$branch" >/dev/null && \
      die "branch $branch already exists (stale) — inspect: git log main..$branch"
  done
  if [ -f "$sf" ]; then
    local prior; prior=$(python3 -c "import json;print(json.load(open('$sf')).get('wave',''))" 2>/dev/null)
    die "wave state $sf already exists (wave ${prior:-?}) — finish it first: merge $module ${prior:-<recorded-wave>} then cleanup $module ${prior:-<recorded-wave>}"
  fi
  mkdir -p "$WT_ROOT"

  # Initialize the journal with the FULL envelope before the first stream —
  # a bare {"streams":{}} breaks wave_streams()'s wave check and strands the
  # advertised `cleanup` recovery after a crash between init and stream 1.
  mkdir -p "$MAIN_ROOT/.autocode/modules/$module"
  python3 - "$sf" "$module" "$wave" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY' || die "could not write $sf"
import json, sys
sf, module, wave, created = sys.argv[1:5]
with open(sf, "w") as fh:
    json.dump({"wave": int(wave), "module": module, "created_at": created,
               "streams": {}}, fh, indent=2)
PY

  # Journal-first per stream: record → branch → worktree → provision. Every
  # artifact that exists is recorded, so cleanup (which tolerates recorded-
  # but-missing branches and worktrees) can always recover a partial wave.
  for pair in "$@"; do
    name=${pair%%:*}; sid=${pair##*:}
    branch="advance/${module}-w${wave}-${name}"
    wt="$WT_ROOT/${module}-w${wave}-${name}"
    state_add_stream "$sf" "$sid" "$name" "$wt" "$branch" || \
      create_fail "$module" "$wave" "could not journal stream $name in $sf"
    git -C "$MAIN_ROOT" branch "$branch" main >&2 || \
      create_fail "$module" "$wave" "could not create branch $branch"
    git -C "$MAIN_ROOT" worktree add "$wt" "$branch" >&2 || \
      create_fail "$module" "$wave" "git worktree add failed for $wt"
    # Subshell so provision's internal die still gets the recovery message.
    ( provision_worktree "$wt" "$module" ) || \
      create_fail "$module" "$wave" "provisioning failed for $wt (see errors above)"
    printf 'WAVE_WT\t%s\t%s\t%s\n' "$name" "$wt" "$branch"
  done
  echo "✓ wave W$wave: $(( $# )) stream worktree(s) created under $WT_ROOT" >&2
}

# module names feed branch names, filesystem paths, and quoted python
# strings; wave numbers feed branch names and json — validate both at every
# entry point (same discipline as the stream name/SID charset guard).
require_module() {
  case "$1" in (""|*[!a-z0-9_-]*) die "invalid module '$1' — allowed charset: a-z0-9_-";; esac
}
require_wave() {
  case "$1" in (""|*[!0-9]*) die "invalid wave number '$1' — digits only";; esac
}

warn_if_behind() { # $1 = branch, $2 = worktree path (for the catch-up command)
  local behind; behind=$(git -C "$MAIN_ROOT" rev-list --count "$1..main" 2>/dev/null || echo 0)
  if [ "${behind:-0}" -gt 0 ]; then
    echo "  WARN: branch $1 is $behind commit(s) behind main — catch up with: git -C $2 merge main" >&2
  fi
}

cmd_single() {
  [ $# -eq 1 ] || usage_die "single <module>"
  local module="$1" branch="$1-window" wt existing
  require_module "$module"
  require_main_ready
  ensure_exclude
  # Resolve an existing worktree BY BRANCH before computing any path: the
  # live cms worktree predates the harness/ namespace and must be reused in
  # place — never `git worktree move` (a live session's cwd sits inside it).
  existing=$(worktree_of_branch "$branch")
  if [ -n "$existing" ] && [ ! -d "$existing" ]; then
    die "stale worktree registration: $branch is registered at $existing but the directory is gone — run: git -C $MAIN_ROOT worktree prune, then re-run single $module"
  fi
  if [ -n "$existing" ]; then
    wt="$existing"
    git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
      die "$wt exists but is not a git worktree"
    local cur; cur=$(git -C "$wt" rev-parse --abbrev-ref HEAD)
    [ "$cur" = "$branch" ] || die "$wt is on branch '$cur', expected '$branch'"
    case "$wt" in
      "$WT_ROOT"/*) ;;
      *) echo "  NOTE: legacy location — reused in place; new module worktrees are created under .claude/worktrees/harness/" >&2 ;;
    esac
    echo "  re-provisioning existing module worktree $wt" >&2
    warn_if_behind "$branch" "$wt"
  else
    # Creation uses $WT_ROOT exclusively — the pre-namespace path is never
    # inspected (a foreign dir may sit there).
    wt="$WT_ROOT/$module"
    mkdir -p "$WT_ROOT"
    if ! git -C "$MAIN_ROOT" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
      git -C "$MAIN_ROOT" branch "$branch" main >&2 || die "could not create branch $branch"
    else
      # A surviving branch with no worktree (pruned crash leftover) may be
      # arbitrarily behind main — the reuse warning applies here too.
      warn_if_behind "$branch" "$wt"
    fi
    git -C "$MAIN_ROOT" worktree add "$wt" "$branch" >&2 || die "git worktree add failed for $wt"
  fi
  provision_worktree "$wt" "$module"
  printf 'WAVE_WT\t%s\t%s\t%s\n' "$module" "$wt" "$branch"
}

cmd_provision() {
  [ $# -ge 1 ] && [ $# -le 2 ] || usage_die "provision <worktree-path> [module]"
  local wt="$1" module="${2:-}"
  [ -d "$wt" ] || die "worktree path $wt does not exist"
  [ "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" = "$COMMON_DIR" ] || \
    die "$wt is not a checkout of this repository"
  if [ -z "$module" ]; then
    module=$(cat "$(git -C "$wt" rev-parse --absolute-git-dir)/active-module" 2>/dev/null | tr -d '[:space:]')
    [ -n "$module" ] || \
      die "cannot infer module — marker absent; pass it explicitly: provision <path> <module>"
  fi
  require_module "$module"
  provision_worktree "$wt" "$module"
  verify_wt "$wt" "" "" "$module"
  exit $?
}

# verify_wt <path> <expected-branch|""> <label> <expected-module|"">
# Prints one ✓/✗ line per check on stdout; returns 1 on any ✗. These lines
# are the pasted evidence /advance and /go are required to show — the final
# line embeds HEAD sha + UTC timestamp so a paste is spot-checkable.
verify_wt() {
  local wt="$1" want_branch="${2:-}" label="${3:-}" want_module="${4:-}"
  [ -n "$label" ] || label=$(basename "$wt")
  local pass=0 total=0 failed=0
  ok()  { echo "✓ $1"; pass=$((pass+1)); total=$((total+1)); }
  bad() { echo "✗ $1"; failed=1; total=$((total+1)); }

  if [ -d "$wt" ] && git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && [ "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" = "$COMMON_DIR" ]; then
    ok "worktree: $wt (registered checkout of this repo)"
  else
    bad "worktree: $wt (missing, or not a checkout of this repo)"
    echo "VERIFY FAIL $label $pass/$total head=? at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    return 1
  fi

  local cur sha
  cur=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
  sha=$(git -C "$wt" rev-parse --short HEAD 2>/dev/null)
  if [ -n "$want_branch" ] && [ "$cur" != "$want_branch" ]; then
    bad "branch: $cur @ $sha (expected $want_branch)"
  else
    ok "branch: $cur @ $sha"
  fi

  local hook; hook=$(hook_path_of "$wt")
  if [ -n "$hook" ] && [ -x "$hook" ]; then
    ok "hooks armed: core.hooksPath resolves to executable pre-commit"
  else
    bad "hooks armed: ${hook:-core.hooksPath unset} not executable — commits here run ZERO quality gates"
  fi

  local is_main=0
  [ "$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" = "$COMMON_DIR" ] && is_main=1
  if [ "$is_main" = "1" ]; then
    if [ -d "$wt/.autocode/modules" ]; then
      ok ".autocode: real directory in main checkout (modules/ readable)"
    else
      bad ".autocode: modules/ missing in main checkout"
    fi
  else
    if [ -L "$wt/.autocode" ] && [ -d "$wt/.autocode/modules" ]; then
      ok ".autocode symlink → $(readlink "$wt/.autocode") (target readable)"
    else
      bad ".autocode symlink missing or broken — task files would read/write the WRONG location"
    fi
    # The untracked "?? .autocode" symlink entry is expected; the hazard this
    # guards against is tracked .autocode paths surfacing as D/M (stageable).
    if [ -z "$(git -C "$wt" status --porcelain -- .autocode 2>/dev/null | grep -v '^??')" ]; then
      ok ".autocode index guard: no tracked .autocode paths visible as modified/deleted"
    else
      bad ".autocode index guard: tracked .autocode paths visible to git — 'git add -A' here would stage deletions"
    fi
  fi

  if [ -d "$wt/node_modules/.pnpm" ]; then
    ok "node_modules: node_modules/.pnpm present"
  else
    bad "node_modules: node_modules/.pnpm missing — run pnpm install"
  fi

  local f
  for f in "${COPY_FILES[@]}"; do
    if [ -f "$wt/$f" ]; then ok "env: $f"; else bad "env: $f missing"; fi
  done

  local marker mod
  marker="$(git -C "$wt" rev-parse --absolute-git-dir)/active-module"
  mod=$(cat "$marker" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$mod" ] && [ "$is_main" = "1" ] && [ -z "$want_module" ]; then
    # get-module treats no-module-set as a legitimate state on the main
    # checkout (a /scope-cleared session); `verify self` there must agree.
    ok "module marker: (none — main checkout; module identity optional here)"
  elif [ -z "$mod" ]; then
    bad "module marker: $marker missing/empty"
  elif [ -n "$want_module" ] && [ "$mod" != "$want_module" ]; then
    bad "module marker: '$mod' (expected '$want_module')"
  else
    ok "module marker: $mod"
  fi

  if [ "$failed" = "0" ]; then
    echo "VERIFY PASS $label $pass/$total head=$sha at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    return 0
  fi
  echo "VERIFY FAIL $label $pass/$total head=$sha at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  return 1
}

wave_state_file() { echo "$MAIN_ROOT/.autocode/modules/$1/.wave-state.json"; }

# Emits one "name<TAB>worktree<TAB>branch" line per stream from wave-state.
wave_streams() { # $1 = module, $2 = waveN
  local sf; sf=$(wave_state_file "$1")
  [ -f "$sf" ] || die "no wave state at $sf — was the wave created by this script?"
  python3 - "$sf" "$2" <<'PY' || exit 1
import json, sys
sf, wave = sys.argv[1], int(sys.argv[2])
data = json.load(open(sf))
if data.get("wave") != wave:
    sys.stderr.write(f"ERROR: wave-state is for wave {data.get('wave')}, not {wave}\n")
    sys.exit(1)
for sid, s in data["streams"].items():
    print(f"{s['name']}\t{s['worktree']}\t{s['branch']}")
PY
}

cmd_verify() {
  local sub="${1:-self}"
  case "$sub" in
    wave)
      [ $# -eq 3 ] || usage_die "verify wave <module> <waveN>"
      local rc=0 line name wt branch
      local streams; streams=$(wave_streams "$2" "$3") || exit 1
      while IFS=$'\t' read -r name wt branch; do
        [ -n "$name" ] || continue
        verify_wt "$wt" "$branch" "$name" "$2" || rc=1
      done <<< "$streams"
      exit $rc
      ;;
    wt)
      [ $# -eq 2 ] || usage_die "verify wt <abs-path>"
      verify_wt "$2" "" "" ""
      exit $?
      ;;
    module)
      [ $# -eq 2 ] || usage_die "verify module <module>"
      # Same branch-resolution as cmd_single: the worktree may live at a
      # legacy (pre-namespace) path.
      local mwt
      mwt=$(worktree_of_branch "$2-window")
      [ -n "$mwt" ] || \
        die "no worktree has $2-window checked out — create one with: bash scripts/wave-worktrees.sh single $2"
      verify_wt "$mwt" "$2-window" "$2" "$2"
      exit $?
      ;;
    self)
      verify_wt "$TOPLEVEL" "" "" ""
      exit $?
      ;;
    *) usage_die "verify [wave <module> <N> | wt <path> | module <module>]" ;;
  esac
}

cmd_merge() {
  [ $# -eq 2 ] || usage_die "merge <module> <waveN>"
  local module="$1" wave="$2"
  require_module "$module"; require_wave "$wave"
  require_main_ready
  # Guard: never entangle a wave merge with someone else's staged batch.
  git -C "$MAIN_ROOT" diff --cached --quiet || \
    die "main index has staged changes — land or unstage them before merging a wave (protects concurrent work)"
  local streams; streams=$(wave_streams "$module" "$wave") || exit 1
  local name wt branch dels
  # Pass 1 — ALL guards before ANY merge: a wave lands whole or not at all
  # (a per-stream guard-then-merge loop strands earlier streams on main when
  # a later stream is refused).
  while IFS=$'\t' read -r name wt branch; do
    [ -n "$name" ] || continue
    # Guard: a stream branch must never delete tracked .autocode files —
    # merging one would destroy shared module state on main.
    # --no-renames is defense-in-depth here: the '-- .autocode/' pathspec
    # already prevents rename pairing across the boundary (verified; pinned by
    # T32), but a future edit that widens or drops the pathspec must not
    # reopen the fold.
    # A guard that cannot run is a FAILED guard, never a passed one — a
    # swallowed crash here would merge an unverified branch.
    # stderr goes to its own capture — a git WARNING on a successful diff must
    # not masquerade as a deletion list (fail-closed but misdiagnosed).
    local gerr; gerr=$(mktemp)
    dels=$(git -C "$MAIN_ROOT" diff --no-renames --diff-filter=D --name-only "main...$branch" -- .autocode/ 2>"$gerr")
    if [ $? -ne 0 ]; then
      local gmsg; gmsg=$(cat "$gerr" 2>/dev/null); rm -f "$gerr"
      die "the .autocode deletion guard could not run for $branch (git diff failed: $gmsg) — refusing to merge unverified"
    fi
    rm -f "$gerr"
    [ -n "$dels" ] && die "branch $branch deletes tracked .autocode files — refusing to merge:
$dels"
  done <<< "$streams"
  # Pass 2 — merge, diagnosing failures honestly before any abort.
  while IFS=$'\t' read -r name wt branch; do
    [ -n "$name" ] || continue
    if git -C "$MAIN_ROOT" merge-base --is-ancestor "$branch" main 2>/dev/null; then
      echo "$branch already merged — skipping" >&2
      continue
    fi
    echo "merging $branch ..." >&2
    if ! git -C "$MAIN_ROOT" merge --no-ff -m "/advance $module W$wave: merge stream $branch

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" "$branch" >&2; then
      if [ -n "$(git -C "$MAIN_ROOT" ls-files -u)" ]; then
        git -C "$MAIN_ROOT" merge --abort 2>/dev/null || \
          die "CONFLICT merging $branch AND merge --abort itself failed — inspect $MAIN_ROOT manually (a merge may still be in progress)"
        die "CONFLICT merging $branch — file-set isolation was violated. Merge aborted; resolve with Max, never auto-resolve."
      fi
      # No unmerged index entries → no merge is in progress (--abort here
      # would itself exit 128). Main is unchanged.
      die "merge of $branch failed but is NOT a content conflict (see git output above). Main is unchanged; fix the named condition and re-run merge."
    fi
  done <<< "$streams"
  echo "✓ all W$wave stream branches merged into main" >&2
}

cmd_cleanup() {
  [ $# -eq 2 ] || usage_die "cleanup <module> <waveN>"
  local module="$1" wave="$2"
  require_module "$module"; require_wave "$wave"
  require_main_ready
  local streams; streams=$(wave_streams "$module" "$wave") || exit 1
  local name wt branch dirty cwd_p wt_p
  cwd_p=$(pwd -P)
  # Pass 1 — refuse-if-work-lost, BEFORE touching anything.
  while IFS=$'\t' read -r name wt branch; do
    [ -n "$name" ] || continue
    if [ -d "$wt" ]; then
      # git worktree remove succeeds even with CWD inside the target
      # (verified: RC=0, directory yanked out from under the session) —
      # guard explicitly.
      wt_p=$(cd "$wt" && pwd -P)
      case "$cwd_p/" in "$wt_p/"*)
        die "current directory is inside worktree $wt, which cleanup would remove — cd to the main checkout or a module worktree first";;
      esac
      dirty=$(git -C "$wt" status --porcelain 2>/dev/null | grep -vE '^.. \.autocode($|/)' || true)
      [ -n "$dirty" ] && die "worktree $wt has uncommitted work — inspect before cleanup (refusal = safety working):
$dirty"
    fi
    if git -C "$MAIN_ROOT" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
      git -C "$MAIN_ROOT" merge-base --is-ancestor "$branch" main || \
        die "branch $branch has unmerged work — run: merge $module $wave first (refusal = safety working)"
    fi
  done <<< "$streams"
  # Pass 2 — everything verified safe; remove.
  while IFS=$'\t' read -r name wt branch; do
    [ -n "$name" ] || continue
    if [ -d "$wt" ]; then
      rm -f "$wt/.autocode"   # symlink only — the shared target is untouched
      git -C "$MAIN_ROOT" worktree remove "$wt" >&2 || die "git worktree remove refused for $wt — inspect manually"
      echo "removed worktree $wt" >&2
    fi
    if git -C "$MAIN_ROOT" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
      git -C "$MAIN_ROOT" branch -d "$branch" >&2 || die "git branch -d refused for $branch — unmerged work?"
      echo "deleted branch $branch" >&2
    fi
  done <<< "$streams"
  rm -f "$(wave_state_file "$module")"
  git -C "$MAIN_ROOT" worktree prune
  echo "✓ W$wave cleaned up. Remaining worktrees:" >&2
  git -C "$MAIN_ROOT" worktree list >&2
}

cmd_list() {
  git -C "$MAIN_ROOT" worktree list
  git -C "$MAIN_ROOT" branch --list 'advance/*' '*-window'
}

cmd_set_module() {
  [ $# -eq 1 ] || usage_die "set-module <module>"
  require_module "$1"
  local gd; gd=$(git rev-parse --absolute-git-dir)
  echo "$1" > "$gd/active-module"
  echo "module '$1' → $gd/active-module" >&2
}

cmd_get_module() {
  local m
  m=$(cat "$(git rev-parse --absolute-git-dir)/active-module" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$m" ] && [ "$(git rev-parse --absolute-git-dir)" = "$COMMON_DIR" ]; then
    # Legacy fallback: the pre-2026-07-10 shared marker — MAIN CHECKOUT ONLY.
    # A worktree reading it through the .autocode symlink would resurrect the
    # last-writer-wins clobbering the per-checkout marker replaced.
    m=$(cat "$TOPLEVEL/.autocode/modules/.active-module" 2>/dev/null | tr -d '[:space:]')
  fi
  # No module set is a legitimate state (a /scope-cleared session), not a
  # failure — print nothing and exit 0, honoring the header's exit contract.
  if [ -n "$m" ]; then echo "$m"; fi
}

case "${1:-}" in
  create)     shift; cmd_create "$@";;
  single)     shift; cmd_single "$@";;
  verify)     shift; cmd_verify "$@";;
  merge)      shift; cmd_merge "$@";;
  cleanup)    shift; cmd_cleanup "$@";;
  provision)  shift; cmd_provision "$@";;
  list)       cmd_list;;
  set-module) shift; cmd_set_module "$@";;
  get-module) cmd_get_module;;
  *) usage_die "wave-worktrees.sh create|single|verify|merge|cleanup|provision|list|set-module|get-module ...";;
esac
