// The English-only guide pages: each has one URL, no other-language versions (so no hreflang beyond English) and no
// entry in the translated strings. Their words live in src/data/<page>.ts, not src/i18n, because scripts/check-i18n.mjs
// would require every one of the 45 languages to translate them. The sitemap, llms.txt and the English footer read
// this list. `updated` is the page's own last real edit (the sitemap's lastmod): change it when its words change.
export type Guide = { path: string; updated: string; linkText: string; summary: string; /** Listed in the English footer (default yes). */ footer?: boolean };

import { rivals } from './compare';

export const guides: Guide[] = [
  {
    path: '/hi-res-audio-player-for-mac/',
    updated: '2026-11-03',
    linkText: 'Hi-res audio player for Mac',
    summary: 'what hi-res playback takes on a Mac, the formats Vespertine plays, how to check playback is bit-perfect, and install',
  },
  {
    path: '/compare/',
    updated: '2026-11-03',
    linkText: 'Vespertine compared with other Mac players',
    summary: 'one page per player (Audirvana, Roon, Colibri, Cog, foobar2000, Apple Music), each from the vendor\'s own documentation',
  },
  ...rivals.map((r) => ({
    path: `/compare/${r.slug}/`,
    updated: '2026-11-03',
    linkText: `Vespertine compared with ${r.name}`,
    summary: r.description,
    footer: false,
  })),
];
