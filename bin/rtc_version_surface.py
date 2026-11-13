#!/usr/bin/env python3
"""rtc_version_surface.py — read/write EXTRA version surfaces (the ONE shared resolver).

Used by BOTH rtc-ship.sh --bump-versions (write) and version_gate (read): two
independent implementations drifted once already (the roadmap_target lesson,
waypoint run-to-completion-bump), so both call THIS script.

Usage:
  rtc_version_surface.py read  <top> <surfaces-json>            -> "<path>\\t<version>" lines
  rtc_version_surface.py write <top> <surfaces-json> <version>

<surfaces-json> is a JSON array — inline, or the path of a file holding it — of:
  {"path": <repo-relative>, "kind": "json"|"toml-package"|"cargo-lock",
   "key": <dotted json path, default "version">, "crate": <name, required for cargo-lock>}

Every failure exits 1 naming the surface: a declared file that is missing or
yields NO version is a failure, never a pass (empty extraction = failure). A
crate appearing with TWO [[package]] blocks in Cargo.lock is refused loudly —
the resolver never picks one. Writes rewrite ONLY the version token in place
(no JSON/TOML round-trip; every other byte is preserved) via tmp + os.replace,
and the written file is re-read and re-extracted as a post-write check — a
writer that mis-targeted fails instead of staying silent.

Environment: none. Depends on: Python 3 stdlib only.
"""
import json
import os
import re
import sys
import tempfile
from typing import NoReturn


def fail(msg) -> NoReturn:
    sys.stderr.write("✖ " + msg + "\n")
    sys.exit(1)


def usage() -> NoReturn:
    sys.stderr.write((__doc__ or "").lstrip())
    sys.exit(2)


def load_surfaces(arg):
    text = arg if arg.lstrip().startswith("[") else open(arg).read()
    try:
        surfaces = json.loads(text)
    except Exception as e:
        fail("extra_version_surfaces is not valid JSON: %s" % e)
    if not isinstance(surfaces, list):
        fail("extra_version_surfaces must be a JSON array, got %s" % type(surfaces).__name__)
    for s in surfaces:
        if not isinstance(s, dict) or "path" not in s or "kind" not in s:
            fail("extra_version_surfaces entry needs \"path\" and \"kind\": %r" % (s,))
        if s["kind"] not in ("json", "toml-package", "cargo-lock"):
            fail("surface %s: unknown kind %r (json | toml-package | cargo-lock)"
                 % (s["path"], s["kind"]))
        if s["kind"] == "cargo-lock" and not s.get("crate"):
            fail("surface %s: kind cargo-lock needs \"crate\"" % s["path"])
        if s["kind"] != "json" and s.get("key"):
            fail("surface %s: \"key\" applies to kind json only" % s["path"])
    return surfaces


def json_walk(data, segs):
    """Follow a dotted key through parsed JSON; return the string value or None."""
    cur = data
    for seg in segs:
        if not isinstance(cur, dict) or seg not in cur:
            return None
        cur = cur[seg]
    return cur if isinstance(cur, str) else None


def rewrite_line_token(line, new):
    """Rewrite the first quoted string after a `key :` on this line; None if no such value."""
    new_line, n = re.subn(r'("(?:[^"\\]|\\.)*"\s*:\s*)"[^"]*"', r'\g<1>"' + new + '"', line, count=1)
    return new_line if n else None


def json_first_field(data):
    """The first "version" STRING value in document order (dicts preserve insertion order) —
    the no-explicit-key contract: `{"package":{"version":"1.0.0"}}` resolves to the nested one."""
    if isinstance(data, dict):
        for k, v in data.items():
            if k == "version" and isinstance(v, str):
                return v
            r = json_first_field(v)
            if r is not None:
                return r
    elif isinstance(data, list):
        for v in data:
            r = json_first_field(v)
            if r is not None:
                return r
    return None


def json_read(text, s):
    try:
        data = json.loads(text)
    except Exception as e:
        fail("%s: not valid JSON (%s)" % (s["path"], e))
    if s.get("key"):
        segs = s["key"].split(".")
        v = json_walk(data, segs)
        if v is None:
            fail('%s: no version at json path "%s"' % (s["path"], s["key"]))
        return v
    v = json_first_field(data)
    if v is None:
        fail('%s: no "version" field' % s["path"])
    return v


