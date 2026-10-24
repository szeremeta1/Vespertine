#!/bin/zsh
# Play one channel-ID WAV through Vespertine (the installed app, isolated data dir) into a loopback device, capture the
# device, trim, and run verify_chid.py on the REAL capture. Test tooling only; touches no app code or settings.
#
#   verification/studio/chid-capture.sh "<layout folder name>" [DEVICE_UID] [DEVICE_NAME_FOR_CAPTURE]
#   e.g. chid-capture.sh "01 2.0 stereo"                                  (defaults: VespertineLoopback_UID / "Vespertine Loopback")
#        chid-capture.sh "09 5.1 side" BlackHole16ch_UID "BlackHole 16ch"  (needs a loopback with >= 6 channels)
# Environment: STUDIO_LIBRARY (the studio library, or the pack folder itself), STUDIO_APP (default /Applications/Vespertine.app),
# STUDIO_DATA (isolated data dir, default ~/Library/Application Support/Vespertine-SH), STUDIO_RESULTS, STUDIO_PYTHON.
# Results: <results>/chid-<timestamp>/ (run.log, app.log, capture-raw.wav, capture.wav); studio-suite.sh --captures
# re-verifies them into its report. Exit 0 = PASS, 1 = routing FAIL, 2/3 = setup or silent capture, 4 = SKIP (too few channels).
#
# Why it is built this way (measured 2026-10-20):
#  * Capture must run in a process that holds Microphone permission. Over SSH, even the built-in mic returns exact
#    digital silence. Terminal.app has the grant, so this script re-launches itself inside Terminal.app and waits.
#  * Vespertine must NOT hold the device exclusively (hog mode blocks outside capture): -exclusiveMode NO.
#  * -systemOutputFollowsPlayback NO / -deviceOnQuit leave: the Mac's system output is not moved.
#  * All overrides are launch arguments (argument domain), never persisted; the real Vespertine settings are untouched.
#  * The loopback must have at least as many channels as the layout (Vespertine Loopback has 2).
set -u
HERE="${0:A:h}"
RESULTS="${STUDIO_RESULTS:-$HERE/results}"
if [[ "${CHID_IN_TERMINAL:-}" != "1" ]]; then
  OUTDIR="$RESULTS/chid-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUTDIR"
  rm -f "$OUTDIR/done"
  cat > "$OUTDIR/run.command" <<EOT
#!/bin/zsh
CHID_IN_TERMINAL=1 CHID_OUT="$OUTDIR" STUDIO_LIBRARY=${(q)${STUDIO_LIBRARY:-}} STUDIO_APP=${(q)${STUDIO_APP:-}} STUDIO_DATA=${(q)${STUDIO_DATA:-}} STUDIO_PYTHON=${(q)${STUDIO_PYTHON:-}} "$HERE/chid-capture.sh" ${(q)@} > "$OUTDIR/run.log" 2>&1
touch "$OUTDIR/done"
exit
EOT
  chmod +x "$OUTDIR/run.command"
  open -g -a Terminal "$OUTDIR/run.command"
  for i in {1..240}; do [[ -f "$OUTDIR/done" ]] && break; sleep 1; done
  cat "$OUTDIR/run.log"; echo "results: $OUTDIR"
  grep -q "^RESULT PASS" "$OUTDIR/run.log"; exit $?
fi

