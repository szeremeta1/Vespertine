#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Rebuilds the website's self-hosted font subsets in src/assets/fonts/.
# Inputs: the Fontsource "latin" variable WOFF2 files (SIL OFL 1.1), version 5.3.0:
#   npm pack @fontsource-variable/newsreader@5.3.0 @fontsource-variable/inter@5.3.0 @fontsource-variable/jetbrains-mono@5.3.0
#   (then untar each into <dir>/fontsource-variable-<name>-5.3.0/)
# Needs fonttools + brotli (pip install fonttools brotli).
# Usage: scripts/subset-fonts.sh <dir-with-unpacked-packages> <out-dir>
set -eu
IN=$1; OUT=$2
# ASCII, accented Latin letters (names such as d'Este, Bokmål), the punctuation the copy uses, footnote superscripts,
# arrows, minus and ≥. Anything else falls back to the system font.
U="U+0020-007E,U+00A0,U+00A9,U+00AE,U+00B0,U+00B7,U+00B9,U+00B2-00B3,U+00C0-00FF,U+2013,U+2018-201D,U+2026,U+2070-2079,U+2122,U+2190-2193,U+2197,U+2212,U+2264-2265"
UI="U+0020-007E,U+00A0,U+00E9,U+2019"   # the italic is display-only (the brass phrases)
one() { # src axis-limits unicodes features out
  fonttools varLib.instancer "$1" $2 -o "$OUT/.tmp.ttf" -q
  pyftsubset "$OUT/.tmp.ttf" --unicodes="$3" --layout-features="$4" --flavor=woff2 \
    --no-hinting --desubroutinize --name-IDs='*' --name-languages='*' --output-file="$OUT/$5"
  rm -f "$OUT/.tmp.ttf"
}
N=$IN/fontsource-variable-newsreader-5.3.0/package/files
one "$N/newsreader-latin-opsz-normal.woff2" "wght=300:400 opsz=18:72" "$U" "kern,liga,clig,calt,lnum,pnum,tnum,case" newsreader-roman.woff2
one "$N/newsreader-latin-opsz-italic.woff2" "wght=300 opsz=24:72" "$UI" "kern,liga,clig,calt,lnum,pnum" newsreader-italic.woff2
one "$IN/fontsource-variable-inter-5.3.0/package/files/inter-latin-wght-normal.woff2" "wght=400:600" "$U" "kern,liga,calt,ss01,cv11,tnum,case,ccmp,locl,mark,mkmk" inter.woff2
one "$IN/fontsource-variable-jetbrains-mono-5.3.0/package/files/jetbrains-mono-latin-wght-normal.woff2" "wght=400:500" "$U" "kern,calt,ccmp,locl,mark,mkmk" jetbrains-mono.woff2
ls -l "$OUT"/*.woff2
