#!/usr/bin/env bash
# tests/test_ship_visibility_plain_repo.sh — the tag-visibility gate works for a PLAIN repo
# ("manifest": "" + version_file): it must poll the version FILE on the default branch, not the
# empty manifest path. 2026-11-24: mac-claude-migration v0.3.1 shipped with manifest:"" — the old
# code fetched raw .../main/ (404 on the real CDN), read <nothing>, and failed the gate 6x after
# the tag was already pushed; the release had to be finished by hand.
#
# Red-green: with the OLD published_version the stub 404s .../main/, so the happy-path ship
# exits 1 (case 1 goes RED) — the empty-path 404 is in the stub on purpose, matching the CDN.
#
# Usage: bash tests/test_ship_visibility_plain_repo.sh
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/rehearsal.sh"

plain_curl() {  # plain_curl <dir> — stub CDN: VERSION path serves the bare version, the empty
                 # manifest path 404s (like raw.githubusercontent.com), anything else serves JSON
  cat > "$1/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf "curl %s\n" "${@: -1}" >> "$CALLS"
case "${@: -1}" in
  */main/VERSION) printf '%s\n' "$PUBLISHED_VERSION" ;;
  */main/|*/main) exit 1 ;;   # the real CDN 404s the empty manifest path
  *) printf '{"name":"rehearsal","version":"%s"}\n' "$PUBLISHED_VERSION" ;;
esac
STUB
  chmod +x "$1/bin/curl"
}

make_plain() {  # make_plain <dir> — turn the rehearsal repo into a plain repo (manifest "")
  ( cd "$1/wt" || exit 1
    sed -i '' -e 's|"manifest": ".claude-plugin/plugin.json"|"manifest": "", "version_file": "VERSION"|' \
           -e 's|"refresh_plugin": "rehearsal"|"refresh_plugin": ""|' rtc-ship.json
    printf '0.2.0\n' > VERSION
    git add -A && git -c user.email=t@t -c user.name=t commit -qm plain-repo )
}

want="curl https://raw.githubusercontent.com/haiggoh/rehearsal/main/VERSION"

# Happy path: the published VERSION file agrees -> ship succeeds and polled the version file.
D="$TMP/plain-ok"; rehearse "$D"; make_plain "$D"; plain_curl "$D"
is "a plain repo (manifest \"\") ships" "0" "$(ship "$D" 0.2.0 'second')"
is "  and polls the version FILE, not the empty manifest path" "1" "$(grep -cxF "$want" "$D/calls")"
has "  and says the tag is VISIBLE" "$(cat "$D/out")" "VISIBLE"

# Stale CDN: published VERSION still 0.1.0 -> the gate FAILS, naming the real surface.
D="$TMP/plain-stale"; rehearse "$D"; make_plain "$D"; plain_curl "$D"
rc=$( cd "$D/wt" && CALLS="$D/calls" PATH="$D/bin:$PATH" RTC_SKIP_TESTS=1 \
      RTC_PLUGIN_CACHE="$D/cache" RTC_BACKUP_DIR="$TMP/bk" RTC_TAG_VISIBILITY_DELAY=0 \
      RTC_TAG_VISIBILITY_TRIES=2 PUBLISHED_VERSION=0.1.0 RTC_SHIP_LOG_DIR="$D/logs" \
      "$ROOT/bin/rtc-ship.sh" "$D/wt" 0.2.0 'second' >"$D/out" 2>&1; echo $? )
is "a stale plain-repo surface fails the ship" "1" "$rc"
has "  and names the version FILE as the surface" "$(cat "$D/out")" "published surface (VERSION)"
has "  and shows what the CDN held" "$(cat "$D/out")" "0.1.0"

summary
