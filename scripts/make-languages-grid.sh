#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Composites the languages shots into one grid: scripts/make-languages-grid.sh <out.png> <languages-xx.png>…
set -euo pipefail
root=${0:A:h:h}
bin=$(mktemp -d)/languages
swiftc -O "$root/scripts/brand/BrandKit.swift" "$root/scripts/brand/languages/main.swift" -o "$bin"
"$bin" "$@"
