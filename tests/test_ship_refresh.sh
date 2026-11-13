#!/usr/bin/env bash
# tests/test_ship_refresh.sh — the refresh is VERIFIED, the tag is VISIBLE, pre-flight runs once.
#
# Part of the ship-loop rehearsal (the rig and its rationale: tests/lib/rehearsal.sh).
# Usage: bash tests/test_ship_refresh.sh
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/rehearsal.sh"

# ---------------------------------------------------------------------------------------------
# The refresh must be VERIFIED, not just invoked. `get-haiggoh` exits 0 having copied nothing when
# the manifest it reads is still the old version (a raw.githubusercontent.com propagation window,
# a stale marketplace cache, an unbumped manifest) — so a green exit code says nothing about
# whether the installed copy is now $V. Measured on 0.6.7: the loop printed "done — v0.6.7 is
# live" and exited 0 while the installed copy was still 0.6.6, and only a manual retry landed it.
# fa-ship.sh checked this; the generalization into rtc-ship.sh dropped the check.
# ---------------------------------------------------------------------------------------------
# landing_stub <dir> <tool> — a refresh tool that LANDS: invoked, it writes the published version into
# the scratch cache. The cache starts OLD, so the success case passes only if the loop really called
# the tool (2026-10-25 review: the cache used to be pre-filled with the new version, proving nothing).
landing_stub() {
  printf '%s\n' '#!/usr/bin/env bash' "printf '$2 %s\\n' \"\$*\" >> \"\$CALLS\"" \
    'case "$*" in *update*|*apply*) mkdir -p "$RTC_PLUGIN_CACHE/haiggoh/rehearsal/$PUBLISHED_VERSION/.claude-plugin"
      printf '"'"'{"name":"rehearsal","version":"%s"}\n'"'"' "$PUBLISHED_VERSION" > "$RTC_PLUGIN_CACHE/haiggoh/rehearsal/$PUBLISHED_VERSION/.claude-plugin/plugin.json" ;; esac' \
    'exit 0' > "$1/bin/$2"
  chmod +x "$1/bin/$2"
}
claude_stub() {  # claude_stub <dir> — record every claude invocation, succeed, copy NOTHING.
                 # Defined here (not in the no-get-haiggoh section below): r6 needs it before that.
  printf '%s\n' '#!/usr/bin/env bash' 'printf "claude %s\n" "$*" >> "$CALLS"' 'exit 0' > "$1/bin/claude"
  chmod +x "$1/bin/claude"
}
D="$TMP/r5"; rehearse "$D"; fake_cache "$D" 0.1.0; landing_stub "$D" get-haiggoh
is "a refresh that moved the version ships" "0" "$(ship "$D" 0.2.0 'second')"
has "and reports the installed version" "$(cat "$D/out")" "installed"

# claude_stub is REQUIRED here, not decoration: r6 ships on the FULL PATH (ship(), not ship_bare),
# and since the native fallback (rtc 1.5.0) a no-op get-haiggoh + stale cache would otherwise reach
# the REAL claude on PATH and mutate the user's installed plugins (§9 of the 1.5.0 plan).
D="$TMP/r6"; rehearse "$D"; fake_cache "$D" 0.1.0; claude_stub "$D"
rc=$(ship "$D" 0.2.0 'second')
is "a refresh that did NOT move the version FAILS the ship" "1" "$rc"
has "and names both the installed and the shipped version" "$(cat "$D/out")" "is at 0.1.0, not 0.2.0"
is "and does not claim the release is live" "0" "$(grep -c 'is live' "$D/out")"
# ---------------------------------------------------------------------------------------------
# The tag must be VISIBLE, not merely pushed. `git push` returns before the host SERVES the new
# state, and the window is real (measured 2026-10-14: raw + ls-remote served the pre-push state for
# about a minute). The refresh reads the PUBLISHED MANIFEST from that CDN, so a ship that moves on
# immediately can print "done — v1.2.3 is live" while every installer still resolves the previous
# version. Measured on 0.6.7: exactly that, and only a manual retry landed it.
# ---------------------------------------------------------------------------------------------
D="$TMP/r7"; rehearse "$D"
PUBLISHED_VERSION=0.2.0
d=$D
cat > "$d/bin/curl" <<'STUB'
#!/usr/bin/env bash
# the stub CDN: serve the manifest an installer would parse, at whatever version it is told
printf '{"name":"rehearsal","version":"%s"}
' "$PUBLISHED_VERSION"
STUB
chmod +x "$d/bin/curl"
is "a visible tag ships" "0" "$(cd "$d/wt" && PUBLISHED_VERSION=0.2.0 CALLS="$d/calls" PATH="$d/bin:$PATH" RTC_PLUGIN_CACHE="$d/cache" RTC_SKIP_TESTS=1 RTC_TAG_VISIBILITY_DELAY=0 bash "$ROOT/bin/rtc-ship.sh" "$d/wt" 0.2.0 'second' >/dev/null 2>&1; echo $?)"

