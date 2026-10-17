// Refreshes src/data/releases.json from GitHub's releases API: the latest published releases, their notes and DMGs.
// The pages workflow runs it before every build (and a published release triggers a build), so the version, download
// link, file size and "What's new" on the site always match the latest release. The committed copy is the fallback:
// if GitHub can't be reached, the build uses it unchanged.
//   node scripts/fetch-releases.mjs        (GITHUB_TOKEN, if set, raises the rate limit)
import { readFileSync, writeFileSync } from 'node:fs';

const REPO = 'szeremeta1/Vespertine';
const KEEP = 6;
const out = new URL('../src/data/releases.json', import.meta.url);

const headers = { Accept: 'application/vnd.github+json', 'User-Agent': 'vespertineapp.com build' };
if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;

try {
  const res = await fetch(`https://api.github.com/repos/${REPO}/releases?per_page=20`, { headers, signal: AbortSignal.timeout(20000) });
  if (!res.ok) throw new Error(`GitHub answered ${res.status}`);
  const all = await res.json();
  const releases = all
    .filter((r) => !r.draft && !r.prerelease)
    .slice(0, KEEP)
    .map((r) => {
      const dmg = (r.assets ?? []).find((a) => a.name.endsWith('.dmg'));
      if (!dmg) throw new Error(`${r.tag_name} has no DMG`);
      return {
        version: r.tag_name.replace(/^v/, ''),
        tag: r.tag_name,
        name: r.name,
        date: r.published_at,
        url: r.html_url,
        body: (r.body ?? '').replace(/\r\n/g, '\n').trim(),
        dmg: { name: dmg.name, url: dmg.browser_download_url, size: dmg.size, sha256: (dmg.digest ?? '').replace(/^sha256:/, '') },
      };
    });
  if (!releases.length) throw new Error('no published releases');
  const json = JSON.stringify(releases, null, 2) + '\n';
  let before = '';
  try { before = readFileSync(out, 'utf8'); } catch { /* first run */ }
  writeFileSync(out, json);
  console.log(`releases.json: ${releases.map((r) => r.version).join(', ')}${before === json ? ' (unchanged)' : ''}`);
} catch (e) {
  // The committed snapshot stays in place; say so loudly in the build log.
  console.warn(`fetch-releases: kept the committed src/data/releases.json (${e.message})`);
}
