# Milestone 2 App Store kit: draft only

No assets or metadata have been uploaded. Alex has approved the A2 icon only. All copy and promotional treatments here are proposals for his review. The app remains a Mac remote; this kit makes no claim that music plays on iOS, or that an iOS audio route is bit-perfect.

## Sources and treatment

The local Vespertine brand guide and marketing sources (`docs/brand/README.md`, `scripts/brand/BrandKit.swift`, `docs/press/README.md`) define obsidian, ivory, brass, Newsreader, Inter and JetBrains Mono. Option A in the supplied plan defines frameless screens with one Newsreader headline and a small mono caption. The renderer follows that as a reviewable draft. It uses the bundled OFL fonts, not Apple's UI fonts.

HuskyHowl references were read locally at `~/Desktop/Projects/HuskyHowl/promo/screenshot-capture-guide.md`, `promo/source/social.html` and `promo/source/kit.css`: real device captures, dark and light sets, a short headline and a secondary label. Its sports-specific colours/type are not applied to Vespertine. No `asc` executable or App Store connector was available. HuskyHowl's current live listing is unverified; local promo assets were used instead. A Vespertine Mac App Store listing was not found locally; repo marketing assets were used.

## Dimensions

The requested 6.9-inch set uses 1320 x 2868; iPad 13-inch uses 2064 x 2752. Both are accepted in Apple's [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/), checked 2026-11-12. Output is RGB PNG with no alpha. The source capture may be one of Apple's other accepted resolutions; the renderer preserves its aspect ratio and fits the entire screen below the caption.

## Production

1. In a normal CoreSimulator session, confirm the UDIDs and device names in `devices.example.json`. These UDIDs were read from local device plists; availability was not verified through the blocked Simulator service.
2. From the repo root run `python3 scripts/capture-ios-matrix.py docs/app-store/ios-m2/devices.example.json --output build/ios-m2`. All four devices run serially. It refuses to boot while any other simulator is already booted. It boots and shuts down only the selected UDID, never all simulators. XCTest parallelism is disabled. Test results, portrait/landscape captures, and light/dark folders stay under `build/ios-m2/`.
3. Review the actual Split View, Slide Over and Stage Manager behaviours manually on a supported iPadOS version. The 440 pt UI-test harness checks narrow layout rendering, not OS multitasking. Inspect 320, 440, 507, 600, 744 and full-screen widths, with the keyboard and pointer, default and accessibility text sizes. Keep queue selection through live resizing. Current automation does not establish OS multitasking correctness.
4. Run `python3 scripts/compose-ios-store.py --captures build/ios-m2 --output docs/app-store/ios-m2/rendered` (Pillow required). Missing sources remain labelled templates; the manifest reports every missing screen. It never substitutes a phone capture for an iPad capture.
5. Inspect every raw and composed PNG, then let Alex choose headlines, screenshot order, light/dark emphasis and the final subtitle. Remove draft status only after recapture, real visual review and his approval.

## Current state

Sandbox denies CoreSimulator XPC, so no milestone 2 simulator screenshots exist. `draft-reference/` uses genuine, unchanged milestone 1 phone captures solely to make the caption treatment reviewable. Every such image is visibly labelled as a milestone 1 reference. The iPad set contains labelled capture slots, not fabricated iPad UI. Neither is an upload-ready screenshot set.

`metadata.json` contains all requested text fields, a second subtitle option and review notes. `captions.json` contains a headline alternative for each screen. These require Alex's wording approval, and the VPN wording needs a real connection check and resolution of milestone 1's changing-port caveat before submission.
