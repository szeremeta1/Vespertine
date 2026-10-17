# vespertineapp.com

The Vespertine website: a static [Astro](https://astro.build) site, published to GitHub Pages by
[`.github/workflows/pages.yml`](../.github/workflows/pages.yml) on every push to `main` that touches it, and whenever a
release is published. Its design system (tokens, type, motion, the routed signal line) comes from szeremeta.org, in
Vespertine's own colors and type from [`docs/brand`](../docs/brand).

```sh
cd site
npm ci
npm run dev        # http://localhost:4321
npm run build      # dist/, then scripts/check-dist.mjs
npm run preview    # serve dist/
```

Needs Node 22.12 or later (`.node-version` pins what CI uses).

## Where things live

| What | Where |
|---|---|
| Facts every page shares: version, links, requirements, Homebrew command | `src/data/app.ts` |
| The home page's words: features, formats, comparison, FAQ, support | `src/data/content.ts` |
| The latest releases and their notes | `src/data/releases.json`, refreshed by `npm run releases` (CI runs it before every build) |
| Pages | `src/pages/` (`index`, `press`, `privacy`, `terms`, `404`, and the `llms.txt`, `llms-full.txt` and `sitemap.xml` endpoints) |
| Styles | `src/styles/global.css` (one file, inlined into each page) |
| Scripts | `src/scripts/main.ts` (enhancements), `motion.ts` (GSAP + Lenis, loaded after the page, never with reduced motion), `route.ts` (the signal line) |
| JSON-LD | `src/lib/seo.ts` |
| Screenshot masters | `src/assets/shots/`, `src/assets/press/`, made from `docs/screenshots` by `scripts/make-site-images.sh` (repo root); the build turns them into AVIF and WebP |
| Fonts | `src/assets/fonts/`, subsets made by `scripts/subset-fonts.sh`; licenses in `public/fonts/` |
| Social cards (1200×630, one per page) | `public/og/`, made by `npm run og` from real assets in the site's own fonts |
| Favicons and manifest icons | `public/`, made from the app icon by `npm run icons` |
| Static files served as-is | `public/`: `CNAME`, `robots.txt`, `site.webmanifest`, `.well-known/security.txt`, the trailer, and the earlier `assets/og*.png` cards |

## Rules the build enforces

`scripts/check-dist.mjs` fails the build (and so the deploy) if a page has an inline script its CSP doesn't allow, an
image without alt text, no canonical link, other than one `<h1>`, a title or description shared with another page, a
social card that isn't a 1200×630 file in the build, JSON-LD that doesn't parse, a `noai` directive, or a local link to
a file that doesn't exist; or if `robots.txt`, `sitemap.xml`, `llms.txt`, `llms-full.txt` or `CNAME` is missing.

## URLs

The pages are `/`, `/press.html`, `/privacy.html` and `/terms.html`, the same as before the rebuild, so links in release
notes, the README and search engines keep working; GitHub Pages also serves them without `.html`.

## Crawlers

`robots.txt` allows every crawler, and names the AI ones (GPTBot, ClaudeBot, PerplexityBot, Google-Extended,
Applebot-Extended, CCBot and others) so it's explicit. `/llms.txt` and `/llms-full.txt` describe the app for language
models, built from the same data as the pages.
