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
| Every word on the site, in English (the source) | `src/i18n/en.json` |
| The same, in each of the app's other 44 languages | `src/i18n/<code>.json` (`de.json`, `ja.json`, `zh-Hans.json` …) |
| The site's languages, and the browser-language matching | `src/i18n/locales.mjs` (follows `LANGUAGES` in `scripts/check-localizations.py`) |
| Paths, number and date formats, release-notes fallback | `src/i18n/index.ts` |
| The home page's structure: which screenshot and links each feature has | `src/data/content.ts` (the words come from `src/i18n`) |
| Page templates, one per page, rendered once per language | `src/views/` (`src/pages/` and `src/pages/[lang]/` just pick the language) |
| The latest releases and their notes | `src/data/releases.json`, refreshed by `npm run releases` (CI runs it before every build) |
| Pages | `src/pages/` (`index`, `press`, `privacy`, `terms`, `404`, and the `llms.txt`, `llms-full.txt` and `sitemap.xml` endpoints), `src/pages/[lang]/` (the same pages in every other language) |
| Styles | `src/styles/global.css` (one file, inlined into each page) |
| Scripts | `src/scripts/main.ts` (enhancements, the language menu), `motion.ts` (GSAP + Lenis, loaded after the page, never with reduced motion), `route.ts` (the signal line), `notfound.ts` (the 404 page in the visitor's language); the first-visit language redirect is `LANG_REDIRECT` in `src/inline-scripts.mjs` |
| JSON-LD | `src/lib/seo.ts` |
| Screenshot masters | `src/assets/shots/`, `src/assets/press/`, made from `docs/screenshots` by `scripts/make-site-images.sh` (repo root); the build turns them into AVIF and WebP |
| Fonts | `src/assets/fonts/`, subsets made by `scripts/subset-fonts.sh`; licenses in `public/fonts/` |
| Social cards (1200×630, one per page and language) | `public/og/<page>.jpg` (English) and `public/og/<code>/<page>.jpg`, made by `npm run og` (or `npm run og -- el de` for some languages) from real assets and the words in `src/i18n` (`og`, the hero and page headings), in the site's own fonts and each script's system face; right-to-left cards mirror |
| Favicons and manifest icons | `public/`, made from the app icon by `npm run icons` |
| Static files served as-is | `public/`: `CNAME`, `robots.txt`, `site.webmanifest`, `.well-known/security.txt`, the trailer, and the earlier `assets/og*.png` cards |

## Languages

The site is in English and every language the app ships, one URL per language: `/`, `/press.html` … for English,
`/de/`, `/de/press.html` … for the rest. Each page has `<html lang>` (and `dir="rtl"` for Arabic, Hebrew, Persian and
Urdu), a canonical URL, `hreflang` alternates for every language plus `x-default`, `content-language` (Bing reads it),
and its own title, description, social card (image, `og:locale`, title, description) and JSON-LD; `sitemap.xml` lists
every version with its alternates. Filipino's hreflang is `tl` (Google takes ISO 639-1 codes only; `hreflangOf`).

- **Search.** Each language's home page title, description, features heading and `seo.keywords` use the words people
  there search with ("Musikplayer für Mac", "lecteur audio hi-res", "Mac 无损音乐播放器", "맥 음악 플레이어"), and the
  JSON-LD describes the app in that language (`featureList`, the card in that language).

- **Detection.** The first visit to `/` from outside the site goes to the browser's preferred language if the site has
  it (`LANG_REDIRECT`, inline in the English home page's `<head>`, `location.replace`). A language picked in the menu
  is stored in `localStorage` (`vespertine-lang`) and always wins, English included. Crawlers (`BOT_UA` in
  `src/i18n/locales.mjs`) are never redirected, and no page but `/` ever redirects, so a shared `/el/` link and its
  preview stay Greek.
- **The menu** (`src/components/LangMenu.astro`) is a `<details>` of plain links to the same page in each language, in
  each language's own name; `main.ts` remembers the choice, keeps the `#section`, and closes it on Esc or a click outside.
- **Changing words.** Edit `src/i18n/en.json`, then the same key in every locale file. Product, format and album names
  stay as they are; feature, button and badge names follow the app's own translations
  (`App/Resources/Localizable.xcstrings`), so the site and the app agree. `{placeholders}` are filled at build time.
- **Release notes** come from GitHub (`src/data/releases.json`). `npm run i18n:releases` copies the ones the site shows
  into `en.json` (`"releases"`) for translation; a release without a current translation shows in English on the other
  languages' pages, marked `lang="en"`, with a note saying so, and `check-i18n` warns until it's translated.
- `node scripts/test-i18n.mjs` (after a build; needs Google Chrome) checks the redirect, the remembered choice, that
  crawlers and shared language links aren't redirected, the menu, the localized 404, RTL mirroring and horizontal
  overflow headlessly, against `scripts/serve-dist.mjs`.

## Rules the build enforces

`scripts/check-i18n.mjs` (also its own step in the workflow) fails the build if the site's languages aren't English plus
the app's, or a locale file is missing a key, has an extra one or an empty value, changes a `{placeholder}`, an HTML tag
or (in release notes) the Markdown, or still has English in it (three common English words in a row once product names,
titles and code are set aside, or a value left as the English, unless the app's own translation uses those words).

`scripts/check-dist.mjs` fails the build (and so the deploy) if a page has an inline script its CSP doesn't allow, an
image without alt text, a `lang` or `dir` that doesn't match its folder, a canonical link other than its own URL, a
missing or wrong `hreflang` alternate, other than one `<h1>`, a title or description shared with another page in its
language, a social card that isn't a 1200×630 file in the build or isn't its language's, social tags (`og:locale` and
its alternates, `og:`/`twitter:` title, description, URL, image) that aren't the page's own, JSON-LD that doesn't parse
or lacks the app (free, macOS, its languages) or the page's language, a `noai` directive, or a local link to a file
that doesn't exist; or if `robots.txt`, `sitemap.xml`, `llms.txt`, `llms-full.txt` or `CNAME` is missing, `robots.txt`
blocks anything, or `sitemap.xml` doesn't list exactly the indexable pages with a `lastmod` and the same alternates as
each page's `<head>`.

## URLs

The pages are `/`, `/press.html`, `/privacy.html` and `/terms.html`, the same as before the rebuild, so links in release
notes, the README and search engines keep working; GitHub Pages also serves them without `.html`. Each has a copy in
every other language under `/<code>/` (`/de/`, `/de/press.html` …). GitHub Pages serves one `404.html` for every
missing path; it swaps in the visitor's language from `/<code>/404.html`.

## Crawlers

`robots.txt` allows every crawler, and names the AI ones (GPTBot, ClaudeBot, PerplexityBot, Google-Extended,
Applebot-Extended, CCBot and others) so it's explicit. `/llms.txt` and `/llms-full.txt` describe the app for language
models, built from the same data as the pages.
