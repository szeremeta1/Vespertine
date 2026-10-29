// Structured data (schema.org JSON-LD). One graph per page; the app, its author and the site have stable @ids, so
// search engines and AI crawlers can join what the pages say about them.
import { SITE, app, latest, links, isoDay, megabytes, releases } from '../data/app';
import { content } from '../data/content';
import { t, fill, pagePath, ogCard, CODES, type Lang } from '../i18n';
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

// The site, the app and the trailer keep one @id in every language; each page describes them in its own.
const website = (lang: Lang) => ({
  '@type': 'WebSite',
  '@id': ids.site,
  url: `${SITE}/`,
  name: 'Vespertine',
  description: content(lang).description,
  inLanguage: CODES,
  publisher: { '@id': ids.author },
});

/** v0.1.0, the first public release: 27 September 2026, Boston time (gh release list). */
const firstRelease = '2026-09-27';

export function appNode(lang: Lang, screenshots: { url: string; caption: string }[]) {
  const seo = t(lang).seo;
  return {
    '@type': 'SoftwareApplication',
    '@id': ids.app,
    name: app.name,
    alternateName: app.formerName,
    description: content(lang).description,
    url: `${SITE}${pagePath(lang, 'home')}`,
    image: `${SITE}${ogCard(lang, 'home')}`,
    applicationCategory: 'MultimediaApplication',
    applicationSubCategory: seo.subCategory,
    operatingSystem: fill(seo.operatingSystem, { minMacOS: app.minMacOS }),
    processorRequirements: seo.processor,
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
    keywords: seo.keywords,
    featureList: content(lang).scenes.map((s) => plain(s.kicker)),
  };
}

const sourceNode = (lang: Lang) => ({
  '@type': 'SoftwareSourceCode',
  '@id': ids.source,
  name: t(lang).seo.sourceName,
  codeRepository: links.repo,
  programmingLanguage: ['Swift', 'C', 'C++'],
  runtimePlatform: 'macOS',
  license: app.licenseUrl,
  author: { '@id': ids.author },
  targetProduct: { '@id': ids.app },
});

export function trailerNode(lang: Lang, contentUrl: string, thumbnailUrl: string) {
  return {
    '@type': 'VideoObject',
    '@id': ids.trailer,
    name: t(lang).seo.trailerName,
    description: t(lang).seo.trailerDescription,
    thumbnailUrl,
    contentUrl,
    // The current cut (git log -- site/public/assets/trailer); the first one went up on 29 September.
    uploadDate: '2026-10-13',
    duration: 'PT44S',
    width: 1920,
    height: 1080,
    // The trailer has music, no speech or on-screen text to translate.
    inLanguage: 'en',
    about: { '@id': ids.app },
    author: { '@id': ids.author },
  };
}

const faqNode = (lang: Lang) => ({
  '@type': 'FAQPage',
  '@id': `${SITE}${pagePath(lang, 'home')}#faq`,
  inLanguage: lang,
  mainEntity: content(lang).faq.map((f) => ({ '@type': 'Question', name: plain(f.q), acceptedAnswer: { '@type': 'Answer', text: plain(f.a) } })),
});

const crumbs = (lang: Lang, name: string, path: string) => ({
  '@type': 'BreadcrumbList',
  itemListElement: [
    { '@type': 'ListItem', position: 1, name: 'Vespertine', item: `${SITE}${pagePath(lang, 'home')}` },
    { '@type': 'ListItem', position: 2, name, item: `${SITE}${path}` },
  ],
});

const page = (lang: Lang, path: string, name: string, desc: string, extra: Record<string, unknown> = {}) => ({
  '@type': 'WebPage',
  '@id': `${SITE}${path}#webpage`,
  url: `${SITE}${path}`,
  name,
  description: desc,
  isPartOf: { '@id': ids.site },
  inLanguage: lang,
  ...extra,
});

export const graph = (...nodes: object[]) => ({ '@context': 'https://schema.org', '@graph': nodes });

export function homeGraph(o: { lang: Lang; title: string; screenshots: { url: string; caption: string }[]; trailer: string; poster: string }) {
  return graph(
    website(o.lang),
    page(o.lang, pagePath(o.lang, 'home'), o.title, content(o.lang).description, { about: { '@id': ids.app }, primaryImageOfPage: `${SITE}${ogCard(o.lang, 'home')}`, dateModified: isoDay(latest.date) }),
    appNode(o.lang, o.screenshots),
    sourceNode(o.lang),
    trailerNode(o.lang, o.trailer, o.poster),
    faqNode(o.lang),
    author,
  );
}

export function innerGraph(o: { lang: Lang; path: string; title: string; crumb: string; description: string; type?: string; dateModified?: string; image: string; screenshots: { url: string; caption: string }[]; trailer?: { url: string; poster: string } }) {
  return graph(
    website(o.lang),
    page(o.lang, o.path, o.title, o.description, {
      ...(o.type ? { '@type': ['WebPage', o.type] } : {}),
      about: { '@id': ids.app },
      breadcrumb: crumbs(o.lang, o.crumb, o.path),
      primaryImageOfPage: o.image,
      ...(o.dateModified ? { dateModified: o.dateModified } : {}),
    }),
    appNode(o.lang, o.screenshots),
    ...(o.trailer ? [trailerNode(o.lang, o.trailer.url, o.trailer.poster)] : []),
    author,
  );
}

export { releases };
