// Renders the per-page social cards (Open Graph, X/Twitter, iMessage, Slack, LinkedIn…) to public/og/<page>.jpg,
// 1200×630. Each card is plain HTML drawn in the site's own fonts from real assets (the brand lockup and mark, and
// real app screenshots), rendered by headless Chrome. No generated imagery. Deterministic: the same inputs and Chrome
// give the same pixels. The cards carry no version number, so a release doesn't make them stale.
//   npm run og            (needs Google Chrome; playwright-core drives it)
import { chromium } from 'playwright-core';
import sharp from 'sharp';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const here = (p) => fileURLToPath(new URL(p, import.meta.url));
const url = (p) => new URL(p, import.meta.url).href;
const tmp = here('../.og-build/');
const out = here('../public/og/');

const css = `
@font-face { font-family: "Newsreader"; font-style: normal; font-weight: 300 400; src: url(${url('../src/assets/fonts/newsreader-roman.woff2')}) format("woff2"); }
@font-face { font-family: "Newsreader"; font-style: italic; font-weight: 300; src: url(${url('../src/assets/fonts/newsreader-italic.woff2')}) format("woff2"); }
@font-face { font-family: "Inter"; font-weight: 400 600; src: url(${url('../src/assets/fonts/inter.woff2')}) format("woff2"); }
@font-face { font-family: "JetBrains Mono"; font-weight: 400 500; src: url(${url('../src/assets/fonts/jetbrains-mono.woff2')}) format("woff2"); }
* { box-sizing: border-box; }
html, body { margin: 0; width: 1200px; height: 630px; overflow: hidden; background: #09090a; }
.card {
  position: relative; width: 1200px; height: 630px; overflow: hidden; color: #ece6da; font-family: "Inter", sans-serif;
  background:
    radial-gradient(620px 520px at 84% 44%, rgba(200, 166, 106, .2), transparent 66%),
    radial-gradient(700px 500px at 0% 100%, rgba(201, 139, 91, .08), transparent 60%),
    #09090a;
}
.grain { position: absolute; inset: 0; opacity: .07; background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2' stitchTiles='stitch' seed='7'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E"); }
.copy { position: absolute; left: 72px; top: 58px; width: 640px; }
.lockup { display: block; height: 88px; margin: 0 0 22px -22px; }
.eyebrow { font: 500 15px/1 "JetBrains Mono", monospace; letter-spacing: .16em; text-transform: uppercase; color: #c8a66a; margin: 18px 0 18px; }
h1 { font: 300 66px/1.0 "Newsreader", serif; letter-spacing: -.03em; font-variation-settings: "opsz" 72; margin: 0; }
h1.big { font-size: 84px; }
/* The gradient paints only inside the padding box; the pad covers the italic's overhang (Alex 2026-10-17). */
.brass-italic {
  font-style: italic; color: #c8a66a;
  background: linear-gradient(100deg, #e7cd98 8%, #c8a66a 48%, #c98b5b 92%);
  -webkit-background-clip: text; background-clip: text; -webkit-text-fill-color: transparent;
  padding: .22em .26em .26em; margin: -.22em -.26em -.26em;
}
p.lede { font-size: 21px; line-height: 1.5; color: #c9c2b5; margin: 24px 0 0; width: 560px; }
.chips { display: flex; flex-wrap: wrap; gap: 9px; margin-top: 26px; width: 600px; }
.chip { font: 500 13px/1 "JetBrains Mono", monospace; letter-spacing: .12em; text-transform: uppercase; color: #a29b8f; border: 1px solid rgba(236,230,218,.16); border-radius: 7px; padding: 8px 11px; }
.chip.brass { color: #c8a66a; border-color: rgba(200,166,106,.55); }
.chip.brass::before { content: "●"; font-size: 9px; margin-right: 8px; vertical-align: 2px; }
.foot { position: absolute; left: 72px; bottom: 44px; font: 400 16px/1 "JetBrains Mono", monospace; letter-spacing: .04em; color: #8f897e; }
.foot b { color: #e7cd98; font-weight: 500; }
.panel { position: absolute; right: 72px; top: 44px; width: 340px; height: 466px; border-radius: 18px; overflow: hidden; background: #0d0d0f;
  box-shadow: 0 0 0 1px rgba(231,205,152,.25), 0 40px 90px -30px rgba(0,0,0,.9), 0 0 90px -16px rgba(200,166,106,.42); }
.panel img { width: 100%; display: block; }
.panel::after { content: ""; position: absolute; inset: 0; background: linear-gradient(180deg, rgba(13,13,15,0) 70%, rgba(13,13,15,.95)), linear-gradient(120deg, rgba(255,255,255,.06), transparent 35%); }
.stack { position: absolute; right: 0; top: 0; width: 560px; height: 530px; overflow: hidden; -webkit-mask-image: linear-gradient(180deg, #000 82%, transparent); mask-image: linear-gradient(180deg, #000 82%, transparent); }
.stack img { position: absolute; width: 520px; border-radius: 12px; box-shadow: 0 0 0 1px rgba(236,230,218,.14), 0 40px 80px -24px rgba(0,0,0,.95); }
.mark { position: absolute; right: 120px; top: 130px; width: 330px; height: 330px; filter: drop-shadow(0 0 60px rgba(200,166,106,.35)); }
.rule { position: absolute; left: 72px; right: 72px; bottom: 86px; height: 1px; background: rgba(236,230,218,.09); }
`;

