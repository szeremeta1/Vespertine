#!/bin/zsh
# Vespertine studio suite: one command, adapts to the audio hardware attached right now, and writes an evidence report.
#
#   verification/studio/studio-suite.sh                  safe layer + evidence + whatever the detected hardware allows
#   ... --loopback        also run the silent software loopback bit-exact test (needs microphone permission once)
#   ... --matrix          also run the offline spatial matrix (every layout x codec; slow, needs FFmpeg)
#   ... --verify-library  check every pack file against SHA256SUMS.txt in the shell too (the evidence step hashes them anyway)
#   ... --skip-tests      skip the full `swift test` (the opt-in evidence tests still run)
#   ... --no-evidence     skip the evidence layer (per-file captures, routing checks, REPORT.md)
#   ... --no-render       skip the offline routing render (StudioRoutingTests)
#   ... --no-config       skip the per-file device configuration check (StudioDeviceConfigTests)
#   ... --signal-path     also play each file into the virtual device and compare the engine's live signal path with
#                         Core Audio (needs a process with Microphone permission when the device has inputs)
#   ... --device NAME     virtual output device for --signal-path and the configuration check (default: Vespertine Loopback)
#   ... --captures DIR... re-verify chid-capture.sh runs (folders with capture.wav and run.log); must be the last option
#   ... --help
# Environment: STUDIO_LIBRARY (the studio library, or the pack folder itself), STUDIO_RESULTS (where results/<ts>/ go),
# STUDIO_PYTHON (a python3 with numpy), STUDIO_TEST_TIMEOUT (seconds, default 5400), STUDIO_RELEASE_TAG (default: last tag).
#
# SAFETY RULE (hard): this script never plays a bitstream (AC-3, E-AC-3, TrueHD, DTS, IEC 61937) to any device, and
# plays nothing at all except into a virtual device (--loopback, --signal-path). The configuration check plays no audio.
# Bitstream sections only PRINT instructions, and only when STUDIO_ALLOW_BITSTREAM="<exact device name>" names a
# detected, real multichannel output. It never touches ~/Library/Application Support/Vespertine.
#
# Exit status: 0 = nothing failed (skips are fine), 1 = at least one FAIL, 2 = could not start.

emulate -L zsh
setopt pipefail

HERE=${0:A:h}
ROOT=${HERE:h:h}
KIT=$ROOT/Packages/VespertineKit
LIB=${STUDIO_LIBRARY:-"$HOME/Music/Vespertine-SH Studio Library"}
PACK_NAME="Vespertine Surround Test Pack (2026-10-15)"
if [[ -f $LIB/SHA256SUMS.txt ]]; then PACK=$LIB; else PACK="$LIB/$PACK_NAME"; fi
FMT="$LIB/Vespertine Format Tests"
ORIG_PACK="$HOME/Music/$PACK_NAME"
ORIG_FMT="$HOME/Music/Vespertine Format Tests"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
PY=${STUDIO_PYTHON:-python3}
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${STUDIO_RESULTS:-$HERE/results}/$STAMP
mkdir -p "$OUT" || { print -u2 "cannot create $OUT"; exit 2 }
ln -sfn "$OUT" "$(dirname $OUT)/latest"
EVIDENCE=$HERE/evidence.py

want_loopback=${STUDIO_LOOPBACK:-0}; want_matrix=${STUDIO_MATRIX:-0}; want_verify=0; skip_tests=0
want_evidence=1; want_render=1; want_config=1; want_signal=0; DEVICE="Vespertine Loopback"
typeset -a CAPTURES; CAPTURES=()
while (( $# )); do
  case $1 in
    --loopback) want_loopback=1 ;;
    --matrix) want_matrix=1 ;;
    --verify-library) want_verify=1 ;;
    --skip-tests) skip_tests=1 ;;
    --no-evidence) want_evidence=0 ;;
    --no-render) want_render=0 ;;
    --no-config) want_config=0 ;;
    --signal-path) want_signal=1 ;;
    --device) shift; DEVICE=$1 ;;
    --captures) shift; CAPTURES=("$@"); break ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 "unknown option $1 (try --help)"; exit 2 ;;
  esac
  shift
done

