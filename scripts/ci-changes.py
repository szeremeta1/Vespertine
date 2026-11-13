#!/usr/bin/env python3
"""Prints which macOS CI jobs a change needs, as GitHub Actions outputs (packages=true, app=false, ...).

    scripts/ci-changes.py [changed file ...]        (default: the files `git diff --name-only HEAD^1 HEAD` lists)

macOS runners are the scarce ones (an account runs only a few at a time), so a job is skipped only when every changed
file is one it provably doesn't read. Anything this script doesn't know about, an empty or unreadable diff, and every
event but a pull request or a push to main run every job. A skipped job reports success, so its required check passes.

App code is the one thing that must never be skipped: any change to it runs BOTH "App (macOS)" and "Engine (macOS)"
(the app links the kit, and a kit change can break the app's tests and the reverse), whatever else the job-by-job rules
below would say. scripts/test-ci-changes.py pins that, and CI runs it on every change.
"""
import os, subprocess, sys

# Never read by any macOS job: the website, docs, root Markdown (except the notices the app ships), issue templates.
DOCS = ("site/", "docs/", ".github/ISSUE_TEMPLATE/", ".github/workflows/pages.yml", "scripts/brand/")
SHIPPED_MARKDOWN = {"THIRD-PARTY-NOTICES.md"}

# App code: a change to any of these runs the App and the Engine macOS jobs, always. Directories and files by name...
APP_CODE_DIRS = ("App/", "Packages/", "Driver/", "Helper/", "RemoteApp/")
APP_CODE_FILES = {"project.yml", "Package.swift", "Package.resolved", "LICENSE", ".github/workflows/ci.yml",
                  "scripts/ci-changes.py", "scripts/test-ci-changes.py", "scripts/generate-project.sh", "scripts/check-lockfiles.py"}
# ...and, as a net for a directory that doesn't exist yet, by extension anywhere outside the DOCS above and these, which
# have rules of their own: verification/ (its harness has a macOS job), tests/ (C audits, the Engine job only) and
# scripts/ (tools and release scripts, listed by name above when the app job reads them).
NET_EXCLUDED = ("verification/", "tests/", "scripts/")
APP_CODE_SUFFIXES = (".swift", ".c", ".h", ".m", ".mm", ".xcstrings", ".plist", ".entitlements", ".xcconfig", ".xcprivacy")

# Per job, what it doesn't read besides DOCS and (for the first two) besides app code, which always runs both.
IRRELEVANT = {
    # VespertineKit and VespertineAnalysis tests, the real-time C (tests/), and the release scripts' parse (scripts/).
    "packages": ("verification/",),
    # The app links VespertineKit, so Packages/ counts; scripts/ holds generate-project.sh and check-lockfiles.py.
    "app": ("verification/", "tests/"),
    # The harness builds against Packages/ and reads verification/'s fixtures and requirements, not its Markdown or the
    # studio suite (verification/studio/, tested on Linux).
    "verification": ("App/", "project.yml", "tests/", "scripts/", "RemoteApp/", "verification/*.md", "verification/hardware/*.md",
                     "verification/studio/"),
}


def matches(path, rule):
    if rule.endswith("/*.md"):
        folder = rule[: -len("*.md")]
        return path.startswith(folder) and "/" not in path[len(folder):] and path.endswith(".md")
    return path.startswith(rule) if rule.endswith("/") else path == rule


def is_docs(path):
    if "/" not in path and path.endswith(".md"):
        return path not in SHIPPED_MARKDOWN
    return any(matches(path, rule) for rule in DOCS)


def is_app_code(path):
    if is_docs(path):
        return False
    if path in APP_CODE_FILES or any(path.startswith(d) for d in APP_CODE_DIRS):
        return True
    if path.startswith(NET_EXCLUDED):
        return False
    name = path.rsplit("/", 1)[-1]
    return name in ("Package.swift", "Package.resolved") or name.endswith(APP_CODE_SUFFIXES)


def needed(files):
    if not files:
        return {job: True for job in IRRELEVANT}
    result = {job: any(not is_docs(f) and not any(matches(f, r) for r in rules) for f in files)
              for job, rules in IRRELEVANT.items()}
    if any(is_app_code(f) for f in files):
        result["packages"] = result["app"] = True
    return result


def main():
    if len(sys.argv) > 1:
        files = sys.argv[1:]
    elif os.environ.get("GITHUB_EVENT_NAME") in ("pull_request", "push"):
        # A pull request is checked out as its test merge into main, and main only takes squash merges, so the first
        # parent is the base either way.
        diff = subprocess.run(["git", "diff", "-z", "--name-only", "HEAD^1", "HEAD"], capture_output=True, text=True)
        if diff.returncode != 0:
            print(f"git diff failed ({diff.stderr.strip()}): running every job", file=sys.stderr)
        files = [f for f in diff.stdout.split("\0") if f] if diff.returncode == 0 else []
        for f in files:
            print(f, file=sys.stderr)
    else:
        files = []
    for job, need in needed(files).items():
        print(f"{job}={'true' if need else 'false'}")


if __name__ == "__main__":
    main()
