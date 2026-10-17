// The facts every page, the JSON-LD, llms.txt and the social cards share. Change a fact here, not in a page.
// Sources: project.yml (deployment target), README.md, docs/FEATURES.md, the Homebrew cask (szeremeta1/homebrew-tap),
// .github/FUNDING.yml and the GitHub releases (src/data/releases.json, refreshed at build time).
import releases from './releases.json';

export const SITE = 'https://vespertineapp.com';
export const REPO = 'https://github.com/szeremeta1/Vespertine';
const BLOB = `${REPO}/blob/main`;

export type Release = (typeof releases)[number];
export const latest: Release = releases[0];
export { releases };

export const app = {
  name: 'Vespertine',
  formerName: 'Nocturne',
  tagline: 'The free, open-source Mac player for surround and hi-res music collections.',
  minMacOS: '14.4',
  minMacOSName: 'Sonoma',
  arch: 'Apple silicon and Intel',
  license: 'GPL-3.0-or-later',
  licenseName: 'GNU General Public License, version 3 or later',
  licenseUrl: 'https://www.gnu.org/licenses/gpl-3.0.html',
  brew: 'brew install --cask szeremeta1/tap/vespertine',
  brewUpgrade: 'brew upgrade --cask vespertine',
  /** Languages besides English (App/Resources/Localizable.xcstrings). */
  languages: 44,
  /** Every interface language, as BCP 47 codes. */
  languageCodes: ['en', 'am', 'ar', 'bn', 'cs', 'da', 'de', 'el', 'es', 'fa', 'fi', 'fil', 'fr', 'gu', 'ha', 'he', 'hi', 'hu', 'id', 'it', 'ja', 'kn', 'ko', 'ml', 'mr', 'ms', 'nb', 'nl', 'pa', 'pl', 'pt-BR', 'pt-PT', 'ro', 'sv', 'sw', 'ta', 'te', 'th', 'tr', 'uk', 'ur', 'vi', 'zh-HK', 'zh-Hans', 'zh-Hant'],
  tested: ['FiiO K11 (every rate to 384 kHz, DoP, integer mode)', 'AirPods Max over USB-C and Bluetooth', 'MacBook Pro speakers'],
  author: {
    name: 'Alexander Szeremeta',
    short: 'Alex Szeremeta',
    url: 'https://szeremeta.org/',
    github: 'https://github.com/szeremeta1',
  },
  pressEmail: 'press@szeremeta.org',
};

export const links = {
  repo: REPO,
  releases: `${REPO}/releases`,
  latestRelease: `${REPO}/releases/latest`,
  issues: `${REPO}/issues`,
  newIssue: `${REPO}/issues/new/choose`,
  dacReport: `${REPO}/issues/new?template=dac_report.yml`,
  discussions: `${REPO}/discussions`,
  sponsors: 'https://github.com/sponsors/szeremeta1',
  security: `${REPO}/security/advisories/new`,
  tap: 'https://github.com/szeremeta1/homebrew-tap',
  license: `${BLOB}/LICENSE`,
  notices: `${BLOB}/THIRD-PARTY-NOTICES.md`,
  features: `${BLOB}/docs/FEATURES.md`,
  verification: `${BLOB}/docs/VERIFICATION.md`,
  comparison: `${BLOB}/docs/COMPARISON.md`,
  analysis: `${BLOB}/docs/ANALYSIS.md`,
  loopback: `${BLOB}/docs/LOOPBACK.md`,
  architecture: `${BLOB}/docs/ARCHITECTURE.md`,
  dvd: `${BLOB}/docs/DVD-VIDEO-LPCM.md`,
  development: `${BLOB}/docs/DEVELOPMENT.md`,
  contributing: `${BLOB}/CONTRIBUTING.md`,
  signalPath: `${BLOB}/Packages/VespertineKit/Sources/VespertineAudio/SignalPath.swift`,
  brandGuide: 'https://raw.githubusercontent.com/szeremeta1/Vespertine/main/docs/brand/brand-guide.pdf',
  raw: 'https://raw.githubusercontent.com/szeremeta1/Vespertine/main',
  ukraine: [
    { name: 'United24', url: 'https://u24.gov.ua/' },
    { name: 'Come Back Alive', url: 'https://savelife.in.ua/en/donate-en/' },
    { name: 'Razom for Ukraine', url: 'https://www.razomforukraine.org/donate/' },
  ],
};

/** "15 October 2026", in Boston time (the releases are published from there). */
export const longDate = (iso: string) =>
  new Intl.DateTimeFormat('en-GB', { timeZone: 'America/New_York', day: 'numeric', month: 'long', year: 'numeric' }).format(new Date(iso));
/** "2026-10-15", in Boston time. */
export const isoDay = (iso: string) =>
  new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(iso));
export const megabytes = (bytes: number) => `${Math.round(bytes / 1e6)} MB`;

/** One line under the download buttons. */
export const requirement = `macOS ${app.minMacOS} or later · ${app.arch}`;

/** The first bold paragraph of a release's notes: its one-sentence summary. */
export const releaseSummary = (r: Release) => (r.body.match(/^\*\*(.+?)\*\*/s)?.[1] ?? r.name).trim();

export const trademarks =
  'Dolby, Dolby Atmos, Dolby Digital, Dolby Digital Plus and Dolby TrueHD are trademarks of Dolby Laboratories. DTS, DTS-HD Master Audio and DTS:X are trademarks of DTS, Inc. Apple, AirPods, AirPods Max, Mac, macOS and Spatial Audio are trademarks of Apple Inc. Vespertine names them only to describe what it plays and where; it isn’t certified, licensed or endorsed by Dolby, DTS or Apple.';
