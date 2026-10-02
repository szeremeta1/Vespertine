# Press and post images

Each image covers one feature at three sizes:

| Suffix | Size | Use |
|---|---|---|
| `-hero` | 2400×1350 | release page, Reddit, Hacker News, the site |
| `-x` | 1600×900 | X and Bluesky |
| `-producthunt` | 1270×760 | Product Hunt gallery |

The features are `bit-perfect`, `stereo-and-surround`, `spatial-audio`, `native-dsd` and `fake-hi-res`. They're built from `docs/screenshots` by `scripts/brand/build.sh`, and follow the [brand guide](../brand/brand-guide.pdf).

## Launch trailer

A 36.6 s trailer in 16:9 and 1:1, cut to "Starlight Lounge" from iMovie's royalty-free music (Apple licenses it for use in your own projects).
- **Scenes:** `scripts/brand/stage` (`render.sh`, `patch.sh`, `deliver.sh`) renders them as ProRes with half-second handles. They're built from window-only screen recordings of the app on the maker's library: ScreenCaptureKit, only the Vespertine window, no other windows or notifications.
- **Edit:** assembled in Final Cut Pro from an FCPXML, with cuts on the bar lines and 16-frame dissolves.
- **Delivery:** H.264 at −14 LUFS.

The 16:9 trailer (web and 1080p versions) is in `site/assets/trailer`. The ProRes masters and the 1:1 and 9:16 versions aren't kept in the repo.
