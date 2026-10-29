#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Reshoots docs/screenshots, one scene at a time (see docs/press/shot-list.md).
# Usage: scripts/shoot.sh [scene…]   (default: every scene). Needs an unlocked screen and Screen Recording for the
# terminal. Uses the app at $VESPERTINE_APP (default /Applications/Vespertine.app).
#   VESPERTINE_DATA=<dir>          a copy of your library to shoot from (-VespertineDataDirectory); default: your real one
#   VESPERTINE_K11_UID, VESPERTINE_AIRPODS_UID
#                                  Core Audio UIDs of the two outputs. When the scene's one is set, the app is pointed at
#                                  it (exclusive access, launch arguments only, nothing saved); otherwise the script stops
#                                  and asks you to select the output, and the capture waits for Return.
#   VESPERTINE_EQ_FILE=<file>      the AutoEQ ParametricEQ.txt the equalizer scene imports
#   VESPERTINE_SACD_SONG="Title|Artist|DSD64|.iso"   the song the sacd-iso scene plays, from an SACD image
# The app is quit through Apple Events (by bundle ID), so it hands the DAC back; other copies of Vespertine are left alone.
set -euo pipefail
root=${0:A:h:h}
app=${VESPERTINE_APP:-/Applications/Vespertine.app}
bin="$app/Contents/MacOS/Vespertine"
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
out=${VESPERTINE_SHOTS:-$root/docs/screenshots}
log=$root/build/shoot
mkdir -p "$log" "$out"
common=(-ApplePersistenceIgnoreState YES -VespertineWindowSize 1440x900 -autoAnalyze NO -analyzeNetworkShares NO -systemOutputFollowsPlayback NO -watchFolders NO -VespertineVolumeRelay NO -eqAssignments '{}')   # no launch rescan, no volume relay, no saved EQ
[[ -n ${VESPERTINE_DATA:-} ]] && common+=(-VespertineDataDirectory "$VESPERTINE_DATA")

# scene → output (k11, k11-idle, airpods or any), settle seconds, window title to capture (none: the main window), launch arguments
typeset -A output settle title args
output[multichannel-albums]=k11-idle;              settle[multichannel-albums]=12
args[multichannel-albums]='-VespertineFormatFilter multichannel -VespertineShowInspector NO'
output[bit-perfect-fosi-zd3-24-96]=k11;           settle[bit-perfect-fosi-zd3-24-96]=10
args[bit-perfect-fosi-zd3-24-96]="-VespertinePlaySong \"jeux d'eaux à la Villa|Lazar Berman\" -VespertineInspectorTab now"
output[dsd-native-dop]=k11;                   settle[dsd-native-dop]=20
args[dsd-native-dop]='-VespertinePlaySong "Love for the Sake of Love|Claudja Barry|DSD" -VespertineInspectorTab now'
output[sacd-iso]=k11;                         settle[sacd-iso]=20
args[sacd-iso]="-VespertinePlaySong \"${VESPERTINE_SACD_SONG:-}\" -VespertineInspectorTab now"
output[stereo-and-surround-versions]=airpods; settle[stereo-and-surround-versions]=10
args[stereo-and-surround-versions]="-VespertinePlaySong \"Don't Look Back in Anger|Oasis|DSD64\" -VespertineInspectorTab now"
output[spatial-audio-airpods-max]=airpods;    settle[spatial-audio-airpods-max]=12
args[spatial-audio-airpods-max]='-VespertinePlaySong "Candle in the Wind|Elton John|5.1" -VespertineInspectorTab now -VespertineScrollInspector YES'
output[fake-hi-res-detection]=k11-idle;            settle[fake-hi-res-detection]=8
args[fake-hi-res-detection]='-VespertineSidebar songs -VespertineSelectSong "Velvet Hour" -VespertineInspectorTab analysis'
output[search]=k11-idle;                           settle[search]=8
args[search]='-VespertineSearch "Let It Be" -VespertineOpenAlbum "Let It Be [DTS 5.1 CD-DA]" -VespertineSelectTracks 6 -VespertineInspectorTab details'
output[genres]=k11-idle;                           settle[genres]=8
args[genres]='-VespertineSidebar genres -VespertineShowInspector NO'
output[smart-playlist]=airpods;               settle[smart-playlist]=8
args[smart-playlist]="-VespertineSidebar \"AirPods Max Bit-Perfect\" -VespertineFilter artist=Oasis -VespertinePlaySong \"Don't Look Back in Anger|Oasis|24/48\" -VespertineInspectorTab now"
output[mini-player]=airpods;                  settle[mini-player]=10; title[mini-player]="Mini"
args[mini-player]="-VespertinePlaySong \"Don't Look Back in Anger|Oasis|24/48\" -VespertineOpenMini YES"
# Silent: Settings › Playback with the remembered output, the fallback and Match 16-bit sources.
output[output-settings]=k11-idle;             settle[output-settings]=6; title[output-settings]="Playback"
args[output-settings]='-VespertineOpenSettings YES -matchSixteenBit YES -outputFallback bestAvailable'
# The equalizer window with a preset on the K11, and the signal path's equalizer step behind it.
output[equalizer]=k11;                        settle[equalizer]=20; title[equalizer]="@main+Equalizer"
args[equalizer]="-VespertineEQPreset \"${VESPERTINE_EQ_FILE:-}\" -VespertinePlaySong \"jeux d'eaux à la Villa|Lazar Berman\" -VespertineInspectorTab now -VespertineOpenWindow equalizer"
# Needs the "Vespertine Loopback" output installed.
output[loopback-test]=any;                    settle[loopback-test]=30
args[loopback-test]='-VespertineOpenSheet loopback-run'
# First-run setup, each on an empty library of its own.
output[setup-welcome]=any;                    settle[setup-welcome]=6
args[setup-welcome]='-VespertineSetup show -VespertineSetupStep welcome'
output[setup-output]=any;                     settle[setup-output]=6
args[setup-output]='-VespertineSetup show -VespertineSetupStep output'
# languages: the same silent window in six languages, then one grid (docs/screenshots/languages.png).
languages=(ja de uk ar pt-BR zh-Hans)
languages_args='-VespertineOpenAlbum "Années de pèlerinage" -VespertineSelectTracks 2 -VespertineInspectorTab details'

