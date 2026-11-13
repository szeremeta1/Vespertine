# Vespertine iOS milestone 2

Status: implementation and draft kit saved locally; milestone is not fully verified or delivered. CoreSimulator and GitHub shell networking are blocked by this session's sandbox. No PR was created and nothing was uploaded to App Store Connect.

## Branch and history

- New worktree: `/Users/szeremeta/Workspace/scratch/2026-11-12-vt-ios-m2/wt`.
- Branch: `vesper/ios-app-m2`.
- Base: PR #296, `vesper/ios-app-m1`, `17d75cbf0a64d107f8d16292399a9da79326c600`. Confirmed against GitHub through the read-only connector.
- Signed implementation commits: `aef8731`, `c1c0928`, `473075f`. Local signature verification reports `G` for each. A final signed documentation commit adds this report.
- Push attempted to `git@github.com:szeremeta1/Vespertine.git`, blocked at DNS resolution. This branch is **local only**. The GitHub connector cannot transfer these existing SSH-signed commit objects.
- Transfer artifact: `../vespertine-ios-m2.bundle`, containing the new branch commits with the PR #296 head as its prerequisite. The original milestone 1 checkout was not modified.

## Changes

1. Installed Alex's approved A2 horizon icon. The light and dark 1024 px masters are pixel-identical to the approved original; the tinted master is pixel-identical to its approved grayscale variant. All are opaque RGB. Xcode's universal catalog generates iPhone/iPad renditions; 60 explicit exports cover 20 through 1024 px for inspection. Light and dark intentionally share the obsidian artwork, as specified by option A.
2. Added a regular-width `NavigationSplitView` with Now Playing, Queue, Albums, Artists, Playlists, Favorites and Output. Narrow windows and compact size classes use tabs. Destination selection lives above the layout switch.
3. Player artwork and controls respond to the actual window dimensions, with columns only when both fit. Album grids change column count; album detail uses a horizontal header when it fits. Queue, output, connection picker and mini player have readable width limits. Cover Flow can scroll vertically in short windows and uses stacked buttons at accessibility sizes.
4. Added pointer effects and keyboard commands: Command-1 through Command-4 for sections, Command-P for play/pause, Command-Option-arrow keys for tracks, Command-comma for Settings. Cover Flow supports arrows and Return while focused. Physical keyboard/pointer behaviour remains unverified.
5. Removed the forced dark appearance. Light uses the plan's ivory field with existing dark ink/brass tokens; dark retains obsidian/brass. Accent and launch assets follow appearance. The target remains universal (`1,2`), supports portrait and landscape, and explicitly does not require full screen. Actual OS multitasking remains unverified.
6. Added six layout unit tests, five UI scenarios plus a capture-orientation helper, and a debug-only narrow-window test harness. Added a serial simulator capture runner for all four requested device classes, 15 main-screen variants, both orientations, light and dark. It refuses to add another simulator when one is already booted, disables parallel testing, bounds commands and shuts down only a UDID it booted. It validates capture orientation and Store-size source dimensions.
7. Added a review-only Store kit: subtitle and alternative, promotional text, description, keywords, What's New, review notes, six captions with alternatives, and a renderer at the requested Store sizes. Existing Vespertine marketing sources and local HuskyHowl promo assets were consulted. No current HuskyHowl live listing was verified; no `asc` executable or Store connector was available.

## Verification

| Check | Result |
|---|---|
| XcodeGen project/scheme generation | Passed, including serial unit/UI test targets |
| New layout unit tests | **6 passed, 0 failures**, run on macOS against the actual shared layout source |
| Debug simulator-source compile and link | Passed, using iOS 27.1 SDK, iOS 17 minimum, arm64 simulator |
| Release simulator-source compile and link | Passed with optimization; same SDK/target |
| Mach-O target verification | Both executables report `IOSSIMULATOR`, minimum 17.0, SDK 27.1 |
| All unit-test source typechecking | Passed, including the existing milestone 1 tests |
| UI-test source typechecking | Passed |
| Swift/Python/shell source checks and `git diff --check` | Passed |
| Icon master pixels, dimensions and opacity | Passed; approved pixels preserved |
| Store draft dimensions/opacity and text lengths | Passed; 1320 x 2868 iPhone and 2064 x 2752 iPad RGB PNGs; all metadata fields within limits, no em dashes |
| Xcodebuild app bundle build | **Blocked/failed**: sandbox denies default cache writes and CoreSimulator; after local cache redirection Xcode reports missing local package products |
| Simulator build/run, unit/UI execution on iPhone/iPad | **Not completed**: CoreSimulator XPC is denied |
| Current app visual verification | **Unverified** on every requested device and appearance |
| Actual Split View, Slide Over and Stage Manager | **Unverified**; the width harness is not an OS multitasking test |
| Real keyboard, pointer, Dynamic Type, accessibility and VPN connection | **Unverified** |
| Push | **Blocked**: github.com cannot resolve from shell |

