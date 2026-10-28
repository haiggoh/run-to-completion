#!/usr/bin/env bash
# rtc-ship.sh — ship one milestone branch of ANY repo: rebase on origin/<default-branch>, the test
# gates, fast-forward merge into that branch, an annotated tag built from the CHANGELOG entry, push,
# a GitHub release with the repo's distributables, then refresh the installed plugin.
#
# "main" IN PROSE MEANS THE DEFAULT BRANCH, whatever it is called. Most repos use `main`; echoprism
# uses `master`. A request to "merge to main" is resolved to this repo's actual default branch —
# never to a branch literally named main, and certainly never by CREATING one, which would be a
# second default and the worst kind of confusion.
#
# WHY THIS EXISTS. The ship loop was hand-rolled per repo, and the costliest failure was not a
# wrong step but a SKIPPED one: the version bump lands after the test suite has already run, so a
# split is introduced between "tests green" and "PR opened" and only a re-check catches it. Measured
# 2026-10-24 — free-agents 0.43.2 shipped with VERSION at 0.43.1 while four other surfaces said
# 0.43.2, because the repo's own version test ran with its verdict discarded. So the gates live here,
# in one place, and a repo cannot skip them by forgetting to run its own script.
#
# Usage:
#   rtc-ship.sh <worktree-dir> <version> "<release title summary>"
#   rtc-ship.sh <worktree-dir> <version> "<title>" --no-reap   keep worktree and branches, this ship only
#   rtc-ship.sh --test-only <worktree-dir>    run the gates and stamp the tree, ship nothing
#   rtc-ship.sh --which-config                print the config this repo would use and exit
#   rtc-ship.sh --help
#
# Per-repo specifics live in TWO places, both inside the repo being shipped:
#   rtc-ship.json   DATA the tool needs: the tag prefix, which version surfaces to check, release
#                   asset globs, the plugin to refresh, test worker count, and "reap": false to
#                   permanently keep worktrees and merged branches (reaping is the default).
#   .rtc/*.sh       COMMANDS only that repo has, run at named points if present and executable:
#                     pre-flight.sh     extra gates, before anything else (a second venv's suite)
#                     pre-package.sh    build the release assets
#                     post-release.sh   after the release (a Homebrew tap trigger, say)
#                   A repo with none of these is fully supported — hooks are opt-in by presence.
#
# Env:
#   RTC_MAIN            canonical checkout (default: derived from the worktree's git common dir)
#   RTC_SKIP_TESTS=1    skip the suite gates (prefer the tree stamp: a green run of THIS tree self-skips)
#   RTC_TEST_WORKERS    xdist workers for the main suite (beats rtc-ship.json test_workers; default 12)
#   RTC_SKIP_REFRESH=1  do not refresh the installed plugin after a confirmed release
#   RTC_TAG_VISIBILITY=0        skip the published-manifest check (default: on, it gates the release)
#   RTC_TAG_VISIBILITY_TRIES    polls before giving up (default 6; the CDN window is ~1 minute)
#   RTC_TAG_VISIBILITY_DELAY    seconds between polls (default 20)
#   RTC_SKIP_CLEANUP=1  keep the shipped worktree and every branch after a confirmed release
#                       (opt-outs for cleanup, reaping being the default: this env var, the
#                       transient --no-reap flag, or "reap": false in rtc-ship.json permanently)
#   RTC_BACKUP_DIR      where uncommitted files are backed up before their worktree is reaped
#                       (default $HOME/.claude/backups/worktrees); a backup that cannot be written
#                       KEEPS the worktree
#   RTC_SHIP_LOG_DIR    where each phase's full output is kept: rebase, pre-package, the upload
#                       (default ${TMPDIR:-/tmp}/rtc-ship-logs/<repo>-<version>); a failing phase
#                       prints its verdict and the last 15 lines either way
set -euo pipefail

# Print every header comment line up to the first line of real code. NOT a hardcoded line range:
# `sed -n '2,31p'` silently hid every line added past 31, which is how a gate shipped with its own
# env vars documented in the source and invisible in --help (measured on 0.6.11).
usage() { awk 'NR>1 && !/^#/ {exit} {sub(/^# ?/, ""); print}' "$0"; }
T0=${SECONDS:-0}
phase() { printf '[%4ss] %s\n' "$((SECONDS - T0))" "$*"; }
# A phase whose output goes to /dev/null cannot be judged from the log: "ran quietly" and "died
# silently, having done nothing" print the same nothing. fa-ship.sh learned this on 2026-10-26 on its
# packaging step and grew run_logged — one day AFTER this script was ported from it, so the port ran
# pre-package and the upload `>/dev/null` (found by the 2026-10-28 parity sweep). Capture, print a
# verdict, and on failure show the tail of what the step itself said.
run_logged() {  # run_logged <label> <log> <cmd...>
  local label=$1 log=$2 rc; shift 2
  mkdir -p "$(dirname "$log")"
  phase "$label — running"
  if "$@" >"$log" 2>&1; then
    phase "✓ $label — done, $(wc -l <"$log" | tr -d ' ') log lines ($log)"
  else
    rc=$?
    phase "✖ $label — FAILED (exit $rc); last 15 lines of $log:"
    tail -n 15 "$log" | sed 's/^/      /' >&2
    return "$rc"
  fi
}

# ----------------------------------------------------------------------------------------------
# Config: DATA comes from rtc-ship.json; COMMANDS come from .rtc/*.sh. Neither is guessed.
# ----------------------------------------------------------------------------------------------

resolve_top() {  # the repo root, or $PWD where there is NO git repo (see below)
  local base=${RTC_REPO_ROOT:-$PWD} t
  t=$(git -C "$base" rev-parse --show-toplevel 2>/dev/null) || t=""
  printf '%s\n' "${t:-$base}"
}

