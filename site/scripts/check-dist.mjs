// Post-build checks on dist/ (from szeremeta.org's, extended). Fails the build, and so the deploy, if:
//  - an inline <script> isn't allowed by its page's CSP hashes (it would silently not run),
//  - an <img> has no alt attribute,
//  - a page lacks the self-hosted stats script (or the CSP that lets it run and report),
//  - a page lacks a canonical link, a description or exactly one <h1>, or shares its title or description with another
//    page in its language,
//  - a page's <html lang> or dir doesn't match its folder (/de/…), or it lacks an hreflang link to every language's
//    version (and x-default), or its canonical isn't its own URL,
//  - a page's og:image or twitter:image isn't a 1200×630 file in dist/, or its JSON-LD doesn't parse,
//  - a page's social tags aren't in its own language: og:locale and its 44 og:locale:alternate, og:title,
//    og:description and the twitter: copies matching its <title> and description, og:url its canonical, its card the
//    one made for its language (/og/<code>/…), content-language its language; or its JSON-LD lacks the app
//    (SoftwareApplication: free offer, macOS, inLanguage, a description and that card) or a WebPage in its language,
//  - an hreflang alternate isn't the absolute URL of that language's version of the page (so every pair links back),
//  - a page carries a noai/noimageai robots directive, or is noindex without being the 404 page,
//  - a root-relative link or asset points at a file that isn't in dist/,
//  - robots.txt, sitemap.xml, llms.txt, llms-full.txt or CNAME is missing, robots.txt blocks anything or doesn't name
//    the sitemap, or sitemap.xml doesn't list exactly the indexable pages (absolute URLs, a lastmod date, and the same
//    alternates, every language and x-default, as each page's own <head>).
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { basename, join, relative, sep } from 'node:path';
import { CODES, LOCALES, hreflangOf } from '../src/i18n/locales.mjs';

const DIST = 'dist';
const SITE = 'https://vespertineapp.com';
const files = [];
(function walk(dir) {
  for (const f of readdirSync(dir)) {
    const p = join(dir, f);
    if (statSync(p).isDirectory()) walk(p);
    else if (p.endsWith('.html')) files.push(p);
  }
})(DIST);

