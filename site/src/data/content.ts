// The words on the home page, as data, so llms.txt, llms-full.txt and the FAQ's JSON-LD say exactly what the page says.
// The words themselves live in src/i18n/<lang>.json (English: en.json); this file joins them with what never changes
// (icons, links, screenshots). Strings are trusted HTML. Every claim follows README.md, docs/FEATURES.md,
// docs/COMPARISON.md and the release notes; if one of those changes, change en.json and every locale with it.
import { app, links } from './app';
import { t, fill, num, pagePath, type Lang } from '../i18n';

export type Scene = {
  id: string;
  jack: string;
  kicker: string;
  title: string;
  lede: string;
  body: string[];
  list?: string[];
  note?: string;
  links?: { href: string; text: string }[];
  shot: string;
  wall?: boolean;
  wallLabel?: string;
  alt: string;
  float?: { shot: string; alt: string; caption: string };
  caption?: string;
};

const icons = [
  'M17 14a3 3 0 1 1 0 6 3 3 0 0 1 0-6ZM9.5 9.5a10.6 10.6 0 0 0 0 15M24.5 9.5a10.6 10.6 0 0 1 0 15M5.5 5.5a16.3 16.3 0 0 0 0 23M28.5 5.5a16.3 16.3 0 0 1 0 23',
  'M4 17h6l3-8 4 16 4-12 3 4h6',
  'M4 26c3-9 5-15 8-15s3 10 6 10 3-14 6-14 3 13 6 19M26 4v26',
  'M7 8h20v14H7zM13 27h8M17 22v5M12 15.5l3 3 6-6',
];

/** The screenshots, links and layout of each scene; the words come from the locale. */
const sceneData: { id: string; shot: string; links?: string[]; float?: string; wall?: boolean }[] = [
  { id: 'signal-path', shot: 'bit-perfect-fosi-zd3-24-96', links: [links.signalPath, links.verification, links.loopback], float: 'loopback-test' },
  { id: 'room-correction', shot: 'room-correction-fosi-zd3', links: [links.roomCorrection], float: 'room-correction-portrait-detail' },
  { id: 'surround', shot: 'spatial-audio-airpods-max', float: 'stereo-and-surround-versions' },
  { id: 'discs', shot: 'sacd-iso', links: [links.dvd], float: 'dsd-native-dop-detail' },
  { id: 'analysis', shot: 'fake-hi-res-detection', links: [links.analysis] },
  { id: 'airpods', shot: 'smart-playlist' },
  { id: 'library', shot: 'genres', links: [links.features] },
  { id: 'languages', shot: 'languages', wall: true },
];

export const marquee = ['FLAC', 'DSD', 'SACD ISO', 'Dolby Atmos', 'DVD-Video', 'TrueHD', 'DTS-HD MA', 'ALAC', 'DTS CD', 'WavPack'];
const exts = ['.flac .m4a .wav .aiff .cue', '.dsf .dff', '.iso', '.iso VIDEO_TS', '.ec3 .m4a .mp4', '.thd .mlp .mka', '.dts .dtshd .mka', '.ac3 .ec3', '.wav .flac .cue', '.ape .wv .tta', '.opus .ogg .mpc .mp3 .m4a'];
const players = ['Vespertine', 'Apple Music (Mac)', 'Audirvana Studio / Origin', 'Roon', 'VeraVox', 'Colibri', 'Cog', 'foobar2000 for Mac'];

/** Values for the {placeholders} in the locale strings. */
export function vars(lang: Lang) {
  return {
    languages: num(lang, app.languages),
    languagesTotal: num(lang, app.languages + 1),
    minMacOS: app.minMacOS,
    minMacOSName: app.minMacOSName,
    formerName: app.formerName,
    brew: `<code>${app.brew}</code>`,
    brewUpgrade: `<code>${app.brewUpgrade}</code>`,
    'href.privacy': pagePath(lang, 'privacy'),
    'href.verification': links.verification,
    'href.dacReport': links.dacReport,
    'href.roomCorrection': links.roomCorrection,
    'href.newIssue': links.newIssue,
    'href.issues': links.issues,
    'href.comparison': links.comparison,
    'href.discussions': links.discussions,
    'href.brandGuide': links.brandGuide,
    'href.license': links.license,
  };
}

export function content(lang: Lang) {
  const d = t(lang).home;
  const v = vars(lang);
  const f = (s: string) => fill(s, v);
  const scenes: Scene[] = sceneData.map((s) => {
    const w = d.scenes[s.id as keyof typeof d.scenes] as {
      jack: string; kicker: string; title: string; lede: string; body?: string[]; list?: string[]; note?: string;
      links?: string[]; alt: string; floatAlt?: string; floatCaption?: string; wallLabel?: string;
    };
    return {
      id: s.id,
      jack: w.jack,
      kicker: f(w.kicker),
      title: w.title,
      lede: f(w.lede),
      body: (w.body ?? []).map(f),
      ...(w.list ? { list: w.list.map(f) } : {}),
      ...(w.note ? { note: w.note } : {}),
      ...(s.links ? { links: s.links.map((href, i) => ({ href, text: w.links![i] })) } : {}),
      shot: s.shot,
      ...(s.wall ? { wall: true, wallLabel: w.wallLabel } : {}),
      alt: f(w.alt),
      ...(s.float ? { float: { shot: s.float, alt: w.floatAlt!, caption: w.floatCaption! } } : {}),
    };
  });
  return {
    description: t(lang).home.description,
    hero: { lede: f(d.hero.lede), fine: t(lang).common.untested },
    pillars: d.pillars.map((p, i) => ({ title: p.title, text: p.text, icon: icons[i] })),
    scenes,
    badges: [
      { text: d.badges.bitPerfect, tone: 'brass' },
      { text: d.badges.exclusive },
      { text: '32 / 192' },
      { text: '44.1 → 48 <span class="unit">kHz</span>', tone: 'copper' },
      { text: 'DSD 128 · <span class="unit">DoP</span>' },
      { text: d.badges.roomCorrection, tone: 'copper' },
      { text: d.badges.spatial },
      { text: d.badges.synthetic, tone: 'copper' },
    ] as { text: string; tone?: string }[],
    marquee,
    formats: d.formats.rows.map((r, i) => ({ name: r.name, text: r.text, ext: exts[i] })),
    compare: {
      intro: d.compare.intro,
      players: players.map((p, i) => (i === 1 ? d.compare.appleMusic : p)),
      rows: d.compare.rows,
      notes: d.compare.notes,
    },
    faq: d.faq.items.map((x) => ({ q: x.q, a: f(x.a) })),
    support: d.support.cards.map((c, i) => ({ title: c.title, text: f(c.text), cta: c.cta, href: [links.sponsors, links.dacReport, links.newIssue, links.repo][i] })),
  };
}

// English, for llms.txt, llms-full.txt and the JSON-LD.
const english = content('en');
export const { description, hero, pillars, scenes, badges, formats, compare, faq, support } = english;
