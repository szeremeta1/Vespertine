// Post-build checks on dist/ (from szeremeta.org's, extended). Fails the build, and so the deploy, if:
//  - an inline <script> isn't allowed by its page's CSP hashes (it would silently not run),
//  - an <img> has no alt attribute,
//  - a page lacks a canonical link, a description or exactly one <h1>, or shares its title or description with another,
//  - a page's og:image or twitter:image isn't a 1200×630 file in dist/, or its JSON-LD doesn't parse,
//  - a page carries a noai/noimageai robots directive, or is noindex without being the 404 page,
//  - a root-relative link or asset points at a file that isn't in dist/,
//  - robots.txt, sitemap.xml, llms.txt, llms-full.txt or CNAME is missing.
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';

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
const seen = { title: new Map(), description: new Map() };
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
  const html = readFileSync(file, 'utf8');
  const is404 = file.endsWith('404.html');
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
  for (const m of html.matchAll(/<img\b[^>]*>/g)) if (!/\salt(=|[\s>])/.test(m[0])) problems.push(`${file}: <img> without alt: ${m[0].slice(0, 80)}`);
  if (!/<link rel="canonical"/.test(html)) problems.push(`${file}: no canonical link`);
  if ((html.match(/<h1\b/g) ?? []).length !== 1) problems.push(`${file}: expected exactly one <h1>`);
  if (/noai|noimageai/i.test(attr(html, /<meta name="robots" content="([^"]+)"/) ?? '')) problems.push(`${file}: noai robots directive`);
  if (/<meta name="robots" content="noindex/.test(html) && !is404) problems.push(`${file}: noindex`);
  for (const k of ['title', 'description']) {
    const v = k === 'title' ? attr(html, /<title>([^<]+)<\/title>/) : attr(html, /<meta name="description" content="([^"]+)"/);
    if (!v) { problems.push(`${file}: no ${k}`); continue; }
    if (!is404 && seen[k].has(v)) problems.push(`${file}: same ${k} as ${seen[k].get(v)}`);
    if (!is404) seen[k].set(v, file);
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
if (problems.length) {
  console.error(problems.join('\n'));
  process.exit(1);
}
console.log(`check-dist: ${files.length} pages OK (CSP hashes, alt text, canonical, one h1, unique titles, social cards, JSON-LD, local links)`);
