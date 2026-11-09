#!/bin/zsh
# Hardware QA for Speaker Groups (beta): the probe-based steps (H1 to H4, H2) for the next session with two USB DACs and a UMIK-1.
# Writes everything to verification/hardware/speaker-groups/<timestamp>/ (one text file per step, plus a SUMMARY.md to fill in).
# The in-app steps (A1 to A10) and H5 to H7 are by hand: see verification/hardware/SPEAKER-GROUPS.md.
#
# Run it in a Terminal window on the Mac with the DACs, not over ssh: the microphone permission is granted to the app that runs
# the probe, and over ssh macOS says "Microphone access is off". From another shell: open -a Terminal scripts/speaker-groups-qa.sh
#
#   scripts/speaker-groups-qa.sh --leader "Fosi Audio ZD3" --follower "FiiO K11" --mic UMIK --probe /path/to/vespertine-probe [--dry-run] [steps…]
#
# steps: info quad control h3 h3nodrift h4 h2   (default: all, in that order)
# --probe is a vespertine-probe built from feat/speaker-groups-probe with fix/room-detector-earliest-arrival merged (the earliest-arrival
# detector: the first one ranked the strongest peak and called 17 of 20 runs in a quiet room "ambiguous").
# Quiet: the chirps play at -20 dBFS and the quad file at about -30 dBFS. Turn the amplifiers down first.
set -eu
setopt pipefail
root=${0:A:h:h}
leader="" follower="" mic="" probe="${VESPERTINE_PROBE:-}" dry=0
typeset -a steps
while (( $# )); do
  case $1 in
    --leader) leader=$2; shift 2 ;;
    --follower) follower=$2; shift 2 ;;
    --mic) mic=$2; shift 2 ;;
    --probe) probe=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) sed -n '2,15p' $0; exit 0 ;;
    -*) print -u2 "unknown option $1"; exit 2 ;;
    *) steps+=($1); shift ;;
  esac
done
(( ${#steps} )) || steps=(info quad control h3 h3nodrift h4 h2)
[[ -n $leader && -n $follower && -n $mic ]] || { print -u2 "need --leader, --follower and --mic (see --help)"; exit 2 }
if (( ! dry )); then
  [[ -x $probe ]] || { print -u2 "need --probe <vespertine-probe binary> (see --help)"; exit 2 }
  # A Terminal window opened with `open -a Terminal` from an ssh shell inherits SSH_CONNECTION but has the microphone: only a
  # session with no terminal app (TERM_PROGRAM isn't passed over ssh) is ssh itself.
  if [[ -n ${SSH_CONNECTION:-} && -z ${TERM_PROGRAM:-} ]]; then
    print -u2 "This is an ssh session: the microphone steps would be refused by macOS. Run it in a Terminal window (open -a Terminal $0)."; exit 2
  fi
fi
stamp=$(date +%Y%m%d-%H%M%S)
out=$root/verification/hardware/speaker-groups/$stamp
(( dry )) && out=${TMPDIR:-/tmp}/speaker-groups-qa-dry-$stamp   # a dry run writes nothing into the repository
mkdir -p $out
export VESPERTINE_GROUP_PROBE=1

# A 4-channel file with a different tone on each channel (440, 554, 659 and 880 Hz, a second each, in turn, then all four at once),
# written with the standard library only. Channel order is the group's: the leader's pair first. Only the quad step plays it, so only
# that step builds it (it was built for every run, ten seconds of CPU even for `info`).
quad=${TMPDIR:-/tmp}/speaker-groups-quad.wav   # not kept with the results
if (( ! dry && ${steps[(Ie)quad]} )); then
python3 -I - $quad <<'PY'
import math, struct, sys, wave
rate = 48000
w = wave.open(sys.argv[1], "wb"); w.setnchannels(4); w.setsampwidth(3); w.setframerate(rate)
tones = [440.0, 554.37, 659.25, 880.0]
# One second of each tone as 24-bit samples, split into its three byte lanes: a part's frames are filled by strided copies.
lanes = []
for f in tones:
    raw = b"".join(struct.pack("<i", int(0.03 * 8388607 * math.sin(2 * math.pi * f * (n / rate))))[:3] for n in range(rate))
    lanes.append([raw[k::3] for k in range(3)])
body = bytearray()
for active in [[0], [1], [2], [3], [0, 1, 2, 3]]:
    part = bytearray(rate * 12)
    for c in active:
        for k in range(3):
            part[c * 3 + k::12] = lanes[c][k]
    body += part
w.writeframes(bytes(body)); w.close()
PY
fi

run() {  # run <name> <command…>: log to $out/<name>.txt, show it, keep going on a failure (the log says so)
  local name=$1; shift
  print "\n== $name: $*"
  if (( dry )); then return 0; fi
  { print "# $(date '+%Y-%m-%d %H:%M:%S')  $*"; "$@" 2>&1 && print "# exit 0" || print "# exit $?"; } | tee $out/$name.txt || true
}

typeset -A file=(info 0-info quad H1-quad control H3-control h3 H3 h3nodrift H3-nodrift h4 H4 h2 H2)
for step in $steps; do
  case $step in
    info)    run 0-info $probe group-info $leader $follower ;;
    quad)    run H1-quad $probe group-play $leader $follower --real-hardware --exclusive-members --seconds 8 $quad ;;
    control) run H3-control $probe group-skew $leader --mic $mic --control --real-hardware --exclusive-members --runs 12 ;;
    h3)      run H3 $probe group-skew $leader $follower --mic $mic --real-hardware --exclusive-members --runs 20 ;;
    h3nodrift) run H3-nodrift $probe group-skew $leader $follower --mic $mic --no-drift --real-hardware --exclusive-members --runs 12 ;;
    # Open item 2: the follower crept about 0.2 ms between 1.6 s and 15.6 s and had not flattened. Longer lead-ins say whether it does.
    h4)      run H4 $probe group-skew $leader $follower --mic $mic --lead-in 1,2,4,8,15,30,60,120 --runs 4 --real-hardware --exclusive-members ;;
    # H2: the DACs' own drift against each other, free-running over 300 s (drift correction off, so they slip). The first attempt found
    # no second chirp after the long gap: if it says "reference not found" again, the probe's end-search window is too narrow.
    h2)      run H2 $probe group-skew $leader $follower --mic $mic --span 300 --no-drift --runs 2 --real-hardware --exclusive-members ;;
    *) print -u2 "unknown step $step"; exit 2 ;;
  esac
done

cat > $out/SUMMARY.md <<SUM
# Speaker groups hardware QA, $stamp

Leader: $leader · follower: $follower · microphone: $mic · probe: ${probe:-(dry run)}
Steps run: ${steps[*]}

Fill in after reading the step files. The in-app checks (A1 to A10) and H5 to H7 are in verification/hardware/SPEAKER-GROUPS.md.

| Step | File | Result (pass / fail / unclear) | Notes |
|---|---|---|---|
$(for s in $steps; do print "| $s | ${file[$s]}.txt | | |"; done)
SUM
print "\nDone: $out"
