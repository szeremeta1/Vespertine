#!/bin/zsh
# Builds libwavpack with DSD support (ENABLE_DSD) for Vespertine's WavPack DSD reader: the prebuilt WavPack that
# SFBAudioEngine ships leaves DSD out ("not configured to handle DSD WavPack files!"). Static, universal (arm64 +
# x86_64), BSD-3-Clause, packaged as Packages/VespertineKit/Vendor/WavPackDSD.xcframework.
#
# Every global symbol is renamed with a `vtwv_` prefix at compile time, so this copy can't be mixed up with the
# WavPack inside SFBAudioEngine, which keeps decoding ordinary WavPack files as before.
#
#   scripts/build-wavpack-dsd.sh [path/to/wavpack-X.Y.Z.tar.xz]
#
# Without an argument it downloads the release below and checks its SHA-256.
set -euo pipefail
cd "$(dirname $0)/.."

version=5.8.1
sha256=7322775498602c8850afcfc1ae38f99df4cbcd51386e873d6b0f8047e55c0c26
out=Packages/VespertineKit/Vendor/WavPackDSD.xcframework
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

tarball=${1:-}
if [[ -z $tarball ]]; then
  tarball="$work/wavpack-$version.tar.xz"
  curl -sSfL "https://www.wavpack.com/wavpack-$version.tar.xz" -o "$tarball"
fi
echo "$sha256  $tarball" | shasum -a 256 -c - >/dev/null || { print -u2 "Checksum mismatch for $tarball"; exit 1; }
tar -xf "$tarball" -C "$work"
src="$work/wavpack-$version"

build() {   # build <dir> <extra C flags>
  cmake -S "$src" -B "$1" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF -DWAVPACK_BUILD_PROGRAMS=OFF \
    -DWAVPACK_ENABLE_DSD=ON -DWAVPACK_ENABLE_LEGACY=OFF -DWAVPACK_ENABLE_THREADS=OFF -DWAVPACK_ENABLE_ASM=OFF \
    -DBUILD_TESTING=OFF -DCMAKE_C_FLAGS="$2" >/dev/null
  cmake --build "$1" --target wavpack -j"$(sysctl -n hw.ncpu)" >/dev/null
}

# Pass 1 finds the library's global symbols; pass 2 builds it with all of them renamed.
build "$work/pass1" ""
nm -gUj "$work/pass1/libwavpack.a" 2>/dev/null | grep -E '^_[A-Za-z]' | sed 's/^_//' | sort -u | grep -v -E '^(vtwv_)' |
  awk '{ printf "#define %s vtwv_%s\n", $1, $1 }' > "$work/prefix.h"
build "$work/pass2" "-include $work/prefix.h"

lib="$work/pass2/libwavpack.a"
# Nothing of WavPack's may be left under its own name.
leaks=$(nm -gUj "$lib" 2>/dev/null | grep -E '^_[A-Za-z]' | grep -v '^_vtwv_' || true)
[[ -z $leaks ]] || { print -u2 "Symbols left unrenamed:\n$leaks"; exit 1; }

rm -rf "$out"
xcodebuild -create-xcframework -library "$lib" -output "$out" >/dev/null
cp "$src/COPYING" "$out/LICENSE.WavPack-BSD-3-Clause.txt"
echo "WavPack $version with ENABLE_DSD (decoder, no threads, no legacy formats), every global symbol prefixed vtwv_, built $(date -u +%Y-%m-%d)" > "$out/VERSION.txt"
echo "Built $out"
