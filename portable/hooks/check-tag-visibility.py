#!/usr/bin/env python3
"""check-tag-visibility.py — is a pushed tag VISIBLE to version-keyed installers?

The run-to-completion shipping loop's FALLBACK for when get-haiggoh is not installed or
transiently unresponsive: fetch the repo's HEAD manifest, diagnose it (unresolved conflict
markers, invalid JSON, missing version key), read the highest v-semver tag, and compare
against the installed version. Verbose verdict either way — a broken release must never
look like a successful push.

Usage:
  check-tag-visibility.py <repo-url> <installed-version>
  check-tag-visibility.py --self-test

Exit 0 = visible, 1 = BROKEN or hidden (verbose diagnosis printed), 2 = usage error.

The diagnosis taxonomy is extracted from get-haiggoh's get_haiggoh_core.diagnose_manifest
(0.9.0) so run-to-completion carries no hard dependency on get-haiggoh; keep the two in
sync — get-haiggoh remains the source of truth for the taxonomy.
"""
import json
import re
import subprocess
import sys
import urllib.request

REMOTE_TIMEOUT_S = 20


def diagnose_manifest(body, url):
    """Classify a fetched HEAD manifest -> (version, diagnostic|None). Same taxonomy as
    get-haiggoh's get_haiggoh_core.diagnose_manifest (0.9.0); keep in sync."""
    if body is None:
        return None, None
    text = body.decode("utf-8", errors="replace") if isinstance(body, bytes) else body
    if "<<<<<<<" in text or ">>>>>>>" in text:
        return None, {"url": url,
                      "problem": "manifest contains unresolved CONFLICT MARKERS",
                      "meaning": ("an unresolved merge was published to the default branch; "
                                  "version-keyed installers read garbage here and fall back to "
                                  "the old version, so the update is invisible"),
                      "fix": ("resolve .claude-plugin/plugin.json on the default branch (align "
                              "every version surface), commit and push; if a tag announces the "
                              "new version, move the tag onto the corrected commit (delete and "
                              "re-push it) and say plainly that it moved")}
    try:
        data = json.loads(text)
    except ValueError:
        return None, {"url": url,
                      "problem": "manifest is not valid JSON",
                      "meaning": "the default branch's manifest cannot be parsed",
                      "fix": "fix .claude-plugin/plugin.json on the default branch and push"}
    version = data.get("version") if isinstance(data, dict) else None
    if not isinstance(version, str) or not version:
        return None, {"url": url,
                      "problem": "manifest has no usable version key",
                      "meaning": "the version the installer compares against is missing",
                      "fix": ("add the version to .claude-plugin/plugin.json on the default "
                              "branch and push")}
    return version, None


def tag_version_tuple(tag):
    m = re.match(r"^v(\d+)\.(\d+)\.(\d+)", tag or "")
    return tuple(int(g) for g in m.groups()) if m else None


def manifest_url_for(repo_url):
    """The raw HEAD manifest URL for a git repo URL — same conversion as get-haiggoh's
    plugin_manifest_url: github.com/<owner>/<repo>(.git) -> raw.githubusercontent.com/
    <owner>/<repo>/HEAD/.claude-plugin/plugin.json. Keep in sync."""
    base = re.sub(r"\.git$", "", repo_url.rstrip("/"))
    if "github.com/" in base:
        base = base.replace("https://github.com/", "https://raw.githubusercontent.com/")
    return base + "/HEAD/.claude-plugin/plugin.json"


def parse_latest_tag(ls_remote_output):
    best, best_key = None, None
    for line in (ls_remote_output or "").splitlines():
        ref = line.strip().split("\t")[-1] if "\t" in line else line.strip()
        if not ref.startswith("refs/tags/") or ref.endswith("^{}"):
            continue
        tag = ref[len("refs/tags/"):]
        key = tag_version_tuple(tag)
        if key is not None and (best_key is None or key > best_key):
            best, best_key = tag, key
    return best


def _print_verdict(name, visible, lines):
    head = "VISIBLE" if visible else "BROKEN OR HIDDEN"
    print(f"[{head}] {name}")
    for line in lines:
        print(f"    {line}")


