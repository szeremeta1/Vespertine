// Headless checks of the language features on the built site (dist/), in Google Chrome via playwright-core:
//  - the first visit to / goes to the browser's language (pt-PT, zh-TW, no …) once, and stays English otherwise;
//  - a language picked in the menu wins over the browser's, English included, and survives a return to /;
//  - arriving at / from another page of the site never redirects;
//  - the menu opens and closes from the keyboard, names each language in itself, marks the current one, and keeps
//    the visitor on the same page (and section) in the new language;
//  - a missing page answers 404 in the visitor's language;
//  - pages in right-to-left languages are mirrored and nothing is wider than the screen.
//   npm run build && node scripts/test-i18n.mjs
import { chromium } from 'playwright-core';
import { serve } from './serve-dist.mjs';

const PORT = 4399;
const BASE = `http://127.0.0.1:${PORT}`;
const server = await serve(PORT);
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const results = [];
const check = (name, ok, detail = '') => { results.push({ name, ok, detail }); console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail ? ` (${detail})` : ''}`); };

/** A fresh visitor whose browser asks for these languages. */
async function visitor(languages, storage) {
  const context = await browser.newContext({ locale: languages[0], reducedMotion: 'reduce' });
  await context.addInitScript(({ languages, storage }) => {
    Object.defineProperty(navigator, 'languages', { get: () => languages });
    Object.defineProperty(navigator, 'language', { get: () => languages[0] });
    if (storage && !sessionStorage.getItem('seeded')) { localStorage.setItem('vespertine-lang', storage); sessionStorage.setItem('seeded', '1'); }
  }, { languages, storage });
  return context;
}
const path = (page) => new URL(page.url()).pathname + new URL(page.url()).hash;

// ---- Detection on the first visit to / ----
const cases = [
  [['de-DE', 'de'], '/de/'], [['en-US', 'en'], '/'], [['en-GB', 'de'], '/'], [['ru-RU', 'uk-UA', 'en'], '/uk/'],
  [['ru-RU', 'en-US', 'de'], '/'], [['fr-CA'], '/fr/'], [['pt-PT'], '/pt-PT/'], [['pt'], '/pt-BR/'], [['pt-BR'], '/pt-BR/'],
  [['zh-CN'], '/zh-Hans/'], [['zh-TW'], '/zh-Hant/'], [['zh-HK'], '/zh-HK/'], [['zh-Hant-HK'], '/zh-HK/'], [['zh'], '/zh-Hans/'],
  [['nb-NO'], '/nb/'], [['no'], '/nb/'], [['he-IL'], '/he/'], [['iw'], '/he/'], [['ar-EG'], '/ar/'], [['fil-PH'], '/fil/'], [['tl'], '/fil/'],
  [['ja-JP'], '/ja/'], [['xx-YY'], '/'],
];
for (const [langs, want] of cases) {
  const ctx = await visitor(langs);
  const page = await ctx.newPage();
  await page.goto(`${BASE}/`, { waitUntil: 'domcontentloaded' });
  await page.waitForLoadState('domcontentloaded');
  check(`browser ${langs.join(',')} on / → ${want}`, path(page) === want, path(page));
  await ctx.close();
}

// Query strings and the section survive the redirect; Back doesn't bounce.
{
  const ctx = await visitor(['de']);
  const page = await ctx.newPage();
  await page.goto(`${BASE}/press.html`);
  await page.goto(`${BASE}/?utm_source=x#faq`, { referer: 'https://example.com/' });
  check('redirect keeps query and hash', new URL(page.url()).pathname === '/de/' && page.url().endsWith('?utm_source=x#faq'), page.url());
  await page.goBack();
  check('Back after the redirect leaves /, not to it', new URL(page.url()).pathname === '/press.html', path(page));
  await ctx.close();
}

// ---- An explicit choice wins ----
{
  const ctx = await visitor(['de-DE'], 'en');
  const page = await ctx.newPage();
  await page.goto(`${BASE}/`);
  check('stored choice en beats browser de', path(page) === '/', path(page));
  await ctx.close();
}
{
  const ctx = await visitor(['en-US'], 'ja');
  const page = await ctx.newPage();
  await page.goto(`${BASE}/`);
  check('stored choice ja beats browser en', path(page) === '/ja/', path(page));
  await ctx.close();
}
{
  const ctx = await visitor(['de-DE'], 'xx');
  const page = await ctx.newPage();
  await page.goto(`${BASE}/`);
  check('a stored value that is not a language is ignored (stays /)', path(page) === '/', path(page));
  await ctx.close();
}

