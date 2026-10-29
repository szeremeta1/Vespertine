// Renders the social cards (Open Graph, X/Twitter, iMessage, Slack, LinkedIn, WhatsApp…), one per page and language,
// 1200×630: public/og/<page>.jpg in English, public/og/<code>/<page>.jpg in each of the site's other languages, so a
// link to /el/ previews in Greek. Each card is plain HTML drawn in the site's own fonts (and, for other scripts, the
// same system faces the site falls back to, from src/styles/global.css) from real assets (the brand lockup and mark,
// real app screenshots) and the words in src/i18n/<code>.json, rendered by headless Chrome. No generated imagery.
// Right-to-left languages mirror the layout, as the site does. Headlines that run long shrink until they fit.
// Deterministic: the same inputs, fonts and Chrome give the same pixels. No version number, so a release doesn't make
// the cards stale; a change to a card's words does (re-run it).
//   npm run og                 every language (needs Google Chrome; playwright-core drives it)
//   npm run og -- el de ja     just these languages (en for the English cards)
import { chromium } from 'playwright-core';
import sharp from 'sharp';
import { mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { LOCALES, CODES, DEFAULT_LOCALE } from '../src/i18n/locales.mjs';

const here = (p) => fileURLToPath(new URL(p, import.meta.url));
const url = (p) => new URL(p, import.meta.url).href;
const tmp = here('../.og-build/');
const out = here('../public/og/');
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const minMacOS = readFileSync(here('../src/data/app.ts'), 'utf8').match(/minMacOS: '([^']+)'/)[1];
const fill = (s) => s.replace(/\{minMacOS\}/g, minMacOS).replace(/\{name\}/g, 'Vespertine');