def json_write(text, s, new):
    """In-place rewrite of the version token, byte-preserving everywhere else.

    Explicit "key": a line-based depth-aware scanner targets that dotted path (a nested decoy
    with the same key name is never touched). No key: the FIRST `"version"` field in document
    order (the 1.4.2 contract). Pretty-printed config files keep the key on its own line; the
    post-write re-extract in surface_write() catches any shape this mis-targets and fails
    instead of corrupting.
    """
    lines = text.splitlines(keepends=True)
    if not s.get("key"):
        for idx, ln in enumerate(lines):
            if '"version"' not in ln:
                continue
            m = re.search(r'("version"\s*:\s*")([^"]*)(")', ln)
            if m:
                lines[idx] = ln[: m.start()] + m.group(1) + new + m.group(3) + ln[m.end():]
                return "".join(lines)
        fail('%s: no "version" field' % s["path"])
    segs = s["key"].split(".")
    path = []       # key stack, by depth
    depth = 0
    done = False
    for idx, ln in enumerate(lines):
        if done:
            break
        # structural braces only: braces inside strings must not move the depth
        in_str = esc = False
        opens = closes = 0
        for ch in ln:
            if esc:
                esc = False
            elif in_str and ch == "\\":
                esc = True
            elif ch == '"':
                in_str = not in_str
            elif not in_str and ch in "{[":
                opens += 1
            elif not in_str and ch in "}]":
                closes += 1
        keym = re.match(r'\s*"((?:[^"\\]|\\.)+)"\s*:', ln)
        if keym:
            # path holds the container keys above this line; at this key the nesting depth is
            # `depth`, so trim to depth-1 entries, then this key: path == segs means target
            while len(path) >= depth:
                path.pop()
            path.append(keym.group(1))
            if path == segs:
                new_line = rewrite_line_token(ln, new)
                if new_line is not None:
                    lines[idx] = new_line
                    done = True
        depth += opens - closes
    if not done:
        fail('%s: could not rewrite json path "%s" in place' % (s["path"], s["key"]))
    return "".join(lines)


def toml_section_scan(text):
    """Yield (section, line_index, line) for body lines, tracking [table] headers."""
    lines = text.splitlines(keepends=True)
    section = None
    for idx, ln in enumerate(lines):
        hm = re.match(r'\s*\[+\s*([^\]]+?)\s*\]+', ln)
        if hm:
            section = hm.group(1)
            continue
        yield section, idx, ln


def toml_read(text, s):
    for section, _, ln in toml_section_scan(text):
        if section != "package":
            continue
        m = re.match(r'\s*version\s*=\s*"([^"]*)"', ln)
        if m:
            return m.group(1)
    fail("%s: no version = \"...\" line in the [package] table" % s["path"])


def toml_write(text, s, new):
    lines = text.splitlines(keepends=True)
    for section, idx, ln in toml_section_scan(text):
        if section != "package" or idx is None:
            continue
        if re.match(r'\s*version\s*=\s*"', ln):
            # rewrite ONLY this line's quoted token — the inline serde = { version = "1.0" }
            # decoy lives on a different line and must survive byte-for-byte
            lines[idx] = re.sub(r'(\bversion\s*=\s*")[^"]*(")', r"\g<1>" + new + r"\g<2>", ln, count=1)
            return "".join(lines)
    fail("%s: no version = \"...\" line in the [package] table" % s["path"])


def lock_blocks(text):
    """Parse Cargo.lock into [{name, version, line_index}]; first name/version per block wins."""
    lines = text.splitlines(keepends=True)
    blocks = []
    cur = None  # type: dict | None
    for idx, ln in enumerate(lines):
        if re.match(r'\s*\[\[package\]\]', ln):
            cur = {"name": None, "version": None, "idx": None}
            blocks.append(cur)
            continue
        if cur is None:
            continue
        m = re.match(r'\s*name\s*=\s*"([^"]*)"', ln)
        if m and cur["name"] is None:
            cur["name"] = m.group(1)
            continue
        m = re.match(r'\s*version\s*=\s*"([^"]*)"', ln)
        if m and cur["version"] is None:
            cur["version"] = m.group(1)
            cur["idx"] = idx
    return blocks, lines


