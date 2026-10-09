# Press and post images

Vespertine is the free, open-source Mac player for surround and hi-res music collections. Lead with extracted SACD 5.1 tracks, DTS CDs, DTS-HD MA, TrueHD and Atmos files in one library, with head-tracked Spatial Audio on AirPods. The source is GPL and the signal-path conditions and tests are public.

Channel-for-channel output and receiver bitstream are experimental, untested on real receivers/multichannel DACs; reports wanted. SACD ISO is not supported yet. PCM hardware checks reach 384 kHz; DSD file support is not proof of native DoP playback at every rate. Hi-res analysis is a feature other players offer too. Use the [feature details](../FEATURES.md), [verification guide](../VERIFICATION.md) and [comparison sources](../COMPARISON.md) when writing claims.

Each image covers one feature at three sizes:

| Suffix | Size | Use |
|---|---|---|
| `-hero` | 2400×1350 | release page, Reddit, Hacker News, the site |
| `-x` | 1600×900 | X and Bluesky |
| `-producthunt` | 1270×760 | Product Hunt gallery |

The features are `bit-perfect`, `stereo-and-surround`, `spatial-audio`, `native-dsd` and `fake-hi-res`. They're built from `docs/screenshots` by `scripts/brand/build.sh`, and follow the [brand guide](../brand/brand-guide.pdf).

The fake hi-res screenshot and trailer scene show a deliberate fake, so no real release is called one: the trailer's own score, encoded to MP3 at 192 kb/s, decoded and upsampled to 24-bit / 192 kHz, and credited to a made-up band (The Lantern Lounge Orchestra, *After Midnight (24/192 Remaster)*).

## Launch trailer

A 36.6 s trailer in 16:9 and 1:1, with an original score: synthesized from scratch by `scripts/brand/stage/score.py` (no samples or loops), so it's Vespertine's own and free to use with the trailer anywhere.
- **Scenes:** `scripts/brand/stage` (`render.sh`, `patch.sh`, `deliver.sh`) renders them as ProRes with half-second handles. They're built from window-only screen recordings of the app on the maker's library: ScreenCaptureKit, only the Vespertine window, no other windows or notifications.
- **Edit:** assembled in Final Cut Pro from an FCPXML, with cuts on the bar lines and 16-frame dissolves.
- **Delivery:** H.264 at −14 LUFS.

The 16:9 trailer (web and 1080p versions) is in `site/assets/trailer`. The ProRes masters and the 1:1 and 9:16 versions aren't kept in the repo.
