# Third-party notices

Vespertine is free software under the GPL-3.0-or-later (see [LICENSE](LICENSE)). It includes the components below, each under its own license. The complete source of Vespertine, including the scripts that build the bundled FFmpeg decoders, is in this repository, so any component can be rebuilt and relinked.

| Component | License | Used for | Source |
|---|---|---|---|
| SFBAudioEngine 0.14.0 | MIT | Decoders, DSD/DoP, metadata reading, ReplayGain | https://github.com/sbooth/SFBAudioEngine |
| GRDB.swift | MIT | The library database | https://github.com/groue/GRDB.swift |
| Sparkle | MIT, with bundled BSD-style components | Software updates | https://github.com/sparkle-project/Sparkle |
| TagLib | LGPL / MPL | Reading and writing tags | https://taglib.org |
| libFLAC, libogg, libvorbis, libopus | BSD | FLAC, Ogg Vorbis and Opus | https://xiph.org |
| WavPack | BSD | WavPack | https://www.wavpack.com |
| Monkey's Audio | BSD-style | APE | https://monkeysaudio.com |
| Musepack decoder | BSD | Musepack | https://www.musepack.net |
| mpg123 | LGPL | MP3 | https://www.mpg123.de |
| libsndfile | LGPL | WAV, AIFF and other PCM containers | https://libsndfile.github.io/libsndfile/ |
| LAME | LGPL | MP3, from SFBAudioEngine's bundled libraries | https://lame.sourceforge.io |
| TTA | LGPL | True Audio | https://sourceforge.net/projects/tta/ |
| DUMB | DUMB license (zlib-like) | Tracker formats | https://github.com/kode54/dumb |
| FFmpeg 9.0.2 (a subset) | LGPL-2.1-or-later | DTS, DTS-HD, TrueHD/MLP, Dolby Digital modes macOS gets wrong, Matroska, DSD | https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz |

The SFBAudioEngine dependencies ship as prebuilt xcframeworks and are embedded in `Contents/Frameworks`. Each is signed with Vespertine's identity.

## FFmpeg

Vespertine links a small, static build of FFmpeg 9.0.2, made from FFmpeg's unmodified release tarball (SHA-256 `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`) by [`scripts/build-dts-decoder.sh`](scripts/build-dts-decoder.sh), which verifies the checksum. The build uses `--disable-everything` and enables only these pieces:

- decoders: `dca`, `truehd`, `mlp`, `ac3`, `eac3`, `dsd_lsbf`, `dsd_msbf`, `dsd_lsbf_planar`, `dsd_msbf_planar`
- parsers: `dca`, `mlp`, `ac3`
- demuxers: `dts`, `dtshd`, `truehd`, `mlp`, `ac3`, `eac3`, `matroska`, `dsf`, `iff`
- protocol: `file`

It is built without `--enable-gpl` or `--enable-nonfree`, so it stays LGPL. To use your own FFmpeg build, run the script and it regenerates `Packages/VespertineKit/Vendor/FFmpegDCA.xcframework`; then rebuild Vespertine as described in the README.

## Trademarks

Dolby, Dolby Atmos, Dolby Digital, Dolby Digital Plus and Dolby TrueHD are trademarks of Dolby Laboratories. DTS, DTS-HD Master Audio and DTS:X are trademarks of DTS, Inc. Apple, AirPods, AirPods Max and Spatial Audio are trademarks of Apple Inc. Vespertine names these formats and products only to describe what it plays. It is not certified, licensed or endorsed by Dolby, DTS or Apple, and it does not use their logos.