typeset -a R_NAME R_STATUS R_NOTE   # one row per check: PASS / FAIL / SKIP / INFO
print -r -- $'name\tstatus\tnote\tlog' > "$OUT/checks.tsv"
# rec NAME STATUS NOTE [LOG]: one check, on the console and in checks.tsv (the report reads it)
rec() {
  R_NAME+=("$1"); R_STATUS+=("$2"); R_NOTE+=("$3"); printf '  [%s] %s: %s\n' "$2" "$1" "$3"
  print -r -- "$1"$'\t'"$2"$'\t'"${3//$'\t'/ }"$'\t'"${4:-}" >> "$OUT/checks.tsv"
}
hdr() { printf '\n== %s ==\n' "$1" }
# bounded NAME SECONDS CMD...: run CMD with a time limit that stops only this command's own process group
bounded() {
  local secs=$1; shift
  if command -v timeout >/dev/null; then timeout --kill-after=60 "$secs" "$@"
  elif command -v gtimeout >/dev/null; then gtimeout --kill-after=60 "$secs" "$@"
  else "$@"; fi
}

[[ -d $KIT ]] || { print -u2 "Package not found at $KIT (run this from a Vespertine checkout)"; exit 2 }
command -v swift >/dev/null || { print -u2 "swift not found"; exit 2 }

# ---------------------------------------------------------------- 0. environment
hdr "0. Environment"
TAG=${STUDIO_RELEASE_TAG:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null)}
print "  checkout : $ROOT"
print "  branch   : $(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null) @ $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null) (last tag $TAG)"
print "  macOS    : $(sw_vers -productVersion) ($(uname -m))   swift: $(swift --version 2>&1 | head -1 | cut -c1-70)"
print "  library  : $LIB"
print "  logs     : $OUT"
dirty=$(git -C "$ROOT" status --porcelain 2>/dev/null | grep -v '^??' | wc -l | tr -d ' ')
[[ $dirty == 0 ]] && rec "checkout clean" PASS "no tracked changes" \
                  || rec "checkout clean" INFO "$dirty tracked file(s) modified"
# The code under test: everything that ships in the app must be the release's, byte for byte.
release_paths=(App Packages/VespertineAnalysis Packages/VespertineKit/Package.swift Packages/VespertineKit/Package.resolved
               Packages/VespertineKit/Sources/VespertineAudio Packages/VespertineKit/Sources/VespertineLibrary
               Packages/VespertineKit/Sources/CVespertineRT Packages/VespertineKit/Sources/CVespertineDTS
               Packages/VespertineKit/Sources/CVespertineGuard Packages/VespertineKit/Sources/CVespertineTags)
if [[ -n $TAG ]]; then
  git -C "$ROOT" diff --stat "$TAG" -- $release_paths > "$OUT/release-diff.txt" 2>&1
  [[ -s $OUT/release-diff.txt ]] && rec "release code" INFO "differs from $TAG (see release-diff.txt): results describe this checkout, not $TAG" "release-diff.txt" \
                                 || rec "release code" PASS "app, engine and library sources identical to $TAG (git diff empty)" "release-diff.txt"
fi
if command -v ffmpeg >/dev/null; then rec "ffmpeg" PASS "$(ffmpeg -version | head -1 | cut -c1-60)"; HAVE_FFMPEG=1
else rec "ffmpeg" SKIP "not on PATH (brew install ffmpeg): spatial matrix and verify_chid.py need it"; HAVE_FFMPEG=0; fi
if $PY -c 'import numpy' 2>/dev/null; then HAVE_NUMPY=1; rec "python numpy" PASS "$PY (verify_chid.py ok)"
else HAVE_NUMPY=0; rec "python numpy" SKIP "missing for $PY: python3 -m venv ~/.vsh-venv && ~/.vsh-venv/bin/pip install numpy, then STUDIO_PYTHON=~/.vsh-venv/bin/python3"; fi

# ---------------------------------------------------------------- 1. library
hdr "1. Studio library"
typeset -a UNVERIFIED_EXTRA; UNVERIFIED_EXTRA=()
if [[ ! -d $PACK ]]; then
  rec "library present" FAIL "missing $PACK"