// The site's per-script font stacks (--serif, --sans, --mono by :lang), so each card is set as its page is.
const fontRules = readFileSync(here('../src/styles/global.css'), 'utf8').split('\n')
  .filter((l) => /^(\[lang\]|:is\(:lang|:lang\()/.test(l) && /--(serif|sans|mono):/.test(l)).join('\n');

// Scripts with no capitals, italics or tracking (as in global.css), and the ones that need taller lines.
const UNTRACKED = new Set(['ar', 'fa', 'ur', 'hi', 'mr', 'bn', 'gu', 'pa', 'ta', 'te', 'kn', 'ml', 'th', 'am']);
const CJK = new Set(['ja', 'ko', 'zh-Hans', 'zh-Hant', 'zh-HK']);
const NO_ITALIC = new Set([...UNTRACKED, ...CJK, 'he']);

const css = `
@font-face { font-family: "Newsreader"; font-style: normal; font-weight: 300 400; src: url(${url('../src/assets/fonts/newsreader-roman.woff2')}) format("woff2"); }
@font-face { font-family: "Newsreader"; font-style: italic; font-weight: 300; src: url(${url('../src/assets/fonts/newsreader-italic.woff2')}) format("woff2"); }
@font-face { font-family: "Inter"; font-weight: 400 600; src: url(${url('../src/assets/fonts/inter.woff2')}) format("woff2"); }
@font-face { font-family: "JetBrains Mono"; font-weight: 400 500; src: url(${url('../src/assets/fonts/jetbrains-mono.woff2')}) format("woff2"); }
@font-face { font-family: "Newsreader fallback"; font-style: normal; src: local("Georgia"); unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02C6, U+02DA, U+02DC, U+2000-206F, U+20AC, U+2122; size-adjust: 91.67%; ascent-override: 80.18%; descent-override: 28.91%; line-gap-override: 0%; }
@font-face { font-family: "Newsreader fallback"; font-style: italic; src: local("Georgia Italic"), local("Georgia-Italic"); unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02C6, U+02DA, U+02DC, U+2000-206F, U+20AC, U+2122; size-adjust: 81.88%; ascent-override: 89.76%; descent-override: 32.36%; line-gap-override: 0%; }
@font-face { font-family: "Inter fallback"; src: local("Arial"), local("ArialMT"); unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02C6, U+02DA, U+02DC, U+2000-206F, U+20AC, U+2122; size-adjust: 106.39%; ascent-override: 91.06%; descent-override: 22.67%; line-gap-override: 0%; }
@font-face { font-family: "JetBrains Mono fallback"; src: local("Menlo"), local("Menlo-Regular"); unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02C6, U+02DA, U+02DC, U+2000-206F, U+20AC, U+2122; size-adjust: 99.66%; ascent-override: 102.35%; descent-override: 30.10%; line-gap-override: 0%; }
${fontRules}
* { box-sizing: border-box; }
html, body { margin: 0; width: 1200px; height: 630px; overflow: hidden; background: #09090a; }
.card {
  position: relative; width: 1200px; height: 630px; overflow: hidden; color: #ece6da; font-family: var(--sans);
  background:
    radial-gradient(620px 520px at 84% 44%, rgba(200, 166, 106, .2), transparent 66%),
    radial-gradient(700px 500px at 0% 100%, rgba(201, 139, 91, .08), transparent 60%),
    #09090a;
}
[dir="rtl"] .card {
  background:
    radial-gradient(620px 520px at 16% 44%, rgba(200, 166, 106, .2), transparent 66%),
    radial-gradient(700px 500px at 100% 100%, rgba(201, 139, 91, .08), transparent 60%),
    #09090a;
}
.grain { position: absolute; inset: 0; opacity: .07; background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2' stitchTiles='stitch' seed='7'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E"); }
.copy { position: absolute; inset-inline-start: 72px; top: 58px; width: 640px; }
.lockup { display: block; height: 88px; margin-block: 0 22px; margin-inline-start: -22px; }
.eyebrow { font: 500 15px/1 var(--mono); letter-spacing: .16em; text-transform: uppercase; color: #c8a66a; margin: 18px 0 18px; }
h1 { font: 300 66px/1.0 var(--serif); letter-spacing: -.03em; font-variation-settings: "opsz" 72; margin: 0; }
h1.big { font-size: 84px; }
/* The gradient paints only inside the padding box; the pad covers the italic's overhang (Alex 2026-10-17). */
.brass-italic {
  font-style: italic; color: #c8a66a;
  background: linear-gradient(100deg, #e7cd98 8%, #c8a66a 48%, #c98b5b 92%);
  -webkit-background-clip: text; background-clip: text; -webkit-text-fill-color: transparent;
  padding: .22em .26em .26em; margin: -.22em -.26em -.26em;
}
[dir="rtl"] .brass-italic { background: linear-gradient(260deg, #e7cd98 8%, #c8a66a 48%, #c98b5b 92%); -webkit-background-clip: text; background-clip: text; }
p.lede { font-size: 21px; line-height: 1.5; color: #c9c2b5; margin: 24px 0 0; width: 560px; }
.chips { display: flex; flex-wrap: wrap; gap: 9px; margin-top: 26px; width: 600px; }
.chip { font: 500 13px/1 var(--mono); letter-spacing: .12em; text-transform: uppercase; color: #a29b8f; border: 1px solid rgba(236,230,218,.16); border-radius: 7px; padding: 8px 11px; white-space: nowrap; }
.chip.brass { color: #c8a66a; border-color: rgba(200,166,106,.55); }
.chip.brass::before { content: "●"; font-size: 9px; margin-inline-end: 8px; vertical-align: 2px; }
.foot { position: absolute; inset-inline-start: 72px; bottom: 44px; max-width: 1056px; white-space: nowrap; font: 400 16px/1 var(--mono); letter-spacing: .04em; color: #8f897e; }
.foot b { color: #e7cd98; font-weight: 500; }
.panel { position: absolute; inset-inline-end: 72px; top: 44px; width: 340px; height: 466px; border-radius: 18px; overflow: hidden; background: #0d0d0f;
  box-shadow: 0 0 0 1px rgba(231,205,152,.25), 0 40px 90px -30px rgba(0,0,0,.9), 0 0 90px -16px rgba(200,166,106,.42); }
.panel img { width: 100%; display: block; }
.panel::after { content: ""; position: absolute; inset: 0; background: linear-gradient(180deg, rgba(13,13,15,0) 70%, rgba(13,13,15,.95)), linear-gradient(120deg, rgba(255,255,255,.06), transparent 35%); }
.stack { position: absolute; inset-inline-end: 0; top: 0; width: 560px; height: 530px; overflow: hidden; -webkit-mask-image: linear-gradient(180deg, #000 82%, transparent); mask-image: linear-gradient(180deg, #000 82%, transparent); }
.stack img { position: absolute; width: 520px; border-radius: 12px; box-shadow: 0 0 0 1px rgba(236,230,218,.14), 0 40px 80px -24px rgba(0,0,0,.95); }
.mark { position: absolute; inset-inline-end: 120px; top: 130px; width: 330px; height: 330px; filter: drop-shadow(0 0 60px rgba(200,166,106,.35)); }
.rule { position: absolute; left: 72px; right: 72px; bottom: 86px; height: 1px; background: rgba(236,230,218,.09); }
/* Other scripts, as on the site: no tracking or synthetic italics, room for tall marks and stacks. */
.no-italic .brass-italic { font-style: normal; }
.no-italic h1, .cjk .eyebrow { letter-spacing: 0; }
.untracked * { letter-spacing: normal !important; }
.untracked h1 { line-height: 1.22; }
.untracked .brass-italic { padding-block: .3em .34em; margin-block: -.3em -.34em; }
.cjk h1 { line-height: 1.12; }
.untracked .eyebrow, .cjk .eyebrow, .untracked .foot, .cjk .foot, .untracked .chip { line-height: 1.3; }
.lang-ur h1 { line-height: 1.6; }
.lang-ko { word-break: keep-all; }
.lang-ja h1 { word-break: auto-phrase; }
`;

const lockup = url('../src/assets/brand/logo.svg');
const shot = (n) => url(`../src/assets/shots/${n}.jpg`);
const press = (n) => url(`../src/assets/press/${n}.jpg`);
const mark = url('../../docs/brand/mark.svg');
const brass = (s) => `<span class="brass-italic">${esc(s)}</span>`;
const bdi = (s) => `<bdi>${esc(s)}</bdi>`;

/** The four cards' HTML in one language, from its locale file (the English cards are the originals, word for word). */
function cards(lang) {
  const s = JSON.parse(readFileSync(here(`../src/i18n/${lang}.json`), 'utf8'));
  const h = s.home.hero;
  const og = s.og;
  // "free and open source · macOS 14.4+ · Apple silicon and Intel": the hero's eyebrow, mid-line.
  const [free, mac, arch] = h.eyebrow.map(fill);
  const lower = (x) => (x.length > 1 && x[1] === x[1].toLocaleLowerCase(lang) ? x[0].toLocaleLowerCase(lang) + x.slice(1) : x);
  const foot = `<div class="rule"></div><div class="foot"><b>vespertineapp.com</b> · ${bdi(lower(free))} · ${bdi(mac)} · ${bdi(arch)}</div>`;
  const before = (whole, tail) => esc(whole.slice(0, whole.length - tail.length));
  // The press heading puts the name where the language needs it; the name and the full stop after it are brass.
  const [pBefore, pRest = ''] = fill(s.press.heading).replace('Vespertine', '\u0000').split('\u0000');
  const pStop = pRest.match(/^[.。।۔።]?/)[0];
  return {
    home: `
    <div class="copy">
      <img class="lockup" src="${lockup}" alt="">
      <h1>${before(h.titleSr, h.titleBrass)}${brass(h.titleBrass)}</h1>
      <p class="lede">${esc(og.homeLede)}</p>
      <div class="chips"><span class="chip brass">${esc(s.home.badges.bitPerfect)}</span><span class="chip" dir="ltr">SACD ISO</span><span class="chip" dir="ltr">DSD · DoP</span><span class="chip">${esc(og.spatial)}</span></div>
    </div>
    <div class="panel"><img src="${shot('bit-perfect-fosi-zd3-24-96-detail')}" alt=""></div>
    ${foot}`,
    press: `
    <div class="copy" style="width:560px">
      <img class="lockup" src="${lockup}" alt="">
      <p class="eyebrow">${esc(s.press.eyebrow)}</p>
      <h1>${esc(pBefore)}${brass(`Vespertine${pStop}`)}${esc(pRest.slice(pStop.length))}</h1>
      <p class="lede" style="width:520px">${esc(og.pressLede)}</p>
    </div>
    <div class="stack">
      <img src="${press('shot-genres')}" style="inset-inline-start:70px;top:44px;opacity:.55" alt="">
      <img src="${press('shot-sacd-iso')}" style="inset-inline-start:40px;top:178px;opacity:.8" alt="">
      <img src="${press('shot-spatial-audio-airpods-max')}" style="inset-inline-start:12px;top:312px" alt="">
    </div>
    ${foot}`,
    privacy: `
    <div class="copy">
      <img class="lockup" src="${lockup}" alt="">
      <p class="eyebrow">${esc(s.privacy.eyebrow)}</p>
      <h1 class="big">${esc(s.privacy.heading)} ${brass(s.privacy.headingBrass)}</h1>
      <p class="lede">${esc(og.privacyLede)}</p>
    </div>
    <img class="mark" src="${mark}" alt="">
    ${foot}`,
    terms: `
    <div class="copy">
      <img class="lockup" src="${lockup}" alt="">
      <p class="eyebrow">${esc(s.terms.eyebrow)}</p>
      <h1 class="big">${esc(s.terms.heading)} ${brass(s.terms.headingBrass)}</h1>
      <p class="lede">${esc(og.termsLede)}</p>
    </div>
    <img class="mark" src="${mark}" alt="">
    ${foot}`,
  };
}

/** Shrink what runs long until it fits: the headline, then the lede, above the rule; the foot within the margins. */
function fit() {
  const room = 630 - 86 - 24;
  const copy = document.querySelector('.copy');
  const h1 = document.querySelector('h1');
  const lede = document.querySelector('.lede');
  const foot = document.querySelector('.foot');
  const over = () => copy.getBoundingClientRect().bottom > room || h1.scrollWidth > h1.clientWidth + 1;
  let size = parseFloat(getComputedStyle(h1).fontSize);
  while (over() && size > 40) h1.style.fontSize = `${(size -= 2)}px`;
  let small = parseFloat(getComputedStyle(lede).fontSize);
  while (over() && small > 16) lede.style.fontSize = `${(small -= 1)}px`;
  let f = 16;
  while (foot.getBoundingClientRect().width > 1056 && f > 11) foot.style.fontSize = `${(f -= 0.5)}px`;
  return { h1: size, lede: small, foot: f, overflow: over() || foot.getBoundingClientRect().width > 1056 };
}

const only = process.argv.slice(2);
const langs = only.length ? only : CODES;
for (const l of langs) if (!CODES.includes(l)) throw new Error(`${l} isn't one of the site's languages`);
mkdirSync(tmp, { recursive: true });
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
const problems = [];
for (const lang of langs) {
  const loc = LOCALES.find((l) => l.code === lang);
  const dir = loc.rtl ? 'rtl' : 'ltr';
  const cls = [`lang-${lang}`, NO_ITALIC.has(lang) && 'no-italic', UNTRACKED.has(lang) && 'untracked', CJK.has(lang) && 'cjk'].filter(Boolean).join(' ');
  const dest = lang === DEFAULT_LOCALE ? out : `${out}${lang}/`;
  mkdirSync(dest, { recursive: true });
  for (const [name, body] of Object.entries(cards(lang))) {
    const file = `${tmp}${lang}-${name}.html`;
    writeFileSync(file, `<!doctype html><html lang="${lang}" dir="${dir}"><head><meta charset="utf-8"><style>${css}</style></head><body><div class="card ${cls}"><div class="grain"></div>${body}</div></body></html>`);
    await page.goto(`file://${file}`, { waitUntil: 'load' });
    await page.evaluate(() => document.fonts.ready);
    const sized = await page.evaluate(fit);
    if (sized.overflow) problems.push(`${lang}/${name}: still runs over at the smallest sizes`);
    const png = await page.screenshot({ type: 'png', clip: { x: 0, y: 0, width: 1200, height: 630 } });
    writeFileSync(`${tmp}${lang}-${name}.png`, png);
    await sharp(png).jpeg({ quality: 88, progressive: true, mozjpeg: true, chromaSubsampling: '4:4:4' }).toFile(`${dest}${name}.jpg`);
    console.log(`og/${lang === DEFAULT_LOCALE ? '' : `${lang}/`}${name}.jpg  h1 ${sized.h1}px · lede ${sized.lede}px · foot ${sized.foot}px`);
  }
}
await browser.close();
if (!process.env.KEEP_OG_BUILD) rmSync(tmp, { recursive: true, force: true });
if (problems.length) {
  console.error(problems.join('\n'));
  process.exit(1);
}
