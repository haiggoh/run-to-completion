#!/usr/bin/env bash
# Tests for install/link-shortcuts.sh. Everything runs against a TEMP HOME, so the
# real ~/.local/bin/rtc-ship.sh is never touched.
#
# The contract is the one cost-tracker and audit-loose-ends established: the entry
# point becomes a SHIM that resolves per call, so a plugin update lands with no
# re-wiring. Deliberately near-identical to those repos' tests, because a shim
# contract that differs per plugin is not a contract.
set -uo pipefail
export LC_ALL=C

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd -P "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
WIRE="$PLUGIN/install/link-shortcuts.sh"

echo "link-shortcuts.sh"

# --- --help and a bad flag must do NO work -------------------------------------
H="$TMP/home"; mkdir -p "$H/.local/bin"
bash "$WIRE" --help > "$TMP/help.out" 2>&1
is "--help exits 0" "$?" "0"
is "--help prints usage" "$(grep -c '^Usage: link-shortcuts.sh' "$TMP/help.out")" "1"
is "--help documents --dry-run" "$(grep -c -- '--dry-run' "$TMP/help.out" | awk '{print ($1>0)?"yes":"no"}')" "yes"
bash "$WIRE" --bogus > /dev/null 2>&1
is "an unknown flag exits 2" "$?" "2"

# --- a fixture "installed plugin": registry-recorded, real bin/ -----------------
# TWO cache versions with the registry naming the OLDER one: the shim must follow the
# registry, not the highest cache dir. With a single version those two orders agree and
# a mutation that deletes the registry step survives green.
PDIR="$TMP/plugins"
FA="$PDIR/cache/haiggoh/run-to-completion/0.7.0"
NEWER="$PDIR/cache/haiggoh/run-to-completion/0.8.0"
for _v in "$FA" "$NEWER"; do
    mkdir -p "$_v/bin" "$_v/.claude-plugin"
    printf '%s\n' '{"name":"run-to-completion","version":"0.7.0"}' > "$_v/.claude-plugin/plugin.json"
    cp "$PLUGIN/bin/rtc-ship.sh" "$_v/bin/"
    cp "$PLUGIN/install/shim-template.sh" "$_v/install/shim-template.sh" 2>/dev/null \
        || { mkdir -p "$_v/install"; cp "$PLUGIN/install/shim-template.sh" "$_v/install/"; }
done
printf '%s' '{"plugins":{"run-to-completion@haiggoh":[{"scope":"user","installPath":"'"$FA"'"}]}}' \
    > "$PDIR/installed_plugins.json"

# --- dry run writes nothing ----------------------------------------------------
BEFORE="$(find "$H/.local/bin" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
HOME="$H" RUN_TO_COMPLETION_BIN_DIR="$H/.local/bin" CLAUDE_PLUGINS_DIR="$PDIR" \
    bash "$WIRE" --dry-run > "$TMP/dry.out" 2>&1
is "dry run exits 0" "$?" "0"
is "dry run says DRY RUN" "$(grep -c 'DRY RUN' "$TMP/dry.out")" "1"
is "dry run writes nothing" \
   "$(find "$H/.local/bin" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "$BEFORE"

# --- apply: a shim, not a symlink ----------------------------------------------
HOME="$H" RUN_TO_COMPLETION_BIN_DIR="$H/.local/bin" CLAUDE_PLUGINS_DIR="$PDIR" \
    bash "$WIRE" > "$TMP/apply.out" 2>&1
is "apply exits 0" "$?" "0"
is "rtc-ship.sh is a shim, not a symlink" \
   "$([ -L "$H/.local/bin/rtc-ship.sh" ] && echo symlink || echo regular)" "regular"
is "the shim carries the haiggoh-shim header" \
   "$(head -n 3 "$H/.local/bin/rtc-ship.sh" | grep -c '^# haiggoh-shim v1 plugin=run-to-completion target=bin/')" "1"
is "the shim is executable" \
   "$([ -x "$H/.local/bin/rtc-ship.sh" ] && echo yes || echo no)" "yes"
is "the shim runs the installed copy's script (its --help)" \
   "$(HOME="$H" RUN_TO_COMPLETION_BIN_DIR="$H/.local/bin" CLAUDE_PLUGINS_DIR="$PDIR" \
       /bin/sh "$H/.local/bin/rtc-ship.sh" --help 2>&1 | head -1 | grep -c '.')" "1"
