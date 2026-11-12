# Mac Sound Output (beta)

A [speaker group](SPEAKER-GROUPS.md) shown as an output of the Mac, under the name you gave it, so any app can play to it: a browser, the TV app, Plex, IINA, VLC. The volume keys set its volume, and it plays with Vespertine open or closed. This is a beta. It is off by default, every group is off until you turn it on, and with nothing turned on nothing about the Mac's sound changes.

**Status.** The routing, the stereo choices, the upmix, the snapshot and the driver's ring and layout code are covered by automated tests (the driver's under the address and undefined-behaviour sanitizers, and through the static analyzer). Not yet tested on real DACs from the app; see [What is not verified](#what-is-not-verified).

## Turning it on

Settings › Playback › **Mac Sound Output (beta)** appears while Speaker Groups (beta) is on and at least one group is saved.

1. **Audio driver.** "Install…" copies Vespertine's audio driver from inside the app to `/Library/Audio/Plug-Ins/HAL/VespertineSound.driver`. That needs an administrator's password, and the Mac's sound stops for a moment while macOS restarts its audio server. "Update…" appears when the app carries a newer driver than the one installed; "Remove…" turns every group off, then deletes the driver and restarts the audio server again.
2. **A switch per group.** Turning a group on makes it an output named exactly as the group is named. A group with a problem (a DAC missing from the Mac, a channel map that doesn't add up) can't be turned on until it is fixed.
3. **Channels it offers.** What the output tells other apps it has: Automatic (from the group's speakers), Stereo, Quad, 5.1, 7.1, 7.1.4 or 9.1.6. An app sends what the output offers; the channels are then placed on the group's speakers by where they stand, as music is. Automatic offers 7.1 for any surround group without heights, a quad included: a 5.1 file names its surrounds either as side (Ls Rs, as films do) or as rear (Rls Rrs, as most 5.1 WAV files do), macOS drops surrounds the output has no channel for, and 7.1 has both pairs. 7.1.4 or 9.1.6 for groups with heights.
4. **Stereo from other apps.** See below.
5. **Show in the menu bar.** Off by default. A small menu that lists the published groups and their state; choosing one makes it the Mac's sound output.

Choose the group in System Settings › Sound, in the menu bar's Sound menu, or with Option-click on the volume icon, as any output.

## The helper

What other apps send is played by **Vespertine Sound Helper**, a small app inside Vespertine with no window or Dock icon. It is registered as a background item only while a group is on, so it runs with Vespertine closed and after a restart, macOS starts it again within a few seconds if it ever ends, and it is unregistered when the last group is turned off. After an update it is registered again, so the new helper takes over.

- **Login Items.** macOS may ask you to allow it in System Settings › General › Login Items (it is listed under Vespertine); Vespertine's settings say so and open that pane.
- **The microphone prompt.** The first time a group plays, macOS asks whether Vespertine may use the microphone (macOS asks for Vespertine, since the helper is part of it). The driver hands the helper what apps play as an audio input, which macOS counts as recording. The helper reads only that input, never a microphone. Refusing means the group stays silent.
- **Idle.** The group's DACs are taken only while an app plays to the output, and let go 30 seconds after it stops.

## How it plays

- **A driver output, and a private aggregate behind it.** Each published group is a Core Audio output (up to 8 of them, up to 16 channels each) with a hidden input on the same clock. The helper builds a private aggregate of that input and the group's DACs, with the group's clock leader leading, and copies what arrives to the speakers each I/O cycle.
- **As music plays on the group.** The channels are routed by position, and the group's delays, level trims, polarity and room correction are applied, as for Vespertine's own playback.
- **The volume keys.** The output has a volume (‑64 to 0 dB) and a mute that the volume keys, the Sound menu and the Control Centre slider drive, applied in the driver. The DACs' own volumes are not touched.
- **Rate.** The output follows the rate the app asks for when the group's DACs can run at it, and otherwise 48 kHz, then 44.1 kHz.
- **Not bit-perfect.** This path is for films, video and the web. The volume and the routing change the samples; for music, play the group from Vespertine.
- **Latency.** The output tells apps how far behind it plays (the DACs' own latency, a few buffers of safety, and the upmix when it is used), so video players keep the picture in step. The status line shows it while the group plays.

## Stereo from other apps

Most websites send stereo; the TV app and players such as IINA and VLC send 5.1 or 7.1 when the output offers it. Stereo can play three ways:

- **As the group plays music** (default): the group's own stereo setting (front pair only, mirrored to the back, and so on).
- **Extended stereo:** left on every speaker on the left, right on every speaker on the right, as a receiver's all-channel stereo.
- **Upmixed to surround:** the stereo is upmixed to 5.1 (a centre from what both sides share, the surrounds from the ambience) with the same upmixer as Spatialize, then placed on the group's speakers. It adds about 64 ms at 48 kHz (the upmixer's 1536 frames plus the buffers that keep it fed), which is included in the latency apps are told and shown in the status line. The surrounds carry the ambience of the recording: music, a film's sound or a live room reach the back speakers, while a dry sound panned hard to one side, such as a test tone, stays almost entirely in front.

Whether an app is sending stereo or surround is worked out from the channels themselves: surround is taken at once, stereo after 0.75 seconds of silence on every channel but the front pair (8 seconds once surround has been heard, so a quiet scene does not flip it).

## When Vespertine plays the same group

Vespertine and the helper never play a group at the same time. When Vespertine starts playing a group, the helper lets go of its DACs first; while Vespertine plays it, what other apps send to that group's output is not heard, and the status line says "Vespertine is playing this group". Three seconds after Vespertine stops, the helper takes the group back. Pausing counts as stopping after 5 seconds: Vespertine lets go of a published group 5 seconds into a pause, so other apps are heard again, and takes it back when you press play.

## Removing it

Turn the groups off, then "Remove…" in the same settings. Deleting Vespertine without that leaves the driver in `/Library/Audio/Plug-Ins/HAL` (its outputs disappear within 20 seconds, since nothing refreshes them); remove it with:

```sh
sudo rm -rf /Library/Audio/Plug-Ins/HAL/VespertineSound.driver && sudo killall coreaudiod
```

The helper's files are in `~/Library/Application Support/Vespertine Mac Sound Output`.

## What is not verified

- Not yet tested on real DACs: playing from Safari, the TV app, IINA and VLC; 5.1 and 7.1 from a film on a quad; the volume keys; the hand-off to and from Vespertine; the latency a player is told against the picture; a DAC unplugged mid-film.
- The upmix's choice between stereo and surround is tested on generated signals, not on real programme material.
- The microphone prompt and the Login Items flow are not yet seen on a signed release build.
