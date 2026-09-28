`dts-cd-tones.wav`: 2.5 s of synthesized 5.1 test tones (L 440 Hz, R 550, C 660, LFE 60, Ls 770, Rs 880),
encoded to DTS at 768 kb/s with FFmpeg's `dca` encoder (the sines were joined without an explicit map, which
rotates the front three, so they were fed C, L, R; FFmpeg's decoder confirms L 440, R 550, C 660), each frame padded to the DTS-CD frame size
(1792 bytes) and packed into 14-bit words stored as 16-bit / 44.1 kHz stereo PCM, exactly like a DTS CD:
one 512-sample DTS frame per 512 WAV frames (216 frames, 110,592 WAV frames).

`dolby-digital-tones.ac3`, `dolby-digital-plus-tones.ec3`, `dolby-digital-plus-tones.m4a`: 1.5 s of the same
5.1 tones at 48 kHz (joined with an explicit map: FL 440, FR 550, FC 660, LFE 60, SL 770, SR 880), encoded with
FFmpeg's `ac3` / `eac3` encoders at 384 kb/s; the M4A holds the same E-AC-3 stream in MP4.

`dts-tones.dts` / `dts-tones.mka`: 1 s of the 5.1 tones (explicit map) as a raw DTS stream (FFmpeg `dca`, 768 kb/s)
and the same stream in Matroska with title/artist/album tags. `truehd-tones.thd` / `truehd-tones.mka`: the same
tones as 24-bit 48 kHz Dolby TrueHD (FFmpeg's experimental `truehd` encoder), raw and in Matroska;
`truehd-source.flac` is the 24-bit PCM they were encoded from (TrueHD is lossless, so decoding must match it exactly).
