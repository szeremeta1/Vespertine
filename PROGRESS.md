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

- [x] App: Settings > Playback > Visualizer (off by default), Window > Visualizer ⌥⌘V, toolbar button, controls,
      window state (display, frame, full screen), pauses when hidden. QA hooks: -VespertineVisualizerStats, -VespertineQuitAfter.
- [x] l10n: 34 keys × 44 languages (catalog change is additive only; check-localizations.py passes).
- [x] Perf measured (see RESULT-visualizer.md); club/vinyl shaders optimized ~30%.
- [x] Docs: docs/VISUALIZER.md, FEATURES.md, ARCHITECTURE.md.

## Next
- [x] Full test run (Kit 395, Analysis 45, App 30), recordings + stills in ./out, RESULT-visualizer.md (local), draft PR.
- Phase 1 done. Phase 2: see "Left for phase 2" in RESULT-visualizer.md / the PR.
- Scripts kept local in .scratch/ (perf.sh, record.sh, l10n_visualizer.py); .scratch and out are git-excluded.

# Phase 2 (run 2, 2026-10-30). Brief: BRIEF-visualizer2.md (local)

- [x] Defaults: vinyl, new "Vespertine" theme (brand tokens: surface #16161A, copper #C98B5B, brass #C8A66A, ivory #ECE6DA).
- [x] Strobe: off by default; needs `strobeWarningAccepted` (one-time alert, normalized() forces it off otherwise);
      blocked by Reduce Motion and Dim Flashing Lights (MADimFlashingLightsEnabled); help text in menu + Settings toggle.
- [x] Styles: scope (goniometer/oscilloscope, phosphor trail, correlation bar), meters (VU IEC 60268-17 / PPM BBC
      Type IIa, auto or fixed reference), particles (GPU compute, curl flow, beat ripples), mirrored (circle/line).
- [x] Tests: VisualizerMetersTests + renderer/settings additions (38 visualizer tests pass).
- [x] tests/rt-audit.c: concurrent tap test (ASan/UBSan + TSan clean). audit.sh on phase 1 HEAD: all passed.
- [x] l10n: 22 keys × 44 (.scratch/l10n_visualizer2.py), check-localizations passes.
- [x] Release perf numbers (offline), clips in ./out (vinyl Vespertine, scope, meters, particles, mirrored), strobe dialog still,
      live app captures, 56 stills. Strobe capped at 2.5 flashes/s. Meters only run while shown.
- [x] Docs (VISUALIZER.md, FEATURES.md, ARCHITECTURE.md), PR-BODY-visualizer.md drafted.
- [x] Full audit.sh on the final code (3a8cc37): all passed (Kit 583 Debug + Release, Analysis 45, App 30, ASan/UBSan, TSan,
      DST fuzz, static analysis, universal Release build). Test numbers in PR-BODY-visualizer.md and RESULT-visualizer.md.
- [x] Meter clips re-rendered from the final code (same pictures; clean timing files).
- Run 2 done. Draft PR #118 body: PR-BODY-visualizer.md (local); Vesper updates the PR.