def lock_read(text, s):
    crate = s["crate"]
    blocks, _ = lock_blocks(text)
    hits = [b for b in blocks if b["name"] == crate]
    if not hits:
        fail("%s: no [[package]] block names crate \"%s\"" % (s["path"], crate))
    if len(hits) > 1:
        fail("%s: crate \"%s\" appears %d times in Cargo.lock (versions %s) — ambiguous, "
             "refusing to pick one" % (s["path"], crate, len(hits),
                                       ", ".join(b["version"] or "<none>" for b in hits)))
    if hits[0]["version"] is None:
        fail("%s: the [[package]] block for \"%s\" holds no version" % (s["path"], crate))
    return hits[0]["version"]


def lock_write(text, s, new):
    crate = s["crate"]
    blocks, lines = lock_blocks(text)
    hits = [b for b in blocks if b["name"] == crate]
    if not hits:
        fail("%s: no [[package]] block names crate \"%s\"" % (s["path"], crate))
    if len(hits) > 1:
        fail("%s: crate \"%s\" appears %d times in Cargo.lock — ambiguous, refusing to pick one"
             % (s["path"], crate, len(hits)))
    idx = hits[0]["idx"]
    if idx is None:
        fail("%s: the [[package]] block for \"%s\" holds no version" % (s["path"], crate))
    lines[idx] = re.sub(r'(\bversion\s*=\s*")[^"]*(")', r"\g<1>" + new + r"\g<2>", lines[idx], count=1)
    return "".join(lines)


def surface_extract(text, s):
    kind = s["kind"]
    if kind == "json":
        return json_read(text, s)
    if kind == "toml-package":
        return toml_read(text, s)
    return lock_read(text, s)


def surface_write(text, s, new):
    kind = s["kind"]
    if kind == "json":
        new_text = json_write(text, s, new)
    elif kind == "toml-package":
        new_text = toml_write(text, s, new)
    else:
        new_text = lock_write(text, s, new)
    # post-write check: the new text must carry the new version where the read path looks —
    # a writer that mis-targeted fails here instead of corrupting the file silently
    got = surface_extract(new_text, s)
    if got != new:
        fail("%s: post-write check failed (extracted %s, wanted %s) — nothing written"
             % (s["path"], got, new))
    return new_text


def write_atomic(path, data):
    # tmp + os.replace: a crash mid-write must not truncate the surface
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=os.path.basename(path) + ".bump-tmp")
    with os.fdopen(fd, "w") as fh:
        fh.write(data)
    os.replace(tmp, path)


def main(argv):
    if len(argv) >= 2 and argv[1] in ("-h", "--help"):
        sys.stdout.write((__doc__ or "").lstrip())
        return 0
    if len(argv) == 4 and argv[1] == "read":
        top, surfaces_arg = argv[2], argv[3]
        new = None
    elif len(argv) == 5 and argv[1] == "write":
        top, surfaces_arg, new = argv[2], argv[3], argv[4]
    else:
        usage()
    surfaces = load_surfaces(surfaces_arg)

    # two passes: validate EVERY surface's extractability first, so a broken third surface
    # never leaves the first two half-bumped
    texts = {}
    versions = {}
    for s in surfaces:
        p = os.path.join(top, s["path"])
        if not os.path.isfile(p):
            fail("%s: declared in extra_version_surfaces but absent" % s["path"])
        with open(p, encoding="utf-8") as fh:
            texts[s["path"]] = fh.read()
        versions[s["path"]] = surface_extract(texts[s["path"]], s)

    for s in surfaces:
        if new is None:
            sys.stdout.write("%s\t%s\n" % (s["path"], versions[s["path"]]))
        else:
            new_text = surface_write(texts[s["path"]], s, new)
            write_atomic(os.path.join(top, s["path"]), new_text)
            sys.stdout.write("  %s -> %s\n" % (s["path"], new))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
