// Structured data (schema.org JSON-LD). One graph per page; the app, its author and the site have stable @ids, so
// search engines and AI crawlers can join what the pages say about them.
import { SITE, app, latest, links, isoDay, megabytes, releases } from '../data/app';
import { faq, description } from '../data/content';
import { plain } from './text';

export const ids = {
  site: `${SITE}/#website`,
  app: `${SITE}/#app`,
  author: `${SITE}/#author`,
  source: `${SITE}/#source`,
  trailer: `${SITE}/#trailer`,
};

const author = {
  '@type': 'Person',
  '@id': ids.author,
  name: app.author.name,
  url: app.author.url,
  sameAs: [app.author.github, app.author.url],
};

const website = {
  '@type': 'WebSite',
  '@id': ids.site,
  url: `${SITE}/`,
  name: 'Vespertine',
  description,
  inLanguage: 'en',
  publisher: { '@id': ids.author },
};

/** v0.1.0, the first public release: 27 September 2026, Boston time (gh release list). */
const firstRelease = '2026-09-27';

export function appNode(screenshots: { url: string; caption: string }[]) {
  return {
    '@type': 'SoftwareApplication',
    '@id': ids.app,
    name: app.name,
    alternateName: app.formerName,
    description,
    url: `${SITE}/`,
    image: `${SITE}/og/home.jpg`,
    applicationCategory: 'MultimediaApplication',
    applicationSubCategory: 'Music player',
    operatingSystem: `macOS ${app.minMacOS} or later`,
    processorRequirements: 'Apple silicon (arm64) or Intel (x86-64)',
    softwareVersion: latest.version,
    datePublished: firstRelease,
    dateModified: isoDay(latest.date),
    releaseNotes: latest.url,
    downloadUrl: latest.dmg.url,
    installUrl: latest.dmg.url,
    fileSize: megabytes(latest.dmg.size),
    softwareHelp: { '@type': 'CreativeWork', url: links.features },
    screenshot: screenshots.map((s) => ({ '@type': 'ImageObject', url: s.url, caption: s.caption })),
    offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD', availability: 'https://schema.org/InStock', url: latest.dmg.url },
    isAccessibleForFree: true,
    license: app.licenseUrl,
    inLanguage: app.languageCodes,
    author: { '@id': ids.author },
    publisher: { '@id': ids.author },
    sameAs: [links.repo],
    keywords: 'bit-perfect, hi-res audio, surround, SACD ISO, DSD, DoP, DVD-Video LPCM, Dolby Atmos, TrueHD, DTS-HD Master Audio, DTS CD, Spatial Audio, AirPods Max, FLAC, music player, macOS, open source',
  };
}

const sourceNode = {
  '@type': 'SoftwareSourceCode',
  '@id': ids.source,
  name: 'Vespertine source code',
  codeRepository: links.repo,
  programmingLanguage: ['Swift', 'C', 'C++'],
  runtimePlatform: 'macOS',
  license: app.licenseUrl,
  author: { '@id': ids.author },
  targetProduct: { '@id': ids.app },
};

export function trailerNode(contentUrl: string, thumbnailUrl: string) {
  return {
    '@type': 'VideoObject',
    '@id': ids.trailer,
    name: 'Vespertine trailer',
    description: 'A 44-second tour of Vespertine, recorded from the real app on the developer’s own library: the bit-perfect signal path, DSD over DoP, surround as Spatial Audio on AirPods and hi-res file analysis.',
    thumbnailUrl,
    contentUrl,
    // The current cut (git log -- site/public/assets/trailer); the first one went up on 29 September.
    uploadDate: '2026-10-13',
    duration: 'PT44S',
    width: 1920,
    height: 1080,
    inLanguage: 'en',
    about: { '@id': ids.app },
    author: { '@id': ids.author },
  };
}

const faqNode = {
  '@type': 'FAQPage',
  '@id': `${SITE}/#faq`,
  mainEntity: faq.map((f) => ({ '@type': 'Question', name: plain(f.q), acceptedAnswer: { '@type': 'Answer', text: plain(f.a) } })),
};

const crumbs = (name: string, path: string) => ({
  '@type': 'BreadcrumbList',
  itemListElement: [
    { '@type': 'ListItem', position: 1, name: 'Vespertine', item: `${SITE}/` },
    { '@type': 'ListItem', position: 2, name, item: `${SITE}${path}` },
  ],
});

const page = (path: string, name: string, desc: string, extra: Record<string, unknown> = {}) => ({
  '@type': 'WebPage',
  '@id': `${SITE}${path}#webpage`,
  url: `${SITE}${path}`,
  name,
  description: desc,
  isPartOf: { '@id': ids.site },
  inLanguage: 'en',
  ...extra,
});

export const graph = (...nodes: object[]) => ({ '@context': 'https://schema.org', '@graph': nodes });

export function homeGraph(o: { title: string; screenshots: { url: string; caption: string }[]; trailer: string; poster: string }) {
  return graph(
    website,
    page('/', o.title, description, { about: { '@id': ids.app }, primaryImageOfPage: `${SITE}/og/home.jpg`, dateModified: isoDay(latest.date) }),
    appNode(o.screenshots),
    sourceNode,
    trailerNode(o.trailer, o.poster),
    faqNode,
    author,
  );
}

export function innerGraph(o: { path: string; title: string; crumb: string; description: string; type?: string; dateModified?: string; image: string; screenshots: { url: string; caption: string }[]; trailer?: { url: string; poster: string } }) {
  return graph(
    website,
    page(o.path, o.title, o.description, {
      ...(o.type ? { '@type': ['WebPage', o.type] } : {}),
      about: { '@id': ids.app },
      breadcrumb: crumbs(o.crumb, o.path),
      primaryImageOfPage: o.image,
      ...(o.dateModified ? { dateModified: o.dateModified } : {}),
    }),
    appNode(o.screenshots),
    ...(o.trailer ? [trailerNode(o.trailer.url, o.trailer.poster)] : []),
    author,
  );
}

export { releases };
