# RESULT — feat/rc-profiles (Room Correction: profiles, Simple / Pro)

Branch `feat/rc-profiles`, based on `fix/umik-float32` (PR #140): **rebase onto `main` once #140 merges.** Signed commits,
all pushed. **No PR opened** (Vesper does). Not tried on real audio hardware or a real UMIK-1, and **the new window has not
been looked at on screen** (see "Not verified").

## What it does now

1. **Profiles** (library, per output)
   - Create (measure / import), rename, duplicate, delete (with confirmation), export, import. Name + optional
     Speakers / Room / Position labels (also entered on the measurement result page before saving).
   - Names: control characters stripped, white space collapsed, max 80, unique per output (case-insensitive); a clash on
     add/import is numbered ("Desk 2"), a clash on rename is refused with the other profile's name.
   - Each output has its own chosen profile and on/off; selecting the output uses its profile (the engine was already
     keyed by output UID). Off keeps the choice; deleting the chosen profile switches that output off.
   - Import of an exported profile binds it to the *selected output* (needs enough channels) with a **new id**: before,
     importing your own export silently overwrote the original (same id). Exported impulse-response profiles now carry
     their filter samples (before, the export referenced files that didn't exist on another Mac).
   - Migration is lossless: schema 3 → 4 only adds optional fields; schema 1/2 still migrate; tests assert every field
     equal. Old `roomProfiles` / `roomAssignments` preferences are read once and written to the new library file.
2. **Simple mode** (default): graph, one **Strength** slider (0–100 %: scales every gain, preamp recomputed so it can't
   clip), **A · As it is / B · Corrected** switch with a note of the level difference, Measure New, on/off, "What it does"
   (per-speaker table) folded away.
3. **Pro mode**: target (presets + **house curve file**), correction range low/high cutoff, largest cut/boost, filters
   per speaker, Apply (refits from the stored measurement; asks before replacing hand edits); **measured positions**
   include/exclude with automatic refit; **per-filter editor** (on, type, freq, gain, Q, add/remove, up to 24) and
   **per-speaker delay and level trim**; graph with Measured / Target / Corrected switches; microphone serial and
   calibration checksum.
4. **Audit of `~/Workspace/vt-umik/RESULT.md`**: its table lists no open trap (all Fixed/Covered). Its "limits" are real
   but not done here, on purpose: (a) the mic's sample rate is switched and restored *per capture* when the mic isn't
   already at the chosen rate (a session-level hold is a controller change in the measurement path, riskier to do blind
   a week before launch; a UMIK-1 at 48 kHz is never touched); (b) output stream not Float32 is refused, not converted;
   (c) aggregate devices unverified; (d) real-hardware run (Fosi ZD3 + UMIK-1) still needed. Nothing else found in scope.

## Hardening found and fixed along the way (all with tests)
- Importing a profile whose id exists replaced it → now a fresh id.
- A profile file could name any path as its filter file (`../..`); names are now checked, and an archive writes under
  new generated names only, and writes nothing if any part is damaged.
- Profiles from a newer Vespertine were silently **dropped and then deleted** on the next save; now kept untouched.
- The library lived in UserDefaults (and positions would have made it several times bigger). It is now
  `Room Profiles.json` in the data folder, written atomically with `Room Profiles.previous.json` beside it; a damaged
  file is set aside and the last good one used.
- `RoomFilterDesignOptions.clamped`: Pro limits can't ask for more than playback runs (range 10 Hz–20 kHz ≥ 1/10 octave,
  cut ≤ 30 dB, boost ≤ 12 dB, 1–24 filters, Q in band limits, NaN → default).
- Strength: NaN/negative/>1 handled; preamp never lets the corrected peak exceed 0 dB at 44.1–192 kHz (tested every 0.1).
- Band edits: NaN refused, values clamped, >24 refused, failed edit changes nothing, preamp follows.

## Tests
- Kit: `RoomProfileBookTests` (library, schema 4, archive/import), `RoomProProfileTests` (strength, house curve,
  limits, band edits, positions), `RoomProfileStoreTests`. Tests were committed first (`54a4b5d`, they didn't compile until
  the next commit); `RoomProfileStoreTests` were written together with the store (not failing first).
- App: `App/Tests/RoomLibraryTests.swift` (4 tests: migration from old preferences, per-output choice, newer profiles kept,
  rename/duplicate/delete persisted) — pass via `xcodebuild test -only-testing:VespertineAppTests/RoomLibraryTests`.
- Full `swift test` in VespertineKit (machine under load, 14 min): 57 + 165 passed, 639 in the audio target with 2 failures:
  (1) my own schema-4 round-trip test compared encoded bytes, but enum-keyed dictionaries encode in no fixed order (an
  old trait of `measured` too): fixed to compare values, passes; (2) `BedMeterTests` "compressed frames … byte-identical"
  (timing-bound, not touched by this work): passes alone, so I read it as load, but it was not re-run in a full pass.
  App: `RoomLibraryTests` 4/4. The full app test suite was not run.
- Real-app check: launched the Debug build with an isolated data directory and `-VespertineRoomProfile`: profile imported,
  bound to the built-in output, `Room Profiles.json` + `.previous.json` written, schema 4, tags and strength kept.

## Not verified (please check)
- **The window itself.** It compiles and runs, but I could not capture it (no usable window capture from this session;
  a full-screen grab showed only another app's stale crash dialog). Layout, spacing, the Pro editor's text fields and
  the segmented Simple/Pro control have not been looked at. First thing to do: open it with a profile and look.
- Real playback with Strength < 100 % and A/B on a DAC; the engine path is the same one used before (it receives the
  scaled profile), covered by `playbackUsesStrength`.
- Exporting/importing an impulse-response profile through the UI (covered at the file level only).

## Needs Alex / known gaps
- **Translations.** `scripts/check-localizations.py` fails: 77 new strings (`NEW-STRINGS.txt`, untracked, one per line)
  aren't in `Localizable.xcstrings` in the 44 languages; plus 2 older ones from the #140 branch (`RoomMeasureModel.swift`).
  I didn't write 3,000+ translations. Needed before release.
- **Website / `verification/CLAIMS.md` / release notes** still describe the old window; I didn't touch site copy.
  `docs/ROOM-CORRECTION.md` is updated.
- **Downgrade:** an older Vespertine ignores the new file (it reads preferences), so profiles made here won't show there.
- Profiles measured before this version have no stored positions, so Pro's position list isn't shown for them.
- The mic **calibration file** can be chosen only when measuring (shown in Pro for reference); swapping the file on an
  existing profile isn't possible (the calibrated responses are stored, the raw recordings are in the measurement folder).
- Editing the filters of an imported APO profile recomputes its preamp from the edited filters (the file's own preamp is
  replaced).

## Options for Alex (wording / colour)
- Mode switch labels **Simple | Pro** (alternatives: Guided | Advanced). Placed top right, next to the title.
- A/B labels **"A · As it is" / "B · Corrected"** (alt: Off / On, Original / Corrected).
- Profile action names: "Name and Labels…", "Duplicate", "Delete Profile…", "Measure New…" (was "Measure Again…").
- Strength helper text: "0% leaves the music as it is, 100% is the full correction."
- Colours: all existing `Palette` (brass for on/status, copper for warnings such as "replaces your edits"); no new colours.
- Default name after measuring is still "<output> · <date>"; alternatives: "<output> – <room>" once a Room label exists.

## Files
`Packages/VespertineKit/Sources/VespertineAudio/`: `RoomProfileLibrary.swift` (book, tags, strength, edits, archive),
`RoomProfileStore.swift`, `RoomCorrection.swift` (schema 4), `RoomFilterDesign.swift` (house curve, `clamped`),
`RoomCorrectionPlayback.swift`, `RoomMeasurementResult.swift` (keeps positions). App: `AppSettings.swift`,
`RoomCorrectionViews.swift`, `RoomProfileViews.swift` (new), `DeveloperHooks.swift`. Docs: `docs/ROOM-CORRECTION.md`.
