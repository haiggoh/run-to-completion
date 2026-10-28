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
D="$TMP/r5"; rehearse "$D"; fake_cache "$D" 0.2.0
is "a refresh that moved the version ships" "0" "$(ship "$D" 0.2.0 'second')"
has "and reports the installed version" "$(cat "$D/out")" "installed"

D="$TMP/r6"; rehearse "$D"; fake_cache "$D" 0.1.0
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

summary
