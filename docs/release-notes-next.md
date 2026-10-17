**Up Next now opens as a panel beside your library, with a History of what you've played, and albums with mastering or reissue labels join their other editions.**

### Up Next and History
- **Up Next beside the library.** Up Next opens on the right of the window, where the Inspector goes, with **Up Next** and **History** tabs. Songs you add with Play Next or Add to Queue are listed under **Playing Next** and play before the rest of the album or list, as in Apple Music, and shuffle leaves them in place. Drag rows to reorder them, remove them with the button that appears on hover or with Delete, and play one with Return or a double-click. **View › Show Up Next** (⌥⌘U).
- **History.** Every song you listen to for 10 seconds or more (or half of it, if it's shorter), most recent first and grouped by day. Songs you played before this version start it with their last play. Removing songs from History or clearing it doesn't change play counts.

### Library
- **Mastering and reissue labels.** Albums titled with labels such as "(DCC Mastering)", "(2009 Re-Mastered)", "(Japan SHM-CD)", "(Expanded)" or "(… Anniversary)" now join their album's editions card instead of showing up as a separate album.

### Fixed
- **Plays counted for the wrong song.** While a newly chosen song, or the next song in a gapless queue, was still opening, the previous song's listening time could count a play and a scrobble for the new one. Plays, scrobbles and History now count only the song you were listening to.

### Install
Download **Vespertine-VERSION.dmg**, or let Vespertine update itself. Requires macOS 14.4 or later on Apple silicon or Intel. Signed with a Developer ID, notarized and stapled. Homebrew: `brew upgrade --cask vespertine`.

---

## Before publishing (delete this section)

Draft for the next weekly beta, written on 2026-10-17 from `git log v0.12.2..origin/main`:

- d2036fd Add play history and rework Up Next into a panel beside the library (#75)
- 6e9333f Album families: recognize mastering, pressing and reissue labels as editions (#77)

For Alex:

- **Version number.** Not chosen here: `VERSION` above is a placeholder. #75 adds a feature, which went with a minor bump before (0.12.0), so 0.13.0 is the likely one. Move the file to `docs/releases/<version>.md` for `scripts/publish.sh`.
- **Anything merged after this draft** (including the launch-polish PR, if merged) needs adding. Launch polish has no user-visible app change, except for the hidden beta-channel opt-in, which only matters once a beta has been published (docs/BETA-CHANNEL.md).
- **Known issues.** 0.12.2 listed "A stray icon can appear next to the sidebar button while the search field is active." Neither commit above mentions it. Check whether it still happens and either keep the line under a `### Known issues` heading or drop it.
- **Checks recorded in the PRs** (not rerun for this draft): #75 adds `PlayHistoryTests` and an app test for Playing Next order, shuffle, moves, Play Next and removal; its 21 new strings are translated into all 44 languages. #77 adds the `masteringLabels` test and reports 148 + 220 tests passing, and that on the owner's library exactly two album families changed.
- Signing, notarizing, tagging and publishing are Alex's (`scripts/release.sh --notarize`, then `scripts/publish.sh`).
