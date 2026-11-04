// The /compare/ pages (English only): one page per player in the home page's comparison table. Every cell comes from
// that table (src/i18n/en.json, home.compare.rows), so the pages can't say anything the home page and
// docs/COMPARISON.md don't; the sources are the primary pages COMPARISON.md already cites. The two hand-written parts
// of each page, the one-line summary and the "choose …" lists, only restate cells of the table: change them
// when the table changes. "Not documented" means the vendor doesn't say either way, not that the feature is missing.
import { links } from './app';
import { compare } from './content';

/** When docs/COMPARISON.md was last updated (its room-correction row); the other cells were checked 9 to 14 October 2026. */
export const CHECKED = { iso: '2026-10-29', text: '29 October 2026', cells: '9 to 14 October 2026' };

export type Rival = {
  slug: string;
  /** Column in the home page's table, 0 = Vespertine. */
  col: number;
  name: string;
  /** What people type when they look for it. */
  title: string;
  description: string;
  summary: string;
  chooseThem: string[];
  chooseUs: string[];
  sources: { text: string; url: string }[];
};

const R = (r: Omit<Rival, 'name'>): Rival => ({ ...r, name: compare.players[r.col] });

export const rivals: Rival[] = [
  R({
    slug: 'audirvana',
    col: 2,
    title: 'Audirvana alternative for Mac: Vespertine compared with Audirvana Studio and Origin',
    description: 'A feature-by-feature comparison of Vespertine, a free open-source Mac player, with Audirvana Studio and Origin, from each product’s own documentation.',
    summary: 'Both play FLAC and DSD with automatic rate switching and exclusive mode, and both play local surround files and SACD ISO. Vespertine is open source and documents Apple Spatial Audio for local surround; Audirvana Studio adds streaming-service integration.',
    chooseThem: [
      'You want streaming-service integration: Audirvana Studio has it (Origin does not).',
      'You want to host Audio Unit plugins or a general convolution engine (Origin: a paid option). Vespertine’s convolution is for room correction only, and it has no plugin hosting.',
    ],
    chooseUs: [
      'You want source code you can read (Vespertine is GPL-3.0; Audirvana is closed).',
      'You want Apple Spatial Audio for your own surround files: Vespertine does it, and Audirvana’s documentation doesn’t mention it.',
      'You want room correction measured inside the app with a USB microphone, or REW / Equalizer APO filter import.',
    ],
    sources: [
      { text: 'Audirvana Origin product page', url: 'https://audirvana.com/audirvana-origin/' },
      { text: 'Is Audirvana bit-perfect? (help center)', url: 'https://help.audirvana.com/en/support/solutions/articles/202000051094-is-audirv%C4%81na-bit-perfect-' },
      { text: 'Supported audio formats (help center)', url: 'https://help.audirvana.com/en/support/solutions/articles/202000050817-which-audio-file-formats-are-compatible-with-audirv%C4%81na-' },
      { text: 'Plugins for EQ or acoustic correction (help center)', url: 'https://help.audirvana.com/en/support/solutions/articles/202000051049-how-to-use-plugins-for-eq-or-acoustic-correction-in-audirv%C4%81na-' },
    ],
  }),
  R({
    slug: 'roon',
    col: 3,
    title: 'Roon alternative for local files on Mac: Vespertine compared with Roon',
    description: 'A feature-by-feature comparison of Vespertine, a free open-source Mac player for local files, with Roon, from Roon’s own documentation.',
    summary: 'Both play FLAC and DSD files with automatic rate switching, exclusive mode and local surround. Roon integrates streaming services and documents convolution filters; Vespertine is open source, plays SACD ISO images, and documents Apple Spatial Audio for local surround.',
    chooseThem: [
      'You want streaming-service integration: Roon has it, and Vespertine plays only music you own.',
      'You want convolution filters in a general DSP engine. Vespertine’s convolution is for room correction.',
    ],
    chooseUs: [
      'You want source code you can read (Vespertine is GPL-3.0; Roon is closed).',
      'You want SACD ISO images played straight from the image: Roon’s supported-formats FAQ lists DSD only as DSF and DFF files.',
      'You want Apple Spatial Audio for your own surround files, or a check for upsampled “hi-res” files (Roon’s audio analysis measures loudness and dynamic range).',
    ],
    sources: [
      { text: 'Roon audio setup basics', url: 'https://help.roonlabs.com/portal/en/kb/articles/audio-setup-basics' },
      { text: 'Roon multichannel', url: 'https://help.roonlabs.com/portal/en/kb/articles/multichannel' },
      { text: 'Roon DSP engine: convolution', url: 'https://help.roonlabs.com/portal/en/kb/articles/dsp-engine-convolution' },
      { text: 'Roon supported formats FAQ', url: 'https://help.roonlabs.com/portal/en/kb/articles/faq-what-audio-file-formats-does-roon-support' },
      { text: 'Roon sound quality', url: 'https://roon.app/en/sound-quality' },
    ],
  }),
  R({
    slug: 'colibri',
    col: 5,
    title: 'Colibri alternative for Mac: Vespertine compared with Colibri',
    description: 'A feature-by-feature comparison of Vespertine, a free open-source Mac player, with the Colibri lossless player, from Colibri’s own documentation.',
    summary: 'Both play FLAC and DSD with automatic rate switching and exclusive mode. Vespertine is open source and also plays SACD ISO images; Colibri’s documentation doesn’t mention surround files, Spatial Audio, file analysis or room correction.',
    chooseThem: [
      'You want a paid Mac App Store player with a 10-band equalizer and BS2B crossfeed, which Colibri has (the other features in the table are not documented either way).',
    ],
    chooseUs: [
      'You want source code you can read (Vespertine is GPL-3.0; Colibri publishes none).',
      'You want SACD ISO images: Colibri’s FAQ says they are unsupported.',
      'You want surround files, Apple Spatial Audio, hi-res file analysis or room correction, none of which Colibri documents.',
    ],
    sources: [
      { text: 'Colibri', url: 'https://colibri-lossless.com/' },
      { text: 'Colibri FAQ', url: 'https://colibri-lossless.com/faq/' },
      { text: 'Colibri on the Mac App Store', url: 'https://apps.apple.com/us/app/colibri/id1178295426' },
    ],
  }),
  R({
    slug: 'cog',
    col: 6,
    title: 'Cog alternative for Mac: Vespertine compared with Cog',
    description: 'A feature-by-feature comparison of Vespertine with Cog, the free open-source Mac player, from Cog’s own site and source code.',
    summary: 'Both are free, open-source players that play FLAC and DSD, local surround files and Apple Spatial Audio, with automatic rate switching and exclusive mode. Vespertine adds SACD ISO images, hi-res file analysis and room correction; Cog streams internet radio. Vespertine does not claim to be the only player offering Apple Spatial Audio for local surround.',
    chooseThem: [
      'You want a GPL-2.0 open-source player that plays internet radio (HTTP and HLS streams) and, like Vespertine, covers FLAC, DSD, local surround and Apple Spatial Audio.',
      'You want an in-app bit-perfect indicator: Cog reports each track as bit perfect, modified or unknown.',
    ],
    chooseUs: [
      'You want SACD ISO images: no Cog decoder reads .iso files.',
      'You want hi-res file analysis: Cog has a live spectrum display, not an analysis of the file.',
      'You want room correction measured in the app, or REW / Equalizer APO filter import.',
    ],
    sources: [
      { text: 'Cog', url: 'https://cog.losno.co/' },
      { text: 'Cog README', url: 'https://github.com/losnoco/Cog/blob/main/README.md' },
    ],
  }),
  R({
    slug: 'foobar2000',
    col: 7,
    title: 'foobar2000 for Mac alternative: Vespertine compared with foobar2000',
    description: 'A feature-by-feature comparison of Vespertine with foobar2000 for Mac, from foobar2000’s own documentation and a hands-on test of DSD and SACD ISO files.',
    summary: 'Both play FLAC with exclusive output. In the hands-on test on foobar2000 2.26, DSF, DFF and SACD ISO files failed to open without extra components; Vespertine plays them. foobar2000 for Mac documents Audio Unit DSP, which Vespertine does not host.',
    chooseThem: [
      'You want Audio Unit effect hosting: the foobar2000 for Mac change log documents “Apple Audio Unit DSP support”. Vespertine does not host effect plugins.',
      'You already use foobar2000 and its settings, and only play formats it handles without extra components.',
    ],
    chooseUs: [
      'You want DSD and SACD ISO files to play without setup: in the test, foobar2000 2.26 refused them with no components installed.',
      'You want an analysis of hi-res files (foobar2000 for Mac has a live spectrum only), a signal path, or room correction.',
      'You want source code you can read (Vespertine is GPL-3.0; foobar2000 is proprietary).',
    ],
    sources: [
      { text: 'foobar2000 for Mac', url: 'https://www.foobar2000.org/mac' },
      { text: 'foobar2000 for Mac change log', url: 'https://www.foobar2000.org/changelog-mac' },
      { text: 'foobar2000 license', url: 'https://www.foobar2000.org/license' },
    ],
  }),
  R({
    slug: 'apple-music',
    col: 1,
    title: 'Apple Music bit-perfect on Mac: how it compares with Vespertine',
    description: 'What Apple Music on the Mac does and doesn’t do for bit-perfect playback, FLAC and DSD, compared with Vespertine, from Apple’s documentation and third-party loopback tests.',
    summary: 'Apple Music plays its own catalog and ALAC; it does not play FLAC or DSD files, and on macOS 27 third-party loopback tests found 16/24-bit playback bit-exact. Vespertine plays your own files, including FLAC, DSD and surround, and switches the DAC rate automatically.',
    chooseThem: [
      'You want the Apple Music streaming catalog: Vespertine plays only music you own and cannot play DRM-protected Apple Music downloads.',
      'You want Spatial Audio for Dolby Atmos tracks in the Apple Music catalog, with head tracking on AirPods.',
    ],
    chooseUs: [
      'You have FLAC or DSD files: the Music app plays neither.',
      'You want automatic DAC rate switching and exclusive (hog) mode, which the table shows Apple Music without.',
      'You want a signal path and hi-res file analysis, or room correction.',
    ],
    sources: [
      { text: 'Apple: lossless audio in Apple Music', url: 'https://support.apple.com/en-us/118295' },
      { text: 'Apple: play high sample rate audio on your Mac', url: 'https://support.apple.com/en-us/108326' },
      { text: 'Apple: Spatial Audio in Music on Mac', url: 'https://support.apple.com/guide/music/play-spatial-audio-mus877f146ac/mac' },
      { text: 'Apple: equalizer and Sound Enhancer in Music', url: 'https://support.apple.com/guide/music/museb684a3de/mac' },
      { text: 'Third-party loopback tests on macOS 27 (Audio Science Review forum)', url: 'https://www.audiosciencereview.com/forum/index.php?threads/music-app-on-macos-27-and-ios-27-finally-plays-bit-perfect.73373/' },
    ],
  }),
];

export const comparison = { sources: links.comparison, issues: links.issues };

/** The table for one rival: [feature, Vespertine, rival], and the footnotes its cells carry. */
export function tableFor(r: Rival) {
  const rows = compare.rows.map((row) => [row[0], row[1], row[1 + r.col]]);
  const marks = new Set(rows.flatMap((row) => [...(row[1] + row[2]).matchAll(/[¹²³⁴]/g)].map((m) => m[0])));
  const notes = compare.notes.filter((n) => marks.has(n[0]));
  return { rows, notes };
}
