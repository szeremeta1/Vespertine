# Transitions

Crossfades between songs, Smart Mix (a transition chosen for each pair of songs), gaps, and fades around play, pause, stop, skip and seek. Off by default. One switch turns it all on or off: Controls › Transitions (⌥⌘X), the transport bar (its menu: style and length), the Up Next header, the menu bar window, the mini player, Settings › Playback › Transitions, and Shortcuts ("Turn Transitions On or Off", "Choose Transition Style").

## Off is off

With the switch off, playback is exactly what it was before transitions existed: the same code path and the same bytes. The engine only takes transitions' settings while the switch is on (`AppSettings.engineSettings()` passes the defaults otherwise), and every new branch in the engine needs the switch on, or a ramp or overlap it created.

The proof is the golden PCM tests (`Packages/VespertineKit/Tests/VespertineAudioTests/GoldenPCMTests.swift`): 23 hashes of what the engine hands the device, recorded before any engine change, rendered through the engine's own `Decoding` and the real ring and I/O stage. They still hold with transitions off. With transitions on, 21 of the 23 are still byte for byte the same; the other two are the cases built to have a transition (a rate change and two unrelated songs).

## What happens at a boundary

The engine plans the end of each song while its last crossfade + 16 seconds are decoded. `TransitionPlanner.decide` picks one of these, in this order:

| Situation | Result |
|---|---|
| Switch off | Gapless, as before |
| Native DSD (DoP), bitstream (Dolby/DTS to a receiver), Dolby Atmos rendered by macOS, integer mode, or a 16-bit word ("Match 16-bit sources") on either side | No transition: never mixed or faded |
| The next region of the same file (CUE sheet, DVD title) or SACD area | Gapless |
| The next track of the same album (the next number, or track 1 of the next disc), playlists included | Gapless |
| A song of an excluded genre on either side (Classical, Opera, Soundtrack, Spoken Word by default) | Gapless |
| The playlist the songs were queued from plays without transitions (its own setting) | Gapless |
| The next song is read live from a network share | Gapless |
| The next song needs another rate or channel count | A dip: the last second fades out, the output is set up again (the short gap there is anyway), the next song's first second fades in. With "transitions first", a PCM song at another rate is resampled to the one playing instead, and blends |
| A gap is set (0–10 s) | That much silence between the songs, each whole and untouched |
| Anything else, Crossfade | A crossfade of the chosen length (1 to 12 s, 6 by default) and curve |
| Anything else, Smart Mix or Live Set | Smart Mix's choice for the two songs (below) |

A playlist can have its own transitions (its menu in the sidebar): the app's setting, off, a crossfade of a length, Smart Mix or Live Set. The master switch still rules: off, a playlist's choice changes nothing.

Curves: equal-power (sin/cos, constant power, the default), linear (constant amplitude, about 3 dB quieter mid-fade on unrelated songs), S-curve (a raised cosine: gentle at both ends).

Silence is trimmed (on by default): the outgoing song's last 15 s and the next song's first 10 s are scanned for sound above −60 dBFS, so the crossfade ends where the music ends and the next song starts at its first sound. A crossfade never takes more than half of the next song, and never reaches back over audio already buffered.

## Smart Mix

Each song's ends are measured (`TransitionAnalyzer`, `VespertineAnalysisCore`, plain Swift so `vespertine-analyze` makes the same profile on a server): the silence at each end, a fade-in or fade-out (the best "steady, then a straight line in dB" split over 30 s, at least 10 dB over 3 s, with a confidence), the loudness (ITU-R BS.1770-4) of the ten seconds of music next to each end and of its first or last second, and the end's type: cold, fade, silence, or segue (loud to the last sample, or from the first). Where the beat is steady, its tempo and one beat's time are kept too (used from Live Set on, not yet). The library computes the profile in the same pass as file analysis and keeps it (`transitionProfile`, made stale by a changed file or analyzer); a server's index carries it; a song with none is measured just in time from its last 40 s and its next song's first 20 s (`EdgeScan`).

`SmartMixPlanner` then chooses, for the end of A and the start of B:

| A ends | B starts | Transition |
|---|---|---|
| fading out (confidence 0.6 or more) | anything | B starts inside A's fade, the overlap as long as the fade (2–12 s); A plays at its own level, B rises over half the overlap unless it starts quietly |
| segue | segue | Gapless: the songs run into each other |
| with silence, or B starts with silence | | The silence trimmed, then a 1 s blend |
| cold or segue | fading in | The silence trimmed, a 1 s fade of A over B's own fade-in |
| cold or segue | cold or segue | A quick cut: 0.5 s, B rising over 0.1 s |
| unsure (no profile, or a fade confidence of 0.3–0.6) | | A plain crossfade of the chosen length and curve |

Loudness: over the overlap, A goes from its own level to *m* dB down and B from *m* dB up to its own, *m* being A's level less B's (ReplayGain included) within ±6 dB, so the two sound at one level throughout and each is at its own where it plays alone. A lookahead limiter (5 ms ahead, 50 ms release, ceiling −0.3 dBFS) catches peaks two loud songs make together; it touches only overlap frames, and passes frames that need nothing untouched. Live Set is Smart Mix with skips that always blend.

## Where it happens

