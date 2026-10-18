// The language wall: Vespertine in every interface language (src/data/names.json), drawn by headless Chrome with the
// site's fonts and the system's fonts for other scripts, for the site, the press kit, the README and the trailer
// (docs/screenshots/languages-wall.png is the trailer's languages scene).
//   node scripts/make-languages-art.mjs
// Needs fonts for every script (on Linux: fonts-noto-core and fonts-noto-cjk). Run node scripts/check-names.mjs after editing names.json.
import { chromium } from 'playwright-core';
import sharp from 'sharp';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const here = (p) => fileURLToPath(new URL(p, import.meta.url));
const url = (p) => new URL(p, import.meta.url).href;
const { names } = JSON.parse(readFileSync(here('../src/data/names.json'), 'utf8'));
const rtl = new Set(['ar', 'fa', 'he', 'ur']);
const tones = ['#ece6da', '#c8a66a', '#cfc8bb', '#e7cd98'];
// Sizes in px of a 1920-wide canvas, by tier.
const sizes = [0, 28, 38, 54, 72, 98];

const page = ({ w, h }) => `<!doctype html><meta charset="utf-8"><style>
@font-face { font-family: Newsreader; font-weight: 300 400; src: url(${url('../src/assets/fonts/newsreader-roman.woff2')}); }
@font-face { font-family: Newsreader; font-style: italic; font-weight: 300; src: url(${url('../src/assets/fonts/newsreader-italic.woff2')}); }
@font-face { font-family: Inter; font-weight: 400 600; src: url(${url('../src/assets/fonts/inter.woff2')}); }
@font-face { font-family: "JetBrains Mono"; font-weight: 400 500; src: url(${url('../src/assets/fonts/jetbrains-mono.woff2')}); }
* { margin: 0; padding: 0; box-sizing: border-box; }
html { font-size: ${w / 1920}px; }
body { width: ${w}px; height: ${h}px; overflow: hidden; color: #ece6da;
  background: radial-gradient(120% 90% at 50% 38%, #17161a 0%, #0b0b0d 62%, #070708 100%);
  display: flex; flex-direction: column; justify-content: center; align-items: center; }
ul { list-style: none; display: flex; flex-wrap: wrap; justify-content: center; align-items: baseline;
  gap: 14rem 40rem; width: 1760rem; }
li { display: inline-flex; flex-direction: column; align-items: center; line-height: 1.05; }
.n { white-space: nowrap; }
.l { margin-top: 9rem; font: 400 15rem "JetBrains Mono", monospace; letter-spacing: .04em; color: #8f897e; }
.serif .n { font-family: Newsreader, serif; font-weight: 400; }
.italic .n { font-family: Newsreader, serif; font-style: italic; font-weight: 300; }
.sans .n { font-family: Inter, sans-serif; font-weight: 600; }
.display .n { font-family: Inter, sans-serif; font-weight: 400; text-transform: uppercase; letter-spacing: .14em; }
.mono .n { font-family: "JetBrains Mono", monospace; }
.cap { margin-top: 64rem; display: flex; gap: 28rem; align-items: baseline; }
.cap b { font: italic 300 46rem Newsreader, serif; color: #ece6da; }
.cap span { font: 400 17rem "JetBrains Mono", monospace; letter-spacing: .12em; color: #c8a66a; }
</style>
<ul>${names.map((n, i) => `<li class="${n.face}" lang="${n.lang}" dir="${rtl.has(n.lang) ? 'rtl' : 'ltr'}" style="--i:${i}">
  <span class="n" style="font-size:${sizes[n.size]}rem;color:${tones[i % 4]}">${n.name}</span><span class="l">${n.native}</span></li>`).join('')}</ul>
<p class="cap"><b>Speaks your language.</b><span>44 LANGUAGES + ENGLISH · RIGHT TO LEFT</span></p>`;

const browser = await chromium.launch({ channel: 'chrome', headless: true }).catch(() => chromium.launch({ headless: true, executablePath: process.env.CHROME_PATH }));
const shoot = async (w, h, scale = 1) => {
  const p = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: scale });
  await p.setContent(page({ w, h }), { waitUntil: 'load' });
  await p.evaluate(() => document.fonts.ready);
  // Shrink the type until the wall and caption fit in 88% of the height (wider canvases wrap into fewer rows).
  await p.evaluate((h) => {
    const root = document.documentElement, used = () => [...document.body.children].reduce((a, e) => a + e.getBoundingClientRect().height, 0) + 64 * parseFloat(getComputedStyle(root).fontSize);
    for (let k = 0; k < 6 && used() > 0.88 * h; k++) root.style.fontSize = parseFloat(getComputedStyle(root).fontSize) * Math.sqrt(0.88 * h / used()) + 'px';
  }, h);
  return p;
};

const out = async (w, h, files, scale = 1) => {
  const p = await shoot(w, h, scale);
  const png = await p.screenshot({ type: 'png' });
  for (const [file, opts] of files) {
    const img = sharp(png);
    await (file.endsWith('.jpg') ? img.resize(opts?.width).jpeg({ quality: 86, mozjpeg: true }) : img.png({ compressionLevel: 9 })).toFile(here(file));
  }
  await p.close();
};
await out(1920, 1080, [['../src/assets/shots/languages.jpg', { width: 1920 }], ['../src/assets/press/languages.jpg', { width: 900 }], ['../../docs/screenshots/languages-wall.png']], 2);
await out(2400, 1350, [['../../docs/press/languages-hero.png']]);
await out(1600, 900, [['../../docs/press/languages-x.png']]);
await out(1270, 760, [['../../docs/press/languages-producthunt.png']]);
await browser.close();