pid=
stop_app() {
  [[ -n $pid ]] || return 0
  osascript -e "tell application id \"$bundle\" to quit" >/dev/null 2>&1 || true
  for _ in {1..40}; do kill -0 $pid 2>/dev/null || break; sleep 0.25; done
  if kill -0 $pid 2>/dev/null; then print -u2 "app didn't quit; stopping it (check the DAC's format afterwards)"; kill $pid; fi
  pid=
}
trap stop_app EXIT

launch() {   # launch <log> <launch arguments, shell-quoted>
  local logfile=$1; shift
  if pgrep -f "^$bin" >/dev/null; then   # a copy left from an earlier run (only this app's path; others are left alone)
    pkill -TERM -f "^$bin"; sleep 2
  fi
  eval "exec \"\$bin\" \"\${common[@]}\" $*" > "$logfile" 2>&1 &
  pid=$!
  place &!   # once its window is up
}

place() {   # moves the app's windows onto the main (Retina) display, so captures are 2×; repeated, as windows appear late
  for _ in {1..20}; do
    sleep 0.5
    osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to repeat with w in windows
      if name of w is \"Equalizer\" then
        set position of w to {184, 150}
      else
        set position of w to {144, 80}
      end if
    end repeat" >/dev/null 2>&1 || true
  done
}

capture() {   # capture <png> [title]; title "@main+<title>": that window laid over the main window, where it sits
  if [[ ${2:-} == @main+* ]]; then
    local t=${2#@main+}
    swift "$root/scripts/capture-window.swift" $pid "$log/main.png"   # the largest: the main window
    swift "$root/scripts/capture-window.swift" $pid "$log/top.png" "$t"
    swift "$root/scripts/compose-windows.swift" "$1" "$log/main.png" "$log/top.png" 80 140   # {184, 150} on {144, 80}, at 2×
    sips -Z 2400 "$1" >/dev/null
    return
  fi
  swift "$root/scripts/capture-window.swift" $pid "$1" ${2:-}   # this copy's windows only
  [[ -n ${2:-} ]] || sips -Z 2400 "$1" >/dev/null   # 1440×900 pt at 2× → 2400×1500
}

device_args() {   # the launch arguments that point the app at a scene's output, when its UID is known
  case $1 in
    k11) [[ -n ${VESPERTINE_K11_UID:-} ]] && print -r -- "-selectedDeviceUID \"$VESPERTINE_K11_UID\" -exclusiveMode YES -integerMode YES -dopDeviceUIDs '(\"$VESPERTINE_K11_UID\")'" ;;
    k11-idle) [[ -n ${VESPERTINE_K11_UID:-} ]] && print -r -- "-selectedDeviceUID \"$VESPERTINE_K11_UID\" -exclusiveMode YES" ;;
    airpods) [[ -n ${VESPERTINE_AIRPODS_UID:-} ]] && print -r -- "-selectedDeviceUID \"$VESPERTINE_AIRPODS_UID\" -exclusiveMode YES" ;;
  esac
  return 0
}

scenes=(${@:-multichannel-albums bit-perfect-fosi-zd3-24-96 dsd-native-dop sacd-iso stereo-and-surround-versions spatial-audio-airpods-max fake-hi-res-detection search genres smart-playlist mini-player output-settings equalizer loopback-test setup-welcome setup-output languages})
for scene in $scenes; do
  print "== $scene"
  if [[ $scene == languages ]]; then
    shots=()
    for lang in $languages; do
      # A Mac set to a right-to-left language lays apps out right to left; -AppleLanguages alone doesn't, so say so.
      rtl=$([[ $lang == (ar|he|fa|ur) ]] && print -- "-AppleTextDirection YES -NSForceRightToLeftWritingDirection YES" || true)
      launch "$log/languages-$lang.log" "$(device_args k11-idle) -AppleLanguages '($lang)' $rtl $languages_args"
      sleep 10
      capture "$log/languages-$lang.png"
      stop_app; sleep 1
      shots+=("$log/languages-$lang.png")
    done
    "$root/scripts/make-languages-grid.sh" "$out/languages.png" $shots
    continue
  fi
  [[ -n ${args[$scene]:-} ]] || { print -u2 "unknown scene: $scene"; exit 2; }
  extra=$(device_args ${output[$scene]})
  [[ $scene == setup-* ]] && extra+=" -VespertineDataDirectory \"$(mktemp -d "$log/setup-library.XXXXXX")\""
  launch "$log/$scene.log" "$extra ${args[$scene]}"
  if [[ ${output[$scene]} != any && -z $(device_args ${output[$scene]}) ]]; then
    print "Select \"${output[$scene]}\" as the output in Vespertine (and check Audio MIDI Setup), then press Return."
    read -r
  fi
  sleep ${settle[$scene]}
  grep '\[qa\]' "$log/$scene.log" || true
  capture "$out/$scene.png" ${title[$scene]:-}
  stop_app; sleep 1
done
print "Shots in $out. Check each against docs/press/shot-list.md before committing."
