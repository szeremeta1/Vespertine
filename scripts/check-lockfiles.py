#!/usr/bin/env python3
"""Fails when App/Package.resolved (the app's lockfile) or verification/harness/Package.resolved (the lockfile of the
spec-traced checks) pins a package differently from Packages/VespertineKit/Package.resolved, or misses one of the kit's
packages: the app would ship, and the checks would test, versions the kit wasn't tested with."""
import json, sys

def pins(path):
    return {p["identity"]: p["state"].get("revision") for p in json.load(open(path))["pins"]}

kit = pins("Packages/VespertineKit/Package.resolved")
problems = []
for label, path in (("app", "App/Package.resolved"), ("harness", "verification/harness/Package.resolved")):
    other = pins(path)
    problems += [f"{name}: kit {rev}, {label} {other.get(name)}" for name, rev in sorted(kit.items()) if other.get(name) != rev]
    if label == "app" and "sparkle" not in other:
        problems.append("sparkle: missing from App/Package.resolved")
for line in problems:
    print(line, file=sys.stderr)
sys.exit(1 if problems else 0)
