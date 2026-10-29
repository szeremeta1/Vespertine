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

`umik-synthetic.txt` / `umik-synthetic_90deg.txt`: synthetic calibration files laid out like a miniDSP UMIK-1 download
(serial 0000001, made up), 0° and 90°: a quoted `Sens Factor` / `SERNO` header line (the 90° file adds a second quoted
comment line), CRLF line endings, a trailing blank line on the 0° file, and 615 tab-separated frequency (Hz) and level
(dB) rows from 10.054 Hz to 20016.816 Hz. The levels are a smooth made-up curve; the 90° file falls about 2 dB more at
15 kHz. No real microphone's data is in the repository.

`room-zd3-umik-impulse.wav`, `room-umik-noise.wav`, `room-umik-start-transient.wav`: 48 kHz mono float32, cut from the
first real room measurement (29 October 2026, Fosi Audio ZD3 USB DAC, UMIK-1, one speaker). The impulse response (8448
samples, 256 before its peak, last 2048 faded) was recovered from a route-check sweep at that run's volume by regularised
deconvolution over 40 Hz-20 kHz, using only the sweep and the second timing tone; the real arrival was 3859 samples
(80 ms) after playback started. The noise is 0.25 s of the microphone with nothing playing (about -63 dBFS rms, mostly
below 200 Hz); the start transient is the first 0.25 s of a capture, the thump the UMIK-1 records as its stream starts
(peak -31 dBFS). No speech or other room sound is audible in them.
