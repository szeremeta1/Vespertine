# PROGRESS (feat/rc-profiles)
- [ ] Kit: RoomProfile v4 (tags, strength, customTarget), RoomProfileBook (create/rename/dup/delete/import/active per device), migration tests
- [ ] Kit: pro design options (custom target, limits, range cutoffs, band edit, averaging weights) + strength scaling
- [ ] App: AppSettings uses book; views: profile bar, simple/pro modes, band editor, curves
- [ ] docs/ROOM-CORRECTION.md, RESULT.md
Build note: swift build --build-tests takes ~5.5 min cold; use `swift test --filter` after.
## Status 1
- Kit: done + 46 new tests passing (RoomProfileBookTests, RoomProProfileTests). Full `swift test --filter Room` passed (173).
- App: AppSettings -> RoomProfileBook; window rewritten (RoomCorrectionViews.swift, RoomProfileViews.swift); xcodebuild Debug OK.
- TODO: localizations (scripts/check-localizations.py already failed on base for 2 strings; mine add ~80), docs, RESULT.md, hardening audit, app tests for settings migration, screenshot check.
