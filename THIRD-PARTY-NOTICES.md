# Third-party notices

Vespertine is free software under the GPL-3.0-or-later (see [LICENSE](LICENSE)). It includes the components below, each under its own license. The complete source of Vespertine, including the scripts that build the bundled FFmpeg decoders, is in this repository, so any component can be rebuilt and relinked.

| Component | License | Used for | Source |
|---|---|---|---|
| SFBAudioEngine 0.14.0 | MIT | Decoders, DSD/DoP, metadata reading, ReplayGain | https://github.com/sbooth/SFBAudioEngine |
| dsd2pcm (in SFBAudioEngine) | BSD-2-Clause | DSD to PCM conversion | https://github.com/sbooth/SFBAudioEngine |
| EBU R128 loudness analyzer (in SFBAudioEngine; Copyright 2024 Google LLC) | Apache-2.0 | Loudness analysis | https://github.com/sbooth/SFBAudioEngine |
| AVFAudioExtensions 0.5.1, CXXAudioRingBuffer 0.2.0, CXXDispatchSemaphore 0.4.1, CXXMessageQueue 0.2.2, CXXQueue 0.1.1, CXXUnfairLock 0.3.1 | MIT | SFBAudioEngine's helper packages | https://github.com/sbooth |
| GRDB.swift 7.11.1 | MIT | The library database | https://github.com/groue/GRDB.swift |
| Sparkle 2.10.0 | MIT, with bundled BSD-style components | Software updates | https://github.com/sparkle-project/Sparkle |
| TagLib (CXXTagLib 2.3.2) | LGPL-2.1 / MPL-1.1 | Reading and writing tags | https://taglib.org |
| libFLAC, libogg, libvorbis, libopus, opusfile | BSD-3-Clause | FLAC, Ogg Vorbis and Opus | https://xiph.org |
| Speex (CSpeex 1.2.1) | BSD-3-Clause | Speex | https://www.speex.org |
| WavPack | BSD-3-Clause | WavPack (SFBAudioEngine's build); a second, prefixed build with DSD support for WavPack DSD (`Vendor/WavPackDSD.xcframework`, WavPack 5.8.1) | https://www.wavpack.com |
| Monkey's Audio (CXXMonkeysAudio 12.13.0) | BSD-3-Clause | APE | https://monkeysaudio.com |
| Musepack decoder | BSD-3-Clause | Musepack | https://www.musepack.net |
| mpg123 | LGPL-2.1 | MP3 | https://www.mpg123.de |
| libsndfile | LGPL-2.1 | WAV, AIFF and other PCM containers | https://libsndfile.github.io/libsndfile/ |
| LAME | LGPL-2.0 | MP3, from SFBAudioEngine's bundled libraries | https://lame.sourceforge.io |
| TTA | LGPL-3.0 | True Audio | https://sourceforge.net/projects/tta/ |
| DUMB (CDUMB 2.0.3) | DUMB license (zlib-like) | Tracker formats | https://github.com/kode54/dumb |
| FFmpeg 9.0.2 (a subset) | LGPL-2.1-or-later | DTS, DTS-HD, TrueHD/MLP, Dolby Digital modes macOS gets wrong, TAK, Matroska/WebM audio (FLAC, ALAC, AAC, MP3, Vorbis, Opus, WavPack, TTA, APE, PCM), DSD | https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz |
| DST decoder, from FFmpeg's `libavcodec/dstdec.c` (Copyright (c) 2014 Peter Ross) | LGPL-2.1-or-later | DST-compressed SACD audio | [`Packages/VespertineKit/Sources/CVespertineDTS/vespertine_dst.c`](Packages/VespertineKit/Sources/CVespertineDTS/vespertine_dst.c) |
| python-tidal (Copyright (C) The Tidalapi Developers), ported to Swift | LGPL-3.0 | TIDAL sign-in, catalog, playback info and rate-limit rules (`VespertineTidal`) | https://github.com/tamland/python-tidal |
| TidalSwiftLib, parts ported to Swift | GPL-3.0 | TIDAL new releases and download retry timing (`VespertineTidal`) | https://github.com/melgu/TidalSwiftLib |

Versions are the ones in the app's lockfile, [`App/Package.resolved`](App/Package.resolved), which release builds are held to. The full license and copyright text of every component ships inside the app, in `Contents/Resources/Licenses` (from [`App/Licenses`](App/Licenses), including SFBAudioEngine's `ACKNOWLEDGMENTS.md` at the shipped version). The FFmpeg source the decoders are built from is attached to every GitHub release; the other LGPL libraries' sources are linked above, and the prebuilt ones come from SFBAudioEngine's `*-binary-xcframework` packages, whose repositories hold the build scripts.

