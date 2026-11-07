# Speaker Groups (beta)

Two or more USB DACs played as one multichannel system: for example a Fosi ZD3 and a FiiO K11 as the front and back pairs of a quad. This is a beta. It is off by default, and with it off nothing about playback changes.

**Status.** The group engine, the routing, the editor and the room-correction pieces are covered by automated tests, and by opt-in tests against virtual devices (Vespertine Loopback and BlackHole). On real DACs only one session has run (a Fosi ZD3 leader, a FiiO K11 follower, a UMIK-1), with a probe tool, not the app: it showed a group can be built, held and played, and measured how the DACs start (see [What is not verified](#what-is-not-verified)). Nothing in the app has been listened to on a real group yet.

## Turning it on

The switch is a hidden setting for now: `defaults write org.szeremeta.Vespertine speakerGroupsFeature -bool YES`, then restart. Off (the default), the app reads no groups, offers none and hands the engine none. The planned Settings switch is not in the app yet.

## How it works, and what that means for bit-perfect

- **A private aggregate.** Vespertine asks Core Audio for an aggregate device made of your DACs. It exists only inside Vespertine: other apps cannot see it or play into it, and it is removed when playback stops.
- **One DAC leads.** Each USB DAC runs on its own crystal; two DACs differ by tens of parts per million (the Fosi measures +17.4 ppm against the UMIK-1), which would move the stereo image within seconds. So one DAC, the clock leader, sets the time, and every other DAC is resampled continuously by a few millionths to follow it (Apple's drift correction, at its highest quality).
- **Only the leader can be bit-perfect.** The leader's channels get the file's samples untouched. A drift-corrected DAC's samples are always changed, however slightly: on virtual devices it measured 103 to 131 dB signal to noise at 17.4 and 100 ppm, far below the noise of a real DAC and amplifier, but not bit-perfect. A group is labelled BIT-PERFECT only when every channel the song uses lands on a DAC that is not resampled (the leader, or DACs that share a hardware clock) and nothing else changes the samples: no mixing, level, filter or digital volume. Otherwise the signal path says what changed. A whole-frame delay only shifts samples, so the leader can stay bit-perfect with one.
- **Zero offset, not zero latency.** The goal is that every speaker reaches the seat at the same moment, to a fraction of a millisecond, not that sound is instant.
- **PCM only.** DSD is converted to PCM (the path says so), Dolby and DTS bitstreams are decoded, and integer mode and "Match 16-bit sources" are off for groups. At most 16 output channels in total.
- **Every DAC is held.** With exclusive access on, each member is held and set to the song's rate; the aggregate itself cannot be held.

## Setting up a group

Settings › Speaker Groups lists, duplicates and removes groups; the editor has:

1. **Devices and clock leader.** The leader is the DAC whose channels matter most (usually the front pair): it is never resampled.
2. **Channel map.** Every channel of every DAC against the speaker on it (front left, centre, back right…), with an **Identify** button per channel that plays a quiet tone (three bursts of pink noise at -30 dBFS) on that channel of that DAC only. Identify plays on the DAC itself, and is refused while the group is playing, because its DACs are held then. Each channel also has an **Inverted** box.
3. **The room.** A top-down drawing: drag the speakers and the seat. The distance, angle, delay and level of each speaker are worked out from it.
4. **Policies.** What stereo music does on a quad (front pair only is the default; mirrored to the back at a level; each pair its own stereo; every speaker), what the LFE channel becomes where there is no subwoofer (dropped by default), and what happens when a DAC goes away (pause, or carry on with the rest).
5. **Volume.** See below.

## What plays

- **Routing by position.** A song's channels are put onto the group's speakers by where the speakers stand: a channel with a speaker of its own goes there untouched; one between two speakers is panned between them with equal power (halfway is -3 dB each, as in ITU-R BS.775); one outside every pair goes to the nearest at -3 dB. Mono is a centre. The ring is as wide as the group, so stereo then 5.1 does not reopen the output. The 4.0 rows are derived from those rules, not from a standard; they need listening approval.
- **Delays.** Each speaker waits for the farthest, and the measured start offset between the DACs, when known, is a delay too (macOS ignores an aggregate's extra latency, so the offset is held as whole frames in the room-correction chain). A speaker's own delay trim is added.
- **Level trims and polarity.** Each speaker's trim (-30 to +12 dB) and **Inverted** flag are played in the same chain, once, whichever room profile is chosen. A flip turns the speaker's signal over (every sample's sign), after the delay and before any filters.
- **Headroom guard.** Positive trims can push a loud song past full scale, so the chain's shared preamp is lowered by the largest boost any channel can reach (its trim plus the top of its filters, rounded up to 0.1 dB). Cuts need none, and a room profile that already leaves room keeps its own preamp. The balance between speakers holds: with +6 dB on one speaker, that speaker plays at the file's level and the others 6 dB below it. Not covered: a measured filter (impulse response), and the worst-case sum of a fold (for example 5.1 onto a quad).
- Any trim, flip or lowered preamp on an output that carries music makes the path ROOM CORRECTION, not BIT-PERFECT; on an output that stays silent it changes nothing.

## Room correction on a group

Open Room Correction with the group as the output:

- **The drawing as a profile.** "Use the Drawing" makes a profile of delays and levels from the drawing (no filters; no microphone needed), binds the group to it and switches the output to play with it. Once it exists it follows the drawing: moving a speaker updates it. A measured or imported profile is never touched by that.
- **Measured against drawn.** When a measured profile and the drawing disagree about a speaker by more than 0.25 ms (about 9 cm of air), the window says which speaker and that the drawing or the cabling may be off. 0.25 ms is a little above the follower's creep seen in the hardware session, and far above the measurement's own noise; it is not a proven bound.
- **Measuring.** The wizard measures the group as the layout the drawing makes (a quad is a quad) on the group's outputs, saved for the group's output, with the timing tones from a speaker on the clock leader. The group plays silence for 15 seconds first (the follower crept about 0.2 ms in the first 15 s of the hardware session), and a silent hold keeps the aggregate running between sweeps so the followers stay settled.

## Volume

A group has no volume of its own. The volume keys do not control it, and the group is never made the Mac's sound output. Each DAC's own volume is set once, by hand: the editor has a slider for each DAC that has a volume Core Audio can set, written when it is let go, never saved or applied by Vespertine itself. The speakers' trims and the optional master volume (the in-app digital volume) are digital and make playback not bit-perfect.

## When a DAC goes away

With "pause", the group fades and pauses and names the DAC; with "carry on", it re-plans on the DACs left and folds the music onto them after a short mute. A lost leader pauses. When the DAC returns, the group is rebuilt at the next play. It never carries on silently on a new clock in the middle of a song.

## What is not verified

- Nothing from the app on real DACs: bit-exact leader, follower quality, quad channel for channel, the Identify tone, the sliders, a real unplug, one hour of playback. [verification/hardware/SPEAKER-GROUPS.md](../verification/hardware/SPEAKER-GROUPS.md) is the script for the next session.
- From the 11-06 session: start offsets are repeatable to about the measurement's noise (σ 21 µs) in typical runs, but 3 of 49 drift-corrected runs came in about 3.5 ms (166 frames) late, unexplained; the follower crept about 0.2 ms between 1.6 s and 15.6 s and had not flattened; the Fosi against FiiO drift over 300 s was not measured.
- The Room Portrait in the wizard still draws its stereo/5.1 sketch for a quad.
- The new words are plain English, not yet in the 44-language catalog.