D="$TMP/r8"; rehearse "$D"; d=$D
cat > "$d/bin/curl" <<'STUB'
#!/usr/bin/env bash
# the stub CDN: serve the manifest an installer would parse, at whatever version it is told
printf '{"name":"rehearsal","version":"%s"}
' "$PUBLISHED_VERSION"
STUB
chmod +x "$d/bin/curl"
# the CDN is still serving the PREVIOUS version, and never catches up
rc=$(cd "$d/wt" && PUBLISHED_VERSION=0.1.0 RTC_TAG_VISIBILITY_TRIES=2 RTC_TAG_VISIBILITY_DELAY=0 CALLS="$d/calls" PATH="$d/bin:$PATH" RTC_PLUGIN_CACHE="$d/cache" RTC_SKIP_TESTS=1 RTC_TAG_VISIBILITY_DELAY=0 RTC_SHIP_LOG_DIR="$d/logs" bash "$ROOT/bin/rtc-ship.sh" "$d/wt" 0.2.0 'second' >/dev/null 2>&1; echo $?)
is "an INVISIBLE tag fails the ship" "1" "$rc"

# ---------------------------------------------------------------------------------------------
# No get-haiggoh installed: the refresh falls back to Claude Code's own CLI, silently, and the
# read-back still decides. PATH is RESTRICTED to the stubs + /usr/bin:/bin so neither the real
# get-haiggoh (~/.local/bin) nor the real claude (/opt/homebrew/bin) can ever run from a test.
# ---------------------------------------------------------------------------------------------
ship_bare() {  # ship_bare <dir> <version> — the loop with ONLY the stubs and the system bin dirs
  local d=$1
  ( cd "$d/wt" && CALLS="$d/calls" PATH="$d/bin:/usr/bin:/bin" RTC_SKIP_TESTS=1 \
      RTC_PLUGIN_CACHE="$d/cache" RTC_TAG_VISIBILITY_DELAY=0 PUBLISHED_VERSION="$2" \
      RTC_SHIP_LOG_DIR="$d/logs" bash "$ROOT/bin/rtc-ship.sh" "$d/wt" "$2" 'second' >"$d/out" 2>&1; echo $? )
}
D="$TMP/r11"; rehearse "$D"; rm -f "$D/bin/get-haiggoh"; landing_stub "$D" claude; fake_cache "$D" 0.1.0
is "no get-haiggoh: the ship still refreshes and ships" "0" "$(ship_bare "$D" 0.2.0)"
is "  through 'claude plugin marketplace update haiggoh'" "1" "$(grep -cx 'claude plugin marketplace update haiggoh' "$D/calls")"
is "  then 'claude plugin update rehearsal@haiggoh'" "1" "$(grep -cx 'claude plugin update rehearsal@haiggoh' "$D/calls")"
is "  silently: no warning about the missing tool" "0" "$(grep -ci 'get-haiggoh' "$D/out")"

D="$TMP/r12"; rehearse "$D"; rm -f "$D/bin/get-haiggoh"; claude_stub "$D"; fake_cache "$D" 0.1.0
is "no get-haiggoh + a native update that copied nothing FAILS the ship" "1" "$(ship_bare "$D" 0.2.0)"
has "  naming both versions (the read-back still decides)" "$(cat "$D/out")" "is at 0.1.0, not 0.2.0"

D="$TMP/r13"; rehearse "$D"; rm -f "$D/bin/get-haiggoh"; fake_cache "$D" 0.2.0
is "neither get-haiggoh nor claude: the ship FAILS" "1" "$(ship_bare "$D" 0.2.0)"
has "  naming both tools" "$(cat "$D/out")" "neither get-haiggoh nor claude"

D="$TMP/r14"; rehearse "$D"; claude_stub "$D"; fake_cache "$D" 0.2.0
is "get-haiggoh present: ships" "0" "$(ship_bare "$D" 0.2.0)"
is "  and claude is never called" "0" "$(grep -c '^claude ' "$D/calls")"

D="$TMP/r9"; rehearse "$D"; counting_preflight "$D"
ship_rc=$(PF_COUNT="$D/pf.count" ship "$D" 0.2.0 'second')
is "a ship with the suite gates skipped still ships" "0" "$ship_rc"
is "  and still runs pre-flight, once (was: never)" "1" "$(wc -l < "$D/pf.count" | tr -d ' ')"

