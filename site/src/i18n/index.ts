// The site's words in every language: src/i18n/<code>.json, English (en.json) the source. Pages take a `lang` and
// read their strings, paths, numbers and dates from here. scripts/check-i18n.mjs keeps every locale complete.
import en from './en.json';
import { LOCALES, CODES, DEFAULT_LOCALE } from './locales.mjs';
import { notesHash, releaseParts } from './release-parts.mjs';

export { LOCALES, CODES, DEFAULT_LOCALE };
export type Lang = string;
export type Dict = typeof en;
type Release = { version: string; body: string; date: string };

const files = import.meta.glob<Dict>('./*.json', { eager: true, import: 'default' });
const dicts: Record<string, Dict> = Object.fromEntries(Object.entries(files).map(([p, d]) => [p.slice(2, -5), d]));
for (const c of CODES) if (!dicts[c]) throw new Error(`src/i18n/${c}.json is missing`);

export const t = (lang: Lang): Dict => dicts[lang];
export const isRtl = (lang: Lang) => !!LOCALES.find((l) => l.code === lang)?.rtl;
export const dir = (lang: Lang) => (isRtl(lang) ? 'rtl' : 'ltr');
export const ogLocale = (lang: Lang) => LOCALES.find((l) => l.code === lang)!.og;
/** Non-English locales, for getStaticPaths. */
export const localePaths = () => CODES.filter((c) => c !== DEFAULT_LOCALE).map((lang) => ({ params: { lang } }));

/** {name} placeholders. A placeholder with no value is a bug, so it fails the build. */
export function fill(s: string, vars: Record<string, string | number>) {
  return s.replace(/\{([\w.]+)\}/g, (m, k) => {
    if (!(k in vars)) throw new Error(`no value for ${m} in "${s.slice(0, 60)}"`);
    return String(vars[k]);
  });
}

/** The language's name in itself, as the menu shows it (CLDR; Hong Kong Chinese short, as in the app's menu). */
export function nativeName(lang: Lang) {
  const name = lang === 'zh-HK' ? '繁體中文（香港）' : new Intl.DisplayNames([lang], { type: 'language' }).of(lang)!;
  return name.charAt(0).toLocaleUpperCase(lang) + name.slice(1);
}

/** Pages: home, press, privacy, terms. English at /, /press.html …; others at /de/, /de/press.html … */
export type Page = 'home' | 'press' | 'privacy' | 'terms' | '404';
export function pagePath(lang: Lang, page: Page) {
  const prefix = lang === DEFAULT_LOCALE ? '/' : `/${lang}/`;
  return page === 'home' ? prefix : `${prefix}${page}.html`;
}

// Numbers and dates in the locale's own digits, separators and calendar.
export const num = (lang: Lang, n: number) => new Intl.NumberFormat(lang).format(n);
export const year = (lang: Lang, n: number) => new Intl.NumberFormat(lang, { useGrouping: false }).format(n);
/** "15 October 2026" (en-GB style for English, as before), in Boston time: the releases are published from there. */
export const longDate = (lang: Lang, iso: string) =>
  new Intl.DateTimeFormat(lang === DEFAULT_LOCALE ? 'en-GB' : lang, { timeZone: 'America/New_York', day: 'numeric', month: 'long', year: 'numeric' }).format(new Date(iso));
export const megabytes = (lang: Lang, bytes: number) =>
  lang === DEFAULT_LOCALE ? `${Math.round(bytes / 1e6)} MB` : new Intl.NumberFormat(lang, { style: 'unit', unit: 'megabyte', maximumFractionDigits: 0 }).format(Math.round(bytes / 1e6));
/** "A, B or C" with each item as given (HTML allowed). */
export function orList(lang: Lang, items: string[]) {
  const marks = items.map((_, i) => `\u0000${i}\u0000`);
  // English as the site always wrote it: "A, B or C".
  return new Intl.ListFormat(lang === DEFAULT_LOCALE ? 'en-GB' : lang, { type: 'disjunction' }).format(marks).replace(/\u0000(\d+)\u0000/g, (_, i) => items[Number(i)]);
}

/**
 * A release's summary and notes in this language: the translation while it matches the notes GitHub serves, else
 * the English, flagged so the page can mark it (lang="en") and say so.
 */
export function releaseText(lang: Lang, r: Release & { name: string }) {
  const english = releaseParts(r.body);
  const other = lang !== DEFAULT_LOCALE;
  const tr = other ? (t(lang) as unknown as { releases?: Record<string, { hash: string; summary: string; notes?: string }> }).releases?.[r.version] : undefined;
  const ok = !!tr && tr.hash === notesHash(r.body);
  const notesOk = ok && tr!.notes !== undefined;
  return {
    summary: ok ? tr!.summary : english.summary || r.name,
    summaryEnglish: other && !ok,
    notes: notesOk ? tr!.notes! : english.notes,
    notesEnglish: other && !notesOk,
  };
}
