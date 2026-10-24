#!/usr/bin/env python3
"""Prints which macOS CI jobs a change needs, as GitHub Actions outputs (packages=true, app=false, ...).

    scripts/ci-changes.py [changed file ...]        (default: the files `git diff --name-only HEAD^1 HEAD` lists)

macOS runners are the scarce ones (an account runs only a few at a time), so a job is skipped only when every changed
file is one it provably doesn't read. Anything this script doesn't know about, an empty or unreadable diff, and every
event but a pull request or a push to main run every job. A skipped job reports success, so its required check passes.
"""
import os, subprocess, sys

# Never read by any macOS job: the website, docs, root Markdown (except the notices the app ships), issue templates.
DOCS = ("site/", "docs/", ".github/ISSUE_TEMPLATE/", ".github/workflows/pages.yml", "scripts/brand/")
SHIPPED_MARKDOWN = {"THIRD-PARTY-NOTICES.md"}

# Per job, what it doesn't read besides DOCS.
IRRELEVANT = {
    # VespertineKit and VespertineAnalysis tests, the real-time C (tests/), and the release scripts' parse (scripts/).
    "packages": ("App/", "project.yml", "verification/"),
    # The app links VespertineKit, so Packages/ counts; scripts/ holds generate-project.sh and check-lockfiles.py.
    "app": ("verification/", "tests/"),
    # The harness builds against Packages/ and reads verification/'s fixtures and requirements, not its Markdown or the
    # studio suite (verification/studio/, tested on Linux).
    "verification": ("App/", "project.yml", "tests/", "scripts/", "verification/*.md", "verification/hardware/*.md",
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


def needed(files):
    if not files:
        return {job: True for job in IRRELEVANT}
    return {job: any(not is_docs(f) and not any(matches(f, r) for r in rules) for f in files)
            for job, rules in IRRELEVANT.items()}


def main():
    if len(sys.argv) > 1:
        files = sys.argv[1:]
    elif os.environ.get("GITHUB_EVENT_NAME") in ("pull_request", "push"):
        # A pull request is checked out as its test merge into main, and main only takes squash merges, so the first
        # parent is the base either way.
        diff = subprocess.run(["git", "diff", "-z", "--name-only", "HEAD^1", "HEAD"], capture_output=True, text=True)
        files = [f for f in diff.stdout.split("\0") if f] if diff.returncode == 0 else []
        for f in files:
            print(f, file=sys.stderr)
    else:
        files = []
    for job, need in needed(files).items():
        print(f"{job}={'true' if need else 'false'}")


if __name__ == "__main__":
    main()
