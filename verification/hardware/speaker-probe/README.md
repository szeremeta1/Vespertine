# Speaker probe

A small test app for tests A and B in [docs/NETWORK-SPEAKERS.md](../../../docs/NETWORK-SPEAKERS.md). It isn't part of Vespertine. It plays channel-identification signals and shows what the system reports about the output. Each channel plays a 1.5-second burst in turn, twice round, while the screen names the speaker that should be sounding. The signals are 2.0 at 44.1, 48 and 96 kHz, 5.1 and 7.1, all at about -20 dBFS.

**Turn the volume down before the first signal.**

## Build

```bash
brew install xcodegen
cd verification/hardware/speaker-probe && xcodegen && open SpeakerProbe.xcodeproj
```

- **SpeakerProbeTV** runs on an Apple TV 4K.
  - Pick your team under Signing & Capabilities.
  - Pair the Apple TV with Xcode: on the Apple TV, Settings › Remotes and Devices › Remote App and Devices; then in Xcode, Window › Devices and Simulators.
  - Pairing needs the Mac and the Apple TV on the same network with device-to-device traffic allowed. Many dorm and campus networks block that, so a phone hotspot or a small travel router both join may be easier.
  - If direct install isn't possible, TestFlight works over any network, but needs a paid developer membership.
  - The app doesn't sign in to or change anything on the Apple TV. Ask whoever owns it anyway.
- **SpeakerProbeMac** runs on the Mac.

## Test B: surround from an app on an Apple TV

The question: when a third-party app plays multichannel PCM on an Apple TV whose audio output is HomePods, do the HomePods play it as surround, or fold it to stereo first?

1. Note the Apple TV model and tvOS version (Settings › General › About), the HomePod models, and Settings › Video and Audio › Audio Format.
2. **Baseline:** with the TV or a soundbar over HDMI as the output, play each signal. Photograph the readout while 5.1 and 7.1 play.
3. **HomePods:** set Settings › Video and Audio › Audio Output to the HomePods (a stereo pair, or four HomePods on the new Apple TV 4K). Repeat step 2.
4. For each signal, write down where each burst seems to come from.

What to record from the readout, during playback:
- Output channels and the route maximum
- Rendering mode
- Each output port's name, type and channel labels

**Pass:** with HomePods as the output, 5.1 and 7.1 report 6 or more output channels or a rendering mode other than mono / stereo. Listening should agree:
- With four HomePods, the surround bursts come from the rear pair.
- With a stereo pair, they sound wider than, or behind, the left and right bursts, and the centre sits between the speakers.

**Fail:** 2 channels and mono / stereo rendering, with the surround bursts coming out of the left and right speakers like the fronts. Then a tvOS Vespertine can't do surround on HomePods with multichannel PCM, and only Dolby Digital Plus (Atmos) would be left to try.

## Test A: what a Mac sends over AirPlay

1. Set up Shairport Sync 5.6 or later in AirPlay 2 mode on another machine, following its [AIRPLAY2.md](https://github.com/mikebrady/shairport-sync/blob/master/AIRPLAY2.md). Use a Raspberry Pi or another Mac rather than a VM unless the output is `stdout` or a pipe.
2. Run it with verbose logging (`-vv` or more) and look for the lines naming each stream's type and format.
3. In SpeakerProbeMac, choose the receiver with the AirPlay button. That routes only the probe's own AVFoundation player, not the system output. Play each signal and copy the log lines.
4. Select the same receiver as the Mac's system output (Control Centre › Sound). Play the same files in Vespertine and copy the log lines. The probe writes them as `speaker-probe-*.caf` to its temporary folder, which `open "$TMPDIR"` shows; any 24-bit / 48 kHz and 5.1 files also work.
5. For comparison, play a lossless track from the Music app.

The result to report is a table with three rows: probe, Vespertine (system output) and Music. For each, give the stream type (realtime or buffered), codec (ALAC or AAC), bit depth, sample rate and channels for each signal.
