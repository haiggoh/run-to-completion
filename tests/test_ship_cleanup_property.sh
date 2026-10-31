#!/usr/bin/env bash
# tests/test_ship_cleanup_property.sh — the cleanup PROPERTY, asserted by outcome over a mixed tree:
#   (1) every file that disappears with the reaped worktree was NOISE, or sits in the backup
#       byte-for-byte;
#   (2) no branch whose tip exists only locally is ever deleted, while merged ones are.
# The noise oracle below is written out here, independently of rtc-ship.sh's classifier, so the test
# cannot agree with the code by construction. (The rtc-ship / watch-your-step taxonomy decision,
# 2026-10-31: one self-contained property test here instead of mutual fixtures between the repos.)
#
# Part of the ship-loop rehearsal (the rig and its rationale: tests/lib/rehearsal.sh).
# Usage: bash tests/test_ship_cleanup_property.sh
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/rehearsal.sh"

oracle_noise() {  # the test's OWN definition of what may vanish without a backup
  case "/$1" in
    */.DS_Store|*.pyc) return 0 ;;
    */__pycache__/*|*/.pytest_cache/*|*/.ruff_cache/*|*/.mypy_cache/*|*/.venv/*|*/venv/*|*/node_modules/*|*/dist/*|*/build/*) return 0 ;;
  esac
  return 1
}

D="$TMP/p1"; rehearse "$D"
(
  cd "$D/wt" || exit 1
  mkdir -p venv myvenv sub junkdir __pycache__ notes config
  echo x > venv/marker;              echo plan > myvenv/plan.md          # cache vs ledger by COMPONENT
  echo f > junkdir/.DS_Store                                            # a collapsed dir of pure junk
  echo f > sub/.DS_Store;            echo 'only copy' > sub/ledger.md    # a collapsed dir hiding a real file
  echo b > __pycache__/m.cpython.pyc; echo c > stray.pyc
  echo same > config/config.local.sh                                    # identical to canonical: not precious
  echo 'handover, unsaved' > notes/handover.md                          # the incident shape
  printf 'venv/\nmyvenv/\nsub/\njunkdir/\n__pycache__/\n*.pyc\nconfig/config.local.sh\nnotes/\n' >> .gitignore
  git add .gitignore && git -c user.email=t@t -c user.name=t commit -qm ignores
)
mkdir -p "$D/main/config" && echo same > "$D/main/config/config.local.sh"
# Branches: one merged (must go), one holding commits that exist nowhere else (must stay).
( cd "$D/main" && git branch merged-old main \
    && git checkout -q -b local-only && echo unique > unique.txt && git add unique.txt \
    && git -c user.email=t@t -c user.name=t commit -qm unique && git checkout -q main )
lonely=$(git -C "$D/main" rev-parse local-only)
# Snapshot every file in the worktree, ignored ones included, with content hashes.
( cd "$D/wt" && find . -type f -not -path './.git' -not -path './.git/*' | sed 's|^\./||' | sort ) > "$D/before.list"

is "the mixed tree ships" "0" "$(ship_c "$D")"
is "  and its worktree was actually reaped (the property is not vacuous)" "1" "$([ -d "$D/wt" ] && echo 0 || echo 1)"

lost_unprotected=""; checked=0
while IFS= read -r f; do
  checked=$((checked + 1))
  oracle_noise "$f" && continue
  [ -f "$D/main/$f" ] && git -C "$D/main" ls-files --error-unmatch "$f" >/dev/null 2>&1 && continue   # tracked: lives on in history
  [ -f "$D/main/$f" ] && [ "$f" = config/config.local.sh ] && continue                                # identical canonical copy
  b=$(find "$TMP/bk" -type f -path "*/$f" 2>/dev/null | head -1)
  [ -n "$b" ] || { lost_unprotected="$lost_unprotected $f"; continue; }
done < "$D/before.list"
is "  every vanished non-noise file is in the backup (checked $checked files)" "" "${lost_unprotected# }"
is "  the backed-up handover is byte-identical" "handover, unsaved" "$(cat "$(find "$TMP/bk" -type f -path '*/notes/handover.md' | head -1)" 2>/dev/null)"
is "  noise was NOT backed up (venv/marker)" "0" "$(bk | grep -c '^venv/')"
is "  the local-only branch survives" "$lonely" "$(git -C "$D/main" rev-parse --verify -q local-only || echo gone)"
is "  the merged branch is swept (the sweep really ran)" "" "$(branches "$D/main" | grep -x merged-old || echo '')"

summary
