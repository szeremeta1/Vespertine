# PLAN: Spatialize Stereo (B)

*Vespertine · Thursday 5 November 2026 · branch `feat/stereo-spatialize` (on top of `feat/spatial-verify`)*

## What it does

An opt-in, per-output switch, **Spatialize stereo**, off by default (Alex, 11-05: originals stay the default). When it's on, a stereo or mono track (FLAC, WAV, ALAC, AAC/MP3, DSD, anything Vespertine decodes) is upmixed to 5.1 and then takes the path a real 5.1 file already takes on that output:

| Output | With the switch on | With it off (today) |
|---|---|---|
| AirPods / Beats with Spatial Audio on (Fixed or Head Tracked) | 5.1 upmix, then Apple's spatial mixer on the 5.1 bed, head tracked if the output's mode is Head Tracked | stereo, untouched |
| Multichannel output, no speaker setup (≥ 6 outputs) | 5.1 upmix to outputs 1–6 in standard order | stereo on outputs 1–2 |
| Configured speaker setup (receiver, Configure Speakers, ≥ 3 speakers) | 5.1 upmix placed by speaker (a 7.1 room: back pair silent; a quad room: centre equal-power on L and R) | stereo on L and R |
| Stereo output with Spatial Audio off | nothing changes: there's nowhere to put the extra channels | — |

One upmixer feeds both destinations, so headphones and speakers get the same centre and ambience, and everything downstream (bed routing, the spatial mixer, head tracking, speaker maps, folds) is the code that part A just verified.

## The upmixer (algorithm)

A frequency-domain primary/ambient decomposition, after Avendano & Jot ("A frequency-domain approach to multichannel upmix", JAES 52(7/8), 2004), made downmix-safe:

1. **STFT.** Frame length N = 2048 at 44.1/48 kHz, scaled with the rate (4096 at 88.2/96, 8192 at 176.4/192, 16384 at 352.8/384) so every frame is about 43 ms. Hop N/4, √Hann analysis and synthesis windows (weighted overlap-add, exact reconstruction when nothing is changed).
2. **Per-bin statistics**, smoothed over time (τ ≈ 40 ms): Φ_LL, Φ_RR and Φ_LR.
3. **Centre.** In-phase coherence φ⁺ = max(0, Re Φ_LR) / √(Φ_LL Φ_RR). The common magnitude is m = φ⁺ · √min(Φ_LL, Φ_RR). The centre bin is m with the phase of L+R. L′ = L·(1 − m/√Φ_LL) and R′ = R·(1 − m/√Φ_RR), so nothing is phase-inverted and a hard-panned source never reaches the centre. The centre output is √2 · centre:
   - **downmix-safe:** under the ITU fold (L′ + 0.707·C) the original L returns for coherent material;
   - **power-preserving:** a phantom centre becomes a real centre at the same power.
4. **Ambience** is the decorrelated part present in *both* channels: a = √(min(Φ_LL, Φ_RR) · (1 − φ²)). The surround feeds are Ls = g_s · (a/√Φ_LL) · L and Rs = g_s · (a/√Φ_RR) · R, then delayed (Ls 12 ms, Rs 15 ms, to decorrelate the pair and keep the front image in front). A dry, hard-panned source makes no ambience. Reverb and room tone do. The fronts keep their ambience: the surrounds add to it, they don't take it away.
5. **LFE** is a 4th-order 120 Hz low-pass of the mono sum at a set gain. **Off by default**, as in Pro Logic II and Neo:6: receivers bass-manage the mains, and an extracted LFE doubles the bass.
6. **Mono** goes in as L = R: everything is coherent, so it all lands on the centre (√2, same power) with no ambience. A mono recording plays from in front of you, as Apple's Spatialize Stereo does.
7. **Latency** (N samples) is compensated inside the upmixer: the first N output frames are dropped and the tail is flushed with zeros at the end of the song. Output frame n is input frame n and the length is unchanged, so positions, gapless joins, seeks, crossfades and the end-of-queue drain all stay as they are.

