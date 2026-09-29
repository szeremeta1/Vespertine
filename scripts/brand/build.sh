#!/bin/zsh
# Builds docs/brand/ (logo set + brand guide) from scripts/brand/*.swift.
set -euo pipefail
cd "$(dirname $0)/../.."
bin=$(mktemp -d)/brand
swiftc -O scripts/brand/BrandKit.swift scripts/brand/main.swift -o "$bin"
"$bin"
swiftc -O scripts/brand/BrandKit.swift scripts/brand/keyart/main.swift -o "$bin-keyart"
"$bin-keyart"
