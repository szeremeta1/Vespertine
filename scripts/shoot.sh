#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Reshoots docs/screenshots on your own library, one scene at a time (see docs/press/shot-list.md).
# Usage: scripts/shoot.sh [scene…]   (default: every scene). Needs an unlocked screen and Screen Recording for the
# terminal. Uses the app at $VESPERTINE_APP (default /Applications/Vespertine.app) and your real library.
# Before a hardware scene it stops and says which output to select; the capture waits for Return.
set -euo pipefail
root=${0:A:h:h}
app=${VESPERTINE_APP:-/Applications/Vespertine.app}
bin="$app/Contents/MacOS/Vespertine"
out=${VESPERTINE_SHOTS:-$root/docs/screenshots}
log=$root/build/shoot
mkdir -p "$log"

# scene  output  settle-seconds  launch arguments…
typeset -A output settle args
output[multichannel-albums]=any;              settle[multichannel-albums]=12
args[multichannel-albums]='-VespertineFormatFilter multichannel -VespertineShowInspector NO'
output[bit-perfect-fiio-24-96]="FiiO K11";    settle[bit-perfect-fiio-24-96]=10
args[bit-perfect-fiio-24-96]="-VespertinePlaySong \"jeux d'eaux à la Villa|Lazar Berman\" -VespertineInspectorTab now"
output[dsd-native-dop]="FiiO K11";            settle[dsd-native-dop]=10
args[dsd-native-dop]='-VespertinePlaySong "Love for the Sake of Love|Claudja Barry|DSD" -VespertineInspectorTab now'
output[stereo-and-surround-versions]="AirPods Max";     settle[stereo-and-surround-versions]=10
args[stereo-and-surround-versions]="-VespertinePlaySong \"Don't Look Back in Anger|Oasis|DSD64\" -VespertineInspectorTab now"
output[spatial-audio-airpods-max]="AirPods Max"; settle[spatial-audio-airpods-max]=12
args[spatial-audio-airpods-max]='-VespertinePlaySong "Candle in the Wind|Elton John|5.1" -VespertineInspectorTab now'
output[fake-hi-res-detection]=any;            settle[fake-hi-res-detection]=8
args[fake-hi-res-detection]='-VespertineSidebar songs -VespertineSelectSong "Velvet Hour" -VespertineInspectorTab analysis'
output[search]=any;                           settle[search]=8
args[search]='-VespertineSearch "Let It Be" -VespertineOpenAlbum "Let It Be [DTS 5.1 CD-DA]" -VespertineSelectTracks 6 -VespertineInspectorTab details'
output[genres]=any;                           settle[genres]=8
args[genres]='-VespertineSidebar genres'
output[smart-playlist]="AirPods Max";                   settle[smart-playlist]=8
args[smart-playlist]="-VespertineSidebar \"AirPods Max Bit-Perfect\" -VespertineFilter artist=Oasis -VespertinePlaySong \"Don't Look Back in Anger|Oasis|24/48\" -VespertineInspectorTab now"
output[mini-player]="AirPods Max";            settle[mini-player]=10
args[mini-player]="-VespertinePlaySong \"Don't Look Back in Anger|Oasis|24/48\" -VespertineOpenMini YES"

scenes=(${@:-multichannel-albums bit-perfect-fiio-24-96 dsd-native-dop stereo-and-surround-versions spatial-audio-airpods-max fake-hi-res-detection search genres smart-playlist mini-player})
for scene in $scenes; do
  [[ -n ${args[$scene]:-} ]] || { print -u2 "unknown scene: $scene"; exit 2; }
  print "== $scene"
  pkill -x Vespertine 2>/dev/null || true
  sleep 1
  eval "\"$bin\" -ApplePersistenceIgnoreState YES -VespertineWindowSize 1440x900 -autoAnalyze NO ${args[$scene]}" > "$log/$scene.log" 2>&1 &
  if [[ ${output[$scene]} != any ]]; then
    print "Select \"${output[$scene]}\" as the output in Vespertine (and check Audio MIDI Setup), then press Return."
    read -r
  fi
  sleep ${settle[$scene]}
  grep '\[qa\]' "$log/$scene.log" || true
  title=$([[ $scene == mini-player ]] && print "Mini" || print "")
  swift "$root/scripts/capture-window.swift" Vespertine "$out/$scene.png" $title
  [[ $scene == mini-player ]] || sips -Z 2400 "$out/$scene.png" >/dev/null   # 1440×900 pt at 2× → 2400×1500
done
pkill -x Vespertine 2>/dev/null || true
print "Shots in $out. Check each against docs/press/shot-list.md before committing."
