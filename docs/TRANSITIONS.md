# Transitions

Crossfades between songs, and fades around play, pause, stop, skip and seek. Off by default. One switch turns it all on or off: Controls › Transitions (⌥⌘X), the transport bar, the Up Next header.

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
| The next song is read live from a network share | Gapless |
| The next song needs another rate or channel count | A dip: the last second fades out, the output is set up again (the short gap there is anyway), the next song's first second fades in |
| Anything else | A crossfade of the chosen length (1 to 12 s, 6 by default) and curve |

Curves: equal-power (sin/cos, constant power, the default), linear (constant amplitude, about 3 dB quieter mid-fade on unrelated songs), S-curve (a raised cosine: gentle at both ends).

Silence is trimmed (on by default): the outgoing song's last 15 s and the next song's first 10 s are scanned for sound above −60 dBFS, so the crossfade ends where the music ends and the next song starts at its first sound. A crossfade never takes more than half of the next song, and never reaches back over audio already buffered.

Smart Mix and Live Set crossfade like Crossfade for now; their analysis comes later.

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
| Skip | Fades out over 0.3 s ("quick fade", the default), or cuts at once when Skip is set to instant |

Native DSD keeps its muted-DSD-silence pause; bitstream and integer output cut as before.

## Now Playing and the badge

- The next song becomes the one playing (Now Playing, history, scrobbles) at the middle of the crossfade.
- The signal path has a Transitions row: what the end of this song does ("Crossfade, 6 s, equal-power", "Gapless: same album", "No transition: native DSD"…), and while a crossfade or a dip's fade is heard, CROSSFADE (MIXING for Smart Mix and Live Set).
- Only while it's heard is the music not bit-perfect: the badge says CROSSFADE then, and goes back to BIT-PERFECT after. It stays at least 2 s so it doesn't flicker.
- The short real-time fades (play, pause, skip) don't change the badge.

## Changes that reach a boundary already mixed

A crossfade is mixed 20–30 s before it's heard. A queue change, or a change to the switch or its settings, takes back a boundary that's planned but not yet in the buffer. One already mixed and not yet heard is rewound to where the overlap starts, and the outgoing song decoded again from there, when that gives exactly the same samples (lossless PCM at its own rate from a local file). Otherwise it plays as mixed and the change applies from the next boundary: the same rule as queue changes close to a boundary without transitions.

## Tests

- `TransitionPlannerTests.swift`: the curves (endpoints, identities, monotonic, symmetric), the album rule, every planner rule on both sides and their order, overlap placement, ramps, the silence thresholds, the dither, the signal path's verdict and badge, the settings the engine takes.
- `FaderTests.swift` and `tests/rt-audit.c`: the idle fader is bit-identical, ramp shapes, fade then mute, DoP/passthrough/integer bypass, commands from other threads under sanitizers.
- `TransitionGoldenTests.swift`: the 23 golden cases with transitions on; crossfades for each curve, trimming, a dip for each curve, checked sample by sample against references computed from the sources; albums, CUE sheets, genres and every cut byte-identical to off; six stored hashes (`Fixtures/golden-pcm-transitions.json`).
- The loopback self-test forces transitions off.
