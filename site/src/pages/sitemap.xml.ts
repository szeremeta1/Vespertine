// sitemap.xml, with each page's real last change, the screenshots on the home page and the trailer.
import type { APIRoute } from 'astro';
import { SITE, latest, isoDay } from '../data/app';
import { escapeHtml as x } from '../lib/text';
import { sceneShots, trailerPoster, TRAILER } from '../lib/shots';

export const GET: APIRoute = async () => {
  const shots = await sceneShots();
  const poster = await trailerPoster();
  const released = isoDay(latest.date);
  const pages = [
    { loc: '/', lastmod: released, extra: [
      ...shots.map((s) => `<image:image><image:loc>${x(s.url)}</image:loc></image:image>`),
      `<video:video><video:thumbnail_loc>${SITE}${poster.src}</video:thumbnail_loc><video:title>Vespertine trailer</video:title><video:description>A 44-second tour of Vespertine, recorded from the real app: the bit-perfect signal path, DSD over DoP, surround as Spatial Audio on AirPods and hi-res file analysis.</video:description><video:content_loc>${SITE}${TRAILER}</video:content_loc><video:duration>44</video:duration><video:publication_date>2026-10-13</video:publication_date><video:family_friendly>yes</video:family_friendly></video:video>`,
    ] },
    { loc: '/press.html', lastmod: released, extra: [] },
    { loc: '/privacy.html', lastmod: '2026-10-17', extra: [] },
    { loc: '/terms.html', lastmod: '2026-09-29', extra: [] },
  ];
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:image="http://www.google.com/schemas/sitemap-image/1.1" xmlns:video="http://www.google.com/schemas/sitemap-video/1.1">
${pages.map((p) => `<url><loc>${SITE}${p.loc}</loc><lastmod>${p.lastmod}</lastmod>${p.extra.join('')}</url>`).join('\n')}
</urlset>
`;
  return new Response(body, { headers: { 'Content-Type': 'application/xml; charset=utf-8' } });
};
