// The site's inline scripts. They live here so astro.config.mjs can hash them for the CSP:
// Astro hashes the scripts it bundles, not `is:inline` ones. Edit here, never in the pages.
import { CODES, STORAGE_KEY, MATCH_LOCALE_SRC, BOT_UA } from './i18n/locales.mjs';

/** <head>: mark JS + motion before first paint, so the CSS intro and JS-only styles apply without a flash. */
export const HEAD_CLASSES =
  "(function(d){d.classList.add('js');if(!matchMedia('(prefers-reduced-motion: reduce)').matches)d.classList.add('motion')})(document.documentElement)";

/** End of <body>: attach the sources of below-the-fold images once the first screen has loaded and painted. */
export const DEFER_IMAGES =
  "(function(){function go(){document.querySelectorAll('picture[data-defer]').forEach(function(p){p.querySelectorAll('source[data-srcset]').forEach(function(s){s.srcset=s.dataset.srcset});var i=p.querySelector('img');i.srcset=i.dataset.srcset;i.src=i.dataset.src;p.removeAttribute('data-defer')})}function settle(){requestAnimationFrame(function(){setTimeout(go,300)})}if(document.readyState==='complete')settle();else addEventListener('load',settle,{once:true})})()";

/**
 * <head> of the English home page only: send a first-time visitor whose browser prefers one of the site's other
 * languages to that language's home page, once, with location.replace (so Back doesn't bounce). A language picked
 * in the menu (localStorage, written by src/scripts/main.ts) always wins, English included, and nothing happens when
 * the visitor arrived from another page of this site, or is a crawler (BOT_UA): search engines index / as English and
 * every other language at its own URL, which never redirects. Locale matching is matchLocale in src/i18n/locales.mjs.
 */
export const LANG_REDIRECT =
  `(function(){var CODES=${JSON.stringify(CODES)};${MATCH_LOCALE_SRC}` +
  `try{var p=location.pathname;if(p!=='/'&&p!=='/index.html')return;if(/${BOT_UA}/i.test(navigator.userAgent))return;var s=null;try{s=localStorage.getItem(${JSON.stringify(STORAGE_KEY)})}catch(e){}` +
  `var to=null;if(s){if(s!=='en'&&CODES.indexOf(s)>=0)to=s}else{var r=document.referrer;if(r){try{if(new URL(r).host===location.host)return}catch(e){}}` +
  `var l=navigator.languages&&navigator.languages.length?navigator.languages:[navigator.language];for(var i=0;i<l.length;i++){var m=matchLocale(l[i]);if(m){if(m!=='en')to=m;break}}}` +
  `if(to)location.replace('/'+to+'/'+location.search+location.hash)}catch(e){}})()`;
