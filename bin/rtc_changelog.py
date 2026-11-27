#!/usr/bin/env python3
"""rtc_changelog.py — the ONE fence-aware CHANGELOG scanner rtc-ship.sh uses for every heading scan.

A `## x.y.z` line inside a fenced code block (``` or ~~~) is an EXAMPLE, not an entry. Every scan —
the door's "has an entry" and placeholder checks, the tag/entry count, the release-notes extraction,
the version gate's top-entry read and --bump-versions — reads headings through unfenced() (or the
offset-preserving mask()) so none of them can be fooled by one (2026-11-27).

Usage:
  rtc_changelog.py section <changelog> <version>
      Print the body of <version>'s entry: the lines AFTER its heading line, up to the next
      same-level (`## `) heading outside a fence. Exit 3 when there is no such entry.
  rtc_changelog.py top <changelog>
      Print the version of the first entry heading (`##`+, either bracket style) outside a
      fence — the version gate's "top entry". Exit 3 when there is none.
  rtc_changelog.py --help

Library (sys.path.insert the bin dir): unfenced(text), mask(text), versions(text), top(text),
section(text, version).
Exit codes: 0 ok · 2 usage error · 3 no entry (for <version>, or no versioned heading at all).
Environment: none.
"""
import re
import sys

# CommonMark fences: 3+ backticks or tildes, indented at most 3 spaces. Only the SAME character at
# >= the opening length, with nothing else on the line, closes one — so a ``` line inside a ~~~~
# fence stays inside it, and ```markdown (info string) can open but never close.
_FENCE = re.compile(r" {0,3}(`{3,}|~{3,})")
# A release entry heading: `## 1.2.3`, `## [1.2.3]`, optionally followed by a date/title.
_ENTRY = re.compile(r"##(?!#)[ \t]+\[?(\d+\.\d+\.\d+)\]?(?![\d.])")
_SAME_LEVEL = re.compile(r"##(?!#)")


def unfenced(text):
    """Yield (index, line) for every line of text OUTSIDE a fenced code block (keepends lines)."""
    fence = None
    for i, line in enumerate(text.splitlines(keepends=True)):
        bare = line.rstrip("\r\n")
        f = _FENCE.match(bare)
        if fence is None:
            if f:
                fence = f.group(1)
                continue
            yield i, line
        elif (f and f.group(1)[0] == fence[0] and len(f.group(1)) >= len(fence)
              and not bare[f.end():].strip()):
            fence = None


def mask(text):
    """text with every fenced line (markers included) blanked to spaces, newlines kept: the SAME
    length, so a regex run over mask(text) yields offsets that are valid in text itself."""
    lines = text.splitlines(keepends=True)
    keep = {i for i, _ in unfenced(text)}
    return "".join(l if i in keep else re.sub(r"[^\r\n]", " ", l) for i, l in enumerate(lines))


# The gate's top entry keeps the old sed's breadth: `##` or deeper, either bracket style.
_TOP = re.compile(r"##+[ \t]+\[?(\d+\.\d+\.\d+)\]?")


def top(text):
    """Version of the first entry heading outside a fence, or None."""
    for _, line in unfenced(text):
        m = _TOP.match(line)
        if m:
            return m.group(1)
    return None


def versions(text):
    """Every x.y.z carried by a `## ` entry heading outside a fence, in file order (dups kept)."""
    out = []
    for _, line in unfenced(text):
        m = _ENTRY.match(line)
        if m:
            out.append(m.group(1))
    return out


def section(text, version):
    """Body of version's first unfenced entry (lines after its heading), or None if absent."""
    head = re.compile(r"##+[ \t]+\[?" + re.escape(version) + r"\]?(?![\d.])")
    lines = text.splitlines(keepends=True)
    start = None
    for i, line in unfenced(text):
        if start is None:
            if head.match(line):
                start = i + 1
        elif _SAME_LEVEL.match(line):
            return "".join(lines[start:i])
    return None if start is None else "".join(lines[start:])


def main(argv):
    if len(argv) == 2 and argv[1] in ("-h", "--help"):
        print((__doc__ or "").strip())
        return 0
    if not ((len(argv) == 4 and argv[1] == "section") or (len(argv) == 3 and argv[1] == "top")):
        print("usage: rtc_changelog.py section <changelog> <version> | top <changelog>"
              "  (--help for more)", file=sys.stderr)
        return 2
    with open(argv[2], encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    if argv[1] == "top":
        v = top(text)
        if v is None:
            return 3
        print(v)
        return 0
    body = section(text, argv[3])
    if body is None:
        return 3
    sys.stdout.write(body)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
