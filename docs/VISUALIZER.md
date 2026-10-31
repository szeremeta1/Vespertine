# Visualizer

An optional window that draws the music: a bar spectrum analyzer, a scrolling spectrogram, the album on a spinning record and club lights pulsing with the beat. It's off by default. Switch it on in Settings > Playback > Visualizer; then Window > Visualizer (⌥⌘V) and a toolbar button open it. The window is separate from the player, so it can sit on another display, go full screen there and keep running while the main window is minimized.

It reads a copy of what plays and never changes the sound. With the window closed, it costs nothing.

## Styles

- **Spectrum.** 32 to 128 log-spaced bands from 20 Hz to 20 kHz, smoothed (fast rise, slower fall), with held peak caps that fall away after 0.7 s. Heights in dB (the default: 0 dB at the top, -72 dB at the floor, a grid every 12 dB) or in linear amplitude.
- **Spectrogram.** Frequency up (log scale), time across, newest on the right, level as colour through the theme's colour map. 6 to 30 s of history.
- **Vinyl.** The album cover as the label of a record turning at 33⅓ or 45 RPM, with grooves, the gaps between songs, a sheen that stays put while the record turns, dust that doesn't, and a platter with strobe dots under a lamp. A ring of light around the platter shows the spectrum (lows at the top, mirrored left and right). The tonearm follows the song from the lead-in to the run-out; the record spins up when playback starts and slows to a stop on pause.
- **Club.** A core that swells with the bass, a circular spectrum around it, rings sent out on every beat, lasers turning faster with the mids and brighter with the highs, and a tunnel of rings rushing outward. The beat strobe (full-window flashes on strong beats) is off by default and never runs with Reduce Motion on.

Every style has six colour themes (Brass, Neon, Aurora, Ember, Ice, Monochrome) and a sensitivity control (a quarter to four times, logarithmic). The controls fade after a few seconds without the pointer moving; in full screen the pointer hides too. Keys 1 to 4 pick a style and Space plays or pauses.

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

Unit tests check sines land in their own bins at 44.1 to 192 kHz, the level calibration, sensitivity, the linear scale, silence (no NaNs, no beats), peak hold, that paused audio falls away, kicks at 120 BPM found one by one at 60 and 120 frames a second with the tempo, and a steady tone with no beats.

## Drawing

`VisualizerRenderer` draws each style as one full-window fragment shader (Metal, compiled from source when the first window opens, so the app needs no Metal toolchain to build). An `MTKView` draws at the display's own refresh rate: 120 Hz on ProMotion displays, and it follows the window to another display. Axis labels and the song's title are drawn with AppKit into a texture when they change and laid over the picture. The spectrogram keeps its history in a texture, one column per step. The record's spin, the tonearm, the beat rings and the lasers are animated on the CPU each frame and passed to the shader.

`vespertine-visualize` renders the same analysis and shaders offline from decoded audio, for stills, recordings and timing:

```bash
ffmpeg -i song.flac -f f32le -ac 2 song.f32
cd Packages/VespertineKit && swift build -c release --product vespertine-visualize
.build/release/vespertine-visualize song.f32 --rate 44100 --style vinyl --art cover.jpg --still 60 --png vinyl.png
```

## The window

The window remembers its display (by ID, then by name), its frame and whether it was full screen, and opens there again: on another display if its own is gone, always on screen (`VisualizerWindowState`, tested). Style, colours and options are saved as JSON; a value from another version that can't be read falls back to its default.