// ---- Arriving from another page of the site ----
{
  const ctx = await visitor(['de-DE']);
  const page = await ctx.newPage();
  await page.goto(`${BASE}/de/`);
  await page.goto(`${BASE}/`, { referer: `${BASE}/de/press.html` });
  check('same-site referrer: no redirect', path(page) === '/', path(page));
  await ctx.close();
}

// ---- The menu ----
{
  const ctx = await visitor(['de-DE']);
  const page = await ctx.newPage();
  await page.goto(`${BASE}/de/press.html`);
  const summary = page.locator('.lang__btn');
  const label = await summary.getAttribute('aria-label');
  check('menu button has an accessible name with the current language', /Deutsch/.test(label ?? ''), label);
  const names = await page.locator('.lang__list a').evaluateAll((as) => as.map((a) => [a.lang, a.textContent, a.getAttribute('aria-current')]));
  check('menu lists 45 languages', names.length === 45, String(names.length));
  for (const [lang, name] of [['de', 'Deutsch'], ['ja', '日本語'], ['ar', 'العربية'], ['he', 'עברית'], ['hi', 'हिन्दी'], ['th', 'ไทย'], ['zh-Hans', '简体中文'], ['zh-HK', '繁體中文（香港）'], ['en', 'English'], ['fr', 'Français'], ['uk', 'Українська']]) {
    check(`menu names ${lang} as ${name}`, names.some(([l, n]) => l === lang && n === name));
  }
  check('menu marks only the current language', names.filter(([, , c]) => c === 'true').map(([l]) => l).join() === 'de');
  // Keyboard: focus the button, Enter opens, arrows move, Escape closes and returns focus.
  await summary.focus();
  await page.keyboard.press('Enter');
  check('Enter opens the menu', await page.locator('.lang').evaluate((d) => d.open));
  await page.keyboard.press('ArrowDown');
  const first = await page.evaluate(() => document.activeElement?.textContent);
  check('ArrowDown moves into the list', !!first && first !== '', first);
  await page.keyboard.press('Escape');
  check('Escape closes the menu and returns focus', !(await page.locator('.lang').evaluate((d) => d.open)) && (await page.evaluate(() => document.activeElement?.classList.contains('lang__btn'))));
  // Pick Japanese: same page, Japanese, remembered.
  await summary.click();
  await page.locator('.lang__list a[lang="ja"]').click();
  await page.waitForURL(`${BASE}/ja/press.html`);
  check('picking 日本語 on the German press kit opens the Japanese press kit', path(page) === '/ja/press.html', path(page));
  check('…with <html lang="ja">', (await page.locator('html').getAttribute('lang')) === 'ja');
  check('…and remembers it', (await page.evaluate(() => localStorage.getItem('vespertine-lang'))) === 'ja');
  await page.goto(`${BASE}/`);
  check('…so / now opens /ja/ (browser says de)', path(page) === '/ja/', path(page));
  // Back to English from the Japanese home page, with a section in the URL.
  await page.goto(`${BASE}/ja/#faq`);
  await page.locator('.lang__btn').click();
  await page.locator('.lang__list a[lang="en"]').click();
  await page.waitForURL((u) => u.pathname === '/');
  check('picking English keeps the section (#faq)', path(page) === '/#faq', path(page));
  await page.goto(`${BASE}/`);
  check('…and / stays English afterwards', path(page) === '/', path(page));
  // Click outside closes.
  await page.locator('.lang__btn').click();
  await page.mouse.click(5, 400);
  check('a click outside closes the menu', !(await page.locator('.lang').evaluate((d) => d.open)));
  await ctx.close();
}

