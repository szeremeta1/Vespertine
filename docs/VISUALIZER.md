# Visualizer

An optional window that draws the music: the album on a spinning record, a bar spectrum analyzer, a scrolling spectrogram, club lights pulsing with the beat, a stereo scope, a pair of analogue VU or PPM meters, a field of particles and mirrored bars. It's off by default. Switch it on in Settings > Playback > Visualizer; then Window > Visualizer (⌥⌘V) and a toolbar button open it. The window is separate from the player, so it can sit on another display, go full screen there and keep running while the main window is minimized.

It reads a copy of what plays and never changes the sound. With the window closed, it costs nothing.

## Styles

- **Spectrum.** 32 to 128 log-spaced bands from 20 Hz to 20 kHz, smoothed (fast rise, slower fall), with held peak caps that fall away after 0.7 s. Heights in dB (the default: 0 dB at the top, -72 dB at the floor, a grid every 12 dB) or in linear amplitude.
- **Spectrogram.** Frequency up (log scale), time across, newest on the right, level as colour through the theme's colour map. 6 to 30 s of history.
- **Vinyl.** The album cover as the label of a record turning at 33⅓ or 45 RPM, with grooves, the gaps between songs, a sheen that stays put while the record turns, dust that doesn't, and a platter with strobe dots under a lamp. A ring of light around the platter shows the spectrum (lows at the top, mirrored left and right). The tonearm follows the song from the lead-in to the run-out; the record spins up when playback starts and slows to a stop on pause.
- **Club.** A core that swells with the bass, a circular spectrum around it, rings sent out on every beat, lasers turning faster with the mids and brighter with the highs, and a tunnel of rings rushing outward. The optional beat strobe is described under [The strobe](#the-strobe).
- **Scope.** A phosphor screen whose trace fades as a CRT's does (a beam that moves fast leaves less light). As a **goniometer** (the default) it plots left against right turned 45°: mono is an upright line, a sound only on the left leans to the upper left, only on the right to the upper right, and out of phase lies across. A correlation bar under it reads +1 for mono, 0 for unrelated channels and -1 for out of phase (that half is tinted red). As an **oscilloscope** it shows left and right against time, about 21 ms across, each sweep starting on a rising zero crossing so the picture holds still. The gain follows the music's recent peak (up at once, down over two seconds, at most +30 dB), as a scope's automatic gain does, so quiet and loud masters fill the screen alike.
- **Meters.** Two backlit analogue meters, left and right, with needles that move as the real ones do (see [Meters](#meters)). **VU** has the classic cream face, a scale linear in voltage (0 VU at 71 % of the way, the red zone to +3) and a per-cent scale under it; **PPM** is a black BBC face marked 1 to 7. A peak light comes on above -1 dBFS. Side by side in a wide window, one above the other in a tall one.
- **Particles.** 20,000 particles on the GPU, carried by a flow that is the curl of a slowly changing noise field (so it never gathers them into seams or thins them out), faster with the mids. The bass breathes the whole field in and out; each beat sends a ripple out from the middle that the particles ride and flare in; the highs make them sparkle. Short trails, optional.
- **Mirrored.** The bar spectrum mirrored: around a **circle** (lows at the top, mirrored left and right, the album cover in the middle growing a little on the beat) or up and down from a **line** across the middle (lows at the centre). Peak caps and 32 to 128 bands as for Spectrum.

Every style has seven colour themes and a sensitivity control (a quarter to four times, logarithmic). **Vespertine**, the default, is the app's own palette (from `App/Sources/Theme/Theme.swift`, the site's tokens and `docs/brand`): obsidian surface `#16161A`, copper `#C98B5B`, brass `#C8A66A` and ivory `#ECE6DA`, dark to bright. The others are Brass, Neon, Aurora, Ember, Ice and Monochrome. The default style is Vinyl. The style is picked from a menu in the controls; the controls fade after a few seconds without the pointer moving, and in full screen the pointer hides too. Keys 1 to 8 pick a style (in the menu's order) and Space plays or pauses.

## The strobe

The Club style can flash the whole window on strong beats. Flashing lights can trigger seizures in people with photosensitive epilepsy, so:

- It's off by default.
- Turning it on the first time shows a warning that has to be accepted ("Photosensitivity Warning": what it does, that flashing lights may trigger seizures in people with photosensitive epilepsy, to leave it off if you or anyone watching has epilepsy or has had a seizure, and to look away and turn it off if you feel unwell). Cancel is the default button; turning it on is marked as the risky choice. Once accepted it isn't asked again (`strobeWarningAccepted`).
- The option repeats the warning: under the toggle in the visualizer's options, in its help tag, and under "Beat strobe in the Club style" in Settings > Playback > Visualizer, which has the same toggle and asks the same way.
- It never flashes while **Reduce Motion** (System Settings > Accessibility > Display) or **Dim Flashing Lights** (same place; `MADimFlashingLightsEnabled`) is on: the toggle is greyed out, shows off, and says which setting is why. With Reduce Motion on, the lasers and particles also move more calmly and beats send no ripples.
- The renderer checks all of this itself before every flash (`strobeAllowed`), and settings that say the strobe is on without the warning accepted (a hand-edited file) load with it off. Both are tested.

A flash rises in one frame and decays over about 45 ms, only on beats with strong bass, and never more than one every 0.4 s: at most 2.5 a second however fast the beats come, under the 3 a second that photosensitivity guidelines (WCAG 2.3.1, the Ofcom/Harding test) allow. That's tested too. It's still a full-window flash at up to 85 % white, which is why it asks first.

## Where the samples come from

```
… ▶ ring buffer ▶ HAL IOProc: room correction ▶ EQ ▶ gain + dither ▶ meters ─▶ DAC
                                                                       │
                                                                       └─ visualizer tap (copy, ÷ gain)
                                                                             ▶ analysis thread ▶ Metal
```

The tap is in the I/O proc's meter loop (`CVespertineRT`, `nrt_context_set_viz` / `nrt_context_copy_viz`), which already reads every frame after the last change to it. When the visualizer is on, each frame's left and right samples are stored into a 32,768-frame ring of its own (two relaxed atomic stores per frame, no locks, no allocation, no calls out); when it's off, the I/O thread checks one flag per slice and does nothing else. The samples going to the DAC are never read differently, written or delayed: a test renders the same input with the tap on and off and compares the output bit for bit, at unity gain and with gain.

The reader (`PlaybackEngine.copyVisualizerTap`) always takes the newest frames. Anything it didn't get to is overwritten, so a slow window drops frames rather than holding anything up. If the I/O thread laps the copy while it's being taken, the copy is thrown away (a test races the two for 4 million frames and checks that every copy kept is one moment, never two).

**Why after room correction and the equalizer.** It's what you hear: a correction or EQ curve shows in the picture. It's also in step with the sound: FIR room correction holds the output back 512 frames, and a tap before it would run that much ahead. **Why ÷ gain.** Digital volume and ReplayGain are a single gain at that point, so dividing it back out shows the music at the same size at any volume, as hardware volume (which never touches the samples) already does. At zero volume the tap reads silence.

**Modes.** Nothing about the tap depends on shared or exclusive (hog) mode: it reads the render context, not the device. In integer mode it reads the 32-bit words as integers, as the meters do. In DoP it reads the levels the meters already take from the DSD bits (good to about 20 kHz), and the DoP frames still go out untouched. Bitstream (IEC 61937) carries no PCM to look at, so the visualizer shows nothing; neither does Atmos rendered by macOS, which doesn't pass through Vespertine's I/O proc. With Spatial Audio, the tap reads the decoded channels before the spatial mixer. With more than two channels it reads the front left and right.

## Analysis

`VisualizerAnalyzer` (in `Packages/VespertineKit/Sources/VespertineVisualizer`) runs on a thread of its own (`VisualizerFeed`, a user-interactive dispatch timer at the display's refresh rate), never on the main thread or the audio thread, and only while a visualizer window is on screen. It also stops while the window is minimized or fully covered.

- A real FFT through Accelerate (`vDSP.FFT`) of the newest 4,096 frames at 44.1/48 kHz, 8,192 at 88.2/96 kHz and 16,384 above (about 85 ms at each), with a Hann window, scaled so a full-scale sine reads 0 dB.
- 512 log-spaced bins from 20 Hz to 20 kHz: the largest FFT bin within each, or interpolated where a bin is wider than it (the lows). A +3 dB per octave tilt around 1 kHz makes typical music look level. The bars take the largest bin in each band.
- Smoothing with time constants (15 ms rise, 220 ms fall), so it behaves the same at 60 and 120 frames a second. Peak hold for 0.7 s, then a fall that speeds up.
- RMS and peak per channel over the newest 2,048 frames.
- Lows (30 to 150 Hz), mids (150 Hz to 2 kHz) and highs (2 to 16 kHz), each against its own recent loudest, so quiet and loud masters move the picture alike.
- Beats: spectral flux of the lows with an adaptive threshold (mean plus 1.6 standard deviations over 1.5 s), at most one every 0.28 s, and a tempo from the median spacing of recent beats.
- For the scope: the newest 2,048 samples per channel (about 43 ms, thinned to about 48 kHz at higher rates) and the correlation of left and right over the same span (lightly smoothed; with either side silent it eases to 0).
- The meters (below), fed only the samples that are new since the last frame.

## Meters

`VisualizerMeters` runs both meters sample by sample, whichever is shown:

- **VU (IEC 60268-17).** The needle is a damped mass on a spring driven by the full-wave rectified signal: damping 0.81, natural frequency 13.42 rad/s. That gives the standard's ballistics: 99 % of the reading 300 ms after a tone starts, with 1.3 % overshoot (the standard asks for 1 to 1.5 %). The needle rests against a pin at the left and pegs against one past +3 VU.
- **PPM (IEC 60268-10 Type IIa, the BBC meter).** A rectifier that charges with a 2.76 ms time constant, so a 10 ms burst reads 2 dB under a steady tone, and falls 24 dB in 2.8 s. The scale is the BBC's: marks 1 to 7, 4 dB apart, PPM 4 at the reference.
- **Reference.** A sine whose RMS is the reference level reads 0 VU and PPM 4. It's **Automatic** by default: 1 dB over the music's loudness over the last few seconds (silence between songs doesn't count), so a quiet 1960s master and a loud modern one both swing around the top of the scale. Fixed references of -20, -18 (EBU R68 alignment), -14 and -10 dBFS are in the options. The sensitivity control moves it too (twice the sensitivity is a reference 6 dB lower).

Tests check the calibration (0 VU and -10 VU), the 300 ms and the overshoot, the needle falling back and pegging, PPM 4 for a steady tone, the 10 ms burst at -2 dB, the 24 dB fall in 2.8 s, the scale, and that the automatic reference reads a quiet and a loud tone alike.

Unit tests check sines land in their own bins at 44.1 to 192 kHz, the level calibration, sensitivity, the linear scale, silence (no NaNs, no beats), peak hold, that paused audio falls away, kicks at 120 BPM found one by one at 60 and 120 frames a second with the tempo, and a steady tone with no beats.

## Drawing

`VisualizerRenderer` draws each style as one full-window fragment shader (Metal, compiled from source when the first window opens, so the app needs no Metal toolchain to build). An `MTKView` draws at the display's own refresh rate: 120 Hz on ProMotion displays, and it follows the window to another display. Axis labels and the song's title are drawn with AppKit into a texture when they change and laid over the picture. The spectrogram keeps its history in a texture, one column per step. The record's spin, the tonearm, the beat rings and the lasers are animated on the CPU each frame and passed to the shader.

The scope and the particles draw light first: into a half-float texture the size of the window that keeps a set fraction of itself each frame (the fade, as a blend), with the new light added on top. The scope's trace is one instanced quad per step between samples, each lit as a Gaussian beam; the particles are moved by a compute kernel, then drawn as soft sprites. The style's own shader then lays that light over its background. The meters' printed faces (scale, numbers, red zone) are drawn once with AppKit into a mask texture whenever the window's size or the meter changes; the shader lights and colours them, and draws the needle, its shadow, the cover over its pivot, the peak light and the glass.

`vespertine-visualize` renders the same analysis and shaders offline from decoded audio, for stills, recordings and timing:

```bash
ffmpeg -i song.flac -f f32le -ac 2 song.f32
cd Packages/VespertineKit && swift build -c release --product vespertine-visualize
.build/release/vespertine-visualize song.f32 --rate 44100 --style vinyl --art cover.jpg --still 60 --png vinyl.png
```

Options: `--style vinyl|bars|spectrogram|club|scope|meters|particles|mirrored`, `--theme vespertine|brass|neon|aurora|ember|ice|mono`, `--scope goniometer|oscilloscope`, `--meter vu|ppm`, `--reference <dBFS>`, `--layout circle|line`, `--no-trails`, `--strobe`, and the others listed at the top of `main.swift`.

### Cost

Offline at 2560 × 1440 on an M1 Pro (GPU time per frame from the command buffers' own timestamps; analysis on the CPU, meters included): Vinyl 1.7 ms, Scope 1.9 ms (oscilloscope 1.5), Meters 1.3, Particles 1.4, Mirrored 1.1 to 1.4, against a frame budget of 8.3 ms at 120 Hz. Analysis is 45 to 60 µs a frame.

## The window

The window remembers its display (by ID, then by name), its frame and whether it was full screen, and opens there again: on another display if its own is gone, always on screen (`VisualizerWindowState`, tested). Style, colours and options are saved as JSON; a value from another version that can't be read falls back to its default.