D="$TMP/r10"; rehearse "$D"; counting_preflight "$D"
mkdir -p "$D/home/.local/bin"
printf '#!/usr/bin/env bash\necho "1 passed in 0.01s"\n' > "$D/home/.local/bin/pytest"
chmod +x "$D/home/.local/bin/pytest"
rc=$(cd "$D/wt" && HOME="$D/home" PF_COUNT="$D/pf.count" CALLS="$D/calls" PATH="$D/bin:$PATH" \
       RTC_PLUGIN_CACHE="$D/cache" RTC_TAG_VISIBILITY_DELAY=0 PUBLISHED_VERSION=0.2.0 \
       bash "$ROOT/bin/rtc-ship.sh" "$D/wt" 0.2.0 'second' >"$D/out" 2>&1; echo $?)
is "a GATED ship ships" "0" "$rc"
is "  and runs pre-flight exactly once (not also as a hook)" "1" "$(wc -l < "$D/pf.count" | tr -d ' ')"

# pytest is found where it is installed, not only at the pipx path (2026-10-25 review): no
# ~/.local/bin/pytest, a pytest on PATH — the gate must use it.
D="$TMP/r15"; rehearse "$D"; counting_preflight "$D"; mkdir -p "$D/home"
printf '#!/usr/bin/env bash\necho ran >> "$PYT_COUNT"; echo "1 passed in 0.01s"\n' > "$D/bin/pytest"; chmod +x "$D/bin/pytest"
rc=$(cd "$D/wt" && HOME="$D/home" PYT_COUNT="$D/pyt.count" PF_COUNT="$D/pf.count" CALLS="$D/calls" PATH="$D/bin:$PATH" \
       RTC_PLUGIN_CACHE="$D/cache" RTC_TAG_VISIBILITY_DELAY=0 PUBLISHED_VERSION=0.2.0 \
       bash "$ROOT/bin/rtc-ship.sh" "$D/wt" 0.2.0 'second' >"$D/out" 2>&1; echo $?)
is "with no ~/.local/bin/pytest, a GATED ship uses the pytest on PATH" "0" "$rc"
is "  and it really ran" "1" "$(wc -l < "$D/pyt.count" 2>/dev/null | tr -d ' ' || echo 0)"

# ---------------------------------------------------------------------------------------------
# The native-CLI fallback (rtc 1.5.0, observation 0060): get-haiggoh exits 0 having copied NOTHING
# when the manifest it reads is stale (a CDN window, a TLS-inspecting network — its Python fetch
# fails SSL and reports "current"), so when the read-back shows it left the old version, the loop
# must fall back to `claude plugin update` and read back AGAIN before failing. Only when BOTH
# refreshers leave it behind does the ship fail — and then it must not blame the CDN when the
# tag-visibility probe already saw the new version (the manifest the installers see is fine; the
# local refresh is what failed).
# ---------------------------------------------------------------------------------------------
D="$TMP/r16"; rehearse "$D"; fake_cache "$D" 0.1.0; landing_stub "$D" claude
is "get-haiggoh misses: the ship still ships via the claude fallback" "0" "$(ship_bare "$D" 0.2.0)"
has "  saying the native CLI did it" "$(cat "$D/out")" "refreshed by claude plugin update (get-haiggoh left 0.1.0)"
is "  and claude really ran both its steps" "1" "$(grep -cx 'claude plugin update rehearsal@haiggoh' "$D/calls")"

D="$TMP/r17"; rehearse "$D"; fake_cache "$D" 0.1.0; claude_stub "$D"
rc=$(ship_bare "$D" 0.2.0)
is "both refreshers leave it behind: the ship FAILS" "1" "$rc"
has "  saying both ran" "$(cat "$D/out")" "both refreshers ran"
is "  and does NOT blame the CDN (the probe saw the new version)" "0" "$(grep -ci 'CDN' "$D/out")"

D="$TMP/r18"; rehearse "$D"; landing_stub "$D" get-haiggoh; claude_stub "$D"; fake_cache "$D" 0.1.0
is "get-haiggoh lands: ships" "0" "$(ship_bare "$D" 0.2.0)"
has "  crediting get-haiggoh" "$(cat "$D/out")" "refreshed by get-haiggoh"
is "  and claude is never called" "0" "$(grep -c '^claude ' "$D/calls")"

D="$TMP/r19"; rehearse "$D"; fake_cache "$D" 0.1.0; claude_stub "$D"
rc=$(cd "$D/wt" && CALLS="$D/calls" PATH="$D/bin:/usr/bin:/bin" RTC_SKIP_TESTS=1 \
      RTC_PLUGIN_CACHE="$D/cache" RTC_TAG_VISIBILITY_DELAY=0 PUBLISHED_VERSION=0.2.0 \
      RTC_TAG_VISIBILITY=0 RTC_SHIP_LOG_DIR="$D/logs" \
      bash "$ROOT/bin/rtc-ship.sh" "$D/wt" 0.2.0 'second' >"$D/out" 2>&1; echo $?)
is "visibility SKIPPED + both refusers: still fails" "1" "$rc"
has "  and MAY blame the CDN (no probe ever saw the new version)" "$(cat "$D/out")" "CDN"

summary
