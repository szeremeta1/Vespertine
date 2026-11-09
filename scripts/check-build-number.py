#!/usr/bin/env python3
# Vespertine: refuses a release whose build number (CFBundleVersion) is not higher than every build already out.
#
#   git ls-remote origin 'refs/heads/chore/build-*' | scripts/check-build-number.py <build> [appcast.xml]
#
# scripts/publish.sh runs it before it tags, pushes or creates anything. Sparkle compares build numbers, so a release
# whose build is not above the newest one a Mac can already have would never be offered as an update. The builds it
# compares with are the ones named by the release-candidate branches on the remote (chore/build-<n>, read from
# `git ls-remote` on standard input) and the highest sparkle:version in the appcast the release carries forward.
# Exit 0 when the build is higher than all of them, 1 with a message when it is not, 2 on bad input.
# SPDX-License-Identifier: GPL-3.0-or-later
import re
import sys

BRANCH = re.compile(r"refs/heads/chore/build-(\d+)\s*$")
VERSION = re.compile(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>")


def highest_branch_build(ls_remote):
    builds = [int(m.group(1)) for line in ls_remote.splitlines() if (m := BRANCH.search(line))]
    return max(builds, default=None)


def highest_appcast_build(appcast_text):
    builds = [int(v) for v in VERSION.findall(appcast_text)]
    return max(builds, default=None)


def check(build, ls_remote, appcast_text):
    """Returns None when `build` is higher than every build found, else the message that refuses it."""
    found = {"a chore/build-<n> branch on origin": highest_branch_build(ls_remote),
             "the appcast": highest_appcast_build(appcast_text or "")}
    for where, other in found.items():
        if other is not None and build <= other:
            return (f"Build {build} is not higher than build {other} in {where}. Sparkle compares build numbers, "
                    f"so this release would not be offered as an update. Raise CURRENT_PROJECT_VERSION in project.yml "
                    f"above {max(o for o in found.values() if o is not None)} and build again.")
    return None


def main():
    if len(sys.argv) not in (2, 3) or not sys.argv[1].isdigit():
        print("usage: git ls-remote origin 'refs/heads/chore/build-*' | check-build-number.py <build> [appcast.xml]",
              file=sys.stderr)
        return 2
    appcast = ""
    if len(sys.argv) == 3:
        try:
            appcast = open(sys.argv[2], encoding="utf-8").read()
        except FileNotFoundError:
            pass
    message = check(int(sys.argv[1]), sys.stdin.read(), appcast)
    if message:
        print(message, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