else
  nfiles=$(find "$LIB" -type f ! -name '.DS_Store' | wc -l | tr -d ' ')
  nsums=$(wc -l < "$PACK/SHA256SUMS.txt" | tr -d ' ')
  rec "library present" PASS "$nfiles files under $LIB"
  if [[ -d $FMT ]]; then rec "format tests present" PASS "$(find "$FMT" -type f | wc -l | tr -d ' ') files"
  else rec "format tests present" INFO "no '${FMT:t}' folder here: those files are not covered by this run"
    UNVERIFIED_EXTRA+=("format-tests|The 'Vespertine Format Tests' files open and play|not present on this machine; not part of this run"); fi
  for pair in "$PACK|$ORIG_PACK" "$FMT|$ORIG_FMT"; do
    c=${pair%%|*}; o=${pair#*|}
    if [[ -d $o && -d $c && $o != $c ]]; then
      nc=$(find "$c" -type f | wc -l | tr -d ' '); no=$(find "$o" -type f | wc -l | tr -d ' ')
      [[ $nc == $no ]] && rec "full corpus: ${c:t}" PASS "$nc of $no files (nothing excluded)" || rec "full corpus: ${c:t}" FAIL "$nc files vs $no in the original"
    fi
  done
  if (( want_verify )); then
    print "  verifying $nsums checksums (SHA-256)..."
    (cd "$PACK" && shasum -a 256 -c SHA256SUMS.txt 2>&1 | grep -v ': OK$' ) > "$OUT/library-verify.log"
    [[ -s $OUT/library-verify.log ]] && rec "library checksums" FAIL "mismatches in $OUT/library-verify.log" "library-verify.log" \
                                     || rec "library checksums" PASS "all $nsums listed files match the pack's SHA256SUMS" "library-verify.log"
  fi
fi

# ---------------------------------------------------------------- 2. build + hardware detection
hdr "2. Build and hardware detection"
cd "$KIT" || exit 2
if swift build --product vespertine-probe > "$OUT/build.log" 2>&1; then
  rec "build vespertine-probe" PASS "builds" "build.log"
  PROBE=$(swift build --show-bin-path 2>/dev/null)/vespertine-probe
else
  rec "build vespertine-probe" FAIL "see $OUT/build.log" "build.log"; PROBE=""
fi

typeset -a D_NAME D_TRANSPORT D_MAXCH D_NONMIX
MULTI_HW=0; BITSTREAM_CAND=0; LOOPBACK_DEV=0; MULTI_NAMES=""; DEVICE_OK=0
if [[ -x $PROBE ]]; then
  "$PROBE" list > "$OUT/devices.txt" 2>&1
  name="" tr="" mx=0 nm=0
  flush() {
    [[ -n $name ]] || return
    D_NAME+=("$name"); D_TRANSPORT+=("$tr"); D_MAXCH+=("$mx"); D_NONMIX+=("$nm")
  }
  while IFS= read -r line; do
    if [[ $line == "■ "* ]]; then
      flush; name=${${line#■ }%%  \[*}; tr=""; mx=0; nm=0
    elif [[ $line == *"transport "* ]]; then
      tr=${${line#*transport }%% ·*}
    elif [[ $line == *"physical:"* ]]; then
      for c in ${(f)"$(print -r -- "$line" | grep -oE '[0-9]+ch' | tr -d ch)"}; do (( c > mx )) && mx=$c; done
      [[ $line == *"(non-mix)"* ]] && nm=1
    fi
  done < "$OUT/devices.txt"
  flush
  print "  output devices found: ${#D_NAME}"
  for i in {1..${#D_NAME}}; do
    kind="stereo/other"
    n=$D_NAME[$i]; t=$D_TRANSPORT[$i]; m=$D_MAXCH[$i]
    if [[ $t == Virtual || $t == Aggregate ]]; then kind="virtual (never counts as hardware)"
      [[ $n == "Vespertine Loopback" ]] && LOOPBACK_DEV=1
      [[ $n == $DEVICE && $t == Virtual ]] && DEVICE_OK=1
    elif [[ $t == Bluetooth || $t == AirPlay ]]; then kind="wireless (never a bitstream or multichannel target)"
    elif (( m > 2 )); then kind="MULTICHANNEL hardware (${m} ch)"; MULTI_HW=1; MULTI_NAMES+="$n; "
      [[ $t == HDMI || $t == DisplayPort || $t == USB || $t == Thunderbolt || $t == PCI || $t == FireWire ]] && BITSTREAM_CAND=1
    elif [[ $D_NONMIX[$i] == 1 && ( $t == HDMI || $t == DisplayPort ) ]]; then kind="digital output with non-mixable (passthrough) format"; BITSTREAM_CAND=1
    fi
    printf '    - %-34s %-10s max %2s ch   %s\n' "$n" "$t" "$m" "$kind"
  done
  (( ${#D_NAME} > 0 )) && rec "device detection" PASS "${#D_NAME} output device(s); details in devices.txt" "devices.txt" \
                       || rec "device detection" FAIL "probe listed no output devices ($OUT/devices.txt)" "devices.txt"
  rec "multichannel hardware" INFO "$( (( MULTI_HW )) && print "DETECTED: ${MULTI_NAMES%; }" || print "none (every real output is stereo or wireless)")"
  rec "bitstream-capable output" INFO "$( (( BITSTREAM_CAND )) && print "candidate present (still needs STUDIO_ALLOW_BITSTREAM, see section 7)" || print "none")"
  rec "Vespertine Loopback (virtual)" INFO "$( (( LOOPBACK_DEV )) && print installed || print "not installed")"
else
  rec "device detection" SKIP "probe unavailable (build failed)"
fi

# environment.json: what the report names as the setup
{
  print -r -- "{"
  print -r -- "  \"machine\": \"$(scutil --get LocalHostName 2>/dev/null || hostname -s)\","
  print -r -- "  \"model\": \"$(sysctl -n hw.model 2>/dev/null)\","
  print -r -- "  \"macos\": \"$(sw_vers -productVersion) ($(sw_vers -buildVersion))\","
  print -r -- "  \"arch\": \"$(uname -m)\","
  print -r -- "  \"swift\": \"$(swift --version 2>&1 | head -1 | sed 's/"/\\"/g')\","
  print -r -- "  \"commit\": \"$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)\","
  print -r -- "  \"branch\": \"$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)\","
  print -r -- "  \"version\": \"release code of $TAG$( [[ -s $OUT/release-diff.txt ]] && print ' WITH CHANGES (release-diff.txt)' )\","
  print -r -- "  \"date\": \"$(date '+%Y-%m-%d %H:%M %Z')\","
  print -r -- "  \"library\": \"${LIB//\"/\\\"}\","
  print -r -- "  \"signal_device\": \"${DEVICE//\"/\\\"}$( (( DEVICE_OK )) && print ' (virtual, 2 ch)' )\","
  print -r -- "  \"devices\": \"$(print -r -- ${(j:; :)D_NAME} | sed 's/"/\\"/g')\","
  print -r -- "  \"unverified\": ["
  sep=""
  for u in $UNVERIFIED_EXTRA; do
    parts=("${(@s:|:)u}")
    print -r -- "    $sep[\"$parts[1]\", \"${parts[2]//\"/\\\"}\", \"${parts[3]//\"/\\\"}\"]"; sep=","
  done
  print -r -- "  ]"
  print -r -- "}"
} > "$OUT/environment.json"
[[ $DEVICE_OK == 1 ]] && sed -i '' "s/ (virtual, 2 ch)/ (virtual, $(grep -A3 "^■ $DEVICE " "$OUT/devices.txt" | grep -oE '[0-9]+ch' | head -1))/" "$OUT/environment.json"

# ---------------------------------------------------------------- 3. safe layer
hdr "3. Safe layer: swift test (fixtures only, no hardware, no audio out)"
# Scrub every opt-in switch so a stray variable in this shell cannot enable a hardware test here.
typeset -a scrub; scrub=()
for v in ${(f)"$(env | grep -oE '^VESPERTINE_[A-Za-z0-9_]*')"}; do scrub+=(-u "$v"); done
(( ${#scrub} )) && print "  (ignoring inherited: ${scrub[*]})"
if (( skip_tests )); then
  rec "swift test" SKIP "--skip-tests"
else
  t0=$SECONDS
  env $scrub nice -n 5 zsh -c "$(typeset -f bounded); bounded ${STUDIO_TEST_TIMEOUT:-5400} swift test" > "$OUT/swift-test.log" 2>&1
  rc=$?
  summary=$(grep -E "Test run with|Executed [0-9]+ tests" "$OUT/swift-test.log" | tail -2 | tr '\n' ' ')
  took="$(( SECONDS - t0 )) s"
  if (( rc == 0 )); then rec "swift test" PASS "${summary:-exit 0} (${took})" "swift-test.log"
  elif (( rc == 124 || rc == 137 )); then rec "swift test" FAIL "did not finish within ${STUDIO_TEST_TIMEOUT:-5400} s (stopped); ${summary}see swift-test.log" "swift-test.log"
  else rec "swift test" FAIL "exit $rc after ${took}; ${summary}see swift-test.log ($(grep -cE '✘|error:' "$OUT/swift-test.log") error lines)" "swift-test.log"
    grep -E '✘|error:' "$OUT/swift-test.log" | head -8 | sed 's/^/      /'; fi
fi

# ---------------------------------------------------------------- 4. format open check
hdr "4. Format check: does Vespertine open and label every library file? (inspection only, no playback)"
if (( want_evidence )) && [[ -x $PROBE && -d $PACK ]]; then
  # E1. every file: SHA-256, raw ffprobe / afinfo / vespertine-probe channels
  print "  hashing and inspecting every file (evidence/files.jsonl)..."
  $PY -I "$EVIDENCE" files --library "$LIB" --out "$OUT" --probe "$PROBE" --jobs 4 > "$OUT/evidence-files.log" 2>&1
  rc=$?; tail -1 "$OUT/evidence-files.log" | sed 's/^/  /'
  (( rc == 0 )) && rec "file hashes" PASS "$(tail -1 "$OUT/evidence-files.log" | cut -d';' -f1)" "evidence/files.jsonl" \
                || rec "file hashes" FAIL "$(tail -1 "$OUT/evidence-files.log")" "evidence/files.jsonl"
  $PY -I - "$OUT" <<'EOF' > "$OUT/format-check.counts"
import json, sys, os
rows = [json.loads(l) for l in open(os.path.join(sys.argv[1], 'evidence', 'files.jsonl'))]
c = {}
with open(os.path.join(sys.argv[1], 'format-check.tsv'), 'w') as f:
    for r in rows:
        k = r.get('open_class')
        if not k:
            continue
        c[k] = c.get(k, 0) + 1
        if k != 'OPENS':
            f.write(f"{k}\t{r['path']}\t{(r.get('vsh') or {}).get('error', '')}\n")
print(c.get('OPENS', 0), c.get('REFUSED-EXPECTED', 0), c.get('KNOWN-GAP', 0), c.get('CANNOT-OPEN', 0), c.get('CRASH', 0))
EOF
  read opened expected gap failed crashed < "$OUT/format-check.counts"
  (( crashed == 0 )) && rec "no probe crash on any file" PASS "incl. corrupt/truncated files" "format-check.tsv" || rec "no probe crash on any file" FAIL "$crashed crash(es), see format-check.tsv" "format-check.tsv"
  (( failed == 0 )) && rec "valid files open" PASS "$opened opened, layout read; $expected broken files refused gracefully (folder 07 and disc images meant to be refused); $gap Matroska-audio files not opened (the pack documents this as a known gap)" "format-check.tsv" \
                    || rec "valid files open" FAIL "$failed valid file(s) would not open ($opened opened, $expected refused as expected, $gap known gaps), see format-check.tsv" "format-check.tsv"
elif [[ -x $PROBE && -d $PACK ]]; then
  : > "$OUT/format-check.tsv"; opened=0 failed=0 crashed=0 expected=0 gap=0
  while IFS= read -r -d '' f; do
    out=$("$PROBE" channels "$f" 2>/dev/null); rc=$?
    if (( rc >= 128 )); then crashed=$((crashed+1)); printf 'CRASH\t%s\n' "$f" >> "$OUT/format-check.tsv"
    elif [[ $out == *" ch · "* ]]; then opened=$((opened+1))
    elif [[ $f == */"07 Should fail gracefully"/* || $f == *"should be refused"* ]]; then expected=$((expected+1)); printf 'REFUSED(expected)\t%s\t%s\n' "$f" "$out" >> "$OUT/format-check.tsv"
    elif [[ $f == *.mka ]]; then gap=$((gap+1)); printf 'KNOWN-GAP(mka; pack notes say clean error expected)\t%s\t%s\n' "$f" "$out" >> "$OUT/format-check.tsv"
    else failed=$((failed+1)); printf 'CANNOT-OPEN\t%s\t%s\n' "$f" "$out" >> "$OUT/format-check.tsv"; fi
  done < <(find "$LIB" -type f \( -iname '*.flac' -o -iname '*.wav' -o -iname '*.caf' -o -iname '*.aif*' -o -iname '*.m4a' -o -iname '*.mp4' \
            -o -iname '*.mka' -o -iname '*.mkv' -o -iname '*.ac3' -o -iname '*.ec3' -o -iname '*.eac3' -o -iname '*.thd' -o -iname '*.mlp' \
            -o -iname '*.dts' -o -iname '*.dtshd' -o -iname '*.dsf' -o -iname '*.dff' -o -iname '*.wv' -o -iname '*.opus' -o -iname '*.ogg' \
            -o -iname '*.mp3' -o -iname '*.tta' -o -iname '*.ape' -o -iname '*.iso' -o -iname '*.aac' -o -iname '*.mpc' -o -iname '*.wma' \
            -o -iname '*.rf64' -o -iname '*.w64' \) -not -path '*/10 Tools*' -print0)
  (( crashed == 0 )) && rec "no probe crash on any file" PASS "incl. corrupt/truncated files" "format-check.tsv" || rec "no probe crash on any file" FAIL "$crashed crash(es), see format-check.tsv" "format-check.tsv"
  (( failed == 0 )) && rec "valid files open" PASS "$opened opened, layout read; $expected broken files refused gracefully; $gap Matroska-audio files not opened (known gap)" "format-check.tsv" \
                    || rec "valid files open" FAIL "$failed valid file(s) would not open, see format-check.tsv" "format-check.tsv"
else
  rec "format check" SKIP "probe or library unavailable"
fi

# ---------------------------------------------------------------- 4b. evidence: routing and signal path
hdr "4b. Evidence: channel routing and signal path (offline, or into a virtual device only)"
if (( want_evidence )) && [[ -f $OUT/evidence/files.jsonl ]]; then
  if (( HAVE_NUMPY && HAVE_FFMPEG )); then
    print "  verify_chid.py on every channel-ID file, FFmpeg and Core Audio decoders (evidence/chid-source.jsonl)..."
    $PY -I "$EVIDENCE" chid --library "$LIB" --out "$OUT" --python "$PY" --jobs 4 > "$OUT/evidence-chid.log" 2>&1
    tail -1 "$OUT/evidence-chid.log" | sed 's/^/  /'
  else
    rec "verify_chid (source files)" SKIP "needs numpy and FFmpeg"
  fi
  if (( want_render )) && [[ -s $OUT/evidence/chid-source.jsonl ]]; then
    $PY -I "$EVIDENCE" render-list --out "$OUT" | sed 's/^/  /'
    print "  rendering through Vespertine's decoder and multichannel converter (render/, StudioRoutingTests)..."
    env $scrub VESPERTINE_STUDIO_RENDER="$OUT/render/list.txt" VESPERTINE_STUDIO_RENDER_OUT="$OUT/render" \
      nice -n 5 zsh -c "$(typeset -f bounded); bounded 3600 swift test --filter StudioRoutingTests" > "$OUT/render-test.log" 2>&1
    rc=$?
    (( rc == 0 )) && rec "routing render" PASS "$(grep -m1 'studio render:' "$OUT/render-test.log" | sed 's/.*studio render: //')" "render-test.log" \
                  || rec "routing render" FAIL "exit $rc, see render-test.log" "render-test.log"
    $PY -I "$EVIDENCE" render-check --library "$LIB" --out "$OUT" --python "$PY" --jobs 4 > "$OUT/evidence-render.log" 2>&1
    tail -1 "$OUT/evidence-render.log" | sed 's/^/  /'
  elif (( want_render )); then
    rec "routing render" SKIP "no channel-ID files resolved (verify_chid step did not run)"
  fi
  if (( want_config )) && (( DEVICE_OK )); then
    $PY -I "$EVIDENCE" config-list --out "$OUT" | sed 's/^/  /'
    print "  configuring '$DEVICE' for every file the way the engine does, then reading Core Audio back (no audio)..."
    env $scrub VESPERTINE_STUDIO_CONFIG="$OUT/evidence/config-list.txt" VESPERTINE_STUDIO_CONFIG_DEVICE="$DEVICE" \
      VESPERTINE_STUDIO_CONFIG_OUT="$OUT/evidence/device-config.jsonl" \
      nice -n 5 zsh -c "$(typeset -f bounded); bounded 3600 swift test --filter StudioDeviceConfigTests" > "$OUT/config-test.log" 2>&1
    rc=$?
    (( rc == 0 )) && rec "device configuration run" PASS "$(grep -m1 'studio device configuration:' "$OUT/config-test.log" | sed 's/.*configuration: //')" "config-test.log" \
                  || rec "device configuration run" FAIL "exit $rc, see config-test.log" "config-test.log"
    $PY -I "$EVIDENCE" config-check --out "$OUT" | sed 's/^/  /'
  elif (( want_config )); then
    rec "device configuration run" SKIP "no virtual output device named '$DEVICE' (use --device)"
  fi
  if (( want_signal )) && (( DEVICE_OK )) && [[ -x $PROBE ]]; then
    print "  playing each file into '$DEVICE' and reading Core Audio back (evidence/signal-path.jsonl)..."
    : > "$OUT/evidence/signal-path.jsonl"
    $PY -I -c 'import json,sys; [print(json.loads(l)["path"]) for l in open(sys.argv[1]) if (json.loads(l).get("vsh") or {}).get("opened")]' \
      "$OUT/evidence/files.jsonl" > "$OUT/evidence/signal-list.txt"
    # one process per 25 files: when Core Audio blocks the engine's I/O the probe reports it and leaves (exit 4)
    split -l 25 "$OUT/evidence/signal-list.txt" "$OUT/evidence/signal-chunk."
    for chunk in "$OUT"/evidence/signal-chunk.*(N); do
      bounded 600 "$PROBE" signal-path "$DEVICE" ${(f)"$(cat "$chunk")"} >> "$OUT/evidence/signal-path.jsonl" 2>> "$OUT/signal-path.log"
      rc=$?; rm -f "$chunk"
      if (( rc == 4 )); then print "  the engine's audio I/O did not start in this process: stopping the signal-path step"; break; fi
    done
    $PY -I "$EVIDENCE" signal-check --out "$OUT" | sed 's/^/  /'
  elif (( want_signal )); then
    rec "signal path (playing)" SKIP "no virtual output device named '$DEVICE'"
  fi
  if (( ${#CAPTURES} )); then
    $PY -I "$EVIDENCE" captures --library "$LIB" --out "$OUT" --python "$PY" --runs $CAPTURES | sed 's/^/  /'
  fi
fi

# ---------------------------------------------------------------- 5. multichannel hardware
hdr "5. Multichannel hardware layer"
if (( MULTI_HW )); then
  print "  Real multichannel output present: ${MULTI_NAMES%; }"
  env $scrub VESPERTINE_HARDWARE_TESTS=1 swift test --filter HardwareAuditTests > "$OUT/hardware-audit.log" 2>&1; rc=$?
  (( rc == 0 )) && rec "HardwareAuditTests (silent)" PASS "$(grep -E 'Test run with' "$OUT/hardware-audit.log" | tail -1)" "hardware-audit.log" \
                || rec "HardwareAuditTests (silent)" FAIL "exit $rc, see hardware-audit.log" "hardware-audit.log"
  print "  Manual listening/routing steps with this hardware: see STUDIO-TEST.md (or verification/studio/README.md)."
else
  rec "HardwareAuditTests" SKIP "no real multichannel output detected (this layer needs one; built-in speakers and AirPods are stereo)"
fi
if (( want_matrix )) && (( HAVE_FFMPEG )); then
  env $scrub VESPERTINE_SPATIAL_MATRIX=1 swift test --filter SpatialMatrixTests > "$OUT/spatial-matrix.log" 2>&1; rc=$?
  (( rc == 0 )) && rec "SpatialMatrixTests (offline)" PASS "$(grep -E 'Test run with' "$OUT/spatial-matrix.log" | tail -1)" "spatial-matrix.log" \
                || rec "SpatialMatrixTests (offline)" FAIL "exit $rc, see spatial-matrix.log" "spatial-matrix.log"
else rec "SpatialMatrixTests (offline)" SKIP "not requested or ffmpeg missing (--matrix; decode-only, silent, slow)"; fi

# ---------------------------------------------------------------- 6. loopback routing
hdr "6. Loopback layer (virtual device only, silent)"
if (( LOOPBACK_DEV )); then
  if (( want_loopback )) && [[ -x $PROBE ]]; then
    bounded 1800 "$PROBE" loopback --quick --json "$OUT/loopback.json" --markdown "$OUT/loopback.md" > "$OUT/loopback.log" 2>&1; rc=$?
    case $rc in
      0) rec "loopback bit-exact (quick)" PASS "every case bit-exact (loopback.md)" "loopback.md" ;;
      1) rec "loopback bit-exact (quick)" FAIL "not bit-exact, see loopback.log" "loopback.log" ;;
      *) rec "loopback bit-exact (quick)" SKIP "setup problem (exit $rc), usually microphone permission for your terminal: $(tail -1 "$OUT/loopback.log")" ;;
    esac
  else
    rec "loopback bit-exact (quick)" SKIP "not requested (add --loopback; it plays only into 'Vespertine Loopback')"
  fi
else
  rec "loopback" SKIP "'Vespertine Loopback' virtual device not installed"
fi
rec "device routing capture (chid-capture.sh)" INFO "$( (( ${#CAPTURES} )) && print "${#CAPTURES} capture run(s) re-verified" || print "none given (--captures); a capture needs a loopback with as many channels as the layout and a terminal with Microphone permission (README.md)")"

# ---------------------------------------------------------------- 7. bitstream gate
hdr "7. Bitstream / IEC 61937 gate"
print "  RULE: never send bitstream to speakers, a stereo DAC, headphones or AirPods. This script plays no bitstream."
allow=${STUDIO_ALLOW_BITSTREAM:-}
if [[ -z $allow ]]; then
  rec "bitstream playback" SKIP "locked (STUDIO_ALLOW_BITSTREAM not set). Correct on any Mac without a receiver attached."
else
  ok=0
  for i in {1..${#D_NAME}}; do
    [[ $D_NAME[$i] == $allow && $D_TRANSPORT[$i] != Virtual && $D_TRANSPORT[$i] != Aggregate && $D_TRANSPORT[$i] != Bluetooth \
       && $D_TRANSPORT[$i] != AirPlay && $D_TRANSPORT[$i] != Built-in && $D_MAXCH[$i] -gt 2 ]] && ok=1
  done
  if (( ok )); then
    rec "bitstream playback" INFO "'$allow' is a real multichannel output. Not auto-run: follow the manual bitstream steps with the receiver volume LOW and a human present."
  else
    rec "bitstream playback" SKIP "'$allow' is not a detected real multichannel (>2 ch) output: refused"
  fi
fi

# ---------------------------------------------------------------- report
if (( want_evidence )); then
  hdr "REPORT (MEASURED vs UNVERIFIED)"
  $PY -I "$EVIDENCE" report --out "$OUT" | sed 's/^/  /'
fi

hdr "SUMMARY (given the hardware detected right now)"
fails=0 passes=0 skips=0
for i in {1..${#R_NAME}}; do
  case $R_STATUS[$i] in PASS) passes=$((passes+1)) ;; FAIL) fails=$((fails+1)) ;; SKIP) skips=$((skips+1)) ;; esac
done
print "  RAN and passed : $passes"
print "  FAILED         : $fails"
print "  SKIPPED        : $skips"
print ""
print "  Skipped, and why:"
for i in {1..${#R_NAME}}; do [[ $R_STATUS[$i] == SKIP ]] && print "    - $R_NAME[$i]: $R_NOTE[$i]"; done
if (( fails )); then print ""; print "  Failed:"; for i in {1..${#R_NAME}}; do [[ $R_STATUS[$i] == FAIL ]] && print "    - $R_NAME[$i]: $R_NOTE[$i]"; done; fi
print ""
print "  Logs: $OUT"
(( want_evidence )) && print "  Report: $OUT/REPORT.md (claims) and $OUT/evidence.json"
(( fails )) && { print "\n  RESULT: FAIL"; exit 1 }
print "\n  RESULT: PASS (skips above are hardware this Mac does not have)"
exit 0
