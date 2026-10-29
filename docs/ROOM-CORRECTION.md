# Room correction

Vespertine can measure your speakers at your listening seat with a calibrated USB measurement microphone (miniDSP
UMIK-1) and fit parametric filters that cut the room's bass peaks, separately for the left and right speaker. It is off
unless you turn it on, it is bound to the output it was measured on, and while it is on the signal path says
**ROOM CORRECTION** and playback is not bit-perfect.

## Using it

1. **View → Room Correction** (or **Edit…/Measure…** under Room Correction in an output's settings, beside the
   equalizer).
2. **Measure…** opens the wizard:
   - **Microphone**: UMIK-1 on a stand at ear height at your seat, pointing straight up; choose its 90° calibration
     file (miniDSP's download for your serial number).
   - **Allow**: macOS asks once whether Vespertine may use the microphone. It listens only while a measurement runs.
   - **Level**: music pauses; a quiet check plays first, and the sweeps get only as loud as the microphone needs.
   - **Sweeps**: left, then right, about a minute in all. More positions (up to five, moving the microphone 20 to
     40 cm around your head position between them) are averaged per speaker.
   - **Result**: the measured response, the target and the predicted response after correction, with the filters.
     **Save and turn on**, **Save**, or **Discard**.
3. In the window: the on/off switch for the current output, the profile it uses, the before/after graph, the target and
   range the filters are fitted to (changing either refits from the stored measurement), and the filter list.

The graph's bold "after" curve is **predicted** (measurement plus filters), not measured. To see what the room really
does, measure again with correction on.

The output is measured at the sample rate it is set to; nothing on the device is changed. Every measurement folder
(`~/Documents/Vespertine Room Measurements/<date-time>/`) keeps the raw recordings, the session, the calibrated
responses (CSV and plot), `room-profile.json` and `room-correction-predicted.png`.

## Where it runs

Room correction runs on the I/O thread in 64-bit floating point, one bank of up to 16 biquads per output channel, ahead
of the equalizer, digital volume and dither (`nrt_context_set_room` in `CVespertineRT`). Coefficients are rebuilt for
the device's actual sample rate whenever the output, rate or profile changes.

It applies to PCM that Vespertine renders as plain stereo (two channels, no Spatial Audio). It is bypassed, and the
signal path says so with the reason, for native DSD sent as DoP, Dolby/DTS bitstreams, Dolby Atmos rendered by macOS,
and streams with another channel count. Integer mode and "Match 16-bit sources" need untouched samples, so they are
off while room correction is on (turning it on mid-song reopens the output on the float path).

## How the filters are designed

`RoomFilterDesigner` (`Packages/VespertineKit/Sources/VespertineAudio/RoomFilterDesign.swift`), deterministic: the same
measurement and options always give the same filters.

1. Each speaker's microphone-calibrated response (positions averaged in power) is smoothed over a sixth of an octave.
2. **Roll-off**: going down from 200 Hz, the first point (third-octave smoothed) more than 6 dB below the 200 Hz to
   2 kHz level. Nothing below it is boosted.
3. **Target**: the chosen curve at the measurement's own 200 Hz to 2 kHz level, so correcting the bass never moves the
   midrange. Presets: *Gentle tilt* (default, −0.8 dB per octave around 1 kHz), *Flat*, *Warm* (−1 dB per octave plus
   a 3 dB lift below about 100 Hz).
4. **Fit**, within the correction range (20 to 500 Hz by default, or full range 20 Hz to 16 kHz) and above the roll-off:
   up to 10 peaking bands, each placed on the largest remaining error and refined (centre, gain, Q) by coordinate
   descent on the squared error, then all refined together. Cut-dominant: errors under the target count half as much
   as over it; deep nulls (more than 6 dB under the target) are left alone. Cuts up to 18 dB with Q 0.5 to 6; boosts
   only for broad dips, at most +3 dB with Q at most 2. The whole correction is held to +3 dB anywhere and +0.5 dB below
   the roll-off.
5. Rounded to 0.1 Hz, 0.1 dB and 0.01 Q; bands under 0.3 dB are dropped.
6. **Preamp**: if the combined response rises above 0 dB anywhere from 10 Hz to 20 kHz at 44.1 to 192 kHz, the preamp
   is minus that peak minus 0.5 dB; with cuts only it is 0 dB. Both channels share the lower preamp, so the balance
   holds. This is a frequency-domain bound, not a guarantee against every inter-sample peak.

Profiles are stored with their measurement and design options (`RoomProfile.measured`, `designOptions`), so the target
and range can be changed later without measuring again.
