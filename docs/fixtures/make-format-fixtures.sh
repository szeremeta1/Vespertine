#!/bin/zsh
# Generates the format fixtures (1-2 s of synthesized tones) into out/. Needs ffmpeg (libopus, libmp3lame), flac/metaflac, afconvert.
set -euo pipefail
mkdir -p out && cd out   # run from a scratch directory
F() { ffmpeg -hide_banner -v error -y "$@"; }
# Stereo 24-bit: L 440 Hz, R 550 Hz, 1 s.
F -f lavfi -i "sine=f=440:r=48000:d=1" -f lavfi -i "sine=f=550:r=48000:d=1" -filter_complex "[0][1]join=inputs=2:channel_layout=stereo" -c:a pcm_s24le stereo24.wav
# 5.1 16-bit: FL 440, FR 550, FC 660, LFE 60, SL 770, SR 880, 1 s.
F -f lavfi -i "sine=f=440:r=48000:d=1" -f lavfi -i "sine=f=550:r=48000:d=1" -f lavfi -i "sine=f=660:r=48000:d=1" -f lavfi -i "sine=f=60:r=48000:d=1" -f lavfi -i "sine=f=770:r=48000:d=1" -f lavfi -i "sine=f=880:r=48000:d=1" \
  -filter_complex "[0][1][2][3][4][5]join=inputs=6:channel_layout=5.1(side):map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-SL|5.0-SR" -c:a pcm_s16le surround16.wav
# Matroska audio
F -i stereo24.wav -c:a flac -metadata title="Matroska FLAC" -metadata artist="Nocturne Test" -metadata album="Formats" flac-stereo.mka
F -i stereo24.wav -c:a flac stereo24.flac
F -i stereo24.wav -c:a alac alac-stereo.mka
F -i surround16.wav -c:a flac surround16.flac
F -i stereo24.wav -i surround16.wav -map 0:a -map 1:a -c:a flac -metadata:s:a:0 title="Stereo mix" -metadata:s:a:0 language=eng \
  -metadata:s:a:1 title="Surround mix" -metadata:s:a:1 language=eng -metadata title="Two Streams" -metadata artist="Nocturne Test" two-streams.mka
F -i surround16.wav -af "channelmap=map=FL-FL|FR-FR|FC-FC|LFE-LFE|SL-BL|SR-BR:channel_layout=5.1" -c:a libopus -b:a 256k -mapping_family 1 opus-51.mka
F -i surround16.wav -af "channelmap=map=FL-FL|FR-FR|FC-FC|LFE-LFE|SL-BL|SR-BR:channel_layout=5.1" -c:a libopus -b:a 256k -mapping_family 1 opus-51.webm
F -i surround16.wav -af "channelmap=map=FL-FL|FR-FR|FC-FC|LFE-LFE|SL-BL|SR-BR:channel_layout=5.1" -c:a libopus -b:a 256k -mapping_family 1 opus-51.opus
F -i stereo24.wav -c:a aac -b:a 128k aac-stereo.mkv
F -i stereo24.wav -c:a libmp3lame -b:a 192k mp3-stereo.mka
F -i stereo24.wav -c:a vorbis -strict -2 -b:a 128k vorbis-stereo.webm
F -i stereo24.wav -c:a pcm_s24le pcm-stereo.mka
# Gapless: 2 s of a cosine (starts at full scale: a delay shows as a mismatch from the first sample).
F -f lavfi -i "aevalsrc=0.5*cos(2*PI*440*t):s=48000:d=2" -c:a pcm_s16le cos2s.wav
F -i cos2s.wav -c:a libmp3lame -b:a 192k gapless.mp3
afconvert -f m4af -d aac -b 128000 cos2s.wav gapless.m4a
F -i cos2s.wav -c:a libopus -b:a 128k gapless.opus
# Embedded CUE: two tracks, as a FLAC CUESHEET block, and as a CUESHEET tag
F -i stereo24.wav -c:a flac cue-block.flac
cat > cue.txt <<'CUE'
PERFORMER "Nocturne Test"
TITLE "Embedded Album"
FILE "cue-block.flac" WAVE
  TRACK 01 AUDIO
    TITLE "First"
    PERFORMER "Nocturne Test"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "Second"
    PERFORMER "Nocturne Test"
    INDEX 01 00:00:37
CUE
metaflac --import-cuesheet-from=cue.txt cue-block.flac
F -i stereo24.wav -c:a flac cue-tag.flac
metaflac --set-tag="CUESHEET=$(cat cue.txt)" cue-tag.flac
afconvert -f caff -d apac -b 256000 surround16.wav apac-51.caf 2>&1 || afconvert -f caff -d apac stereo24.wav apac-stereo.caf
ls -l
# Not made here: xhe-stereo.m4a (build xhe-aac-enc from github.com/mstorsjo/fdk-aac with -DBUILD_PROGRAMS=ON, then
#   ffmpeg -i stereo24.wav -c:a pcm_s16le stereo16.wav; xhe-aac-enc -r 64000 -l -23 stereo16.wav x.loas; afconvert -f m4af -d 0 x.loas xhe-stereo.m4a)
# and tak-excerpt.tak (the first 74,493 bytes of FATE's tak/luckynight-partial.tak: its header and four whole frames).
