#!/usr/bin/env bash
# tests/test_ship_visibility_private.sh — the tag-visibility gate for a PRIVATE GitHub repo and for
# a PLAIN repo without a version file, plus honest gate labels on a plain repo.
#
# 2026-11-27/28: joyia-keyswitch (private, "manifest": "", no version_file, version in the
# CHANGELOG + keyswitch/__init__.py) could not ship through rtc: the probe curled
# raw.githubusercontent.com unauthenticated (404 on a private repo) for a VERSION file the repo
# does not have, failed 6x AFTER the tag was pushed, and blamed "installers". And the plain-repo
# gate labelled its changelog anchor "manifest" ("   : 0.1.2", "… manifest says 0.1.2").
#
# Cases: a private plain repo ships, reading the CHANGELOG through an AUTHENTICATED gh api contents
# call (never the raw CDN); a stale private surface fails naming the surface and the version it
# held; a PUBLIC plain repo without a version file polls the raw CDN for the CHANGELOG; the gate on
# a plain repo never says "manifest" and names the real anchor in a mismatch.
#
# Usage: bash tests/test_ship_visibility_private.sh
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/rehearsal.sh"

make_plain_cl() {  # make_plain_cl <dir> — plain repo, NO version file: the CHANGELOG is the anchor
  ( cd "$1/wt" || exit 1
    sed -i '' -e 's|"manifest": ".claude-plugin/plugin.json"|"manifest": ""|' \
           -e 's|"refresh_plugin": "rehearsal"|"refresh_plugin": ""|' rtc-ship.json
    git add -A && git -c user.email=t@t -c user.name=t commit -qm plain-repo )
}

stub_gh_private() {  # stub_gh_private <dir> <private:true|false> — gh answers the repo-metadata
                     # and contents calls; everything else (release create/view) succeeds quietly
  cat > "$1/bin/gh" <<STUB
#!/usr/bin/env bash
printf "gh %s\n" "\$*" >> "\$CALLS"
case "\$*" in
  *"api repos/haiggoh/rehearsal --jq .private"*) echo "$2" ;;
  *"api"*"repos/haiggoh/rehearsal/contents/CHANGELOG.md?ref=main"*)
     printf '# Changelog\n\n## %s\n\nsecond\n' "\$PUBLISHED_VERSION" ;;
  *"api"*) exit 1 ;;
  "release view"*) exit 0 ;;
esac
exit 0
STUB
  chmod +x "$1/bin/gh"
}

stub_curl_changelog() {  # the public CDN: serves the CHANGELOG, 404s everything else
  cat > "$1/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf "curl %s\n" "${@: -1}" >> "$CALLS"
case "${@: -1}" in
  */main/CHANGELOG.md) printf '# Changelog\n\n## %s\n\nsecond\n' "$PUBLISHED_VERSION" ;;
  *) exit 22 ;;
esac
STUB
  chmod +x "$1/bin/curl"
}

echo "== a PRIVATE plain repo ships: authenticated read of the CHANGELOG, never the raw CDN =="
D="$TMP/priv-ok"; rehearse "$D"; make_plain_cl "$D"; stub_gh_private "$D" true; stub_curl_changelog "$D"
is "a private plain repo ships" "0" "$(ship "$D" 0.2.0 'second')"
has "  and says the tag is VISIBLE" "$(cat "$D/out")" "VISIBLE"
is "  read through gh api contents" "1" \
   "$(grep -c 'api.*repos/haiggoh/rehearsal/contents/CHANGELOG.md?ref=main' "$D/calls")"
is "  and never polled raw.githubusercontent.com" "0" "$(grep -c '^curl .*raw.githubusercontent' "$D/calls")"

echo "== a STALE private surface fails, naming the surface and what it held =="
D="$TMP/priv-stale"; rehearse "$D"; make_plain_cl "$D"; stub_gh_private "$D" true; stub_curl_changelog "$D"
rc=$( cd "$D/wt" && CALLS="$D/calls" PATH="$D/bin:$PATH" RTC_SKIP_TESTS=1 \
      RTC_PLUGIN_CACHE="$D/cache" RTC_BACKUP_DIR="$TMP/bk" RTC_TAG_VISIBILITY_DELAY=0 \
      RTC_TAG_VISIBILITY_TRIES=2 PUBLISHED_VERSION=0.1.0 RTC_SHIP_LOG_DIR="$D/logs" \
      "$ROOT/bin/rtc-ship.sh" "$D/wt" 0.2.0 'second' >"$D/out" 2>&1; echo $? )
is "a stale private surface fails the ship" "1" "$rc"
has "  names the CHANGELOG as the surface" "$(cat "$D/out")" "published surface (CHANGELOG.md)"
has "  shows what the branch held" "$(cat "$D/out")" "declares 0.1.0"

echo "== a PUBLIC plain repo with no version file polls the raw CDN for the CHANGELOG =="
D="$TMP/pub-cl"; rehearse "$D"; make_plain_cl "$D"; stub_gh_private "$D" false; stub_curl_changelog "$D"
is "a public plain repo without a version file ships" "0" "$(ship "$D" 0.2.0 'second')"
is "  polled the CHANGELOG on the raw CDN" "1" \
   "$(grep -cxF 'curl https://raw.githubusercontent.com/haiggoh/rehearsal/main/CHANGELOG.md' "$D/calls")"

echo "== the gate on a plain repo names its real anchor, never 'manifest' =="
D="$TMP/label"; rehearse "$D"; make_plain_cl "$D"
mkdir -p "$D/wt/pkg"; printf '__version__ = "0.0.9"\n' > "$D/wt/pkg/__init__.py"
python3 - "$D/wt/rtc-ship.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["extra_version_surfaces"] = [{"path": "pkg/__init__.py", "kind": "regex",
                                "pattern": '^__version__ = "([^"]+)"$'}]
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
out=$(bash "$ROOT/bin/rtc-ship.sh" --versions-only "$D/wt" 2>&1)
has "  mismatch names the CHANGELOG as the anchor" "$out" "pkg/__init__.py says 0.0.9, CHANGELOG.md says 0.2.0"
is "  the word 'manifest' appears nowhere" "0" "$(printf '%s\n' "$out" | grep -c 'manifest')"
is "  no empty-label line" "0" "$(printf '%s\n' "$out" | grep -cE '^[[:space:]]+: ')"

summary