cfg_get() {  # cfg_get <key> [default] — one scalar out of rtc-ship.json
  local key=$1 def=${2-} top toplevel
  top=$(resolve_top)
  RTC_CFG_FILE="$top/rtc-ship.json" python3 - "$key" "$def" <<'PY'
import json, os, sys
key, default = sys.argv[1], sys.argv[2]
try:
    with open(os.environ["RTC_CFG_FILE"]) as f:
        v = json.load(f).get(key)
except Exception:
    v = None
if v is None:
    print(default)
elif isinstance(v, bool):
    print("1" if v else "0")
else:
    print(v)
PY
}

# ----------------------------------------------------------------------------------------------
# The version gate. The repo's OWN test wins when it has one; otherwise the config's declared
# surfaces are checked here. Both paths print the table and both exit non-zero on a split — the
# point of this script is that the gate cannot be skipped by not running it.
# ----------------------------------------------------------------------------------------------

version_gate() {
  # THE SAME resolver cfg_get uses, and for the same reason: an installed plugin cache is a plain
  # directory with no .git anywhere above it, and so is an extracted release tarball. Letting `git
  # rev-parse` fail left `top` EMPTY, so every surface was read through "/" and came back "<none>"
  # — a consistent tree reported as disagreeing. Found by dogfooding installed 0.6.6.
  local top; top=$(resolve_top)
  if [ -x "$top/tests/test_version_consistency.sh" ]; then
    if ! bash "$top/tests/test_version_consistency.sh"; then
      echo "✖ version surfaces disagree (the repo's own test) — ship refused" >&2; return 1
    fi
    return 0
  fi
  # No repo test: check what the config declares. A repo that declares fewer surfaces than it has
  # will drift, but a repo that declares NONE gets a manifest+changelog check rather than nothing.
  local manifest changelog vfile roadmap want mv cv vv rv
  manifest=$(cfg_get "manifest" ".claude-plugin/plugin.json")
  changelog=$(cfg_get "changelog" "CHANGELOG.md")
  vfile=$(cfg_get "version_file" "")
  roadmap=$(cfg_get "roadmap" "")
  mv=$(python3 -c "import json,sys;print(json.load(open('$top/$manifest')).get('version',''))" 2>/dev/null || echo "")
  # BOTH heading styles: Keep-a-Changelog permits `## 1.2.3` and `## [1.2.3]`, and this repo's own
  # CHANGELOG uses the unbracketed form while free-agents' uses brackets.
  cv=$(sed -n -E 's/^##+[[:space:]]+\[?([0-9]+\.[0-9]+\.[0-9]+)\]?.*/\1/p' "$top/$changelog" 2>/dev/null | head -1)
  vv=""; [ -n "$vfile" ] && [ -f "$top/$vfile" ] && vv=$(tr -d '[:space:]' < "$top/$vfile")
  rv=""; [ -n "$roadmap" ] && [ -f "$top/$roadmap" ] && rv=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$top/$roadmap" | head -1)
  echo "  $manifest : ${mv:-<none>}"
  echo "  $changelog (top entry) : ${cv:-<none>}"
  [ -n "$vfile" ] && echo "  $vfile : ${vv:-<none>}"
  [ -n "$roadmap" ] && echo "  $roadmap : ${rv:-<none>}"
  local bad=0
  # An EMPTY extraction is a FAILURE, never a pass. A gate that cannot find its input and then
  # declares success is worse than no gate — it let a planted split through on the first run of
  # this script, because an unreadable changelog silently skipped its comparison.
  if [ -z "$mv" ]; then echo "✖ no version in $manifest" >&2; bad=1; fi
  if [ -z "$changelog" ]; then
    # A repo may legitimately have no changelog at all (echoprism: package.json, no CHANGELOG.md).
    # Saying so beats failing on a file that was never promised.
    echo "  (no changelog declared — not checked)"
    cv=$mv
  elif [ -z "$cv" ]; then echo "✖ no numbered heading found in $changelog" >&2; bad=1
  elif [ "$cv" != "$mv" ]; then echo "✖ changelog top is $cv, manifest says $mv" >&2; bad=1; fi
  if [ -n "$vfile" ] && [ ! -f "$top/$vfile" ]; then echo "✖ $vfile is declared in the config but absent" >&2; bad=1
  elif [ -n "$vv" ] && [ "$vv" != "$mv" ]; then echo "✖ $vfile says $vv, manifest says $mv" >&2; bad=1; fi
  if [ -n "$roadmap" ] && [ -f "$top/$roadmap" ] && [ -n "$rv" ] && [ "$rv" != "$mv" ]; then
    echo "✖ $roadmap says $rv, manifest says $mv" >&2; bad=1
  fi
  return "$bad"
}

# ----------------------------------------------------------------------------------------------
# The suite gates: parallel pytest, plus a tree stamp so a tree that already passed is not re-run.
# A repo's own extra gates go in .rtc/pre-flight.sh (free-agents' litellm/picker venvs, say).
# ----------------------------------------------------------------------------------------------