Direct source compilation is useful evidence, but is not a successful Xcode app-bundle build, archive, simulator run or visual approval. The only compiler warning from project code is an existing unnecessary `nonisolated(unsafe)` in `RemoteTransport.swift`. The runtime/sandbox failures were not attributed to application correctness.

Evidence is saved in `../logs/`: `source-check.log`, `layout-tests.log`, `icon-validation.log`, `xcodegen.log`, `baseline-build.log`, `m2-build.log`, `capture-matrix.log`, and `push.log`. Build executables are in `build/source-check/`. Reproduce source checks with `scripts/check-ios-sources.sh` and layout tests with `scripts/check-ios-layout.sh`.

## Images and Store kit

- Draft contact sheet: `docs/app-store/ios-m2/draft-reference/contact-sheet.png`.
- Draft iPhone set: `docs/app-store/ios-m2/draft-reference/iphone69/` (six PNGs at 1320 x 2868).
- iPad caption templates: `docs/app-store/ios-m2/draft-reference/ipad13/` (six PNGs at 2064 x 2752).
- Icon contact sheet: `docs/design/ios-icon-a2/contact-sheet.png`.
- Icon sizes: `docs/design/ios-icon-a2/sizes/`.
- Text and caption proposals: `docs/app-store/ios-m2/metadata.json` and `captions.json`.
- Capture instructions and source notes: `docs/app-store/ios-m2/README.md`.

**No milestone 2 simulator screenshots were captured.** The draft phone compositions use real milestone 1 captures and are visibly labelled `M1 reference: recapture required`. The iPad images are visibly labelled `Template only: capture required` and contain no fabricated iPad UI. Their manifest marks every image `uploadReady: false`. The contact sheets were inspected for composition only. This is not a finished App Store screenshot set.

The requested Store dimensions were checked against Apple's [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/) on 2026-11-12. No listing or app data was changed.

## Open design calls for Alex

- Subtitle: `Your Mac library, within reach` or `A remote for your Mac music`.
- Headlines: the first proposal or the alternative for each entry in `captions.json`.
- Screenshot emphasis: dark-first option A treatment or a balanced light/dark sequence using the same plan palette.
- Screenshot order: Now Playing, Library, Queue, Output, Connection, Cover Flow; alternatively move Cover Flow earlier and keep Connection later. These remain drafts.
- Review the ivory light appearance and the same-artwork light/dark icon on a real iPad. No new palette outside the supplied brand tokens was introduced.

## Work still required before calling this done

Vesper needs an unrestricted CoreSimulator session to run `python3 scripts/capture-ios-matrix.py docs/app-store/ios-m2/devices.example.json --output build/ios-m2`. Confirm the example UDIDs first: they were read from local device plists, not verified through the blocked service. Run one device at a time. The runner has not been exercised end to end and may need adjustment after its first real run.

Inspect every main screen on the 6.9-inch iPhone, iPad Pro 13-inch, iPad 11-inch and mini, in both orientations and appearances. Exercise actual OS multitasking and continuous resizing, keyboard and pointer, largest Dynamic Type, Reduce Motion and VoiceOver. Fix any issues found, then regenerate the real Store set with `scripts/compose-ios-store.py --captures build/ios-m2 --output docs/app-store/ios-m2/rendered` (Pillow required) and obtain Alex's design/copy choices.

Milestone 1's changing Mac port caveat and real Tailscale reachability remain open; verify those before using the VPN text for a submission. Streaming/playback on iOS is not part of this milestone's task.

From this worktree, push the signed branch when networking is available:

```sh
git push git@github.com:szeremeta1/Vespertine.git HEAD:refs/heads/vesper/ios-app-m2
```

Vesper opens the PR after those checks. No `gh pr create` was run.