const lockup = url('../src/assets/brand/logo.svg');
const shot = (n) => url(`../src/assets/shots/${n}.jpg`);
const press = (n) => url(`../src/assets/press/${n}.jpg`);
const mark = url('../../docs/brand/mark.svg');
const foot = '<div class="rule"></div><div class="foot"><b>vespertineapp.com</b> · free and open source · macOS 14.4+ · Apple silicon and Intel</div>';

const cards = {
  home: `
    <div class="copy">
      <img class="lockup" src="${lockup}" alt="">
      <h1>Surround and hi-res music, <span class="brass-italic">on your Mac.</span></h1>
      <p class="lede">SACD and DVD-Video images, DSD, Dolby Atmos, TrueHD and DTS in one library, with a signal path you can check.</p>
      <div class="chips"><span class="chip brass">Bit-perfect</span><span class="chip">SACD ISO</span><span class="chip">DSD · DoP</span><span class="chip">Spatial Audio</span></div>
    </div>
    <div class="panel"><img src="${shot('bit-perfect-fosi-zd3-24-96-detail')}" alt=""></div>
    ${foot}`,
  press: `
    <div class="copy" style="width:560px">
      <img class="lockup" src="${lockup}" alt="">
      <p class="eyebrow">Press kit</p>
      <h1>Everything you need to write about <span class="brass-italic">Vespertine.</span></h1>
      <p class="lede" style="width:520px">Fact sheet, logos, key art, real screenshots and the trailer.</p>
    </div>
    <div class="stack">
      <img src="${press('shot-genres')}" style="left:70px;top:44px;opacity:.55" alt="">
      <img src="${press('shot-sacd-iso')}" style="left:40px;top:178px;opacity:.8" alt="">
      <img src="${press('shot-spatial-audio-airpods-max')}" style="left:12px;top:312px" alt="">
    </div>
    ${foot}`,
  privacy: `
    <div class="copy">
      <img class="lockup" src="${lockup}" alt="">
      <p class="eyebrow">Privacy</p>
      <h1 class="big">Vespertine collects <span class="brass-italic">nothing.</span></h1>
      <p class="lede">No accounts, analytics, telemetry, crash reporting or advertising. The source is public, so you can check.</p>
    </div>
    <img class="mark" src="${mark}" alt="">
    ${foot}`,
  terms: `
    <div class="copy">
      <img class="lockup" src="${lockup}" alt="">
      <p class="eyebrow">Terms</p>
      <h1 class="big">Free software, <span class="brass-italic">plainly.</span></h1>
      <p class="lede">The GNU General Public License, version 3 or later. Nothing to pay, nothing to sign up for.</p>
    </div>
    <img class="mark" src="${mark}" alt="">
    ${foot}`,
};

mkdirSync(tmp, { recursive: true });
mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
for (const [name, body] of Object.entries(cards)) {
  const file = `${tmp}${name}.html`;
  writeFileSync(file, `<!doctype html><html lang="en"><head><meta charset="utf-8"><style>${css}</style></head><body><div class="card"><div class="grain"></div>${body}</div></body></html>`);
  await page.goto(`file://${file}`, { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready);
  const png = await page.screenshot({ type: 'png', clip: { x: 0, y: 0, width: 1200, height: 630 } });
  writeFileSync(`${tmp}${name}.png`, png);
  await sharp(png).jpeg({ quality: 88, progressive: true, mozjpeg: true, chromaSubsampling: '4:4:4' }).toFile(`${out}${name}.jpg`);
  console.log(`og/${name}.jpg`);
}
await browser.close();
if (!process.env.KEEP_OG_BUILD) rmSync(tmp, { recursive: true, force: true });