worktree_tree() {  # the tree id of what the suites will actually read: the WORKING tree
  # Keyed on HEAD^{tree}, uncommitted edits rode on an earlier stamp and --test-only skipped them
  # (measured 2026-10-27). Hash the working tree into a TEMPORARY index (seeded from the real one
  # for git's stat cache) so the real index is never touched. A clean tree hashes to HEAD^{tree},
  # so the ship path's stamp lookup is unchanged; ignored files are, rightly, not part of the key.
  local idx id rc
  idx=$(mktemp) || return 1
  rm -f "$idx"; cp "$(git rev-parse --git-path index)" "$idx" 2>/dev/null || :
  id=$(GIT_INDEX_FILE=$idx git add -A -- ':/' 2>/dev/null && GIT_INDEX_FILE=$idx git write-tree); rc=$?
  rm -f "$idx"
  [ "$rc" = 0 ] && [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

gates() {
  local tree stamp d rc=0 pids=() names=() out
  tree=$(worktree_tree) || { echo "✖ could not hash the working tree for the test stamp" >&2; return 1; }
  stamp="$(git rev-parse --git-common-dir)/rtc-tested/$tree"
  if [ -e "$stamp" ]; then
    phase "tests: tree ${tree:0:10} already passed every gate ($(date -r "$stamp" '+%H:%M')) — skipped"
    return 0
  fi
  # Worker count: env, then rtc-ship.json's test_workers, then 12. The config key was documented
  # and never read (2026-10-27) — a SET but invalid value now aborts rather than falling through.
  local workers src
  if [ -n "${RTC_TEST_WORKERS:-}" ]; then workers=$RTC_TEST_WORKERS; src=RTC_TEST_WORKERS
  else workers=$(cfg_get "test_workers" "12"); src="rtc-ship.json test_workers"; fi
  case "$workers" in
    ''|*[!0-9]*|0) echo "✖ $src must be a positive integer, got '$workers'" >&2; return 1 ;;
  esac
  d=$(mktemp -d)
  # Pre-flight runs ALONGSIDE the main suite, not before it: its suites are the ones the main
  # collection skips (a second venv's), so the two are disjoint, and serially every ship waited
  # ~2 minutes for it. Its output goes to a log and is shown when it fails.
  local pf_pid=""
  if [ -x .rtc/pre-flight.sh ]; then
    ./.rtc/pre-flight.sh </dev/null >"$d/pre-flight" 2>&1 &
    pf_pid=$!
  fi
  # How this repo's tests run is the REPO'S business, not the tool's assumption. A pytest suite is
  # the default, but a repo of shell suites would otherwise collect nothing and exit 5 — so the
  # command comes from the config, and an UNCOLLECTED suite is a failure, never a silent pass.
  local test_cmd; test_cmd=$(cfg_get "test_cmd" "")
  if [ -n "$test_cmd" ]; then
    if bash -c "$test_cmd" >"$d/main" 2>&1; then phase "tests (config): pass"
    else phase "✖ tests (config) FAILED"; grep -E "FAIL|✖" "$d/main" | head -10 >&2; rc=1; fi
  else
    "$HOME/.local/bin/pytest" -q tests -p no:cacheprovider -n "$workers" \
      </dev/null >"$d/main" 2>&1 &
    names+=(main); pids+=($!)
  fi
  local i ok
  for i in "${!pids[@]}"; do
    # wait FIRST, so the log is complete before it is classified.
    ok=0; wait "${pids[$i]}" && ok=1
    if [ "$ok" = 0 ]; then
      rc=1; phase "✖ pytest ${names[$i]} FAILED: $(grep -E 'passed|failed|error' "$d/${names[$i]}" | tail -1)"
      grep -E '^(FAILED|ERROR) ' "$d/${names[$i]}" | head -10 >&2
    elif grep -q "no tests ran" "$d/${names[$i]}"; then
      rc=1; phase "✖ pytest ${names[$i]} collected NO tests — declare a test_cmd in rtc-ship.json"
    else
      phase "pytest ${names[$i]}: $(grep -E 'passed|failed' "$d/${names[$i]}" | tail -1)"
    fi
  done
  if [ -n "$pf_pid" ]; then
    if wait "$pf_pid"; then phase "pre-flight gates: pass"
    else rc=1; phase "✖ pre-flight gates FAILED"; tail -30 "$d/pre-flight" >&2; fi
  fi
  # Stamp only the tree that was tested: an edit DURING the run means neither the tree the suites
  # started on nor the one now on disk is proven green.
  if [ "$rc" = 0 ] && [ "$(worktree_tree)" != "$tree" ]; then
    phase "tests passed, but the working tree changed during the run — NOT stamped; rerun to cache it"
    rm -rf "$d"
  elif [ "$rc" = 0 ]; then mkdir -p "$(dirname "$stamp")"; touch "$stamp"; rm -rf "$d"
  else echo "✖ tests failed — full logs kept in $d" >&2; fi
  return "$rc"
}

hook() {  # hook <name> — run a repo hook if it is present and executable
  local name=$1
  if [ -x ".rtc/$name" ]; then
    if "./.rtc/$name"; then phase "hook $name: pass"; return 0
    else phase "✖ hook $name FAILED"; return 1; fi
  fi
  return 0
}

# --- what a worktree may be reaped without losing anything -----------------------------------
# Harmonised with watch-your-step's worktree-remove guard (bin/watch-your-step.py on branch
# fix/block-worktree-remove-ignored: CACHE_DIRS, _is_cache_path, _dir_is_all_cache). The general
# rules are deliberately DUPLICATED rather than shared: these two repos have no dependency on each
# other, and this routine is the AUTOMATIC one. A reaper that leans on a guard written for manual
# commands has its safety installed by luck — it would be safe only while watch-your-step happens
# to be installed. So this decides on its own, and the shared rules are pinned by the tests below.
#   - .DS_Store and *.pyc are noise anywhere;
#   - a path is excused by a DIRECTORY component: `venv/x` is cache, `myvenv/plan.md` is NOT — a
#     substring match would excuse `myvenv/` too, which is exactly the second half of the trap;
#   - git COLLAPSES a wholly-ignored directory to `sub/`, so the name alone cannot separate a
#     Finder-junk directory from a ledger holding the only copy of something. A collapsed dir is
#     therefore INSPECTED, never judged by its name (unless its name is itself a cache dir).
#   - an ignored file byte-identical to the same path in the canonical checkout is not information
#     this worktree alone holds. This generalises fa-ship.sh's config.local.sh special case, which
#     had to be dropped on porting: hardcoding one repo's path would have left every other repo
#     looking protected while protecting nothing.
CACHE_DIRS="__pycache__ .pytest_cache .ruff_cache .mypy_cache .venv venv node_modules dist build"

cleanup_is_cache() {  # cleanup_is_cache <relpath> — noise a reaper may drop without a backup?
  local p=$1 base rest part
  base=${p##*/}
  case "$base" in .DS_Store|*.pyc) return 0 ;; esac
  rest=${p%/*}
  [ "$rest" = "$p" ] && return 1   # a bare filename: no directory component can excuse it
  while [ -n "$rest" ]; do
    part=${rest%%/*}
    case " $CACHE_DIRS " in *" $part "*) return 0 ;; esac
    [ "$part" = "$rest" ] && break
    rest=${rest#*/}
  done
  return 1
}

cleanup_identical_to_main() {  # does $MAIN already hold this exact file, byte for byte?
  [ -f "$1" ] && [ -f "$MAIN/${1#"$WT"/}" ] && cmp -s "$1" "$MAIN/${1#"$WT"/}"
}

cleanup_collapsed() {  # print the PRECIOUS files inside a git-collapsed ignored directory
  local p=$1 prefix=${1%/} d rel
  d="$WT/$prefix"
  [ -d "$d" ] || return 0
  # Files and symlinks only: an empty directory and one holding nothing but subdirectories of
  # noise both lose nothing, and `find -type d` would name them as if they did.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    cleanup_is_cache "$prefix/$rel" && continue
    cleanup_identical_to_main "$d/$rel" && continue
    printf '%s\n' "$prefix/$rel"
  done < <(cd "$d" 2>/dev/null && find . -mindepth 1 \( -type f -o -type l \) 2>/dev/null | sed 's|^\./||')
}

cleanup_extra() {  # print one RELATIVE path per line for everything a reaper would destroy that is
                   # NOT noise. EMPTY output = reap without a backup. A non-zero EXIT = "cannot
                   # tell", which the caller must refuse to read as "safe".
  local p
  # pipefail is load-bearing here: a `git status` that fails makes this whole function fail, so the
  # caller keeps the worktree instead of guessing that nothing precious was in it.
  # NOT --untracked-files=all: with it git names ignored files individually and the COLLAPSED
  # '!! sub/' form never appears — which made cleanup_collapsed dead code and let both halves of the
  # trap pass without the inspection ever running (measured: mutating cleanup_collapsed into an
  # immediate `return 0` left every test green). Without -uall git collapses a wholly-ignored
  # directory, that is the form inspection actually judges, and the ship's own dirty check has
  # already refused a worktree holding untracked files, so nothing untracked can reach here anyway.
  git -C "$WT" status --porcelain --ignored 2>/dev/null \
    | sed -n -e 's/^!! //p' -e 's/^?? //p' \
    | while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in
          */) cleanup_collapsed "$p" ;;
          *)  if cleanup_is_cache "$p"; then continue; fi
              if cleanup_identical_to_main "$WT/$p"; then continue; fi
              printf '%s\n' "$p" ;;
        esac
      done
}

