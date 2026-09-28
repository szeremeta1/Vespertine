#!/bin/zsh
# Builds the FFmpeg pieces Nocturne uses for formats macOS can't decode: the DTS decoder (DTS CDs,
# DTS-WAV, DTS-HD Master Audio), Dolby TrueHD, and the containers they come in (.dts, .dtshd,
# .thd/.mlp, Matroska). Only those decoders, parsers and demuxers (LGPL-2.1+), static, universal
# (arm64 + x86_64), packaged as Packages/NocturneKit/Vendor/FFmpegDCA.xcframework.
#
#   scripts/build-dts-decoder.sh [path/to/ffmpeg-X.Y.Z.tar.xz]
#
# Without an argument it downloads the release below and checks its SHA-256.
set -euo pipefail
cd "$(dirname $0)/.."

version=9.0.2
sha256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
out=Packages/NocturneKit/Vendor/FFmpegDCA.xcframework
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

tarball=${1:-}
if [[ -z $tarball ]]; then
  tarball="$work/ffmpeg-$version.tar.xz"
  curl -sSfL "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz" -o "$tarball"
fi
echo "$sha256  $tarball" | shasum -a 256 -c - >/dev/null || { print -u2 "Checksum mismatch for $tarball"; exit 1; }
tar -xf "$tarball" -C "$work"
src="$work/ffmpeg-$version"

for arch in arm64 x86_64; do
  build="$work/build-$arch"
  mkdir -p "$build"
  (cd "$build" && "$src/configure" \
    --prefix="$work/install-$arch" --arch=$arch --target-os=darwin --enable-cross-compile \
    --cc="clang -arch $arch -mmacosx-version-min=26.0" \
    --enable-static --disable-shared --disable-programs --disable-doc --disable-network \
    --disable-autodetect --disable-everything --disable-avdevice --disable-avfilter \
    --disable-swscale --disable-swresample --disable-x86asm \
    --enable-decoder=dca,truehd,mlp --enable-parser=dca,mlp \
    --enable-demuxer=dts,dtshd,truehd,mlp,matroska --enable-protocol=file >/dev/null)
  make -C "$build" -j"$(sysctl -n hw.ncpu)" >/dev/null
  make -C "$build" install >/dev/null
  libtool -static -o "$work/libffmpegdca-$arch.a" "$work/install-$arch/lib/libavformat.a" "$work/install-$arch/lib/libavcodec.a" \
    "$work/install-$arch/lib/libavutil.a" 2>/dev/null
done

lipo -create "$work/libffmpegdca-arm64.a" "$work/libffmpegdca-x86_64.a" -output "$work/libffmpegdca.a"
headers="$work/headers"
mkdir -p "$headers"
cp -R "$work/install-arm64/include/libavcodec" "$work/install-arm64/include/libavformat" "$work/install-arm64/include/libavutil" "$headers/"
cat > "$headers/module.modulemap" <<'EOF'
module FFmpegDCA {
    header "libavcodec/avcodec.h"
    header "libavformat/avformat.h"
    header "libavutil/channel_layout.h"
    header "libavutil/frame.h"
    header "libavutil/mem.h"
    link "ffmpegdca"
    export *
}
EOF
rm -rf "$out"
xcodebuild -create-xcframework -library "$work/libffmpegdca.a" -headers "$headers" -output "$out" >/dev/null
cp "$src/COPYING.LGPLv2.1" "$out/LICENSE.FFmpeg-LGPL-2.1.txt"
echo "FFmpeg $version (dca, truehd, mlp decoders; dca, mlp parsers; dts, dtshd, truehd, mlp, matroska demuxers), built $(date -u +%Y-%m-%d)" > "$out/VERSION.txt"
echo "Built $out"
