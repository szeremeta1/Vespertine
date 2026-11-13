# Approved A2 horizon icon

Alex selected A2 on 2026-11-12 at 13:45. The universal AppIcon catalog uses the original A2-horizon artwork from milestone 1, unchanged. As the plan specifies, light and dark use the same obsidian field. The tinted master is the original grayscale A2 variant, with an opaque black field.

Xcode generates iPhone and iPad icon renditions from the three 1024 px masters. `sizes/` provides opaque RGB PNGs at device, Settings, Spotlight and marketing pixel sizes for inspection. No rounded corners are baked in.

Reproduce with `python3 scripts/prepare-ios-icons.py` (Pillow required). Masters stay in `docs/design/ios-icon-proposals/`.