cleanup() {  # after a CONFIRMED release: reap the shipped worktree, its branch, and every branch
             # whose content is already on the default branch. Ported from fa-ship.sh, whose
             # routine has run in production since 2026-10-23; the CHANGELOG has advertised this
             # step since 0.7.0 and the generalization silently dropped it.
  local upstream="origin/$DEFAULT_BRANCH" in_wt b r extra bk list rel bk_ok
  # Never the canonical checkout: a ship must not delete the tree every other worktree is measured
  # against. (Shipping $MAIN itself is a caller error; refusing is cheaper than recovering.)
  if [ "$WT" = "$MAIN" ]; then
    echo "⚠ cleanup: $WT is the canonical checkout — not touched" >&2
    return 0
  fi
  git fetch -q --prune origin
  in_wt=$(git worktree list --porcelain | sed -n 's#^branch refs/heads/##p')
  # The shipped worktree itself, only when its branch is fully merged AND the tree is clean. A
  # dirty or unmerged worktree is kept, and says so — never removed silently.
  if ! extra=$(cleanup_extra); then
    echo "⚠ cleanup: kept $WT (could not tell what it would lose)" >&2
  elif ! git merge-base --is-ancestor "$BR" "$upstream"; then
    echo "⚠ cleanup: kept $WT ($BR is not merged into $upstream)" >&2
  elif [ -n "$(git -C "$WT" status --porcelain)" ]; then
    echo "⚠ cleanup: kept $WT (the tree is dirty)" >&2
  elif [ -z "$extra" ]; then
    git worktree remove --force "$WT" && git branch -q -d "$BR" \
      && phase "cleanup: removed worktree $WT and branch $BR"
    if git ls-remote --exit-code --heads origin "$BR" >/dev/null 2>&1; then
      git push -q origin --delete "$BR" && phase "cleanup: deleted origin/$BR"
    fi
  else
    # Deletion is allowed ONLY after a timestamped backup of every uncommitted file that would be
    # lost. Measured 2026-10-24: a removed worktree once took an uncommitted handover with it, so
    # the routine must not lose data even where a human might have run --force.
    # EVERY step of the backup is checked by hand: this function runs as `cleanup || …`, and bash
    # switches set -e OFF for the whole body of a function called on the left of `||`. Unchecked, a
    # failed mkdir/cp printed "backed up" and went on to `worktree remove --force` — measured
    # 2026-10-28 (rehearsal p7): the only copy of an ignored file was destroyed.
    bk="${RTC_BACKUP_DIR:-$HOME/.claude/backups/worktrees}/$(basename "$WT")-$(date +%Y%m%d-%H%M%S)"
    list=$extra
    bk_ok=1
    mkdir -p "$bk" 2>/dev/null || bk_ok=0
    if [ "$bk_ok" = 1 ]; then
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        [ -e "$WT/$rel" ] || [ -L "$WT/$rel" ] || continue
        { mkdir -p "$bk/$(dirname "$rel")" && cp -R "$WT/$rel" "$bk/$rel"; } 2>/dev/null \
          || { bk_ok=0; break; }
      done <<< "$list"
    fi
    if [ "$bk_ok" = 0 ]; then
      echo "⚠ cleanup: kept $WT (backup failed — could not write $bk); nothing was removed" >&2
    else
      phase "cleanup: backed up $(printf '%s\n' "$list" | grep -c .) file(s) to $bk"
      git worktree remove --force "$WT" && git branch -q -d "$BR" \
        && phase "cleanup: removed worktree $WT (backed up first)"
      if git ls-remote --exit-code --heads origin "$BR" >/dev/null 2>&1; then
        git push -q origin --delete "$BR" && phase "cleanup: deleted origin/$BR"
      fi
    fi
  fi
  # Every OTHER local branch already on the default branch, except one a worktree still has
  # checked out — a concurrent session may be standing in it.
  # HONEST ACCOUNTING of these two loops (mutated 2026-10-27, one safeguard at a time): the
  # `in_wt` test is the one that carries the LOCAL sweep, because `git branch -d` already refuses
  # a branch that is checked out — deleting the in_wt test from THIS loop changes nothing
  # observable. The `$DEFAULT_BRANCH` test here is structurally unreachable: the ship has already
  # required $MAIN to be on $DEFAULT_BRANCH, so the default branch is always in $in_wt. Both are
  # kept as belt-and-braces (they match fa-ship.sh, and they survive a future caller that skips
  # that precondition), but neither is pinned by a test and nobody should read them as covered.
  for b in $(git for-each-ref --merged "$upstream" --format='%(refname:short)' refs/heads); do
    [ "$b" = "$DEFAULT_BRANCH" ] && continue
    printf '%s\n' "$in_wt" | grep -qx "$b" && continue
    git branch -q -d "$b" && phase "cleanup: deleted merged branch $b"
  done
  # And the same for the remote-tracking refs: a merged topic branch left on origin is clutter that
  # `git fetch --prune` will not clean, because it was never deleted there. Here the in_wt test IS
  # load-bearing and IS tested (u3): `git push --delete` knows nothing about local worktrees. The
  # $DEFAULT_BRANCH test is again unreachable-by-construction, for the reason above.
  for r in $(git for-each-ref --merged "$upstream" --format='%(refname:lstrip=3)' refs/remotes/origin); do
    case "$r" in "$DEFAULT_BRANCH"|HEAD) continue ;; esac
    printf '%s\n' "$in_wt" | grep -qx "$r" && continue
    git push -q origin --delete "$r" && phase "cleanup: deleted merged origin/$r"
  done
  return 0
}

