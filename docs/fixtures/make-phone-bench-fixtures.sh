#!/bin/sh
#
# Vespertine: test songs for the phone bench (docs/IOS-AUDIO-BENCH.md, "Measured without a listener").
# One 1 kHz tone, cut into songs where it crosses zero, so that a join played right is one unbroken tone:
#   tone-flac, tone-mp3, tone-aac   three songs each (6 s, 4 s, 4 s); every join should read GAPLESS
#   gap-30-80                       the same in FLAC with 30 ms and 80 ms of silence put in: the joins should read
#                                   GAP 30 ms and GAP 80 ms (this shows the meter sees a gap when there is one)
#   replaygain                      a 10 s tone tagged track −6.20 dB, album −3.50 dB (FLAC and MP3), and one tagged
#                                   +9.00 dB with a peak that only leaves room for +6.02 dB
# Needs ffmpeg with libmp3lame.   Usage: make-phone-bench-fixtures.sh <folder to make>
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -eu
out="${1:?usage: make-phone-bench-fixtures.sh <folder to make>}"
mkdir -p "$out/tone-flac" "$out/tone-mp3" "$out/tone-aac" "$out/gap-30-80" "$out/replaygain"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }

# 44.1 samples to a cycle: every 441st sample is a zero crossing. The cuts are at 264,600 and 441,000.
ff -f lavfi -i "sine=frequency=1000:sample_rate=44100:duration=14" -ac 2 -c:a pcm_s16le "$work/whole.wav"
cut() { ff -i "$work/whole.wav" -af "atrim=start_sample=$1:end_sample=$2,asetpts=N/SR/TB" -c:a pcm_s16le "$work/$3.wav"; }
cut 0 264600 01
cut 264600 441000 02
cut 441000 617400 03

for n in 01 02 03; do
    ff -i "$work/$n.wav" -c:a flac -metadata title="Tone $n" -metadata album="Bench tone FLAC" -metadata track="$n" "$out/tone-flac/$n.flac"
    # libmp3lame writes a LAME header with the delay and the padding.
    ff -i "$work/$n.wav" -c:a libmp3lame -b:a 192k -metadata title="Tone $n" -metadata album="Bench tone MP3" -metadata track="$n" "$out/tone-mp3/$n.mp3"
    # The edit list is in whole samples only with the movie's clock at the sample rate.
    ff -i "$work/$n.wav" -c:a aac -b:a 192k -movie_timescale 44100 -metadata title="Tone $n" -metadata album="Bench tone AAC" -metadata track="$n" "$out/tone-aac/$n.m4a"
done

# The control: silence in front of the second and third songs.
ff -i "$work/01.wav" -c:a flac -metadata title="Gap 01" -metadata album="Bench gaps" -metadata track=1 "$out/gap-30-80/01.flac"
# adelay counts samples with S: 30 ms and 80 ms at 44.1 kHz are 1,323 and 3,528.
ff -i "$work/02.wav" -af "adelay=1323S:all=1" -c:a flac -metadata title="Gap 02" -metadata album="Bench gaps" -metadata track=2 "$out/gap-30-80/02.flac"
ff -i "$work/03.wav" -af "adelay=3528S:all=1" -c:a flac -metadata title="Gap 03" -metadata album="Bench gaps" -metadata track=3 "$out/gap-30-80/03.flac"

# ReplayGain: the tone is at an eighth of full scale (ffmpeg's sine), so its peak is 0.125.
ff -f lavfi -i "sine=frequency=1000:sample_rate=44100:duration=10" -ac 2 -c:a pcm_s16le "$work/ten.wav"
ff -i "$work/ten.wav" -c:a flac -metadata title="Tagged FLAC" -metadata album="Bench ReplayGain" \
    -metadata "REPLAYGAIN_TRACK_GAIN=-6.20 dB" -metadata "REPLAYGAIN_TRACK_PEAK=0.125000" \
    -metadata "REPLAYGAIN_ALBUM_GAIN=-3.50 dB" -metadata "REPLAYGAIN_ALBUM_PEAK=0.125000" "$out/replaygain/tagged.flac"
ff -i "$work/ten.wav" -c:a libmp3lame -b:a 192k -metadata title="Tagged MP3" -metadata album="Bench ReplayGain" \
    -metadata "REPLAYGAIN_TRACK_GAIN=-6.20 dB" -metadata "REPLAYGAIN_TRACK_PEAK=0.125000" \
    -metadata "REPLAYGAIN_ALBUM_GAIN=-3.50 dB" -metadata "REPLAYGAIN_ALBUM_PEAK=0.125000" "$out/replaygain/tagged.mp3"
# Asks for +9 dB, but says its peak is 0.5: only +6.02 dB of room. The bench should report it held by the peak.
ff -i "$work/ten.wav" -c:a flac -metadata title="Held by the peak" -metadata album="Bench ReplayGain" \
    -metadata "REPLAYGAIN_TRACK_GAIN=+9.00 dB" -metadata "REPLAYGAIN_TRACK_PEAK=0.500000" \
    -metadata "REPLAYGAIN_ALBUM_GAIN=+9.00 dB" -metadata "REPLAYGAIN_ALBUM_PEAK=0.500000" "$out/replaygain/held.flac"
echo "made $(find "$out" -type f | wc -l | tr -d ' ') songs in $out"
