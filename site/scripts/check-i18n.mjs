// Checks the site's translations (src/i18n/<lang>.json against the English source, en.json). Fails if:
//  - the site's languages aren't exactly English plus the app's (LANGUAGES in scripts/check-localizations.py),
//    or src/i18n/locales.mjs and the files disagree;
//  - a locale is missing a key, has one English doesn't, or an array of another length;
//  - a value is empty;
//  - a value's {placeholders}, HTML tags (with their attributes) or Markdown structure (code spans, link URLs,
//    headings, bullets, bold) differ from the English;
//  - a value still contains English sentences (three or more common English words in a row once product names,
//    titles, code and URLs are set aside), or is the English text unchanged.
// Release notes the site shows but no locale has translated yet (a release published after the last translation)
// are a warning, not a failure: the page shows them in English, marked as English, until they are translated.
//   node scripts/check-i18n.mjs
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { CODES, LOCALES, MATCH_LOCALE_SRC, matchLocale } from '../src/i18n/locales.mjs';
import { notesHash } from '../src/i18n/release-parts.mjs';

const here = (p) => fileURLToPath(new URL(p, import.meta.url));
const read = (p) => JSON.parse(readFileSync(here(p), 'utf8'));
const errors = [];
const warnings = [];

// ---- The set of languages ----
const shipped = [...readFileSync(here('../../scripts/check-localizations.py'), 'utf8').match(/LANGUAGES = \[([^\]]+)\]/)[1].matchAll(/"([\w-]+)"/g)].map((m) => m[1]);
const files = readdirSync(here('../src/i18n')).filter((f) => f.endsWith('.json')).map((f) => f.slice(0, -5));
const want = ['en', ...shipped].sort();
if (JSON.stringify([...CODES].sort()) !== JSON.stringify(want)) errors.push(`src/i18n/locales.mjs lists ${[...CODES].sort().join(' ')}; the app ships en ${shipped.join(' ')}`);
for (const c of want) if (!files.includes(c)) errors.push(`src/i18n/${c}.json is missing`);
for (const f of files) if (!want.includes(f)) errors.push(`src/i18n/${f}.json is not a language the app ships`);
if (LOCALES.filter((l) => l.rtl).map((l) => l.code).sort().join() !== 'ar,fa,he,ur') errors.push('right-to-left locales should be ar, fa, he, ur');

// The redirect script's copy of matchLocale answers like the module's.
const inlineMatch = new Function('CODES', `${MATCH_LOCALE_SRC}; return matchLocale;`)(CODES);
for (const tag of ['de', 'de-DE', 'en-US', 'pt', 'pt-BR', 'pt-PT', 'pt-AO', 'zh', 'zh-CN', 'zh-SG', 'zh-TW', 'zh-HK', 'zh-MO', 'zh-Hans', 'zh-Hant', 'zh-Hant-HK', 'zh-Hans-HK', 'no', 'nn', 'nb-NO', 'tl', 'fil-PH', 'iw', 'in', 'he-IL', 'ar-EG', 'fa-IR', 'ru', 'xx', '', 'EN', 'ZH-hk', 'sr-Latn', 'es-419', 'fr-CA', ...CODES]) {
  if (inlineMatch(tag) !== matchLocale(tag)) errors.push(`MATCH_LOCALE_SRC("${tag}") is ${inlineMatch(tag)}, matchLocale says ${matchLocale(tag)}`);
}