# --no-reap may appear in ANY position: pull it out before the dispatch so the flag composes
# with every invocation shape. Transient only — it skips cleanup for THIS ship; the permanent
# opt-out is rtc-ship.json's "reap": false, and the environment's RTC_SKIP_CLEANUP=1 (which
# predates the flag and which scripts already set) still applies on its own.
no_reap_seen=0
args=()
for a in "$@"; do
  case $a in
    --no-reap) no_reap_seen=1 ;;
    *) args+=("$a") ;;
  esac
done
set -- ${args[@]+"${args[@]}"}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
  --test-only) ;;
  --versions-only) ;;
  --which-config)
    git rev-parse --show-toplevel
    cfg_get "tag_prefix" "(none)"; exit 0 ;;
  -*) echo "rtc-ship.sh: unrecognised option $1" >&2; usage >&2; exit 2 ;;
esac

if [ "$1" = --test-only ]; then
  [ $# -eq 2 ] || { usage >&2; exit 2; }
  cd "$2"
  # FAIL, do not warn. A gate that reports a mismatch and exits 0 trains the operator to believe
  # the ground is covered — that is exactly how a decorative check survives.
  if ! version_gate; then echo "✖ version surfaces disagree — see above. Ship will refuse." >&2; exit 1; fi
  gates; exit $?
fi
if [ "$1" = --versions-only ]; then
  [ $# -eq 2 ] || { usage >&2; exit 2; }
  cd "$2"
  # The version gate ALONE — fast enough to run before every commit, and the only part a
  # hand-rolled ship reliably skips.
  if ! version_gate; then echo "✖ version surfaces disagree" >&2; exit 1; fi
  phase "version surfaces agree"; exit 0
fi
[ $# -eq 3 ] || { usage >&2; exit 2; }

WT=$1 V=$2 TITLE=$3
cd "$WT"; WT=$(pwd)
# -z, not -n: `[ -n "$out" ] || { dirty }` declares a CLEAN tree dirty and refuses every valid ship.
[ -z "$(git status --porcelain)" ] || { echo "✖ $WT is dirty" >&2; exit 1; }
BR=$(git branch --show-current)
TOP=$(git rev-parse --show-toplevel)
MAIN=${RTC_MAIN:-$(git rev-parse --git-common-dir | sed 's#/.git$##')}
PREFIX=$(cfg_get "tag_prefix" "")
# The reaping opt-out is validated HERE, before anything irreversible runs: a typo'd value
# ("flase") must abort the ship at the door — after the tag is pushed is far too late to learn
# the config was never read. Reaping is the default; the routes are --no-reap (transient),
# "reap": false in rtc-ship.json (permanent), RTC_SKIP_CLEANUP=1 (environment).
REAP=$(cfg_get "reap" 1)
case "$REAP" in
  1|0) : ;;
  *) echo "✖ rtc-ship.json: \"reap\": '$REAP' is not a boolean (use true or false) — fix the config" >&2
     exit 2 ;;
esac
# The default branch is NOT assumed. Config first (echoprism uses `master`), then the remote's own
# HEAD, and only then `main` — a hardcoded `main` would mis-ship a whole repo.
DEFAULT_BRANCH=$(cfg_get "default_branch" "")
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH=$(git -C "$MAIN" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
                   | sed 's|^origin/||' || true)
fi
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH=main
SHIP_LOG_DIR=${RTC_SHIP_LOG_DIR:-${TMPDIR:-/tmp}/rtc-ship-logs/$(basename "$MAIN")-$V}

# --- the door check: the version ARGUMENT is the version the tree carries ----------------------
# The version gate below compares the surfaces with EACH OTHER; nothing compared them with $V, so a
# typo'd argument merged main locally and then died inside the notes extraction with no message
# (fa-ship.sh checked VERSION and the CHANGELOG heading against $V first; the port dropped it).
door_manifest=$(cfg_get "manifest" ".claude-plugin/plugin.json")
tree_v=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("version",""))' \
         "$TOP/$door_manifest" 2>/dev/null || true)