def self_test():
    """Network-free assertions of the diagnosis taxonomy. Returns 0 when they hold."""
    marker_body = ('{\n  "name": "x",\n<<<<<<< HEAD\n  "version": "1.0.0",\n'
                   '=======\n  "version": "2.0.0",\n>>>>>>> abc\n}')
    version, diag = diagnose_manifest(marker_body, "u")
    assert version is None and diag and "CONFLICT MARKERS" in diag["problem"], diag
    version, diag = diagnose_manifest("<html>502</html>", "u")
    assert version is None and diag and "not valid JSON" in diag["problem"], diag
    version, diag = diagnose_manifest('{"name": "x"}', "u")
    assert version is None and diag and "no usable version" in diag["problem"], diag
    version, diag = diagnose_manifest('{"version": "1.2.3"}', "u")
    assert version == "1.2.3" and diag is None
    assert parse_latest_tag("refs/tags/v0.32.1\nrefs/tags/v0.33.0\nrefs/tags/v0.33.0^{}\n") \
        == "v0.33.0"
    assert tag_version_tuple("v0.33.0-rc1") == (0, 33, 0)
    print("self-test OK: diagnosis taxonomy + tag parsing hold")
    return 0


def main(argv):
    if "--self-test" in argv:
        return self_test()
    if len(argv) != 3:
        print(__doc__)
        return 2
    repo_url, installed = argv[1], argv[2]
    manifest_url = manifest_url_for(repo_url)
    try:
        with urllib.request.urlopen(manifest_url, timeout=REMOTE_TIMEOUT_S) as response:
            body = response.read()
    except Exception as exc:
        _print_verdict(repo_url, False, [
            f"fetched: {manifest_url}",
            f"problem: fetch failed: {exc}",
            "meaning: the published manifest could not be downloaded",
            "fix: check connectivity; the manifest must exist at the default branch"])
        return 1
    version, diagnostic = diagnose_manifest(body, manifest_url)
    if diagnostic:
        _print_verdict(repo_url, False, [
            f"fetched: {diagnostic['url']}",
            f"problem: {diagnostic['problem']}",
            f"meaning: {diagnostic['meaning']}",
            f"fix:     {diagnostic['fix']}"])
        return 1
    installed_tuple = tag_version_tuple(installed)
    head_tuple = tag_version_tuple(version)
    if head_tuple is not None and installed_tuple is not None and head_tuple < installed_tuple:
        _print_verdict(repo_url, False, [
            f"HEAD publishes {version} but the installed version is {installed} — HEAD is "
            "BEHIND: the merge/push of the release did not land on the default branch",
            "fix: push the release commit to the default branch, then re-check"])
        return 1
    # The deterministic tag check: the repo's highest v-tag announces what the RELEASE
    # claims; the HEAD manifest says what installers actually see. A disagreement is the
    # hidden-update shape (tagged commit's manifest not bumped, or tag on the wrong commit).
    tag, tag_tuple = None, None
    try:
        out = subprocess.run(["git", "ls-remote", "--tags", repo_url], capture_output=True,
                             text=True, timeout=REMOTE_TIMEOUT_S).stdout
        tag = parse_latest_tag(out)
        tag_tuple = tag_version_tuple(tag) if tag else None
    except Exception:
        pass
    if tag and tag_tuple is not None and head_tuple is not None and tag_tuple > head_tuple:
        _print_verdict(repo_url, False, [
            f"the latest tag {tag} announces a NEWER version than the HEAD manifest publishes ({version})",
            "meaning: the tagged commit's manifest was not bumped, or the tag points at the "
            "wrong commit — version-keyed installers compare the HEAD manifest and will never "
            "see the tagged version",
            f"fix: align the version surfaces on the default branch (plugin.json must say "
            f"{tag[1:]}) and move the tag onto the corrected commit, saying plainly that it moved"])
        return 1
    _print_verdict(repo_url, True, [
        f"HEAD publishes {version}; version-keyed installers will see the update"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
