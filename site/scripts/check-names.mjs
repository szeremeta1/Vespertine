// Checks src/data/names.json (the language wall): one entry per language the app ships plus English, each language's
// name for itself as CLDR spells it, and every name in its language's script. Russian is never one of them.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const here = (p) => fileURLToPath(new URL(p, import.meta.url));
const { names } = JSON.parse(readFileSync(here('../src/data/names.json'), 'utf8'));
const shipped = [...readFileSync(here('../../scripts/check-localizations.py'), 'utf8').match(/LANGUAGES = \[([^\]]+)\]/)[1].matchAll(/"([\w-]+)"/g)].map((m) => m[1]);
const scripts = { am: 'Ethiopic', ar: 'Arabic', fa: 'Arabic', ur: 'Arabic', bn: 'Bengali', el: 'Greek', gu: 'Gujarati', he: 'Hebrew', hi: 'Devanagari', mr: 'Devanagari', ja: 'Katakana', kn: 'Kannada', ko: 'Hangul', ml: 'Malayalam', pa: 'Gurmukhi', ta: 'Tamil', te: 'Telugu', th: 'Thai', uk: 'Cyrillic' };
// CLDR's own name for Hong Kong Chinese is the long region name; the app's language menu reads better short.
const native = { 'zh-HK': '繁體中文（香港）' };
const errors = [];
const langs = names.map((n) => n.lang);
for (const l of [...shipped, 'en']) if (!langs.includes(l)) errors.push(`${l}: missing`);
for (const n of names) {
  if (!shipped.includes(n.lang) && n.lang !== 'en') errors.push(`${n.lang}: not a language the app ships`);
  if (langs.indexOf(n.lang) !== langs.lastIndexOf(n.lang)) errors.push(`${n.lang}: listed twice`);
  const own = native[n.lang] ?? new Intl.DisplayNames([n.lang], { type: 'language' }).of(n.lang);
  if (n.native !== own) errors.push(`${n.lang}: native "${n.native}", CLDR says "${own}"`);
  const script = scripts[n.lang];
  if (!script && n.name !== 'Vespertine') errors.push(`${n.lang}: Latin-script and Chinese languages keep the name Vespertine`);
  // Katakana names may use the long-vowel mark and Ethiopic, Indic and Arabic names their combining marks.
  if (script && !new RegExp(`^[\\p{Script=${script}}\\p{M}\\u30FC\\u200C\\u200D]+$`, 'u').test(n.name)) errors.push(`${n.lang}: "${n.name}" is not all ${script}`);
  if (![1, 2, 3, 4, 5].includes(n.size) || !['serif', 'italic', 'sans', 'display', 'mono'].includes(n.face)) errors.push(`${n.lang}: bad size or face`);
}
if (errors.length) { console.error(`names.json:\n  ${errors.join('\n  ')}`); process.exit(1); }
console.log(`names.json: ${names.length} languages OK`);