export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
LIB="${STUDIO_LIBRARY:-$HOME/Music/Vespertine-SH Studio Library}"
if [[ -f "$LIB/SHA256SUMS.txt" ]]; then PACK="$LIB"; else PACK="$LIB/Vespertine Surround Test Pack (2026-10-15)"; fi
TOOLS="$PACK/10 Tools (for Claude)"
PY="${STUDIO_PYTHON:-python3}"
APP="${STUDIO_APP:-/Applications/Vespertine.app}"
DATA="${STUDIO_DATA:-$HOME/Library/Application Support/Vespertine-SH}"
LAYOUT="$1"; UID_="${2:-VespertineLoopback_UID}"; CAPNAME="${3:-Vespertine Loopback}"
OUT="$CHID_OUT"
DIR="$PACK/01 Layouts/$LAYOUT"
WAV=("$DIR"/*"1 channel ID.wav"(N))
[[ -f "${WAV[1]}" ]] || { echo "no 1-channel-ID WAV in $DIR"; echo "RESULT FAIL (setup)"; exit 2; }
WAV="${WAV[1]}"; BASE="${${WAV:t}%.wav}"
# Layout folder -> segments name (the same table as evidence.py: "09 5.1 side" is 5.1side, not 5.1).
typeset -A KEYS
KEYS=(01 2.0 02 2.1 03 3.0 04 quad 05 lcrs 06 5.0 07 5.0side 08 5.1 09 5.1side 10 6.1 11 7.1 12 7.1wide 13 7.1wideside
      14 8.1 15 5.1.2 16 5.1.4 17 7.1.2 18 7.1.4 19 9.1.6 20 22.2)
LNAME="${KEYS[${LAYOUT[1,2]}]:-}"
SEG="$TOOLS/segments/${LNAME}-1_channel_ID-48000.json"
[[ -n $LNAME && -f "$SEG" ]] || { echo "no segments json for '$LAYOUT'"; echo "RESULT FAIL (setup)"; exit 2; }
echo "segments: ${SEG:t}"
NEED=$($PY -c "import json,sys; print(len(json.load(open(sys.argv[1]))[\"channels\"]))" "$SEG")
HAVE=$(system_profiler SPAudioDataType 2>/dev/null | awk -v n="$CAPNAME" "index(\$0, n\":\"){f=1} f&&/Input Channels/{print \$3; exit}")
echo "layout $LAYOUT needs $NEED channels; capture device \"$CAPNAME\" input channels: ${HAVE:-unknown}"
if [[ -z "$HAVE" || "$HAVE" -lt "$NEED" ]]; then
  echo "capture device has fewer channels than the layout: a routing capture is not possible with it."
  echo "RESULT SKIP (device too narrow, UNVERIFIED)"; exit 4
fi
# Never stop someone else's player: refuse while any Vespertine with this data dir is running.
if pgrep -f "VespertineDataDirectory $DATA" >/dev/null; then
  echo "Vespertine with the data dir $DATA is running: quit it from its menu first"; echo "RESULT FAIL (setup)"; exit 2
fi
[[ -x "$APP/Contents/MacOS/Vespertine" ]] || { echo "no app at $APP"; echo "RESULT FAIL (setup)"; exit 2; }
echo "app: $APP ($(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null))"
shasum -a 256 "$WAV" | sed 's/^/source sha256: /'
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WAV"); CAPSEC=$(printf "%.0f" $(( DUR + 22 )))
ffmpeg -nostdin -y -v error -f avfoundation -i ":$CAPNAME" -t $CAPSEC -ac $NEED -ar 48000 -c:a pcm_f32le "$OUT/capture-raw.wav" &
FF=$!
sleep 1
"$APP/Contents/MacOS/Vespertine" -VespertineDataDirectory "$DATA" -VespertineAddSource "$LIB" -skipNonMusic NO \
  -selectedDeviceUID "$UID_" -exclusiveMode NO -systemOutputFollowsPlayback NO -deviceOnQuit leave \
  -VespertinePlaySong "$BASE| | |$BASE.wav" > "$OUT/app.log" 2>&1 &
APPPID=$!
wait $FF
kill -TERM $APPPID 2>/dev/null; sleep 2
grep "\[qa\] play song" "$OUT/app.log"
$PY "$HERE/trim_capture.py" "$OUT/capture-raw.wav" "$OUT/capture.wav" || { echo "RESULT FAIL (silent capture)"; exit 3; }
shasum -a 256 "$OUT/capture-raw.wav" "$OUT/capture.wav" | sed 's/^/capture sha256: /'
OUTV=$($PY "$TOOLS/verify_chid.py" "$SEG" "$OUT/capture.wav" --verbose); RC=$?
echo "$OUTV"
[[ $RC -eq 0 ]] && echo "RESULT PASS" || echo "RESULT FAIL (routing)"
exit $RC