The SFBAudioEngine dependencies ship as prebuilt xcframeworks and are embedded in `Contents/Frameworks`. Each is signed with Vespertine's identity.

## FFmpeg

Vespertine links a small, static build of FFmpeg 9.0.2, made from FFmpeg's unmodified release tarball (SHA-256 `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`) by [`scripts/build-dts-decoder.sh`](scripts/build-dts-decoder.sh), which verifies the checksum. The build uses `--disable-everything` and enables only these pieces:

- decoders: `dca`, `truehd`, `mlp`, `ac3`, `eac3`, `dsd_lsbf`, `dsd_msbf`, `dsd_lsbf_planar`, `dsd_msbf_planar`, `tak`, `flac`, `alac`, `aac`, `mp3float`, `vorbis`, `opus`, `wavpack`, `tta`, `ape`, `pcm_u8`, `pcm_s16le`, `pcm_s16be`, `pcm_s24le`, `pcm_s24be`, `pcm_s32le`, `pcm_s32be`, `pcm_f32le`, `pcm_f32be`, `pcm_f64le`, `pcm_f64be`
- parsers: `dca`, `mlp`, `ac3`, `tak`, `flac`, `aac`, `aac_latm`, `mpegaudio`, `opus`, `vorbis`
- demuxers: `dts`, `dtshd`, `truehd`, `mlp`, `ac3`, `eac3`, `matroska` (which also reads WebM), `dsf`, `iff`, `tak`
- libraries: `libswresample`, which FFmpeg's Opus decoder needs
- the xHE-AAC (USAC) support is part of FFmpeg's `aac` decoder; macOS plays xHE-AAC itself
- protocol: `file`

It is built without `--enable-gpl` or `--enable-nonfree`, so it stays LGPL. To use your own FFmpeg build, run the script and it regenerates `Packages/VespertineKit/Vendor/FFmpegDCA.xcframework`; then rebuild Vespertine as described in the README.

## WavPack with DSD

SFBAudioEngine's prebuilt WavPack is compiled without DSD support, so [`scripts/build-wavpack-dsd.sh`](scripts/build-wavpack-dsd.sh) builds libwavpack 5.8.1 from WavPack's unmodified release tarball (SHA-256 `7322775498602c8850afcfc1ae38f99df4cbcd51386e873d6b0f8047e55c0c26`, BSD-3-Clause, Copyright (c) David Bryant) with `ENABLE_DSD`, static and universal, into `Packages/VespertineKit/Vendor/WavPackDSD.xcframework`. Every global symbol is renamed with a `vtwv_` prefix at compile time so it can't be confused with the WavPack in SFBAudioEngine. Its licence text ships in the xcframework and as `WavPack.txt`.

## DST decoder

SACD images often store their audio compressed with DST (Direct Stream Transfer, ISO/IEC 14496-3 subpart 10). FFmpeg's DST decoder only puts out PCM, which can't go to a DAC as DoP, so [`vespertine_dst.c`](Packages/VespertineKit/Sources/CVespertineDTS/vespertine_dst.c) is a copy of it (from FFmpeg's `libavcodec/dstdec.c`, by Peter Ross) that returns the decoded DSD instead. It stands alone, with its own bit reader in place of FFmpeg's internal one, and rejects frames that can't be valid instead of decoding them. The file says what was changed and when. It keeps FFmpeg's license, the LGPL 2.1 or later (its text ships as `FFmpeg-LGPL-2.1.txt`), and is compiled from source with the rest of Vespertine. The SACD image layout (Master TOC, area TOCs, audio sectors) follows the Scarlet Book as documented by the open-source [SACD Ripper](https://github.com/sacd-ripper/sacd-ripper) project; Vespertine's reader is its own code, and none of SACD Ripper's is included.

## Trademarks

Dolby, Dolby Atmos, Dolby Digital, Dolby Digital Plus and Dolby TrueHD are trademarks of Dolby Laboratories. DTS, DTS-HD Master Audio and DTS:X are trademarks of DTS, Inc. Apple, AirPods, AirPods Max and Spatial Audio are trademarks of Apple Inc. Vespertine names these formats and products only to describe what it plays. It is not certified, licensed or endorsed by Dolby, DTS or Apple, and it does not use their logos.
