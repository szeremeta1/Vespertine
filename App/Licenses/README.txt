Licenses of the components bundled with Vespertine

Vespertine itself is under the GNU GPL, version 3 or later (LICENSE, beside this folder). The components it bundles
are listed in THIRD-PARTY-NOTICES.md; this folder holds their full license and copyright texts, as each license asks
for copies distributed in binary form:

- SFBAudioEngine-ACKNOWLEDGMENTS.md: SFBAudioEngine's own notices for the libraries it builds on (dsd2pcm, FLAC,
  Monkey's Audio, Musepack, mpg123, Speex, TagLib, Ogg, Vorbis, WavPack, DUMB, libsndfile, TTA, Opus, LAME), with
  their license texts.
- One file per package, taken from that package's repository at the version Vespertine ships (App/Package.resolved).
- FFmpeg-LGPL-2.1.txt: the license of the FFmpeg decoders built by scripts/build-dts-decoder.sh, and of the DST
  decoder for SACD images taken from FFmpeg's (Packages/VespertineKit/Sources/CVespertineDTS/vespertine_dst.c).

Sources of the LGPL components are linked from THIRD-PARTY-NOTICES.md; the FFmpeg source is attached to each GitHub release.
