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
# swiftbox is a chroot that sees the Swift image and the workspace (at /work), but it is not airtight: it mounts /proc
# and /dev, and through /proc a process could reach the host's file system. So the text of every command run inside
# it is searched too, for /proc, /sys, devices other than the usual pseudo-devices, and mount or namespace tools. A
# command outside swiftbox is listed in full, with any path it names outside the workspace, and every problem call
# with what came back (refused, an error, or its output), so a reader can tell whether it did anything.
# The audit also lists which models served the agent and whether its own words or files mention the product.
# Transcripts themselves are not kept in the repository: they include the session's environment (see REPORT.md).

import json
import re
import shlex
import sys
from pathlib import Path

ALLOWED = {"Read", "Write", "Edit", "Bash", "SubagentHandback"}
PRODUCT = re.compile(r"vespertine", re.IGNORECASE)
# Ways out of the chroot, or onto the host's devices: what a command run inside swiftbox must not mention.
ESCAPES = re.compile(r"/proc\b|/sys\b|/dev/(?!null\b|zero\b|u?random\b|std(in|out|err)\b|fd/)|"
                     r"\b(nsenter|chroot|unshare|mount|umount|pivot_root)\b|/srv\b|/home\b|/root\b|/opt\b")


def tool_calls(transcript: Path):
    for line in transcript.read_text(encoding="utf-8").splitlines():
        entry = json.loads(line)
        msg = entry.get("message")
        if entry.get("type") != "assistant" or not isinstance(msg, dict):
            continue
        for block in msg.get("content") or []:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                yield block.get("id"), msg.get("model", "?"), block.get("name", "?"), block.get("input") or {}


def tool_results(transcript: Path) -> dict:
    """tool_use id -> what came back (text, cut short), so a problem call shows whether it was refused or ran."""
    out = {}
    for line in transcript.read_text(encoding="utf-8").splitlines():
        entry = json.loads(line)
        msg = entry.get("message")
        if entry.get("type") != "user" or not isinstance(msg, dict) or not isinstance(msg.get("content"), list):
            continue
        for block in msg["content"]:
            if isinstance(block, dict) and block.get("type") == "tool_result":
                content = block.get("content")
                if isinstance(content, list):
                    content = " ".join(str(c.get("text", "")) for c in content if isinstance(c, dict))
                text = " ".join(str(content or "").split())
                out[block.get("tool_use_id")] = ("error: " if block.get("is_error") else "") + (text[:300] or "(no output)")
    return out


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


def sandboxed_command(cmd: str) -> str:
    """The command a sandboxed call runs inside swiftbox (its third token)."""
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    return list(lex)[2]


def check(name: str, ws: Path, transcript: Path):
    problems, rows, models, reports = [], [], set(), []
    results = tool_results(transcript)
    for call_id, model, tool, args in tool_calls(transcript):
        came_back = f"\n\n  What came back: `{results.get(call_id, '(no result recorded)').replace('`', chr(39))}`"
        models.add(model)
        if tool == "SubagentHandback":
            reports.append(str(args.get("message", "")).strip())
            rows.append((tool, "(its final report, in reports/)"))
            continue
        if tool == "Bash":
            cmd = str(args.get("command", ""))
            rows.append((tool, cmd.replace("\t", " ").replace("\n", "\\n")[:400].rstrip()))
            if not sandboxed(cmd, ws):
                outside = sorted({p for p in re.findall(r"(?<![\w.])(/[\w./-]+)", cmd) if not inside(p, ws)})
                problems.append(f"Bash outside the sandbox (paths outside the workspace: "
                                f"{', '.join(outside) or 'none'}):\n\n  ```\n  " + cmd.replace("\n", "\n  ") + "\n  ```" + came_back)
            elif m := ESCAPES.search(sandboxed_command(cmd)):
                problems.append(f"command in the sandbox mentions `{m.group(0)}`:\n\n  ```\n  "
                                + cmd.replace("\n", "\n  ") + "\n  ```" + came_back)
            continue
        path = str(args.get("file_path") or args.get("path") or args.get("notebook_path") or "")
        detail = path
        if tool == "Write":
            detail += f" ({len(str(args.get('content', '')))} chars)"
        rows.append((tool, detail))
        if tool not in ALLOWED:
            problems.append(f"tool {tool} used: {json.dumps(args)[:200]}" + came_back)
        elif not inside(path, ws):
            problems.append(f"{tool} outside the workspace: `{path}`" + came_back)
    report = reports[0] if len(reports) == 1 else "\n\n".join(
        f"## Round {i}\n\n{r}" for i, r in enumerate(reports))
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
            details.append(f"### {name}\n\n" + "\n".join(f"- {p}" for p in problems) + "\n")
    lines += ["", *(details or ["No agent broke isolation."]), ""]
    (run / "AUDIT.md").write_text("\n".join(lines).rstrip("\n") + "\n", encoding="utf-8")
    print("\n".join(lines))
    return 0 if clean else 1


if __name__ == "__main__":
    sys.exit(main())