const problems = [];
// The indexable pages' URLs and their hreflang alternates, to compare with sitemap.xml.
const pageAlternates = new Map();
const urlOf = (rel) => `${SITE}/${rel.join('/')}`.replace(/\/index\.html$/, '/');
/** The URL of a page (its path after the language folder, "index.html", "press.html" …) in another language. */
const urlIn = (code, rest) => `${SITE}/${code === 'en' ? '' : `${code}/`}${rest}`.replace(/\/index\.html$/, '/');
const metas = (html, key) => [...html.matchAll(new RegExp(`<meta (?:property|name)="${key}" content="([^"]*)"`, 'g'))].map((m) => m[1]);
const decode = (s) => s?.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
const seen = { title: new Map(), description: new Map() };
const rtl = new Set(LOCALES.filter((l) => l.rtl).map((l) => l.code));
const attr = (html, re) => html.match(re)?.[1];
const jpegSize = (buf) => {
  for (let i = 2; i < buf.length;) {
    const marker = buf[i + 1], len = buf.readUInt16BE(i + 2);
    if (marker >= 0xc0 && marker <= 0xc3) return [buf.readUInt16BE(i + 7), buf.readUInt16BE(i + 5)];
    i += 2 + len;
  }
  return [0, 0];
};
const exists = (url) => {
  const p = decodeURIComponent(url.split(/[?#]/)[0]);
  const f = join(DIST, p);
  return existsSync(f) && statSync(f).isFile() || existsSync(f + '.html') || existsSync(join(f, 'index.html'));
};

for (const file of files) {
  // Search-engine ownership files (Google Search Console) are plain tokens, not pages.
  if (/^google[0-9a-f]+\.html$/.test(basename(file))) continue;
  const html = readFileSync(file, 'utf8');
  const is404 = file.endsWith('404.html');
  const rel = relative(DIST, file).split(sep);
  const lang = rel.length > 1 && CODES.includes(rel[0]) ? rel[0] : 'en';
  if (attr(html, /<html lang="([^"]+)"/) !== lang) problems.push(`${file}: <html lang> isn't ${lang}`);
  if (attr(html, /<html lang="[^"]+" dir="([^"]+)"/) !== (rtl.has(lang) ? 'rtl' : 'ltr')) problems.push(`${file}: dir isn't ${rtl.has(lang) ? 'rtl' : 'ltr'}`);
  const own = urlOf(rel);
  const rest = (lang === 'en' ? rel : rel.slice(1)).join('/');
  if (!is404) {
    const alts = new Map([...html.matchAll(/<link rel="alternate" hreflang="([^"]+)" href="([^"]+)"/g)].map((m) => [m[1], m[2]]));
    const want = new Map([...CODES.map((c) => [hreflangOf(c), urlIn(c, rest)]), ['x-default', urlIn('en', rest)]]);
    for (const [h, href] of want) {
      if (!alts.has(h)) problems.push(`${file}: no hreflang ${h}`);
      else if (alts.get(h) !== href) problems.push(`${file}: hreflang ${h} is ${alts.get(h)}, expected ${href}`);
    }
    for (const h of alts.keys()) if (!want.has(h)) problems.push(`${file}: unexpected hreflang ${h}`);
    if (alts.get(hreflangOf(lang)) !== own) problems.push(`${file}: its own hreflang (${hreflangOf(lang)}) isn't its URL`);
    pageAlternates.set(own, alts);
    const canonical = attr(html, /<link rel="canonical" href="([^"]+)"/) ?? '';
    if (canonical !== own) problems.push(`${file}: canonical ${canonical}, expected ${own}`);
  }
  // Social and language tags, in the page's own language.
  {
    const loc = LOCALES.find((l) => l.code === lang);
    const one = (key) => { const v = metas(html, key); if (v.length !== 1) problems.push(`${file}: ${v.length} ${key} tags`); return decode(v[0]); };
    if (one('og:locale') !== loc.og) problems.push(`${file}: og:locale isn't ${loc.og}`);
    const others = metas(html, 'og:locale:alternate');
    const wantOthers = LOCALES.filter((l) => l.code !== lang).map((l) => l.og);
    if (others.length !== wantOthers.length || wantOthers.some((o) => !others.includes(o))) problems.push(`${file}: og:locale:alternate isn't every other language (${others.length})`);
    const title = decode(attr(html, /<title>([^<]+)<\/title>/));
    const description = decode(attr(html, /<meta name="description" content="([^"]+)"/));
    for (const k of ['og:title', 'twitter:title']) if (one(k) !== title) problems.push(`${file}: ${k} isn't the page title`);
    for (const k of ['og:description', 'twitter:description']) if (one(k) !== description) problems.push(`${file}: ${k} isn't the page description`);
    if (!is404 && one('og:url') !== own) problems.push(`${file}: og:url isn't ${own}`);
    if (one('twitter:card') !== 'summary_large_image') problems.push(`${file}: twitter:card isn't summary_large_image`);
    const image = one('og:image');
    if (one('twitter:image') !== image || one('og:image:secure_url') !== image) problems.push(`${file}: twitter:image or og:image:secure_url isn't og:image`);
    const cardDir = image ? new URL(image).pathname.split('/').slice(2, -1).join('/') : '';
    if (cardDir !== (lang === 'en' ? '' : lang)) problems.push(`${file}: og:image ${image} isn't the ${lang} card`);
    for (const k of ['og:image:alt', 'twitter:image:alt']) if (!one(k)?.trim()) problems.push(`${file}: no ${k}`);
    if (one('og:image:width') !== '1200' || one('og:image:height') !== '630') problems.push(`${file}: og:image width/height aren't 1200×630`);
    if (attr(html, /<meta http-equiv="content-language" content="([^"]+)"/) !== lang) problems.push(`${file}: content-language isn't ${lang}`);
    if (!is404) {
      const ld = [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].map((m) => { try { return JSON.parse(m[1]); } catch { return {}; } });
      const nodes = ld.flatMap((g) => g['@graph'] ?? [g]);
      const app = nodes.find((n) => n['@type'] === 'SoftwareApplication');
      if (!app) problems.push(`${file}: no SoftwareApplication in JSON-LD`);
      else {
        if (app.offers?.price !== '0' || !app.isAccessibleForFree) problems.push(`${file}: SoftwareApplication isn't offered free`);
        if (!/macOS/.test(app.operatingSystem ?? '')) problems.push(`${file}: SoftwareApplication operatingSystem lacks macOS`);
        if (!Array.isArray(app.inLanguage) || !CODES.every((c) => app.inLanguage.includes(c))) problems.push(`${file}: SoftwareApplication inLanguage isn't every language`);
        if (!app.description) problems.push(`${file}: SoftwareApplication has no description`);
        if (app.image?.split('?')[0] !== `${SITE}/og/${lang === 'en' ? '' : `${lang}/`}home.jpg`) problems.push(`${file}: SoftwareApplication image isn't the ${lang} card`);
      }
      const webpage = nodes.find((n) => [].concat(n['@type']).includes('WebPage'));
      if (webpage?.inLanguage !== lang) problems.push(`${file}: WebPage inLanguage isn't ${lang}`);
    }
  }
  const csp = attr(html, /http-equiv="content-security-policy" content="([^"]+)"/) ?? '';
  const allowed = new Set([...csp.matchAll(/'(sha256-[^']+)'/g)].map((m) => m[1]));
  for (const m of html.matchAll(/<script(?![^>]*\bsrc=)([^>]*)>([\s\S]*?)<\/script>/g)) {
    if (/type="application\/ld\+json"/.test(m[1])) {
      try { JSON.parse(m[2]); } catch (e) { problems.push(`${file}: JSON-LD doesn't parse (${e.message})`); }
      continue;
    }
    const hash = `sha256-${createHash('sha256').update(m[2]).digest('base64')}`;
    if (!allowed.has(hash)) problems.push(`${file}: inline script not in CSP (${hash}): ${m[2].slice(0, 50)}`);
  }
  if (!/<script defer src="https:\/\/stats\.szeremeta\.org\/howl\.js" data-website-id="a4b69e33-e989-45bd-bbc2-4d6b1036aa63" data-domains="vespertineapp\.com,www\.vespertineapp\.com" data-do-not-track="true">/.test(html)) problems.push(`${file}: stats script missing or changed`);
  if (!/script-src[^;]*https:\/\/stats\.szeremeta\.org/.test(csp) || !/connect-src[^;]*https:\/\/stats\.szeremeta\.org/.test(csp)) problems.push(`${file}: CSP doesn't allow stats.szeremeta.org`);
  for (const m of html.matchAll(/<img\b[^>]*>/g)) if (!/\salt(=|[\s>])/.test(m[0])) problems.push(`${file}: <img> without alt: ${m[0].slice(0, 80)}`);
  if (!/<link rel="canonical"/.test(html)) problems.push(`${file}: no canonical link`);
  if ((html.match(/<h1\b/g) ?? []).length !== 1) problems.push(`${file}: expected exactly one <h1>`);
  if (/noai|noimageai/i.test(attr(html, /<meta name="robots" content="([^"]+)"/) ?? '')) problems.push(`${file}: noai robots directive`);
  if (/<meta name="robots" content="noindex/.test(html) && !is404) problems.push(`${file}: noindex`);
  for (const k of ['title', 'description']) {
    const v = k === 'title' ? attr(html, /<title>([^<]+)<\/title>/) : attr(html, /<meta name="description" content="([^"]+)"/);
    if (!v) { problems.push(`${file}: no ${k}`); continue; }
    if (!is404 && seen[k].has(`${lang} ${v}`)) problems.push(`${file}: same ${k} as ${seen[k].get(`${lang} ${v}`)}`);
    if (!is404) seen[k].set(`${lang} ${v}`, file);
  }
  for (const prop of ['property="og:image"', 'name="twitter:image"']) {
    const img = attr(html, new RegExp(`<meta ${prop} content="([^"]+)"`));
    if (!img?.startsWith(`${SITE}/`)) { problems.push(`${file}: ${prop} missing or not absolute`); continue; }
    const local = join(DIST, new URL(img).pathname);
    if (!existsSync(local)) { problems.push(`${file}: ${prop} ${img} not in dist`); continue; }
    const [w, h] = jpegSize(readFileSync(local));
    if (w !== 1200 || h !== 630) problems.push(`${file}: ${prop} is ${w}×${h}, not 1200×630`);
  }
  for (const m of html.matchAll(/\s(?:href|src|poster|data-src)="(\/[^"]*)"/g)) {
    if (m[1].startsWith('//')) continue;
    if (!exists(m[1])) problems.push(`${file}: broken link ${m[1]}`);
  }
  for (const m of html.matchAll(/\s(?:srcset|data-srcset)="([^"]+)"/g)) {
    for (const part of m[1].split(',')) {
      const u = part.trim().split(/\s+/)[0];
      if (u.startsWith('/') && !exists(u)) problems.push(`${file}: broken srcset ${u}`);
    }
  }
}
for (const f of ['robots.txt', 'sitemap.xml', 'llms.txt', 'llms-full.txt', 'CNAME', 'site.webmanifest', 'favicon.ico', '404.html']) {
  if (!existsSync(join(DIST, f))) problems.push(`missing dist/${f}`);
}
// robots.txt lets everything be crawled and names the sitemap.
if (existsSync(join(DIST, 'robots.txt'))) {
  const robots = readFileSync(join(DIST, 'robots.txt'), 'utf8');
  if (/^\s*Disallow:\s*\S/im.test(robots)) problems.push('robots.txt disallows something');
  if (!robots.includes(`Sitemap: ${SITE}/sitemap.xml`)) problems.push('robots.txt doesn\'t name the sitemap');
}
// sitemap.xml lists exactly the indexable pages, each with a lastmod and the alternates its <head> has.
if (existsSync(join(DIST, 'sitemap.xml'))) {
  const xml = readFileSync(join(DIST, 'sitemap.xml'), 'utf8');
  const listed = new Set();
  for (const [, body] of xml.matchAll(/<url>([\s\S]*?)<\/url>/g)) {
    const loc = body.match(/<loc>([^<]+)<\/loc>/)?.[1];
    if (!loc?.startsWith(`${SITE}/`)) { problems.push(`sitemap.xml: loc ${loc} isn't absolute`); continue; }
    if (listed.has(loc)) problems.push(`sitemap.xml: ${loc} listed twice`);
    listed.add(loc);
    if (!/<lastmod>\d{4}-\d{2}-\d{2}<\/lastmod>/.test(body)) problems.push(`sitemap.xml: ${loc} has no lastmod date`);
    const head = pageAlternates.get(loc);
    if (!head) { problems.push(`sitemap.xml: ${loc} isn't an indexable page in dist`); continue; }
    const alts = new Map([...body.matchAll(/<xhtml:link rel="alternate" hreflang="([^"]+)" href="([^"]+)"\/>/g)].map((m) => [m[1], m[2]]));
    if (alts.size !== head.size || [...head].some(([h, href]) => alts.get(h) !== href)) problems.push(`sitemap.xml: ${loc}'s alternates differ from its page's`);
    for (const href of alts.values()) if (!pageAlternates.has(href)) problems.push(`sitemap.xml: ${loc} has an alternate that isn't a page: ${href}`);
  }
  for (const url of pageAlternates.keys()) if (!listed.has(url)) problems.push(`sitemap.xml: ${url} isn't listed`);
}
if (problems.length) {
  console.error(problems.join('\n'));
  process.exit(1);
}
console.log(`check-dist: ${files.length} pages OK (CSP hashes, alt text, lang and dir, canonical, hreflang both ways, one h1, unique titles, social cards and tags in each page's language, JSON-LD, local links, robots.txt, sitemap.xml)`);