// ---- 404 in the visitor's language ----
{
  const ctx = await visitor(['en-US']);
  const page = await ctx.newPage();
  const res = await page.goto(`${BASE}/de/no-such-page`);
  await page.waitForFunction(() => document.documentElement.lang === 'de', null, { timeout: 5000 }).catch(() => {});
  check('missing /de/… answers 404', res?.status() === 404, String(res?.status()));
  check('…in German', (await page.locator('html').getAttribute('lang')) === 'de' && (await page.locator('h1').textContent())?.trim() !== 'This page isn’t here.', await page.locator('h1').textContent());
  check('…keeping the address', path(page) === '/de/no-such-page');
  await ctx.close();
}
{
  const ctx = await visitor(['ar']);
  const page = await ctx.newPage();
  await page.goto(`${BASE}/no-such-page`);
  await page.waitForFunction(() => document.documentElement.lang === 'ar', null, { timeout: 5000 }).catch(() => {});
  check('missing page for an Arabic browser: Arabic, right to left', (await page.locator('html').getAttribute('dir')) === 'rtl');
  await ctx.close();
}

// ---- Layout: mirrored RTL, nothing wider than the screen ----
for (const width of [390, 1440]) {
  for (const lang of ['en', 'de', 'fi', 'el', 'ta', 'ml', 'kn', 'te', 'bn', 'am', 'ar', 'ur', 'ja', 'th', 'zh-Hant', 'zh-HK']) {
    const ctx = await browser.newContext({ viewport: { width, height: 900 }, reducedMotion: 'reduce' });
    const page = await ctx.newPage();
    await page.goto(`${BASE}${lang === 'en' ? '/' : `/${lang}/`}`, { waitUntil: 'load' });
    const over = await page.evaluate(() => {
      const w = document.documentElement.clientWidth;
      const bad = [...document.querySelectorAll('body *')].filter((e) => {
        const r = e.getBoundingClientRect();
        if (!r.width || getComputedStyle(e).position === 'fixed') return false;
        if (e.closest('.marquee, .compare, .route, .sr-only, .scene, .hero__glow, .closing__glow, .lang__panel')) return false;
        return r.right > w + 1 || r.left < -1;
      });
      return { scroll: document.documentElement.scrollWidth - w, bad: bad.slice(0, 3).map((e) => `${e.tagName.toLowerCase()}.${[...e.classList].join('.')}`) };
    });
    check(`${lang} at ${width}px: no horizontal overflow`, over.scroll <= 0 && over.bad.length === 0, `${over.scroll}px ${over.bad.join(' ')}`);
    if (lang === 'ar' || lang === 'ur') {
      const brand = await page.locator('.nav__brand').boundingBox();
      check(`${lang} at ${width}px: brand on the right (mirrored)`, !!brand && brand.x > width / 2, String(brand?.x));
    }
    const navOk = await page.evaluate(() => {
      const nav = document.querySelector('.nav'); const r = nav.getBoundingClientRect();
      const clip = document.querySelector('.nav__links').getBoundingClientRect();
      const inBar = (b) => b.top >= r.top - 1 && b.bottom <= r.bottom + 1 && b.left >= -1 && b.right <= innerWidth + 1;
      // Links must also sit wholly inside the list's clip box (not cut off at its edge).
      const links = [...nav.querySelectorAll('.nav__links li:not(.is-squeezed) a')].filter((e) => e.offsetParent).every((e) => { const b = e.getBoundingClientRect(); return inBar(b) && b.left >= clip.left - 1 && b.right <= clip.right + 1 && b.bottom <= clip.bottom + 1; });
      return links && [...nav.querySelectorAll('.lang__btn, .nav > .btn')].every((e) => inBar(e.getBoundingClientRect()));
    });
    check(`${lang} at ${width}px: nav items fit in the bar`, navOk);
    // Each of the hero headline's lines stays one line (the size estimate plus main.ts's last step down).
    await page.evaluate(() => document.fonts.ready.then(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))));
    const wrapped = await page.evaluate(() => {
      const title = document.querySelector('.hero__title');
      const lh = parseFloat(getComputedStyle(title).lineHeight) || parseFloat(getComputedStyle(title).fontSize);
      return [...title.querySelectorAll('.line > span')].filter((s) => s.getBoundingClientRect().height > lh * 1.5).map((s) => s.textContent);
    });
    check(`${lang} at ${width}px: each hero headline line fits on one line`, wrapped.length === 0, wrapped.join(' | '));
    await ctx.close();
  }
}

await browser.close();
server.close();
const failed = results.filter((r) => !r.ok);
console.log(`\ntest-i18n: ${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);
