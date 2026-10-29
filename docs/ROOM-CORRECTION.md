# Room correction

Vespertine can measure your speakers at your listening seat with a calibrated USB measurement microphone (miniDSP
UMIK-1), line them up in time and level, and fit parametric filters that cut the room's bass peaks, separately for each
speaker (stereo or 5.1). It can also play filters made elsewhere: REW's Equalizer APO export (each speaker's delay,
level and parametric filters) or impulse responses (convolution filters). It is off unless you turn it on, it is bound
to the output it was measured on (or imported for), and while it is on the signal path says **ROOM CORRECTION** and
playback is not bit-perfect.

## Using it

1. **View → Room Correction** (or **Set Up…/Edit…** under Room Correction in an output's settings, beside the
   equalizer). One window holds everything: the output's on/off switch, **Measure…**, **Import**, **Export**, the
   profiles, the before/after graph, the target and range, and each speaker's delay, level and filters.
2. **Measure…** opens the wizard, with the **Room Portrait**: a top-down sketch of the room with the speakers, the seat
   and the microphone spots. The spot to measure glows with the microphone on it, the speaker playing sends its sound
   toward the seat, and measured spots fill in.
   - **Set Up**: UMIK-1 on a stand at ear height at your seat, pointing straight up; choose its 90° calibration file
     (miniDSP's download for your serial number). Choose **Stereo** or **5.1 surround** (on an output with six channels
     or more) and how many spots to measure (five by default: the seat, then left, right, in front and behind, about
     a head's width out).
   - **Allow**: macOS asks once whether Vespertine may use the microphone. It listens only while a measurement runs.
   - **Level**: music pauses; a quiet check plays first, and the sweeps get only as loud as the microphone needs.
   - **Sweeps**: each speaker in turn at each spot; between spots the wizard waits for you to move the microphone.
     Positions are averaged per speaker.
   - **Result**: the measured response morphs into the predicted response after correction, with the target, each
     speaker's delay and level and the filters. **Save and turn on**, **Save**, or **Discard**.
3. **Import**:
   - **Equalizer APO or REW Filters…**: an Equalizer APO configuration, as REW exports it. `Preamp:` before any
     `Channel:` is the profile's preamp; under `Channel:` it is that speaker's level. `Delay:` in milliseconds,
     `Filter:` lines (peak, shelves, low- and high-pass). Channels by APO name (L R C LFE/SUB, RL RR or SL SR), number
     (1 to 6) or ALL; a file with no `Channel:` lines corrects left and right alike, one naming the centre, LFE or
     surrounds is a 5.1 profile. Up to 24 filters per speaker. Graphic EQ, `Copy:` and `Convolution:` lines, delays in
     samples and unknown channel names are refused with the line number, rather than played as something else.
   - **Impulse Responses…**: WAV, AIFF, CAF or FLAC. A file with several channels gives them to the speakers in order
     (L R C LFE Ls Rs); single-channel files go to the speaker their names point to ("…_L.wav", "Right.flac"), or else
     in order; one filter alone corrects both speakers. Up to 5.5 s at 48 kHz (262,144 taps at the playing rate).
   - **Vespertine Room Profile…**: a `room-profile.json` from a measurement folder or an export.
4. **Export**: Equalizer APO text (which Import reads back; impulse responses are named in a comment, not exported),
   or the Vespertine profile.

The graph's **Before / After (predicted)** switch morphs the bold curve between the measurement and the measurement
plus filters. "After" is **predicted**, not measured: to see what the room really does, measure again with correction
on. Imported profiles have no measurement to compare against: the graph shows what their correction does to each
speaker.

The output is measured at the sample rate it is set to; nothing on the device is changed. Every measurement folder
(`~/Documents/Vespertine Room Measurements/<date-time>/`) keeps the raw recordings, the session, the calibrated
responses (CSV and plot), `room-profile.json` and `room-correction-predicted.png`.

## Lining the speakers up

During the sweeps the timing tones always come from the left speaker while the measured speaker plays the sweep, so
every speaker's arrival is timed against the same one. (A capture's own start can't be timed: on the first real run
the latency moved by up to 8 ms from one capture to the next.) Each speaker's arrival at the seat comes from its
impulse response's peak, to a fraction of a sample; its level from the calibrated response over 200 Hz to 2 kHz,
averaged over the positions. The nearer speakers are then held back until the farthest one's sound arrives, and the
louder ones turned down to the quietest one's level (never up, so alignment can't clip). Delays go up to 40 ms, levels
from −30 to +12 dB (imports may raise a level; measurements never do).

## Where it runs

Room correction runs on the I/O thread, per output channel, in one chain:
**delay → level (and the shared preamp) → up to 24 parametric filters (64-bit) → measured filter (convolution)**, then
the equalizer, digital volume and dither (`nrt_context_set_room` and `nrt_context_set_fir` in `CVespertineRT`).
Coefficients are rebuilt and measured filters resampled (keeping their gain) for the device's actual sample rate
whenever the output, rate or profile changes; a filter too long for a rate is left out there and the signal path says
so.

The convolution is two-stage partitioned overlap-save: the first 8,192 taps in 512-frame blocks (which sets its
latency, 512 frames), the rest in 4,096-frame blocks with their work spread over the following I/O cycles. New
filters take over with a one-block crossfade; channels without a filter stay bit-exact. Once a stream has had
filters, every channel is 512 frames late until the output is reopened, so switching filters doesn't jump.

At the end of the queue the sound held back by delays and filters plays out before the device stops; a seek or skip
starts them from silence.

It applies to PCM that Vespertine renders (no Spatial Audio) whose channels match the profile's speakers: a stereo
profile to stereo, a 5.1 profile to 5.1 and, through its front left and right, to stereo music. It is bypassed, and the
signal path says so with the reason, for Dolby/DTS bitstreams, Dolby Atmos rendered by macOS and streams with other
channel counts. **DSD**: while correction is on, DSD on a DoP DAC is converted to PCM so it is corrected too (the signal
path says so); tick **Keep native DSD** to send it natively over DoP, uncorrected, instead. With correction off, DSD
goes out natively as always. Integer mode and "Match 16-bit sources" need untouched samples, so they are off while room
correction is on (turning it on mid-song reopens the output on the float path).

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