// ---- What may stay in Latin script, untranslated ----
// Product, brand, format and proper names, and the album, work and artist names the screenshots show.
const PROTECTED = [
  'Love for the Sake of Love', 'Goodbye Yellow Brick Road', 'Brothers In Arms', 'Les jeux d’eaux à la Villa d’Este', 'Années de pèlerinage',
  'Lazar Berman', 'Elton John', 'Dire Straits', 'Claudja Barry', 'Come Back Alive', 'Razom for Ukraine', 'United24',
  'Apple Music', 'Apple silicon', 'Core Audio', 'Spatial Audio', 'AirPods Max', 'AirPods', 'Digital Crown', 'MacBook Pro', 'Developer ID',
  'Cover Art Archive', 'MetaBrainz Foundation', 'Internet Archive', 'iTunes Search', 'Do Not Track', 'Equalizer APO', 'Audio Units',
  'Audirvana Studio', 'Audirvana', 'foobar2000 for Mac', 'FFmpeg Decoder Wrapper', 'Dolby Digital Plus', 'Dolby Digital', 'Dolby Atmos', 'Dolby TrueHD', 'Dolby Laboratories',
  'DTS-HD Master Audio', 'DTS-HD HR', 'DTS-HD MA', 'Master Audio', 'GNU General Public License', 'Fosi Audio ZD3', 'Fosi Audio', 'FiiO K11', 'Sony TV',
  'Made with ❤️ in Boston', 'Star it on GitHub', 'Join the discussion', 'Reduce Motion', 'Suspect Hi-Res', 'Look Up on MusicBrainz', 'Enrich Metadata',
  'Find Music on This Mac', 'Find Music', 'Check for Updates', 'Fetch cover art', 'Keep Offline', 'Volume control in Vespertine', 'playing now',
  'Room Correction', 'Room Measurement', 'Gentle tilt', 'Flat', 'Warm', 'Converted from DSD', 'Downmixed to stereo',
];
const strip = (s) => {
  let t = s
    .replace(/<code>[\s\S]*?<\/code>|<span class="mono[^"]*">[\s\S]*?<\/span>|`[^`]*`/g, ' ')
    .replace(/\]\([^)]*\)/g, ']')
    .replace(/<[^>]+>/g, ' ')
    .replace(/\{[\w.]+\}/g, ' ')
    .replace(/https?:\/\/\S+|\b[\w.-]+\.(?:org|com|md|json|is|txt|io)\b/g, ' ');
  for (const p of PROTECTED) t = t.split(p).join(' ');
  return t;
};
// Words that are English and not ordinary words in any of the site's Latin-script languages.
const EN = new Set(`the and with your you that this which when what from every each only are was were been have has will would can't doesn't
isn't aren't it's there their they them its into about after before while between without through also still just than then here how
why who any some other most such both very again even never always plays played music songs files library output signal playback player
tracks track albums sample samples changes changed checks checked tested untested experimental reports wanted receiver receivers channel
channels lossless lossy shows shown read reads write written free open source code device devices settings setting turn turns choose
should could where whether because however like more less same own first last next new now our we us he she his her him my me be being
does did done doing make makes made get gets got see seen look looks want wants need needs know known use uses used using way ways
off over under up down out on of to in is it as at by or an no not for all one two three if so do`.split(/\s+/));
// Of those, words that some target language also uses (in, an, on, is, of, to, for, no, a …): they count only next to two others.
const WEAK = new Set(['in', 'an', 'on', 'is', 'of', 'to', 'for', 'no', 'as', 'at', 'by', 'or', 'up', 'so', 'do', 'it', 'be', 'me', 'we', 'us', 'he', 'she', 'his', 'her', 'him', 'my', 'all', 'one', 'two', 'if', 'not', 'open', 'source', 'free', 'more', 'like', 'over', 'under', 'out', 'off', 'here', 'still', 'music', 'code', 'track', 'tracks', 'player', 'device', 'channel', 'channels', 'turn', 'die', 'per', 'files', 'albums', 'sample', 'samples', 'has', 'are', 'was', 'made', 'use', 'shows', 'type', 'what', 'just', 'way']);
function englishRun(s, lang) {
  const words = strip(s).toLowerCase().match(/[a-z][a-z'’]*/g) ?? [];
  let run = 0, strong = 0;
  for (const w of words) {
    if (EN.has(w) && !vocab[lang]?.has(w)) { run++; if (!WEAK.has(w)) strong++; if (run >= 3 && strong >= 2) return true; }
    else { run = 0; strong = 0; }
  }
  return false;
}

// Values a native reviewer confirmed are written exactly as in English in that language (French "Contact",
// "Architecture"), per language. Anything else equal to the English is a leftover.
const SAME_OK = JSON.parse(readFileSync(here('./i18n-same-as-english.json'), 'utf8'));

// Words many languages write the English way (German Trailer, Logo, Screenshots …), so a value may equal the English.
const SAME = new Set(['version', 'trailer', 'surround', 'download', 'name', 'links', 'website', 'video', 'logo', 'screenshots', 'genres', 'genre',
  'album', 'albums', 'faq', 'stereo', 'mono', 'format', 'formats', 'playlist', 'playlists', 'tags', 'test', 'sponsor', 'support', 'details',
  'hi-res', 'design', 'analyse', 'platform', 'spectrum', 'audio', 'radio', 'internet', 'streaming', 'plugins', 'feedback', 'online', 'offline', 'studio', 'origin']);
// Product and format names and units that appear in values on their own.
const NAMES = /^(Vespertine|Nocturne|Mac|macOS|Apple|Intel|AirPods|Max|Music|Atmos|Dolby|TrueHD|Digital|Plus|Master|Audio|WavPack|Opus|Vorbis|Musepack|AudioScan|Roon|VeraVox|Colibri|Cog|Audirvana|Studio|Origin|Video|Homebrew|GitHub|Discord|Sonoma|Rosetta|Linux|Bluetooth|Boston|Szeremeta|Alexander|Alex|Sony|FiiO|Fosi|UPnP|Units|kHz|fps|bit|bits|Hi-Res|Spatial|Crown|DoP|DSD\d*|DVD-Video|DVD-Audio)$/;

// Latin-script words the app's own translation for each language uses (Czech keeps "Bit-perfect" and "open source",
// many keep "DAC"): on the site they are the app's terms, not leftovers.
const catalog = JSON.parse(readFileSync(here('../../App/Resources/Localizable.xcstrings'), 'utf8')).strings;
const vocab = {};
const collect = (lang, node) => {
  if (!node || typeof node !== 'object') return;
  if (typeof node.value === 'string') for (const w of node.value.toLowerCase().match(/[a-z][a-z'’-]*/g) ?? []) vocab[lang].add(w);
  for (const v of Object.values(node)) collect(lang, v);
};
for (const entry of Object.values(catalog)) {
  for (const [lang, loc] of Object.entries(entry.localizations ?? {})) {
    vocab[lang] ??= new Set();
    collect(lang, loc);
  }
}

// An English term kept in parentheses after its translation ("… (gapless)"): a gloss copied from the English source,
// or in a non-Latin-script language any Latin words the app doesn't use there and that aren't names.
const NON_LATIN = new Set(['am', 'ar', 'bn', 'el', 'fa', 'gu', 'he', 'hi', 'ja', 'kn', 'ko', 'ml', 'mr', 'pa', 'ta', 'te', 'th', 'uk', 'ur', 'zh-Hans', 'zh-Hant', 'zh-HK']);
const norm = (x) => x.toLowerCase().replace(/[-‐\s]+/g, ' ').trim();
function glosses(en, tr, lang) {
  const found = [];
  for (const m of tr.matchAll(/[(（]([A-Za-z][A-Za-z' \-]{2,40})[)）]/g)) {
    const g = m[1];
    if (PROTECTED.some((p) => norm(p) === norm(g)) || g.split(/\s+/).every((w) => NAMES.test(w))) continue;
    if (new RegExp(`\\(${g.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\)`, 'i').test(en)) continue; // the English has it in parentheses too
    const words = g.match(/[A-Za-z][A-Za-z'-]*/g) ?? [];
    const copied = norm(en).includes(norm(g));
    const foreign = NON_LATIN.has(lang) && words.some((w) => !vocab[lang]?.has(w.toLowerCase()) && !NAMES.test(w) && !PROTECTED.some((p) => p.includes(w)) && w !== w.toUpperCase());
    if ((copied && words.some((w) => !vocab[lang]?.has(w.toLowerCase()) && !NAMES.test(w) && w !== w.toUpperCase())) || foreign) found.push(g);
  }
  return found;
}

// ---- Structure ----
const placeholders = (s) => [...s.matchAll(/\{[\w.]+\}/g)].map((m) => m[0]).sort().join(' ');
const tags = (s) => [...s.matchAll(/<\/?[a-z][^>]*>/g)].map((m) => m[0]).sort().join('');
const markdown = (s) => [
  [...s.matchAll(/`[^`]+`/g)].map((m) => m[0]).sort().join(' '),
  [...s.matchAll(/\]\(([^)]+)\)/g)].map((m) => m[1]).sort().join(' '),
  (s.match(/^#{2,4} /gm) ?? []).length, (s.match(/^- /gm) ?? []).length, (s.match(/\*\*/g) ?? []).length,
].join(' | ');

const en = read('../src/i18n/en.json');
function walk(a, b, path, lang, out) {
  if (typeof a === 'string') {
    if (typeof b !== 'string') return out.push(`${path}: not a string`);
    if (!b.trim()) return out.push(`${path}: empty`);
    if (path.endsWith('.hash')) { if (a !== b) out.push(`${path}: translated from other notes (hash ${b}, English ${a})`); return; }
    if (placeholders(a) !== placeholders(b)) out.push(`${path}: placeholders ${placeholders(b) || 'none'}, English has ${placeholders(a) || 'none'}`);
    if (tags(a) !== tags(b)) out.push(`${path}: HTML tags differ from the English`);
    if (path.startsWith('releases.') && markdown(a) !== markdown(b)) out.push(`${path}: Markdown differs from the English (${markdown(b)} vs ${markdown(a)})`);
    const english = strip(a).match(/[A-Za-z][A-Za-z-]{2,}/g) ?? [];
    const leftover = (w) => !vocab[lang]?.has(w.toLowerCase()) && (EN.has(w.toLowerCase()) || (!SAME.has(w.toLowerCase()) && w !== w.toUpperCase() && !NAMES.test(w)));
    if (a === b && !(SAME_OK[lang] ?? []).includes(a) && english.some(leftover)) out.push(`${path}: unchanged English "${a.slice(0, 70)}"`);
    else if (englishRun(b, lang)) out.push(`${path}: English left in "${strip(b).replace(/\s+/g, ' ').trim().slice(0, 90)}"`);
    for (const g of glosses(a, b, lang)) out.push(`${path}: English gloss "(${g})"`);
    return;
  }
  if (Array.isArray(a)) {
    if (!Array.isArray(b)) return out.push(`${path}: not a list`);
    if (a.length !== b.length) out.push(`${path}: ${b.length} items, English has ${a.length}`);
    a.forEach((x, i) => i < b.length && walk(x, b[i], `${path}[${i}]`, lang, out));
    return;
  }
  if (!b || typeof b !== 'object' || Array.isArray(b)) return out.push(`${path}: not an object`);
  for (const k of Object.keys(a)) {
    if (!(k in b)) out.push(`${path ? `${path}.` : ''}${k}: missing`);
    else walk(a[k], b[k], path ? `${path}.${k}` : k, lang, out);
  }
  for (const k of Object.keys(b)) if (!(k in a)) out.push(`${path ? `${path}.` : ''}${k}: not in en.json`);
}

for (const lang of want.filter((c) => c !== 'en' && files.includes(c))) {
  const out = [];
  walk(en, read(`../src/i18n/${lang}.json`), '', lang, out);
  errors.push(...out.map((e) => `${lang}: ${e}`));
}

// ---- Release notes on the page vs the translated ones ----
const releases = read('../src/data/releases.json');
for (const [i, r] of releases.entries()) {
  const e = en.releases?.[r.version];
  const hash = notesHash(r.body);
  if (!e) warnings.push(`release ${r.version} isn't in en.json: run node scripts/i18n-releases.mjs, then translate it (shown in English until then)`);
  else if (e.hash !== hash) warnings.push(`release ${r.version}'s notes changed on GitHub since they were translated (shown in English until retranslated)`);
  else if (i === 0 && !e.notes) warnings.push(`release ${r.version} is the latest, but only its summary is translated (its notes show in English)`);
}

if (warnings.length) console.warn(`check-i18n warnings:\n  ${warnings.join('\n  ')}`);
if (errors.length) {
  console.error(`check-i18n: ${errors.length} problem${errors.length === 1 ? '' : 's'}:\n  ${errors.join('\n  ')}`);
  process.exit(1);
}
const count = (x) => (typeof x === 'string' ? 1 : Object.values(x).reduce((n, v) => n + count(v), 0));
console.log(`check-i18n: ${want.length} languages × ${count(en)} strings OK (keys, placeholders, HTML, Markdown, no English left)`);
