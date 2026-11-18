# Vespertine Remote for iPhone and iPad: after 1.0 (7)

What changed in the iPhone and iPad app after TestFlight build 1.0 (7), from the feedback sent on that build. The iPhone and iPad app is a separate download and ships on its own schedule; this file is not a Mac release.

## Changes

- The volume the app shows for this device is read from iOS whenever the output may have changed (a DAC plugged in or unplugged, another output chosen, the app coming back to the front, a song starting), not only when iOS announces a change. It no longer shows a level from before the DAC was connected. A level iOS hasn't reported is shown as "Not reported by iOS", never as a number.
- While a DAC is being switched to a song's sample rate, the signal chip says "switching to 96 kHz…" and the Output screen says what was asked for. The old rate is no longer shown as if the DAC had settled on it. If iOS never gives the rate, the app shows the rate the DAC runs at and says the song is resampled by iOS.
- With the volume below 100% on a DAC, the Output screen's "Original file" row says "Changed by the volume (below 100%)", and the chip still shows the volume.
- The DoP test asks "What did you hear?" with four answers: Music, Hiss or noise, Heard nothing, Play again. Hearing nothing is no longer recorded as hiss and never turns DoP off for a DAC. The rate is named as the DAC's display names it: "DSD128 (384 kHz carrier)". A second of DSD silence now comes before the chord, so a DAC has time to lock onto DSD.
- The DoP test no longer needs the volume at 100%. It runs at any volume. On a DAC whose volume is set on the DAC, the chord heard below 100% shows that the phone's volume changes nothing it receives; from then on the app says "Volume is set on the DAC" for it and sends DSD as DoP at that level. Hiss heard below 100% proves nothing and saves nothing.
- A DSD song being made ready for a DAC that passed the test says "Preparing DSD for your DAC (DoP)…". "Converting DSD to PCM…" appears only when the song really is converted, and a DSD song played as PCM says why.
- Surround songs on AirPods and Beats are handed to iOS whole, so iOS's own Spatial Audio renders them. Surround on Headphones is now Off or Spatial Audio; Fixed or Head Tracked is chosen in Control Center, as with Apple Music. The badge says SPATIAL AUDIO only when iOS reports it.
- Tapping a song in a playlist plays that song and carries on from there. Playlists have Play and Shuffle, a song count and a length, and long playlists load a page at a time.
- The flat album cover shows for songs with large covers. Tapping the cover switches between the cover and the record; the button is gone, and the choice is remembered.
- Letting go of the position slider seeks, also after a tap on the track or a VoiceOver adjustment, and the knob stays where it was put until the player gets there.

## Verification

Tests: the package tests (`swift test --package-path Packages/VespertineRemoteKit`) on Linux and macOS, and the app's tests for the Output report, the volume slider, the scrubber, song taps and playlists on an iPhone SE simulator. All 44 languages carry the new words.

None of the changes above was run on an iPhone with a DAC or AirPods before this file was written. Unverified, and listed as bench rows in [docs/IOS-AUDIO-BENCH.md](../IOS-AUDIO-BENCH.md):

- What iOS reports as the volume of a FiiO K11 and a Fosi ZD3, and whether the phone's volume buttons move it (B16).
- Whether the app's rate agrees with each DAC's display within a second, song after song (B7).
- The DoP test on each DAC: what was heard and what the display showed at each rate, five runs each, with the new lead-in (B8).
- Surround on AirPods Max through iOS's Spatial Audio (B4).
- The position slider on a real phone: the reported fault could not be reproduced in tests or on the simulator, so the change is a hardening of the slider, not a confirmed fix.

No bit-perfect claim is made for the phone. "ORIGINAL FILE · NO PROCESSING" and "VERIFIED ON THIS DAC" keep the rules in [docs/REMOTE-STREAMING.md](../REMOTE-STREAMING.md).
