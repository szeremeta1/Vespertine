# Vespertine Room Correction: profiles + simple/pro modes (for 1.0, launch 11-11)
Branch feat/rc-profiles (based on fix/umik-float32 = PR #140; rebase on main once #140 merges). Repo worktree: this dir.
Alex's words (11-03): users "should absolutely be able to rename their profiles for specific speakers, specific rooms, specific desks... comprehensive... pro-level feature... simple to use but with professional correctness"; "simple to use for those... really professional and granular changes and professional setup for those that want it". Goal: "iron clad and ready for 1.0".
Build:
1. Profiles: create/rename/duplicate/delete/import/export; name + optional speakers/room/position tags; pick active per output device (auto-switch when that output is selected); migrate existing profile data losslessly.
2. Simple mode (default): guided measure -> apply, one strength slider, on/off, A/B.
3. Pro mode: per-band filter list editable (freq/gain/Q/type), target curve choice + custom house curve, max boost/cut limits, correction range low/high cutoffs, per-channel trim, multi-position averaging, view measured vs target vs corrected curves, mic calibration file.
4. Read ~/Workspace/vt-umik/RESULT.md audit table; fix any remaining 1.0 hardening traps it lists that are in scope.
Rules: failing tests first, signed commits, push often, open NO PR (Vesper does). Design follows existing app style; wording/colour choices noted in RESULT.md as options for Alex. Write RESULT.md at the end.
