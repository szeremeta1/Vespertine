#!/bin/bash
#
# Vespertine verification: builds the FFmpeg the IEC 61937 oracle check needs (hardware/IEC61937-ORACLE.md).
# SPDX-License-Identifier: GPL-3.0-or-later
#
#   build_ffmpeg.sh <dir>       # leaves <dir>/ffmpeg; put <dir> on PATH for check_carriers.py
#
# FFmpeg 6.1.1 from its own source at tag n6.1.1 (the tag whose libavformat/spdifdec.c the IEC-O-001 record reviewed),
# fetched from FFmpeg's repository on GitHub and refused unless the tag is the commit below, which fixes every file in
# it. Only what the check runs is built: the S/PDIF demuxer, the AC-3 parser and decoders it hands its frames to, and
# the raw AC-3 and E-AC-3 writers. No assembly and no outside libraries, so it needs a C compiler and make and nothing
# else, and takes about half a minute.
# It is built, not installed from a package: installing Ubuntu's ffmpeg package (a hundred packages from a mirror)
# hung in CI on some of GitHub's runners until the job's time ran out, with nothing to show which download had stopped.
set -euo pipefail

TAG=n6.1.1
COMMIT=e38092ef9395d7049f871ef4d5411eb410e283e0

if [ $# -ne 1 ]; then echo "usage: build_ffmpeg.sh <dir>" >&2; exit 2; fi
mkdir -p "$1"
out=$(cd "$1" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" https://github.com/FFmpeg/FFmpeg.git "$work/src"
got=$(git -C "$work/src" rev-parse HEAD)
if [ "$got" != "$COMMIT" ]; then
    echo "FFmpeg's tag $TAG is commit $got, but the oracle was reviewed at $COMMIT: not building it." >&2
    exit 1
fi
# Without its .git the build names itself from the RELEASE file ("6.1.1"), which is what check_carriers.py asks for.
rm -rf "$work/src/.git"

cd "$work/src"
./configure --disable-everything --disable-autodetect --disable-doc --disable-debug --disable-x86asm \
    --disable-ffplay --disable-ffprobe --disable-network \
    --enable-demuxer=spdif --enable-parser=ac3 --enable-decoder=ac3,eac3 --enable-muxer=ac3,eac3 \
    --enable-protocol=file,pipe >"$work/configure.log" 2>&1 || { cat "$work/configure.log" >&2; exit 1; }
make -j"$(getconf _NPROCESSORS_ONLN)" ffmpeg >"$work/make.log" 2>&1 || { tail -50 "$work/make.log" >&2; exit 1; }
cp ffmpeg "$out/ffmpeg"
"$out/ffmpeg" -version | head -1
