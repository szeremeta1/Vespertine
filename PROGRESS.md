# Visualizer: progress (phase 1)

Branch `feat/visualizer`. Brief: BRIEF-visualizer.md (local, untracked). Delete this file before merging.

## Done
- [x] C tap: `nrt_context_set_viz` / `nrt_context_copy_viz` (CVespertineRT). Stereo, 32768 frames, off by default,
      written in the meter loop after room correction/EQ/gain, scaled by 1/gain. Torn copies return 0.
- [x] `PlaybackEngine.setVisualizerTap(_:)`, `copyVisualizerTap(left:right:)` (applied to every new session).
- [x] Tests: `VisualizerTapTests` (bit-identical output on/off, newest frames, mono, mute, DoP, never blocks/tears).

- [x] VespertineVisualizer module (Packages/VespertineKit): analyzer, feed (own thread), settings, window placement,
      Metal renderer (shaders compiled from source at runtime: no Metal toolchain needed), 4 styles, overlay labels.
- [x] `vespertine-visualize` CLI: offline renders from f32le audio (stills, raw BGRA for ffmpeg), prints µs/GPU ms.
- [x] Tests: VespertineVisualizerTests (24) all pass.

## Next
- [ ] App: setting (off by default), Window > Visualizer (⌥⌘V), toolbar button, window persistence, controls
- [ ] Perf numbers (window open/closed), screenshots + recordings to ./out (local only, not committed: music is copyrighted)
- [ ] l10n, docs (ARCHITECTURE, FEATURES), RESULT-visualizer.md, draft PR