```
ENGINE THREAD (20–30 s ahead of what's heard)
deck A: decoder → converter → ReplayGain ─┐
                                           ├─ crossfade (or a dip's ramp) ─▶ ring
deck B: decoder → converter → ReplayGain ─┘

I/O THREAD
ring ▶ room correction ▶ FIR ▶ EQ ▶ gain × fader ▶ dither ▶ DAC
```

- The mix is on the engine thread, before the ring, where ReplayGain already is (`TransitionMixer.swift`). ReplayGain stays per song. Equalizer, room correction and digital volume act on the mixed signal, after the ring. Frames outside an overlap or ramp are passed on untouched: not multiplied by 1, their exact bits.
- Mixed frames get TPDF dither at the device's word length when nothing after the ring dithers (an integer DAC at unity gain, no EQ or room correction).
- The fader for play, pause, stop, skip and seek is in the real-time gain stage (`nrt_context_fade` in `vespertine_rt.c`). Idle, it isn't entered, so the copy path stays a copy. It never scales native DSD, bitstream or integer words.

## Fades around what you do

| Action | With transitions on |
|---|---|
| Play, resume, seek | Fades in over 0.25 s |
| Pause, stop | Fades out over 0.4 s, then pauses or stops as before (the device is let go after the fade) |
| Skip | Fades out over 0.3 s ("quick fade", the default), cuts at once ("cut at once"), or crossfades into the next song ("crossfade"; always in Live Set) |

A skip's crossfade: the ring already holds the old song's next seconds. They're copied out from a quarter second ahead of what's heard (`nrt_ring_peek`), the ring is taken back to there (`nrt_ring_rewind`), and the copy is mixed with the new song's start, as long as the crossfade or what the ring holds. When it can't be (native DSD, bitstream or integer output, a song needing another format, one read live from a share, or one that doesn't open within 0.4 s), the skip is the quick fade.

Native DSD keeps its muted-DSD-silence pause; bitstream and integer output cut as before.

## Now Playing and the badge

- The next song becomes the one playing (Now Playing, history, scrobbles) at the middle of the crossfade.
- The signal path has a Transitions row: what the end of this song does ("Crossfade, 6 s, equal-power", "Gapless: same album", "No transition: native DSD"…), and while a crossfade or a dip's fade is heard, CROSSFADE (MIXING for Smart Mix and Live Set).
- Only while it's heard is the music not bit-perfect: the badge says CROSSFADE then, and goes back to BIT-PERFECT after. It stays at least 2 s so it doesn't flicker.
- The short real-time fades (play, pause, skip) don't change the badge.

## Transitions first

Settings › Playback › Transitions › "When a transition needs a change to the signal". **Bit-perfect first** (the default) never changes the output format for a transition. **Transitions first**, while the switch is on: a PCM song at another rate is resampled to the one playing when that lets it blend (its signal path says RESAMPLED); DSD plays as PCM (as room correction makes it); integer mode and Match 16-bit aren't used. The signal path's Transitions row says so. Turning it on or off while DSD, integer or 16-bit output plays reopens the output at the same place.

## Changes that reach a boundary already mixed

A crossfade is mixed 20–30 s before it's heard. A queue change, or a change to the switch or its settings, takes back a boundary that's planned but not yet in the buffer. One already mixed and not yet heard is rewound to where the overlap starts, and the outgoing song decoded again from there, when that gives exactly the same samples (lossless PCM at its own rate from a local file). Otherwise it plays as mixed and the change applies from the next boundary: the same rule as queue changes close to a boundary without transitions.

## Tests

- `TransitionPlannerTests.swift`: the curves (endpoints, identities, monotonic, symmetric), the album rule, every planner rule on both sides and their order, overlap placement, ramps, the silence thresholds, the dither, the signal path's verdict and badge, the settings the engine takes.
- `FaderTests.swift` and `tests/rt-audit.c`: the idle fader is bit-identical, ramp shapes, fade then mute, DoP/passthrough/integer bypass, commands from other threads under sanitizers.
- `TransitionGoldenTests.swift`: the 23 golden cases with transitions on; crossfades for each curve, trimming, a dip for each curve, checked sample by sample against references computed from the sources; albums, CUE sheets, genres and every cut byte-identical to off; six stored hashes (`Fixtures/golden-pcm-transitions.json`).
- `TransitionAnalysisTests.swift` (analysis package): EBU Tech 3341 cases 1–5 (case 1 at 44.1–192 kHz), 5.1 weights, exponential and linear fades, fade-ins, cold, segue and silent ends, a tail measured alone, chunking, click tracks at 90/120/128/174 BPM, noise.
- `SmartMixTests.swift`: every pair of end types, fade lengths, unsure fades, the loudness match, the gains, the limiter (transparent under the ceiling, never over it, smooth, the same in any chunking), playlist overrides, the gap and policy settings.
- `SmartMixGoldenTests.swift`: into a fade, a quick cut, trimmed silence, a stored profile, the limiter, checked sample by sample against references from the sources and the decision; a segue, a gap, a playlist set to off and every golden case with Smart Mix on byte-identical where nothing should mix; five stored hashes (`Fixtures/golden-pcm-smartmix.json`).
- `TransitionProfileStoreTests.swift`: profiles stored, made stale, imported from a server; a playlist's own transitions.
- `tests/rt-audit.c` `test_concurrent_peek`: peek and rewind while the reader runs, under the sanitizers. Harness mutants: a fade's gain left on (float), a float mix of integer words, a fade-in on DoP music.
- The loopback self-test forces transitions off.
