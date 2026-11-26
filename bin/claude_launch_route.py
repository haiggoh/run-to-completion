#!/usr/bin/env python3
"""claude_launch_route — learn HOW the calling Claude Code session was launched, without
naming any gateway: walk the process ancestry to the `claude` process and classify its parent.

  wrapper  claude's parent is a launcher program (a gateway CLI or similar). Its leading
           plain words (up to the first flag) are the replayable launcher, e.g. `gw agent claude`.
  env      claude was started directly from a shell and the route/credential variables are set.
  login    started directly, no route variables, and a CLEAN-env `claude auth status --json`
           reports loggedIn — a normal Anthropic login, where a plain `claude` just works.
  none     nothing to inherit and not logged in.

Never prints or stores credential values or full argv: launcher words are kept only if every
token is a short plain word, otherwise the launcher is `unavailable (unsafe token)`.

Usage:
  claude_launch_route.py --classify FIXTURE.json   classify a fixture (tests)
  claude_launch_route.py --detect                  classify THIS process tree (read-only)
  claude_launch_route.py --help

A fixture is {"ancestry": [{"pid","comm","args"}...], "env": {...}, "logged_in_clean": bool|null}
with ancestry[0] = this process's parent, upward.
Environment variables read: the route/credential set (CREDENTIAL_VARS) by --detect, plus HOME
and PATH for the clean login probe. Exit codes: 0 ok, 2 usage.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import TypedDict
from urllib.parse import urlparse

# The variables that decide which gateway, key, model and cloud a session talks to.
CREDENTIAL_VARS = re.compile(r'^(ANTHROPIC_[A-Z0-9_]+|CLAUDE_CODE_USE_(VERTEX|BEDROCK|FOUNDRY)|CLOUD_ML_REGION|VERTEX_REGION_[A-Z0-9_]+|OPENAI_[A-Z0-9_]+|AWS_(REGION|PROFILE|ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN))$')
HAS_CREDENTIAL = ('ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_FOUNDRY')

SHELLS = {'sh', 'bash', 'zsh', 'fish', 'dash', 'ksh', 'tcsh', 'csh', 'login', 'tmux', 'screen'}
TRANSPARENT = {'env', 'nohup', 'caffeinate', 'arch', 'time', 'sudo'}
SAFE_WORD = re.compile(r'^[A-Za-z0-9._/-]{1,40}$')
KEY_SHAPED = re.compile(r'^(sk-|ghp_|gho_|eyJ)|[A-Za-z0-9+/_=-]{32,}')
UNSAFE = 'unavailable (unsafe token)'


class Proc(TypedDict):
    pid: int
    comm: str
    args: list[str]


@dataclass
class Route:
    kind: str                      # 'wrapper' | 'env' | 'login' | 'none'
    launcher: list[str] | None     # replayable launcher words, wrapper only, when safe
    launcher_name: str | None      # basename of the wrapper program
    unsafe_launcher: bool          # wrapper found but its words failed the safety check
    lane: str                      # base-URL host / cloud-provider / anthropic-default
    inside_session: bool           # a claude ancestor was found

    def line(self) -> str:
        launcher = UNSAFE if self.unsafe_launcher else (' '.join(self.launcher) if self.launcher else '-')
        return f'kind={self.kind} launcher={launcher} lane={self.lane} inside_session={self.inside_session}'


def _base(comm: str) -> str:
    return os.path.basename(comm).lstrip('-')


def _is_claude(p: Proc) -> bool:
    b = _base(p['comm'])
    if b == 'claude':
        return True
    return b == 'node' and any(a.endswith('/claude') or 'claude-code' in a for a in p['args'][1:])


def _is_direct(p: Proc) -> bool:
    return _base(p['comm']) in SHELLS or '.app/Contents/MacOS/' in p['comm']


def lane_of(env: dict[str, str]) -> str:
    """The route as a host name for verdict lines (never a credential)."""
    if env.get('ANTHROPIC_BASE_URL'):
        return urlparse(env['ANTHROPIC_BASE_URL']).netloc or 'custom'
    if env.get('CLAUDE_CODE_USE_VERTEX') or env.get('CLAUDE_CODE_USE_BEDROCK') or env.get('CLAUDE_CODE_USE_FOUNDRY'):
        return 'cloud-provider'
    return 'anthropic-default'


def launcher_words(args: list[str]) -> list[str] | None:
    """Leading words up to the first flag; None when any kept word is not plainly safe."""
    words: list[str] = []
    for a in args:
        if a.startswith('-'):
            break
        if not SAFE_WORD.match(a) or KEY_SHAPED.search(a):
            return None
        words.append(a)
    return words or None


def classify(ancestry: list[Proc], env: dict[str, str], logged_in_clean: bool | None) -> Route:
    route_env = {k: v for k, v in env.items() if CREDENTIAL_VARS.match(k)}
    has_creds = any(route_env.get(k) for k in HAS_CREDENTIAL)
    lane = lane_of(route_env)
    idx = next((i for i, p in enumerate(ancestry) if _is_claude(p)), None)
    parent = None
    if idx is not None:
        parent = next((p for p in ancestry[idx + 1:] if _base(p['comm']) not in TRANSPARENT), None)
    if parent is not None and not _is_direct(parent):
        words = launcher_words(parent['args'])
        return Route('wrapper', words, _base(parent['comm']), words is None, lane, True)
    if has_creds:
        kind = 'env'
    elif logged_in_clean:
        kind = 'login'
    else:
        kind = 'none'
    return Route(kind, None, None, False, lane, idx is not None)


def _ps(pid: int, *fields: str) -> str:
    # One -o per field, each with its own '=': BSD ps drops the header only for the field the
    # '=' is attached to, so '-o ppid,comm=' still prints a PPID header line (2026-11-26).
    cmd = ['ps'] + [x for f in fields for x in ('-o', f'{f}=')] + ['-p', str(pid)]
    out = subprocess.run(cmd, capture_output=True, text=True, check=False, env={**os.environ, 'LC_ALL': 'C'})
    return out.stdout.strip()


def collect_ancestry(start: int | None = None, limit: int = 30) -> list[Proc]:
    """This process's ancestors, parent first. argv is read only for the process directly
    above the first claude (the wrapper candidate) and is never printed."""
    chain: list[Proc] = []
    pid = start if start is not None else os.getppid()
    seen_claude = False
    wrapper_read = False    # argv is read for transparent procs + ONE candidate above claude
    for _ in range(limit):
        if pid <= 1:
            break
        row = _ps(pid, 'ppid', 'comm')
        if not row:
            break
        ppid_s, _, comm = row.partition(' ')
        comm = comm.strip()
        if not ppid_s.isdigit() or not comm:
            break
        args: list[str] = [comm]
        if (seen_claude and not wrapper_read) or (not seen_claude and _base(comm) == 'node'):
            args = _ps(pid, 'args').split()
            if seen_claude and _base(comm) not in TRANSPARENT:
                wrapper_read = True
        p: Proc = {'pid': pid, 'comm': comm, 'args': args}
        if not seen_claude and _is_claude(p):
            seen_claude = True
        chain.append(p)
        try:
            pid = int(ppid_s)
        except ValueError:
            break
    return chain


def probe_login_clean() -> bool | None:
    """Would a plain `claude` in a fresh window be logged in? Probed with a CLEAN env."""
    env = {'HOME': os.environ.get('HOME', ''), 'PATH': os.environ.get('PATH', '/usr/bin:/bin')}
    try:
        out = subprocess.run(['claude', 'auth', 'status', '--json'], env=env, capture_output=True,
                             text=True, timeout=20, check=False)
        return bool(json.loads(out.stdout).get('loggedIn'))
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def detect() -> Route:
    return classify(collect_ancestry(), dict(os.environ), probe_login_clean())


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__)
        return 0
    if argv[0] == '--classify' and len(argv) == 2:
        try:
            with open(argv[1]) as fh:
                fx = json.load(fh)
        except (OSError, ValueError) as err:
            print(f'claude_launch_route: --classify {argv[1]!r}: {err}', file=sys.stderr)
            return 2
        print(classify(fx['ancestry'], fx.get('env', {}), fx.get('logged_in_clean')).line())
        return 0
    if argv == ['--detect']:
        print(detect().line())
        return 0
    print(f'claude_launch_route: unknown argument(s): {" ".join(argv)} (see --help)', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
