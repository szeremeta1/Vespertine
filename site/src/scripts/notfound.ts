/* GitHub Pages answers every missing path with the one /404.html, in English. If the visitor reads another of the
   site's languages (the path they asked for, /de/…, then the language they picked in the menu, then the browser's),
   swap in that language's copy of the page, built at /<lang>/404.html. The address bar keeps the missing URL. */
import { CODES, STORAGE_KEY, matchLocale } from '../i18n/locales.mjs';

function wanted(): string | null {
  const seg = location.pathname.split('/')[1]?.toLowerCase();
  const fromPath = CODES.find((c) => c.toLowerCase() === seg);
  if (fromPath) return fromPath;
  try {
    const s = localStorage.getItem(STORAGE_KEY);
    if (s && CODES.includes(s)) return s;
  } catch { /* storage blocked */ }
  for (const l of navigator.languages ?? [navigator.language]) {
    const m = matchLocale(l);
    if (m) return m;
  }
  return null;
}

async function localize() {
  const lang = wanted();
  if (!lang || lang === 'en') return;
  const res = await fetch(`/${lang}/404.html`);
  if (!res.ok) return;
  const doc = new DOMParser().parseFromString(await res.text(), 'text/html');
  document.documentElement.lang = doc.documentElement.lang;
  document.documentElement.dir = doc.documentElement.dir;
  document.title = doc.title;
  doc.querySelectorAll('script').forEach((s) => s.remove());
  document.body.replaceChildren(...[...doc.body.childNodes].map((n) => document.importNode(n, true)));
}

localize().catch(() => { /* the English page stays */ }).finally(() => import('./main'));
