// sitemap.xml, with each page's real last change, every language's version of it (hreflang alternates), the
// screenshots on the home page and the trailer.
import type { APIRoute } from 'astro';
import { SITE, latest, isoDay } from '../data/app';
import { escapeHtml as x } from '../lib/text';
import { sceneShots, trailerPoster, TRAILER } from '../lib/shots';
import { CODES, hreflangOf, pagePath, t, type Page } from '../i18n';

export const GET: APIRoute = async () => {
  const poster = await trailerPoster();
  const released = isoDay(latest.date);
  const pages: { page: Page; lastmod: string }[] = [
    { page: 'home', lastmod: released },
    { page: 'press', lastmod: released },
    { page: 'privacy', lastmod: '2026-10-29' },
    { page: 'terms', lastmod: '2026-09-29' },
  ];
  const urls: string[] = [];
  for (const p of pages) {
    const alternates = [...CODES.map((c) => `<xhtml:link rel="alternate" hreflang="${hreflangOf(c)}" href="${SITE}${pagePath(c, p.page)}"/>`), `<xhtml:link rel="alternate" hreflang="x-default" href="${SITE}${pagePath('en', p.page)}"/>`].join('');
    for (const lang of CODES) {
      const extra: string[] = [];
      if (p.page === 'home') {
        const shots = await sceneShots(lang);
        const seo = t(lang).seo;
        extra.push(...shots.map((s) => `<image:image><image:loc>${x(s.url)}</image:loc></image:image>`));
        extra.push(`<video:video><video:thumbnail_loc>${SITE}${poster.src}</video:thumbnail_loc><video:title>${x(seo.trailerName)}</video:title><video:description>${x(seo.trailerDescription)}</video:description><video:content_loc>${SITE}${TRAILER}</video:content_loc><video:duration>55</video:duration><video:publication_date>2026-11-01</video:publication_date><video:family_friendly>yes</video:family_friendly></video:video>`);
      }
      urls.push(`<url><loc>${SITE}${pagePath(lang, p.page)}</loc><lastmod>${p.lastmod}</lastmod>${alternates}${extra.join('')}</url>`);
    }
  }
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml" xmlns:image="http://www.google.com/schemas/sitemap-image/1.1" xmlns:video="http://www.google.com/schemas/sitemap-video/1.1">
${urls.join('\n')}
</urlset>
`;
  return new Response(body, { headers: { 'Content-Type': 'application/xml; charset=utf-8' } });
};
