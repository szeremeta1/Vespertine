#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Rebuilds the website's screenshot JPEGs from docs/screenshots (2400×1500 PNGs):
#   site/assets/<shot>.jpg           2000×1250, the page and press-kit images
#   site/assets/<shot>-detail.jpg    the inspector side, cut 1:1 (the fake-hi-res one from the Album column on)
#   site/assets/press/shot-<shot>.jpg  720×450 press-kit thumbnails
# Usage: scripts/make-site-images.sh [shot…]   (default: every shot the site uses). Needs ffmpeg.
set -euo pipefail
root=${0:A:h:h}
shots=$root/docs/screenshots
site=$root/site/assets

jpeg() { ffmpeg -loglevel error -y -i "$1" -vf "$2" -q:v 4 "$3"; }   # q 4: the site's JPEG quality

full=(genres spatial-audio-airpods-max bit-perfect-fiio-24-96)
typeset -A detail=(
  [smart-playlist]="crop=1300:1100:1100:110"
  [dsd-native-dop]="crop=1300:1100:1100:110"
  [spatial-audio-airpods-max]="crop=1260:1140:1140:160"
  [fake-hi-res-detection]="crop=1333:1128:1067:147,scale=1300:1100:flags=lanczos"
)
thumbs=(bit-perfect-fiio-24-96 dsd-native-dop fake-hi-res-detection genres multichannel-albums search smart-playlist
        spatial-audio-airpods-max stereo-and-surround-versions)

want=(${@:-$full $thumbs ${(k)detail}})
for s in ${(u)want}; do
  [[ -e $shots/$s.png ]] || { print -u2 "no docs/screenshots/$s.png"; continue; }
  (( ${full[(Ie)$s]} )) && jpeg "$shots/$s.png" "scale=2000:1250:flags=lanczos" "$site/$s.jpg"
  [[ -n ${detail[$s]:-} ]] && jpeg "$shots/$s.png" "${detail[$s]}" "$site/$s-detail.jpg"
  (( ${thumbs[(Ie)$s]} )) && jpeg "$shots/$s.png" "scale=720:450:flags=lanczos" "$site/press/shot-$s.jpg"
  print "$s"
done
