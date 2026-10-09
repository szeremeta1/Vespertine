#!/usr/bin/env python3
#
# Vespertine verification: audits the clean-room agents' transcripts after a run.
# SPDX-License-Identifier: GPL-3.0-or-later
#
#   audit_runs.py <run-dir> <workspace-root> <name>=<transcript.jsonl> ...
#
# For every agent: writes its final report to <run-dir>/reports/<name>.md and a log of every tool call it made to
# <run-dir>/tool-calls/<name>.tsv, then writes <run-dir>/AUDIT.md. A tool call breaks isolation when it
#   - uses a tool other than Read, Write, Edit or Bash (or the hand-back that ends the run),
#   - reads, writes or edits a path outside the agent's workspace,
#   - runs Bash other than exactly `swiftbox <its workspace> "<command>"` (nothing before or after it).
# A command inside swiftbox can't reach anything but the workspace (a chroot that sees only it, at /work), so its
# text isn't searched; a command outside it is listed in full, with any path it names outside the workspace.
# The audit also lists which models served the agent and whether its own words or files mention the product.
# Transcripts themselves are not kept in the repository: they include the session's environment (see REPORT.md).

import json
import re
import shlex
import sys
from pathlib import Path

ALLOWED = {"Read", "Write", "Edit", "Bash", "SubagentHandback"}
PRODUCT = re.compile(r"vespertine", re.IGNORECASE)


def tool_calls(transcript: Path):
    for line in transcript.read_text(encoding="utf-8").splitlines():
        entry = json.loads(line)
        msg = entry.get("message")
        if entry.get("type") != "assistant" or not isinstance(msg, dict):
            continue
        for block in msg.get("content") or []:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                yield msg.get("model", "?"), block.get("name", "?"), block.get("input") or {}


def assistant_text(transcript: Path) -> str:
    parts = []
    for line in transcript.read_text(encoding="utf-8").splitlines():
        entry = json.loads(line)
        msg = entry.get("message")
        if entry.get("type") == "assistant" and isinstance(msg, dict):
            for block in msg.get("content") or []:
                if isinstance(block, dict) and block.get("type") == "text":
                    parts.append(block["text"])
                if isinstance(block, dict) and block.get("type") == "thinking":
                    parts.append(block.get("thinking", ""))
    return "\n".join(parts)


def inside(path: str, ws: Path) -> bool:
    try:
        return Path(path).resolve().is_relative_to(ws.resolve())
    except (OSError, ValueError):
        return False


def sandboxed(cmd: str, ws: Path) -> bool:
    """True when the whole command is `swiftbox <ws> "<one argument>"`, with no shell operator outside the quotes."""
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        tokens = list(lex)
    except ValueError:
        return False
    return len(tokens) == 3 and tokens[0] == "swiftbox" and tokens[1] == str(ws)


def check(name: str, ws: Path, transcript: Path):
    problems, rows, models, report = [], [], set(), ""
    for model, tool, args in tool_calls(transcript):
        models.add(model)
        if tool == "SubagentHandback":
            report = str(args.get("message", ""))
            rows.append((tool, ""))
            continue
        if tool == "Bash":
            cmd = str(args.get("command", ""))
            rows.append((tool, cmd.replace("\t", " ").replace("\n", "\\n")[:400]))
            if not sandboxed(cmd, ws):
                outside = sorted({p for p in re.findall(r"(?<![\w.])(/[\w./-]+)", cmd) if not inside(p, ws)})
                problems.append(f"Bash outside the sandbox (paths outside the workspace: "
                                f"{', '.join(outside) or 'none'}):\n\n  ```\n  " + cmd.replace("\n", "\n  ") + "\n  ```")
            continue
        path = str(args.get("file_path") or args.get("path") or args.get("notebook_path") or "")
        detail = path
        if tool == "Write":
            detail += f" ({len(str(args.get('content', '')))} chars)"
        rows.append((tool, detail))
        if tool not in ALLOWED:
            problems.append(f"tool {tool} used: {json.dumps(args)[:200]}")
        elif not inside(path, ws):
            problems.append(f"{tool} outside the workspace: `{path}`")
    mentions = len(PRODUCT.findall(assistant_text(transcript) + report))
    for f in ws.rglob("*.swift"):
        if ".build" not in f.parts and PRODUCT.search(f.read_text(encoding="utf-8", errors="replace")):
            problems.append(f"workspace file {f.relative_to(ws)} mentions the product")
    if mentions:
        problems.append(f"the agent's own words mention the product {mentions} time(s)")
    return problems, rows, sorted(models), report


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__ or "usage: audit_runs.py <run-dir> <workspace-root> <name>=<transcript.jsonl> ...")
        return 2
    run, root = Path(sys.argv[1]), Path(sys.argv[2])
    (run / "reports").mkdir(parents=True, exist_ok=True)
    (run / "tool-calls").mkdir(parents=True, exist_ok=True)
    lines = ["# Isolation audit", "",
             "Every tool call each clean-room agent made, checked against its brief's rules (see "
             "`tools/audit_runs.py`). The full call logs are in `tool-calls/`, the agents' final reports in `reports/`.",
             "", "| Agent | Model(s) | Tool calls | By tool | Isolation |", "|---|---|---|---|---|"]
    details = []
    clean = True
    for arg in sys.argv[3:]:
        name, transcript = arg.split("=", 1)
        problems, rows, models, report = check(name, root / name, Path(transcript))
        (run / "reports" / f"{name}.md").write_text(f"# {name}: final report\n\n{report.strip()}\n", encoding="utf-8")
        (run / "tool-calls" / f"{name}.tsv").write_text(
            "tool\targument\n" + "".join(f"{t}\t{d}\n" for t, d in rows), encoding="utf-8")
        counts = {}
        for t, _ in rows:
            counts[t] = counts.get(t, 0) + 1
        by_tool = ", ".join(f"{t} {n}" for t, n in sorted(counts.items()))
        verdict = "clean" if not problems else f"**{len(problems)} problem(s)**"
        clean &= not problems
        lines.append(f"| {name} | {', '.join(models)} | {len(rows)} | {by_tool} | {verdict} |")
        if problems:
            details.append(f"### {name}\n\n" + "\n".join(f"- {p}" for p in problems))
    lines += ["", *(details or ["No agent broke isolation."]), ""]
    (run / "AUDIT.md").write_text("\n".join(lines), encoding="utf-8")
    print("\n".join(lines))
    return 0 if clean else 1


if __name__ == "__main__":
    sys.exit(main())
