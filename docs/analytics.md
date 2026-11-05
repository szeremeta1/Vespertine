# Website analytics

What the vespertineapp.com website counts, and how to read and tag it. The **app** has no analytics and never contacts the stats server; this page is only about the website. The privacy wording shown to visitors is on the [privacy page](https://vespertineapp.com/privacy.html).

## How it works

- The site loads one script, [Umami](https://umami.is), self-hosted at `https://stats.szeremeta.org/howl.js` (website id `a4b69e33-e989-45bd-bbc2-4d6b1036aa63`, only on `vespertineapp.com` and `www.vespertineapp.com`, and it skips visitors whose browser sends Do Not Track). No cookies, nothing stored on the device, no IP address kept. The script tag is in `site/src/layouts/Base.astro`; `scripts/check-dist.mjs` fails the build if it changes or its CSP entry is missing.
- `site/public/track.js` turns clicks on links into named events with one delegated listener, so no per-link markup is needed. **It is a copy shared with huskyhowl.app and readbaba.com** (`public/assets/track.js` in HuskyHowlServer, `server/public/site/track.js` in Baba). Keep the event names identical across the three, so one dashboard convention covers all. `placement` is the nearest `data-placement` attribute, else the enclosing `header`, `nav`, `footer` or `main`.

## Events

| Event | When | Data |
|---|---|---|
| `app-store-click` | a link to apps.apple.com or itunes.apple.com (none on this site today; kept for parity) | `placement`, `ct`, `locale` |
| `testflight-click` | testflight.apple.com | `placement`, `locale` |
| `download` | a release asset or file link (`.dmg`, `.zip` …), e.g. the Download buttons | `file`, `version`, `placement`, `locale` |
| `github-click` | any other github.com link | `kind` (`release`, `issues`, `docs`, `repo`), `placement`, `locale` |
| `email-click` | a `mailto:` link (the address is not recorded) | `placement`, `locale` |
| `outbound-click` | any other external host | `host`, `placement`, `locale` |
| `brew-copy` | the Copy button next to the Homebrew command | `placement`, `locale` |

Pages added later may add events (for example a `faq-open` event with `page` and `q`, and `compare-click` with `from` and `to`, for the English guide pages); they are listed here once they are on `main`.

`locale` is the page's `<html lang>`, so the 45 language versions can be told apart.

## Campaign links (UTM)

- **Don't tag links between Alex's own sites.** The referrer already attributes them, and tags would split the campaign list.
- Tag links placed **off-site** (QR codes, flyers, emails, social bios, directory submissions, launch posts). Umami reads `utm_source`, `utm_medium`, `utm_campaign`, `utm_content` and `utm_term` itself.
- Lowercase, hyphens only, no personal data:
  - `utm_source` = the platform: `flyer`, `email`, `x`, `reddit`, `hn`, `discord`, `producthunt`, `alternativeto`, `github`
  - `utm_medium` = `qr`, `email`, `social`, `directory`, `press`, `referral`
  - `utm_campaign` = `<site>-<yyyymm>-<slug>`, at most 40 characters, e.g. `vespertine-202611-launch`
  - `utm_content` = the variant, e.g. `poster-a`, `qr-door`
- Example: `https://vespertineapp.com/?utm_source=reddit&utm_medium=social&utm_campaign=vespertine-202611-launch`
- The same string is the App Store `ct` value on the sites that link to the App Store (huskyhowl.app and readbaba.com), so App Store Connect campaigns line up with Umami. Vespertine isn't on the App Store, so `ct` doesn't apply here.

## Revenue

None is tracked: Vespertine is free and the website has no checkout. (GitHub Sponsors is off-site.) If a web checkout or donation page ever appears, fire an event with `revenue` and `currency` fields then; don't invent a figure before.

## Goals and funnels (set up in the Umami dashboard, no code)

- Funnel: pageview `/` → `download` (by `version`) and → `brew-copy`.
- Split `outbound-click` and `github-click` by `placement` and `kind`.
- Event names in the dashboard are as the code defines them here; the dashboard's current contents haven't been checked from the repository (**unverified**).
