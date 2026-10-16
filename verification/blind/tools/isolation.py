#!/usr/bin/env python3
"""Isolation check for a blind role: every tool call the run made (from the runner's command log, JSON lines with
`t`, `cwd` and `cmd`) must stay inside its room. Flags absolute paths outside the room, `..`, `~`, $HOME, network and git commands.

Usage: python3 -I tools/isolation.py <room_dir> <cmdlog.jsonl> [...]  -> prints a report; exit 1 if anything flagged
"""
import json
import re
import sys
from pathlib import Path

# shell commands that reach the network, git or other apps, at a command position
NET = re.compile(r"(?:^|[;&|]\s*|\n\s*|\bthen\s+|\bdo\s+)(curl|wget|git|gh|ssh|scp|nc|pip3?|uv|brew|open|osascript)\b")
# absolute paths into the rest of the machine
ABS = re.compile(r"(?<![\w.])((?:/Users|/Volumes|/private/var|/opt|/etc|/System|/Library|/Applications|/var)(?:/[^\s'\"`;|&)]*)?)")
ALLOWED_ABS = ("/dev/null", "/tmp/", "/usr/bin/", "/bin/", "/private/tmp/")


def main(argv):
    room = Path(argv[0]).resolve()
    logs = argv[1:]
    calls, flags = 0, []
    for lf in logs:
        for line in open(lf):
            d = json.loads(line)
            if Path(d.get("cwd") or "/").resolve() != room:
                continue
            calls += 1
            cmd = d["cmd"]
            why = []
            for p in ABS.findall(cmd):
                if not (p.startswith(str(room)) or p.startswith(ALLOWED_ABS)):
                    why.append(f"path outside room: {p}")
            if re.search(r"(^|[\s/'\"])\.\.(/|\s|$)", cmd):
                why.append("parent directory (..)")
            if "~" in cmd or "$HOME" in cmd:
                why.append("home directory")
            m = NET.search(cmd)
            if m and not cmd.startswith(("Read ", "Grep ", "Glob ", "Write ", "Edit ")):
                why.append(f"command {m.group(1)!r}")
            if why:
                flags.append((d["t"], cmd[:200].replace("\n", " ").rstrip(), why))
    print(f"{room.name}: {calls} tool calls logged with cwd = room; {len(flags)} flagged")
    for t, c, w in flags:
        print(f"  {t}  {c}\n      -> {'; '.join(w)}")
    return 1 if flags or calls == 0 else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
