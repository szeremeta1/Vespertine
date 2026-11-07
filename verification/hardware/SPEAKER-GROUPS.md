# Speaker groups: hardware QA

For the next session with the Fosi ZD3 (leader), the FiiO K11 (follower, through the Cable Matters USB-over-Cat extender) and the UMIK-1. It checks what the automated tests cannot: what real DACs do. Nothing in the app has been listened to on a real group yet, so expect to find things; write them down as they are.

**Turn the amplifiers down first.** The tones are quiet (-20 to -30 dBFS) but a wrong setting can still play loudly.

Results go in `verification/hardware/speaker-groups/<timestamp>/` (the script makes it), one file per step and a `SUMMARY.md` to fill in. Commit what you want kept.

## What was found last time (2026-11-06, with a probe tool, not the app)

Aggregate with the Fosi as leader and the FiiO drift-corrected played a 4-channel file with 0 underruns, both DACs held, rates and holds restored afterwards. Start offset between the DACs: σ 21 µs over 19 good runs (the measurement's own noise is σ 32 µs), so a fixed delay can hold. Open: three of 49 drift-corrected runs came in about 3.5 ms (166 frames) late; the follower crept about 0.2 ms between 1.6 s and 15.6 s and had not flattened; Fosi against FiiO drift over 300 s was not measured; the Fosi has no hardware volume Core Audio can set, the FiiO has. Details: `verification/hardware/` of the wave 1 work, `FINDINGS.md`.

## Part 1: the probe steps (`scripts/speaker-groups-qa.sh`)

Needs a `vespertine-probe` built from `feat/speaker-groups-probe` with `fix/room-detector-earliest-arrival` merged. Run it **in a Terminal window on the Mac with the DACs**, not over ssh (the microphone permission is the running app's; over ssh macOS says "Microphone access is off"): `open -a Terminal scripts/speaker-groups-qa.sh` with the arguments in its header, or run it from a Terminal you opened yourself. Close other apps that use the DACs (a held DAC can't join; the info step says which).

```sh
scripts/speaker-groups-qa.sh --leader "Fosi Audio ZD3" --follower "FiiO K11" --mic UMIK --probe /path/to/vespertine-probe
```

| Step | What it checks | Pass looks like |
|---|---|---|
| info (read-only) | members, clock domains, rates, latency, who holds them | no BLOCKER lines; both DACs on the same rate |
| quad (H1) | both DACs held, the real engine plays a 4-channel file to the aggregate | 0 underruns; each tone (440, 554, 659, 880 Hz) only from its own speaker, by ear; rates and holds restored (`info` again) |
| control | the method's own noise (leader alone) | σ about 30 µs |
| h3 (H3) | start offset between the DACs over 20 restarts | σ under about 50 µs, no outliers; note any run about 3.5 ms (166 frames) late and the order they came in |
| h3nodrift | the same with drift correction off | similar to h3 (runs are short, so it can't show drift) |
| h4 (H4) | settle: offset against time since start, 1 to 120 s | the follower's offset flattens; record at what time and where. The 11-06 session only reached 15 s |
| h2 (H2) | the DACs' own drift against each other over 300 s | a ppm figure; if "reference not found", the probe's end-search window is too narrow: say so |

Read `H3` against the 0.25 ms tolerance of the geometry warning and the 15 s settle of the wizard: if the offset keeps moving after 15 s, those numbers are wrong.

## Part 2: the app (`speakerGroupsFeature` on)

Turn it on with `defaults write org.szeremeta.Vespertine speakerGroupsFeature -bool YES` and restart. Make the group (Fosi first, FiiO second, Fosi the clock leader), put the four speakers on the four channels, draw the room. Take a screenshot of anything odd.

| # | Do | Expect |
|---|---|---|
| A1 | With nothing playing, press Identify on each of the four channels | a quiet burst, three times, only from the speaker on that channel; with music playing, Identify says to stop playback and plays nothing |
| A2 | Play a stereo file, then a 4-channel file | stereo: front pair only, the badge says BIT-PERFECT if the Fosi is exclusive at the file's rate; quad: each speaker its own channel; the per-DAC rows say the FiiO is resampled; a rate change between songs does not wedge either DAC (H5: play 44.1, 96, 48 kHz songs back to back, skip around) |
| A3 | Mono on both front speakers, then tick Inverted on one | they cancel at the seat (the sound thins out and moves); untick: back to normal |
| A4 | Level trim +6 dB on one speaker, loud track | no clipping on either DAC; that speaker 6 dB above the others (UMIK or a meter app); the Room Correction window shows the lowered preamp; the badge says ROOM CORRECTION |
| A5 | Room Correction with the group as output: Use the Drawing | the profile is made and chosen; move a speaker in the editor: the profile follows (no new profile appears) |
| A6 | Measure the group with the wizard | the wizard names the group, counts 15 s before the first sweep, measures four speakers, timing tones from the Fosi; the saved profile fits the group; compare its delays with the drawing: the warning appears only if they disagree by more than 0.25 ms. Record the disagreements |
| A7 | Volume | a slider for the FiiO, none for the Fosi (expected from last time); the volume keys, and the Mac's volume, do nothing to the group; the group is not made the Mac's sound output; nothing changes a DAC's volume by itself |
| A8 | H6: unplug the follower mid-song, then the leader, then plug them back | with "pause": a fade, a pause naming the DAC, then a rebuild at the next play; with "carry on": the music folds onto the rest after a short mute; the leader lost always pauses; no stuck hold afterwards (`info` shows no hog) |
| A9 | Switch the group off, play a song on the Fosi alone | exactly as before (BIT-PERFECT as it was); nothing left behind: no aggregate in Audio MIDI Setup, no hog |
| A10 | H7: play for one hour | no underruns on the group, offset constant (repeat h3 at the end), CPU acceptable |

Also note: which sounds are wrong, which words are confusing, and anything that took more than two clicks.

## Reporting

Paste the step files' key lines and the A-table results into the `SUMMARY.md`, with the app version and macOS. Where a result differs from the expectation above, say what you saw, not what you think it means.