if [ -n "$tree_v" ] && [ "$tree_v" != "$V" ]; then
  echo "✖ you asked to ship $V, but $door_manifest says $tree_v — fix the argument or bump the tree" >&2
  exit 1
fi
door_changelog=$(cfg_get "changelog" "CHANGELOG.md")
if [ -n "$door_changelog" ] && [ -f "$TOP/$door_changelog" ] \
   && ! grep -qE "^##+[[:space:]]+\[?${V//./\\.}\]?([^0-9.]|$)" "$TOP/$door_changelog"; then
  echo "✖ $door_changelog has no entry for $V — the release notes would be empty" >&2
  exit 1
fi

# --- the rebase: onto the default branch as it is NOW, before any gate ------------------------
# The header has always promised it and fa-ship.sh did it; the port had no `git rebase` call, so a
# branch behind the default branch passed every gate and then died at `merge --ff-only`. A conflict
# is aborted (never left half-rebased) and stops the ship before anything is tested or published.
mkdir -p "$SHIP_LOG_DIR"
git fetch -q origin
if ! git rebase -q "origin/$DEFAULT_BRANCH" >"$SHIP_LOG_DIR/rebase.log" 2>&1; then
  git rebase --abort >/dev/null 2>&1 || true
  echo "✖ rebase onto origin/$DEFAULT_BRANCH failed — resolve it in $WT, then re-run:" >&2
  sed 's/^/      /' "$SHIP_LOG_DIR/rebase.log" | tail -n 15 >&2
  exit 1
fi

# --- the version gate, where a hand-rolled ship skips it --------------------------------
# It runs AFTER the rebase and BEFORE the merge, because the bump lands between "suite green"
# and "PR opened". This is the gate whose absence let 0.43.2 ship split.
if ! version_gate; then echo "✖ version surfaces disagree — see above. Ship refused." >&2; exit 1; fi
# Pre-flight runs exactly ONCE: inside gates() (concurrently with the main suite), or on its own when
# the suite gates are skipped. The standalone call used to be `hook pre-flight` — no `.sh`, so it
# looked for a file that never exists and RTC_SKIP_TESTS=1 ships ran no pre-flight at all.
if [ "${RTC_SKIP_TESTS:-0}" != 1 ]; then gates || exit 1
else hook pre-flight.sh || exit 1; fi

cd "$MAIN"
[ "$(git branch --show-current)" = "$DEFAULT_BRANCH" ] || { echo "✖ $MAIN not on $DEFAULT_BRANCH" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "✖ $MAIN has tracked changes" >&2; exit 1; }
git fetch -q origin
git pull -q --ff-only origin "$DEFAULT_BRANCH"
git merge -q --ff-only "$BR"

# Extracted with python, not an awk program assembled from quoted fragments: the bracket-optional
# heading form plus an interpolated version made a regex too fragile to trust in shell quoting.
# Both heading styles are accepted (## 1.2.3 and ## [1.2.3]).
notes=$(if [ -f CHANGELOG.md ]; then CHANGELOG_FILE=CHANGELOG.md VERSION="$V" python3 - <<'PYEOF'
import os, re, sys
path, version = os.environ["CHANGELOG_FILE"], os.environ["VERSION"]
text = open(path, encoding="utf-8", errors="replace").read()
m = re.search(r"^##+[ \t]+\[?" + re.escape(version) + r"\]?\b", text, re.M)
if not m:
    sys.exit(1)
# Skip to the end of the HEADING line: a heading may carry a date and title after the version
# (`## [0.6.4] — 2026-10-24 — …`), and those are not release notes.
nl = text.find("\n", m.end())
rest = text[len(text) if nl == -1 else nl + 1:]
# Stop at the next SAME-LEVEL heading only: `##+` would also match `###`, truncating every
# entry at its first sub-heading and producing an empty release note.
nxt = re.search(r"^##(?!#)", rest, re.M)
sys.stdout.write(rest[:nxt.start()] if nxt else rest)
PYEOF
else echo ""; fi)
git tag -a "${PREFIX}${V}" -m "$(basename "$MAIN") $V — $TITLE

$notes"
git push -q origin "$DEFAULT_BRANCH" "${PREFIX}${V}"
phase "merged, tagged ${PREFIX}${V}, pushed"