It runs on the decode thread, seconds ahead of the I/O thread, like BedRouter does today: no FFT on the real-time thread. Cost is about 7 FFTs per hop (2 forward, 5 inverse). At 48 kHz that's roughly 650 FFTs of 2048 points a second with vDSP, negligible.

**Creative parameters are Alex's call.** Built with these defaults and kept as named constants: ambience g_s = −6 dB, centre strength 100 %, LFE off, surround delay 12/15 ms. Options to try by ear:
- ambience at −3, −6 or −9 dB;
- centre extraction full, or partial (75 %) for a wider front;
- LFE off, or at −10 dB;
- on AirPods, a "virtual stereo speakers only" style: stereo on a stereo bed, no upmix, the closest to Apple's own Spatialize Stereo.

## Engine integration (all gated by one plan flag)

- `EngineSettings.spatializeStereoUIDs: Set<String>` (per output, empty by default) and `spatializesStereo(for:)`.
- `FormatPlanner.plan(…, spatializeStereo: Bool = false)`. Applies only when the source has 1 or 2 channels, is PCM or DSD, and the output has a destination: Spatial Audio on, a speaker setup of 3 or more, or 6 or more outputs. It then sets `plan.upmix = true` and `channels = 6` (with `spatialBed` = 5.1 for headphones), or the setup's speakers, or `routeLabels` = 5.1. DSD goes to PCM first, as for room correction.
- `Decoding`: the converter keeps the source's own 1 or 2 channels, then `StereoUpmixer` produces 5.1, then BedRouter (when the output layout isn't plain 5.1) puts it on the setup's speakers. Then the ring, as now.
- Integer mode, "Match 16-bit sources" and DoP already require the plan's channels to equal the source's, so they turn off by themselves. The signal path shows "Stereo spatialized: upmixed to 5.1 …" and never claims bit-perfect.
- Room correction filters for 2 channels don't apply to a 6-channel plan, so they're bypassed and reported as bypassed (existing behaviour for multichannel).
- With the switch off, every plan is byte-identical to today's. That's proved by the golden PCM hashes and a planner property test across device and source shapes.

## UI

The output popover (TransportBar), under the Spatial Audio picker: a toggle **Spatialize stereo**, with one line of help per output type. That's 3 new strings, each needing all 44 shipped languages (`scripts/check-localizations.py` enforces this).

## Tests

- **Upmixer, offline:**
  - centre-panned tone → C only (everything else ≤ −40 dB), at +3 dB amplitude (equal power);
  - hard-left tone → L only, with no C and no surround;
  - uncorrelated noise → surrounds at g_s, no C;
  - anti-phase → no C;
  - the ITU fold of the output returns the input within −40 dB for coherent panned material;
  - an impulse comes out at the same frame, and the length is unchanged;
  - mono → C only.
- **Planner:** every output type with the switch on and off, and the switch off is identical to today for a matrix of sources and devices.
- **Engine, offline (GoldenRender path):** a stereo FLAC to a 16-channel output gives 6 outputs (C carrying the centre tone), the rest silent. To AirPods: the 5.1 bed, spatial, two channels out.
- **Live (opt-in):** BlackHole 16ch, the upmix on outputs 1–6, and on the binaural pair with Spatial Audio.

## Risk to 1.0 (Wednesday 11 November)

- **Default path:** low by construction. It's off by default and gated by one plan flag, and the golden hashes guard it.
- **Shipping it on in 1.0:** medium to high.
  - It's a new DSP block whose quality can only be judged by listening. I can't listen on dormhub (muted, no headphones), and tuning is Alex's call.
  - It touches FormatPlanner, Decoding, EngineSettings and the output popover, five days before launch, with rc2 already built.
  - The 44-language strings need a review pass.
- **Recommendation:** build it fully on its branch and keep it PR-ready, but **park it for 1.0.1**. Part A's fixes are the 1.0 priority.

## Effort

Upmixer and its tests about 4–5 h; planner and engine about 3 h; UI and localisation about 2 h; live check about 1 h. Total about 10–11 h of agent time, plus Alex's listening session to set the defaults.
