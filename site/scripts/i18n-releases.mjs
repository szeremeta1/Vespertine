// Copies the release notes the site shows into src/i18n/en.json ("releases"), so they can be translated like every
// other string: for each release in src/data/releases.json (and any draft notes named on the command line), its
// one-sentence summary, the rest of its notes without the Install section, and a hash of the GitHub text. A locale's
// translation of a release is used only while its hash matches the notes GitHub serves; otherwise the page shows the
// English notes, marked as English (src/i18n/index.ts), and scripts/check-i18n.mjs warns. Run it after a release (or
// with the next release's draft notes), then translate the new entries into every locale file.
//   node scripts/i18n-releases.mjs [../docs/releases/0.14.0.md ...]
import { readFileSync, writeFileSync } from 'node:fs';
import { basename } from 'node:path';
import { releaseParts } from '../src/i18n/release-parts.mjs';

const enFile = new URL('../src/i18n/en.json', import.meta.url);
const releases = JSON.parse(readFileSync(new URL('../src/data/releases.json', import.meta.url), 'utf8'));
const en = JSON.parse(readFileSync(enFile, 'utf8'));

const out = {};
for (const file of process.argv.slice(2)) {
  const version = basename(file, '.md');
  out[version] = releaseParts(readFileSync(file, 'utf8'));
}
for (const r of releases) out[r.version] = releaseParts(r.body);
// Newest first, like the page. Only the latest release's full notes are on the page; earlier ones show their summary.
// The newest two keep their notes, so a draft (the next release) and the current one are both ready.
const order = Object.keys(out).sort((a, b) => b.localeCompare(a, 'en', { numeric: true }));
en.releases = Object.fromEntries(order.map((v, i) => [v, i < 2 ? out[v] : { hash: out[v].hash, summary: out[v].summary }]));
writeFileSync(enFile, JSON.stringify(en, null, 2) + '\n');
console.log(`en.json releases: ${order.join(', ')}`);