# --- the tag must be VISIBLE, not merely pushed ------------------------------------------------
# A push returns BEFORE the host serves the new state, and the window is real (measured 2026-10-14:
# raw + ls-remote served the pre-push state for about a minute). The refresh step resolves the
# published MANIFEST from that CDN, so a ship that moves on immediately can print "done — v1.2.3 is
# live" while every installer still resolves the previous version. Measured on 0.6.7: exactly that
# — get-haiggoh read the stale manifest, reported "0.6.6 (current)" and copied nothing, and only a
# manual retry landed it. The fifth silent-failure class in this loop.
published_version() {  # the version the PUBLISHED manifest declares, or "" if it cannot be read
  local url body owner_repo
  url=$(git -C "$MAIN" remote get-url origin 2>/dev/null) || return 0
  owner_repo=$(printf '%s' "$url" | sed -e 's#^git@github.com:#github/#' -e 's#^https://github.com/##' \
                                        -e 's#^https://##' -e 's#\.git$##')
  case "$owner_repo" in */*) ;; *) return 0 ;; esac     # a local-path remote: nothing to check
  body=$(curl -fsS --max-time 20 \
    "https://raw.githubusercontent.com/$owner_repo/$DEFAULT_BRANCH/$(cfg_get manifest .claude-plugin/plugin.json)" 2>/dev/null) || body=""
  printf '%s' "$body" | sed -n -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1
  return 0
}

if [ "${RTC_TAG_VISIBILITY:-1}" = 1 ]; then
  vis_tries=0
  while :; do
    got=$(published_version)
    if [ "$got" = "$V" ]; then phase "tag ${PREFIX}${V} is VISIBLE to installers"; break; fi
    vis_tries=$((vis_tries + 1))
    if [ "$vis_tries" -ge "${RTC_TAG_VISIBILITY_TRIES:-6}" ]; then
      echo "✖ the published manifest declares ${got:-<nothing>}, not $V — installers still resolve the old version" >&2
      echo "  the tag and the branch are pushed, but nothing is released yet. Re-check, then re-run:" >&2
      echo "    curl -s https://raw.githubusercontent.com/<owner>/<repo>/$DEFAULT_BRANCH/$(cfg_get manifest .claude-plugin/plugin.json)" >&2
      echo "    rtc-ship.sh $WT $V \"$TITLE\"" >&2
      exit 1
    fi
    phase "tag not visible yet (${got:-<nothing>}) — waiting ${RTC_TAG_VISIBILITY_DELAY:-20}s (try $vis_tries/${RTC_TAG_VISIBILITY_TRIES:-6})"
    sleep "${RTC_TAG_VISIBILITY_DELAY:-20}"
  done
fi

# --- assets: built by the repo's own hook, so the tool never hardcodes a filename ----------
if [ -x "$TOP/.rtc/pre-package.sh" ]; then
  ( cd "$TOP" && run_logged "pre-package" "$SHIP_LOG_DIR/pre-package.log" ./.rtc/pre-package.sh ) \
    || { echo "✖ pre-package failed" >&2; exit 1; }
fi
# Resolve the globs in the MAIN shell, not a process substitution: an `exit` inside `< <(...)`
# only leaves that subshell, so a glob matching nothing would be dropped, the pipe would carry on
# with the globs that DID match, and the ship would publish a release missing an asset while
# reporting success — indistinguishable from a working release until someone tries to install it.
ASSETS=(); MISSING=()
# `set -f` around the split: each pattern arrives as ONE word from the config, and an unquoted
# for-word PATHNAME-EXPANDS against the CURRENT directory — which is $MAIN here, after the merge
# (measured 2026-10-26, free-agents 0.46.2: MAIN held the previous release's leftover
# dist/free-agents-0.46.1.tar.gz, the pattern expanded into literal filenames THERE, and compgen
# in the worktree then matched nothing — aborting the ship AFTER the tag was pushed). The shell
# must split the value but never glob it; compgen -G below is the only globber, and it runs in $TOP.
set -f
for g in $(cfg_get "assets" ""); do
  [ -n "$g" ] || continue
  # `|| true` inside the substitution: a non-matching glob makes compgen exit non-zero, and that
  # status becomes the assignment's own — under `set -e` it aborts the ship before the message
  # below can say WHICH glob failed. Exit code 1 with no reason is the failure this loop prevents.
  m=$(cd "$TOP" && compgen -G "$g" || true)
  if [ -z "$m" ]; then MISSING+=("$g"); else
    # Absolute, worktree-anchored paths: gh runs with cwd=$MAIN, so a relative asset name would
    # hand it MAIN's file — the stale build this loop exists to avoid. A match that is already
    # absolute (the config declared an absolute pattern) is passed through untouched.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case $f in /*) ASSETS+=("$f") ;; *) ASSETS+=("$TOP/$f") ;; esac
    done <<< "$m"
  fi
done
set +f
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "✖ asset glob(s) matched nothing in $TOP: ${MISSING[*]}" >&2
  echo "  the release would ship without them — fix the packaging hook or the glob" >&2
  exit 1
fi
# obs 0057 — a version-bearing asset that does not carry THIS release's version is a stale
# build: pre-package's output was never asserted, so a previous release's tarball left in dist/
# satisfied the glob and free-agents 0.45.2/0.45.3 shipped against dist/free-agents-0.44.1.tar.gz
# (packaging had built nothing current). The rehearsal replays exactly that. Version-free assets
# (an install script keeps its name across releases) cannot carry a version and pass. FAIL, do
# not warn — a gate that reports a mismatch and exits 0 trains the operator to believe the green.
ver_re='-([0-9]+)(\.[0-9]+)+'
if [ "${#ASSETS[@]}" -gt 0 ]; then
  for a in "${ASSETS[@]}"; do
    [ -f "$a" ] || continue
    b=$(basename "$a")
    if [[ $b =~ $ver_re ]]; then
      tok=${BASH_REMATCH[0]#-}
      if [ "$tok" != "$V" ]; then
        echo "✖ asset $b carries version $tok, not the release version $V — the build in $TOP is stale" >&2
        echo "  re-run (or fix) .rtc/pre-package.sh so dist/ holds THIS release's assets" >&2
        exit 1
      fi
    fi
  done
fi
if [ -n "$notes" ]; then
  nf=$(mktemp); printf '%s\n' "$notes" > "$nf"
  run_logged "gh release create" "$SHIP_LOG_DIR/gh-release.log" \
    gh release create "${PREFIX}${V}" --title "$(basename "$MAIN") $V — $TITLE" \
    --notes-file "$nf" ${ASSETS[@]+"${ASSETS[@]}"} || { rm -f "$nf"; exit 1; }
  rm -f "$nf"
else
  # No changelog to draw notes from (a repo may legitimately have none). Let gh derive them from
  # the commits rather than shipping an EMPTY body — which is what the first version of this script
  # did, and an empty release is a release nobody reads.
  run_logged "gh release create" "$SHIP_LOG_DIR/gh-release.log" \
    gh release create "${PREFIX}${V}" --title "$(basename "$MAIN") $V — $TITLE" \
    --generate-notes ${ASSETS[@]+"${ASSETS[@]}"} || exit 1
fi
phase "release published${ASSETS:+ with ${#ASSETS[@]} asset(s)}"
# ASK the release what it holds (fa-ship.sh listed it; the port dropped it). An upload that exited 0
# is a claim; the asset list GitHub serves back is the outcome. A declared asset it does not hold
# fails the ship — "published" over a missing tarball is the silent failure this loop exists to stop.
if [ "${#ASSETS[@]}" -gt 0 ]; then
  held=$(gh release view "${PREFIX}${V}" --json assets -q '.assets[].name' 2>/dev/null || true)
  printf '%s\n' "$held" | sed '/^$/d; s/^/  asset: /'
  lost=()
  for a in "${ASSETS[@]}"; do
    printf '%s\n' "$held" | grep -qxF "$(basename "$a")" || lost+=("$(basename "$a")")
  done
  if [ "${#lost[@]}" -gt 0 ]; then
    echo "✖ the published release does not hold: ${lost[*]} — re-upload with: gh release upload ${PREFIX}${V} <file>" >&2
    exit 1
  fi
fi

installed_version() {  # installed_version <plugin> — the version the INSTALLED cache holds, or ""
  local plugin=$1 base best v
  # Overridable so a test can point at a scratch cache: the real one is tool-owned state, and a
  # ship must never read (let alone write) it except through the tool that owns it.
  base=${RTC_PLUGIN_CACHE:-$HOME/.claude/plugins/cache}
  for d in "$base"/*/"$plugin"; do
    [ -d "$d" ] || continue
    # Versionless numeric sort: the cache dirs are named by version and there is no index to read.
    best=$(find "$d" -maxdepth 1 -mindepth 1 -type d | sort -V | tail -1)
    [ -n "$best" ] || continue
    v=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("version",""))' \
        "$best/.claude-plugin/plugin.json" 2>/dev/null) || v=""
    [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
  done
  return 0
}

