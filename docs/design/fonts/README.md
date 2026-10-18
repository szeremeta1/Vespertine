# Fonts for rendered artwork

Social cards (`scripts/make-social-preview.sh`) and the README tour (`scripts/make-tour.swift`) are drawn with these open fonts, not Apple's system fonts: Apple's font licence covers user-interface mock-ups for its platforms, not marketing images.

| Font | Role | Licence |
|---|---|---|
| Newsreader | Names and headlines (stands in for New York) | SIL OFL 1.1, `OFL-Newsreader.txt` |
| Inter | Interface text (stands in for SF Pro) | SIL OFL 1.1, `OFL-Inter.txt` |
| JetBrains Mono | Numbers and labels (stands in for SF Mono) | SIL OFL 1.1, `OFL-JetBrainsMono.txt` |

From [google/fonts](https://github.com/google/fonts). `web/` holds the latin-subset WOFF2 copies the artwork scripts load (`scripts/brand/BrandKit.swift`, `scripts/make-dmg-background.swift`, `docs/design/social-preview.html`). The website builds its own smaller subsets from Fontsource into `site/src/assets/fonts/` (`site/scripts/subset-fonts.sh`).
