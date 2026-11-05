// IndexNow (https://www.indexnow.org): tells Bing, Yandex, Seznam, Naver and Yep which pages are new or changed, so
// they needn't wait to re-crawl. Used by .github/workflows/pages.yml around a deploy:
//   node scripts/indexnow.mjs changed   (before the deploy, in site/) prints the URLs in dist/sitemap.xml that are new
//                                       or whose lastmod differs from the live sitemap.xml, one per line;
//   node scripts/indexnow.mjs submit    (after the deploy) POSTs the URLs in $CHANGED_URLS (or stdin) once to
//                                       api.indexnow.org, after checking the key file is live.
// Add --dry-run to `submit` to print what would be sent. The key is public by design: the file public/<KEY>.txt on the
// site is the proof of ownership (no secret or credential is involved). Failure here never affects the deploy.
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const HOST = 'vespertineapp.com';
const SITE = `https://${HOST}`;
const here = (p) => fileURLToPath(new URL(p, import.meta.url));
// The key is the name of the one 32-hex .txt file in public/ (its content is the same key).
const keyFile = readdirSync(here('../public')).find((f) => /^[0-9a-f]{32}\.txt$/.test(f));
if (!keyFile) throw new Error('public/<key>.txt is missing');
const KEY = keyFile.slice(0, -4);
const KEY_LOCATION = `${SITE}/${keyFile}`;

/** {url → lastmod} from a sitemap's <url> blocks (not the hreflang alternates inside them). */
export function entries(xml) {
  const map = new Map();
  for (const [, body] of xml.matchAll(/<url>([\s\S]*?)<\/url>/g)) {
    const loc = body.match(/<loc>([^<]+)<\/loc>/)?.[1].trim();
    if (loc) map.set(loc, body.match(/<lastmod>([^<]+)<\/lastmod>/)?.[1].trim() ?? '');
  }
  return map;
}

/** URLs in `next` that `live` lacks or lists with another lastmod. */
export function changed(live, next) {
  return [...next].filter(([url, lastmod]) => live.get(url) !== lastmod).map(([url]) => url);
}

async function liveSitemap() {
  try {
    const res = await fetch(`${SITE}/sitemap.xml`);
    if (res.ok) return entries(await res.text());
    console.error(`indexnow: live sitemap.xml answered ${res.status}; treating every page as new`);
  } catch (e) {
    console.error(`indexnow: couldn't read the live sitemap (${e.message}); treating every page as new`);
  }
  return new Map();
}

async function keyIsLive() {
  for (let i = 0; i < 6; i++) {
    try {
      const res = await fetch(KEY_LOCATION, { cache: 'no-store' });
      if (res.ok && (await res.text()).trim() === KEY) return true;
    } catch { /* retry: a deploy can take a moment to reach every Pages edge */ }
    await new Promise((r) => setTimeout(r, 10_000));
  }
  return false;
}

async function main(mode, flags) {
  if (mode === 'changed') {
    const next = entries(readFileSync('dist/sitemap.xml', 'utf8'));
    console.log(changed(await liveSitemap(), next).join('\n'));
  } else if (mode === 'submit') {
    const input = process.env.CHANGED_URLS ?? readFileSync(0, 'utf8');
    const urls = [...new Set(input.split('\n').map((u) => u.trim()).filter(Boolean))].filter((u) => new URL(u).host === HOST);
    if (!urls.length) return console.log('indexnow: nothing changed, nothing to submit');
    if (flags.includes('--dry-run')) return console.log(`indexnow (dry run): would submit ${urls.length} URLs\n${urls.join('\n')}`);
    if (!(await keyIsLive())) throw new Error(`the key file isn't live at ${KEY_LOCATION}`);
    for (let i = 0; i < urls.length; i += 10_000) {
      const res = await fetch('https://api.indexnow.org/IndexNow', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=utf-8' },
        body: JSON.stringify({ host: HOST, key: KEY, keyLocation: KEY_LOCATION, urlList: urls.slice(i, i + 10_000) }),
      });
      // 200 and 202 are both success (202: accepted, key validation pending).
      if (!res.ok) throw new Error(`IndexNow answered ${res.status} ${res.statusText}: ${(await res.text()).slice(0, 200)}`);
      console.log(`indexnow: submitted ${Math.min(10_000, urls.length - i)} URLs (HTTP ${res.status})`);
    }
  } else {
    throw new Error('usage: indexnow.mjs changed | submit [--dry-run]');
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main(process.argv[2], process.argv.slice(3)).catch((e) => {
    console.error(`indexnow: ${e.message}`);
    process.exit(1);
  });
}