is "--which prints the resolved target" \
   "$(HOME="$H" RUN_TO_COMPLETION_BIN_DIR="$H/.local/bin" CLAUDE_PLUGINS_DIR="$PDIR" \
       /bin/sh "$H/.local/bin/rtc-ship.sh" --which)" "$FA/bin/rtc-ship.sh"

# --- THE UPDATE: repoint the registry, re-run nothing ---------------------------
printf '%s' '{"plugins":{"run-to-completion@haiggoh":[{"scope":"user","installPath":"'"$FA"'"}]}}' \
    > "$PDIR/installed_plugins.json"
is "after a registry change the shim still resolves the recorded copy" \
   "$(HOME="$H" RUN_TO_COMPLETION_BIN_DIR="$H/.local/bin" CLAUDE_PLUGINS_DIR="$PDIR" \
       /bin/sh "$H/.local/bin/rtc-ship.sh" --which)" "$FA/bin/rtc-ship.sh"
# and a STALE entry (the dir is gone) falls through to the highest cache dir
printf '%s' '{"plugins":{"run-to-completion@haiggoh":[{"scope":"user","installPath":"'"$TMP/gone"'"}]}}' \
    > "$PDIR/installed_plugins.json"
is "a stale installPath falls through to the highest cache dir" \
   "$(HOME="$H" RUN_TO_COMPLETION_BIN_DIR="$H/.local/bin" CLAUDE_PLUGINS_DIR="$PDIR" \
       /bin/sh "$H/.local/bin/rtc-ship.sh" --which)" "$NEWER/bin/rtc-ship.sh"

# --- a replaced symlink is backed up; a foreign file is refused -----------------
SL="$TMP/slink"; mkdir -p "$SL/.local/bin" "$SL/target/bin"
printf '%s\n' 'OLD' > "$SL/target/bin/rtc-ship.sh"
ln -s "$SL/target/bin/rtc-ship.sh" "$SL/.local/bin/rtc-ship.sh"
HOME="$SL" RUN_TO_COMPLETION_BIN_DIR="$SL/.local/bin" CLAUDE_PLUGINS_DIR="$PDIR" \
    bash "$WIRE" > /dev/null 2>&1
is "a replaced symlink exits 0" "$?" "0"
SBK="$(find "$SL/.claude/backups" -maxdepth 1 -name 'run-to-completion-link-*' 2>/dev/null | head -1)"
is "the replaced symlink is backed up" "$(grep -c OLD "$SBK/rtc-ship.sh" 2>/dev/null)" "1"
is "and the path now carries a shim" \
   "$([ -L "$SL/.local/bin/rtc-ship.sh" ] && echo symlink || echo regular)" "regular"

FH="$TMP/foreign"; mkdir -p "$FH/.local/bin"
printf 'echo mine\n' > "$FH/.local/bin/rtc-ship.sh"
HOME="$FH" RUN_TO_COMPLETION_BIN_DIR="$FH/.local/bin" CLAUDE_PLUGINS_DIR="$PDIR" \
    bash "$WIRE" > "$TMP/foreign.out" 2>&1
is "a foreign file is refused (exit 1)" "$?" "1"
is "the refusal names the way out" "$(grep -c -- '--force' "$TMP/foreign.out")" "1"
is "the foreign file is left untouched" "$(cat "$FH/.local/bin/rtc-ship.sh")" "echo mine"
HOME="$FH" RUN_TO_COMPLETION_BIN_DIR="$FH/.local/bin" CLAUDE_PLUGINS_DIR="$PDIR" \
    bash "$WIRE" --force > /dev/null 2>&1
is "--force replaces it" "$?" "0"

# --- a re-run is a no-op --------------------------------------------------------
HOME="$H" RUN_TO_COMPLETION_BIN_DIR="$H/.local/bin" CLAUDE_PLUGINS_DIR="$PDIR" \
    bash "$WIRE" > "$TMP/rerun.out" 2>&1
is "a re-run exits 0" "$?" "0"
is "a re-run reports nothing to do" "$(grep -c 'Nothing to do' "$TMP/rerun.out")" "1"

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
