// The site's languages: English (the source, at /) and every language the app ships (LANGUAGES in
// scripts/check-localizations.py, at /<code>/). Plain JS, so astro.config.mjs and the inline redirect script can use it.
// scripts/check-i18n.mjs fails if this list and the app's drift apart.

export const DEFAULT_LOCALE = 'en';

/** code: BCP 47 tag, URL segment and file name (src/i18n/<code>.json); og: Open Graph locale. */
export const LOCALES = [
  { code: 'en', og: 'en_US' },
  { code: 'am', og: 'am_ET' },
  { code: 'ar', og: 'ar_AR', rtl: true },
  { code: 'bn', og: 'bn_BD' },
  { code: 'cs', og: 'cs_CZ' },
  { code: 'da', og: 'da_DK' },
  { code: 'de', og: 'de_DE' },
  { code: 'el', og: 'el_GR' },
  { code: 'es', og: 'es_ES' },
  { code: 'fa', og: 'fa_IR', rtl: true },
  { code: 'fi', og: 'fi_FI' },
  { code: 'fil', og: 'fil_PH' },
  { code: 'fr', og: 'fr_FR' },
  { code: 'gu', og: 'gu_IN' },
  { code: 'ha', og: 'ha_NG' },
  { code: 'he', og: 'he_IL', rtl: true },
  { code: 'hi', og: 'hi_IN' },
  { code: 'hu', og: 'hu_HU' },
  { code: 'id', og: 'id_ID' },
  { code: 'it', og: 'it_IT' },
  { code: 'ja', og: 'ja_JP' },
  { code: 'kn', og: 'kn_IN' },
  { code: 'ko', og: 'ko_KR' },
  { code: 'ml', og: 'ml_IN' },
  { code: 'mr', og: 'mr_IN' },
  { code: 'ms', og: 'ms_MY' },
  { code: 'nb', og: 'nb_NO' },
  { code: 'nl', og: 'nl_NL' },
  { code: 'pa', og: 'pa_IN' },
  { code: 'pl', og: 'pl_PL' },
  { code: 'pt-BR', og: 'pt_BR' },
  { code: 'pt-PT', og: 'pt_PT' },
  { code: 'ro', og: 'ro_RO' },
  { code: 'sv', og: 'sv_SE' },
  { code: 'sw', og: 'sw_KE' },
  { code: 'ta', og: 'ta_IN' },
  { code: 'te', og: 'te_IN' },
  { code: 'th', og: 'th_TH' },
  { code: 'tr', og: 'tr_TR' },
  { code: 'uk', og: 'uk_UA' },
  { code: 'ur', og: 'ur_PK', rtl: true },
  { code: 'vi', og: 'vi_VN' },
  { code: 'zh-Hans', og: 'zh_CN' },
  { code: 'zh-Hant', og: 'zh_TW' },
  { code: 'zh-HK', og: 'zh_HK' },
];

export const CODES = LOCALES.map((l) => l.code);

/** Where the localStorage choice lives (the language menu writes it; the redirect on / reads it). */
export const STORAGE_KEY = 'vespertine-lang';

/**
 * matchLocale as ES5 source, for the inline redirect script in <head> (bundlers reformat Function.toString(), which
 * would break its CSP hash). scripts/check-i18n.mjs checks it answers exactly like matchLocale below.
 */
export const MATCH_LOCALE_SRC =
  "function matchLocale(tag){var t=String(tag||'').toLowerCase();if(!t)return null;for(var i=0;i<CODES.length;i++)if(CODES[i].toLowerCase()===t)return CODES[i];" +
  "var p=t.split('-'),l=p[0],r=p.slice(1),has=function(x){return r.indexOf(x)>=0};" +
  "if(l==='zh'){if(has('hant'))return has('hk')||has('mo')?'zh-HK':'zh-Hant';if(has('hans'))return 'zh-Hans';if(has('hk')||has('mo'))return 'zh-HK';if(has('tw'))return 'zh-Hant';return 'zh-Hans'}" +
  "if(l==='pt')return r.length&&!has('br')?'pt-PT':'pt-BR';var a={no:'nb',nn:'nb',tl:'fil',iw:'he','in':'id'}[l];if(a)return a;return CODES.indexOf(l)>=0?l:null}";

/**
 * The supported locale a browser language tag maps to, or null. Exact tags first (pt-BR, zh-HK), then Chinese by
 * script or region, Portuguese by region, Norwegian, legacy codes, then the primary language.
 */
export function matchLocale(tag) {
  const t = String(tag || '').toLowerCase();
  if (!t) return null;
  for (const c of CODES) if (c.toLowerCase() === t) return c;
  const [lang, ...rest] = t.split('-');
  if (lang === 'zh') {
    if (rest.includes('hant')) return rest.includes('hk') || rest.includes('mo') ? 'zh-HK' : 'zh-Hant';
    if (rest.includes('hans')) return 'zh-Hans';
    if (rest.includes('hk') || rest.includes('mo')) return 'zh-HK';
    if (rest.includes('tw')) return 'zh-Hant';
    return 'zh-Hans';
  }
  if (lang === 'pt') return rest.length && !rest.includes('br') ? 'pt-PT' : 'pt-BR';
  const alias = { no: 'nb', nn: 'nb', tl: 'fil', iw: 'he', in: 'id' }[lang];
  if (alias) return alias;
  return CODES.includes(lang) ? lang : null;
}
