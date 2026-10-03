#!/usr/bin/env python3
"""Fails when App/Package.resolved (the app's lockfile) and Packages/VespertineKit/Package.resolved pin a package
differently, or when the app's misses one of the kit's packages: the app would ship versions the kit wasn't tested with."""
import json, sys

def pins(path):
    return {p["identity"]: p["state"].get("revision") for p in json.load(open(path))["pins"]}

app, kit = pins("App/Package.resolved"), pins("Packages/VespertineKit/Package.resolved")
problems = [f"{name}: kit {rev}, app {app.get(name)}" for name, rev in sorted(kit.items()) if app.get(name) != rev]
if "sparkle" not in app:
    problems.append("sparkle: missing from App/Package.resolved")
for line in problems:
    print(line, file=sys.stderr)
sys.exit(1 if problems else 0)
