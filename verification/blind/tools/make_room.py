#!/usr/bin/env python3
"""Build an isolated room for one blind role by copying ONLY the files its manifest names.

Usage: python3 -I tools/make_room.py <role> <rooms_dir> [--from <other_room>:<subdir> ...]
Prints the room's full file listing (minus .venv) and its SHA-256 manifest, written to <room>/MANIFEST.txt.
"""
import hashlib
import shutil
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
KIT, CORPUS = BASE / "kit", BASE / "corpus"
COMMON = [("kit/SCOPE.md", "SCOPE.md"), ("kit/RULINGS.md", "RULINGS.md"), ("kit/stub/vblind.py", "stub/vblind.py"),
          ("corpus/index.json", "corpus/index.json")]
HARNESS = [("kit/harness/conftest.py", "conftest.py"), ("kit/harness/citecheck.py", "citecheck.py"),
           ("kit/harness/pytest.ini", "pytest.ini")]
MANIFESTS = {"meter": COMMON, "tester": COMMON + HARNESS, "saboteur": COMMON, "auditor": COMMON + HARNESS,
             "meter-fix": COMMON + [("kit/excerpts/meter-fix.md", "AUDIT-EXCERPT.md")],
             "tester-fix": COMMON + HARNESS + [("kit/excerpts/tester-fix.md", "AUDIT-EXCERPT.md")],
             "auditor-r2": COMMON + HARNESS}


def main(argv):
    role, rooms = argv[0], Path(argv[1])
    extra = [a.split(":", 1) for a in argv[3::2]] if "--from" in argv else []
    room = rooms / role
    brief = role
    if room.exists():
        print(f"{room} exists; refusing to overwrite", file=sys.stderr)
        return 2
    room.mkdir(parents=True)
    files = list(MANIFESTS[role])
    files += [(f"corpus/{p.relative_to(CORPUS)}", f"corpus/{p.relative_to(CORPUS)}") for p in sorted((CORPUS / "md").glob("*.md"))]
    for src, dst in files:
        (room / dst).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(BASE / src, room / dst)
    for src_room, sub in extra:
        shutil.copytree(Path(src_room) / sub, room / sub, ignore=shutil.ignore_patterns("__pycache__", ".pytest_cache"))
    (room / "BRIEF.md").write_text((KIT / "briefs" / f"{role}.md").read_text())
    subprocess.run(["uv", "venv", "-q", str(room / ".venv")], check=True)
    subprocess.run(["uv", "pip", "install", "-q", "--python", str(room / ".venv/bin/python"), "pytest"], check=True)
    lines = []
    for p in sorted(room.rglob("*")):
        if p.is_file() and ".venv" not in p.parts:
            lines.append(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(room)}")
    (room / "MANIFEST.txt").write_text("\n".join(lines) + "\n")
    print(f"room {room}: {len(lines)} files (+ .venv)")
    print("\n".join("  " + ln.split("  ", 1)[1] for ln in lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
