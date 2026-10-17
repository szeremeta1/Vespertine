// The site's two inline scripts. They live here so astro.config.mjs can hash them for the CSP:
// Astro hashes the scripts it bundles, not `is:inline` ones. Edit here, never in the pages.

/** <head>: mark JS + motion before first paint, so the CSS intro and JS-only styles apply without a flash. */
export const HEAD_CLASSES =
  "(function(d){d.classList.add('js');if(!matchMedia('(prefers-reduced-motion: reduce)').matches)d.classList.add('motion')})(document.documentElement)";

/** End of <body>: attach the sources of below-the-fold images once the first screen has loaded and painted. */
export const DEFER_IMAGES =
  "(function(){function go(){document.querySelectorAll('picture[data-defer]').forEach(function(p){p.querySelectorAll('source[data-srcset]').forEach(function(s){s.srcset=s.dataset.srcset});var i=p.querySelector('img');i.srcset=i.dataset.srcset;i.src=i.dataset.src;p.removeAttribute('data-defer')})}function settle(){requestAnimationFrame(function(){setTimeout(go,300)})}if(document.readyState==='complete')settle();else addEventListener('load',settle,{once:true})})()";
