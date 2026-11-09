#!/usr/bin/env python3
# Vespertine: removes the <item> entries of old releases from a Sparkle appcast, in place.
#
#   scripts/prune-appcast.py <appcast.xml> <newest-version-to-remove>
#
# scripts/publish.sh runs it on the feed it carries forward from the Latest release, before generate_appcast, which
# signs the whole feed: nothing may edit the appcast after generate_appcast has written it. Every item whose
# sparkle:shortVersionString is at or below the given version is dropped (for example 0.8.0 drops 0.8.0 and 0.5.9
# but keeps 0.9.0). An item with no version it can read is kept. The rest of the file is left byte for byte as it was.
# Prints one line per removed item to stderr, and "kept" lines are not printed.
# SPDX-License-Identifier: GPL-3.0-or-later
import re
import sys

ITEM = re.compile(r"[ \t]*<item>.*?</item>[ \t]*\n?", re.DOTALL)
SHORT = re.compile(r"<sparkle:shortVersionString>\s*([^<\s]+)\s*</sparkle:shortVersionString>")


def parse(version):
    """The numeric parts of "0.8.0" as a tuple; None when it is not made of numbers and dots."""
    parts = version.split(".")
    if not all(p.isdigit() for p in parts):
        return None
    return tuple(int(p) for p in parts)


def at_or_below(version, limit):
    a, b = parse(version), parse(limit)
    if a is None or b is None:
        return False
    width = max(len(a), len(b))
    return a + (0,) * (width - len(a)) <= b + (0,) * (width - len(b))


def prune(text, limit):
    removed = []

    def drop(match):
        found = SHORT.search(match.group(0))
        if found and at_or_below(found.group(1), limit):
            removed.append(found.group(1))
            return ""
        return match.group(0)

    return ITEM.sub(drop, text), removed


def main():
    if len(sys.argv) != 3 or parse(sys.argv[2]) is None:
        print("usage: prune-appcast.py <appcast.xml> <newest-version-to-remove, e.g. 0.8.0>", file=sys.stderr)
        return 2
    path, limit = sys.argv[1], sys.argv[2]
    with open(path, encoding="utf-8") as f:
        text = f.read()
    pruned, removed = prune(text, limit)
    if removed:
        with open(path, "w", encoding="utf-8") as f:
            f.write(pruned)
    for version in removed:
        print(f"Removed {version} from the appcast.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