PLUGIN=$(cfg_get "refresh_plugin" "")
if [ -n "$PLUGIN" ] && [ "${RTC_SKIP_REFRESH:-0}" != 1 ]; then
  get-haiggoh apply --only "$PLUGIN" 2>&1 | sed 's/^/  /' || echo "⚠ refresh failed" >&2
  # VERIFY it moved — invoking is not the same as landing. `get-haiggoh` exits 0 having copied
  # NOTHING when the manifest it reads is still the old version (a raw.githubusercontent.com
  # propagation window, a stale marketplace cache, an unbumped manifest), so a green exit code
  # says nothing about whether the installed copy is now $V. Measured 2026-10-25 on 0.6.7: this
  # loop printed "done — v0.6.7 is live" and exited 0 while the installed copy was still 0.6.6,
  # and only a manual retry landed it. fa-ship.sh checked this; the generalization dropped it.
  got=$(installed_version "$PLUGIN")
  if [ "$got" != "$V" ]; then
    echo "✖ the installed $PLUGIN is at ${got:-<none>}, not $V — the refresh did not land" >&2
    echo "  re-run once after a short delay (the manifest is served by a CDN), then: get-haiggoh apply --only $PLUGIN" >&2
    exit 1
  fi
  phase "installed $PLUGIN is $V"
fi
if [ -x "$TOP/.rtc/post-release.sh" ]; then
  # FAIL, do not warn. post-release is where a repo verifies the refresh it just performed (the
  # installed copy is at $V, the tap formula points at this release). A warning here lets a release
  # whose refresh silently did nothing print "done — v1.2.3 is live", which is the exact failure
  # this loop exists to prevent: a success message over an unverified outcome.
  if ! ( cd "$TOP" && ./.rtc/post-release.sh >/dev/null ); then
    echo "✖ post-release hook failed — the release is published but NOT confirmed live" >&2
    exit 1
  fi
fi
# The release is confirmed live. What happens to the branch that carried it is now safe to decide —
# and deciding it HERE is the point: the step every hand-rolled ship forgot is the one that lives
# inside the loop. A cleanup failure never fails a confirmed release; the release outranks the tidy.
# Three opt-out routes, reaping being the default. A skip is ANNOUNCED, never silent — a tool
# that quietly stops tidying looks broken from its own output (no-hidden-changes: the tool's
# own output must show the state it is in).
skip_reasons=""
if [ "$no_reap_seen" = 1 ]; then skip_reasons="--no-reap"; fi
if [ "$REAP" = 0 ]; then
  skip_reasons="${skip_reasons:+$skip_reasons, }reap:false in rtc-ship.json"
fi
if [ "${RTC_SKIP_CLEANUP:-0}" = 1 ]; then
  skip_reasons="${skip_reasons:+$skip_reasons, }RTC_SKIP_CLEANUP=1"
fi
if [ -n "$skip_reasons" ]; then
  phase "cleanup: skipped ($skip_reasons) — the worktree, its branch and merged branches are kept"
else
  cleanup || echo "⚠ cleanup failed; the release itself is done" >&2
fi
phase "done — ${PREFIX}${V} is live"
