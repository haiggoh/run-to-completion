#!/usr/bin/env python3
"""rtc_changelog.py — the ONE fence-aware CHANGELOG scanner rtc-ship.sh uses for every heading scan.

A `## x.y.z` line inside a fenced code block (``` or ~~~) is an EXAMPLE, not an entry. Every scan —
the door's "has an entry" and placeholder checks, the tag/entry count, the release-notes extraction —
reads headings through unfenced() so none of them can be fooled by one (2026-11-27).

Usage:
  rtc_changelog.py section <changelog> <version>
      Print the body of <version>'s entry: the lines AFTER its heading line, up to the next
      same-level (`## `) heading outside a fence. Exit 3 when there is no such entry.
  rtc_changelog.py --help

Library (sys.path.insert the bin dir): unfenced(text), versions(text), section(text, version).
Exit codes: 0 ok · 2 usage error · 3 no entry for <version>.
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
    if len(argv) != 4 or argv[1] != "section":
        print("usage: rtc_changelog.py section <changelog> <version>  (--help for more)", file=sys.stderr)
        return 2
    with open(argv[2], encoding="utf-8", errors="replace") as fh:
        body = section(fh.read(), argv[3])
    if body is None:
        return 3
    sys.stdout.write(body)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
