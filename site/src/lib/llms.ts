// The text behind /llms.txt (https://llmstxt.org) and /llms-full.txt: what Vespertine is, how to install it and
// where everything lives, written for language models and AI assistants. Built from the same data as the pages,
// so it can't drift from them.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { SITE, app, latest, releases, links, longDate, megabytes, releaseSummary } from '../data/app';
import { description, hero, pillars, scenes, formats, compare, faq } from '../data/content';
import { markdownish, plain } from './text';

const install = [
  `- [Download Vespertine ${latest.version} for Mac](${latest.dmg.url}) (${latest.dmg.name}, ${megabytes(latest.dmg.size)}, released ${longDate(latest.date)}). Open the DMG and move Vespertine to Applications. Signed with a Developer ID and notarized by Apple; it updates itself, and every update is EdDSA-signed.`,
  `- Homebrew: \`${app.brew}\` (update with \`${app.brewUpgrade}\` or the app's own updates).`,
  `- Requires macOS ${app.minMacOS} (${app.minMacOSName}) or later, on ${app.arch}. The Intel build has run under Rosetta; real Intel Macs are untested.`,
  `- Price: free. License: ${app.licenseName} (${app.license}). No account, subscription, ads or telemetry.`,
].join('\n');

const keyLinks = [
  `- [Home page](${SITE}/): features, formats, comparison, what's new, FAQ`,
  `- [Press kit](${SITE}/press.html): fact sheet, logos, key art, screenshots, trailer, press contact`,
  `- [Privacy](${SITE}/privacy.html): Vespertine collects nothing; what the app and website connect to`,
  `- [Terms](${SITE}/terms.html): GPL-3.0-or-later, no warranty, trademarks`,
  `- [Source code on GitHub](${links.repo})`,
  `- [Release notes](${links.releases})`,
  `- [All features, in detail](${links.features})`,
  `- [How to verify bit-perfect playback](${links.verification})`,
  `- [Comparison sources and scope](${links.comparison})`,
  `- [How the hi-res analysis works](${links.analysis})`,
  `- [Loopback test](${links.loopback})`,
  `- [DVD-Video LPCM](${links.dvd})`,
  `- [Architecture](${links.architecture})`,
  `- [Sponsor on GitHub](${links.sponsors})`,
  `- [Report a DAC or receiver](${links.dacReport})`,
].join('\n');

export function llmsTxt() {
  return `# Vespertine

> ${app.tagline} Current version: ${latest.version} (${longDate(latest.date)}). Free and open source (GPL-3.0-or-later), for macOS ${app.minMacOS} or later on ${app.arch}.

${plain(hero.lede).replace(app.tagline, '').trim()} ${hero.fine}

Vespertine plays music you own (local drives and SMB, NFS or WebDAV shares). It does not stream from Qobuz, TIDAL or Apple Music, and it cannot play DRM-protected files. It was called ${app.formerName} until version 0.6.0. Developer: ${app.author.name} (${app.author.url}).

## Install

${install}

## What it does

${scenes.map((s) => `- **${s.kicker}:** ${plain(s.lede)}`).join('\n')}

## Links

${keyLinks}

## Optional

- [llms-full.txt](${SITE}/llms-full.txt): everything on the site in one file, with the full feature guide, formats, comparison, FAQ and recent release notes
`;
}

const table = (head: string[], rows: string[][]) =>
  [`| ${head.join(' | ')} |`, `|${head.map(() => '---').join('|')}|`, ...rows.map((r) => `| ${r.join(' | ')} |`)].join('\n');

export function llmsFullTxt() {
  // The repository's own feature guide, with its relative links made absolute.
  const features = readFileSync(join(process.cwd(), '../docs/FEATURES.md'), 'utf8')
    .replace(/^# .*\n/, '')
    .replace(/\]\((?!https?:|#)([^)]+)\)/g, (_, p: string) => `](${p.startsWith('screenshots/') ? `${links.raw}/docs/${p}` : `${links.repo}/blob/main/docs/${p}`.replace('/docs/../', '/')})`)
    .replace(/<p align="center"><img src="screenshots\/([^"]+)"[^>]*alt="([^"]*)"[^>]*><\/p>/g, (_, f, alt) => `![${alt}](${links.raw}/docs/screenshots/${f})`)
    .trim();

  return `${llmsTxt()}
---

# Vespertine, in full

${description}

## Why Vespertine

${pillars.map((p) => `- **${p.title}.** ${p.text}`).join('\n')}

## Features

${scenes
  .map((s) => [
    `### ${s.kicker}: ${s.title}`,
    plain(s.lede),
    ...s.body.map(markdownish),
    ...(s.list ?? []).map((li) => `- ${markdownish(li)}`),
    ...(s.note ? [s.note] : []),
    ...(s.links ?? []).map((l) => `- [${l.text}](${l.href})`),
  ].join('\n\n'))
  .join('\n\n')}

## Formats

${table(['Format', 'How it plays', 'Files'], formats.map((f) => [f.name, f.text, f.ext]))}

## Compared with other Mac players

${compare.intro}

${table(['Feature', ...compare.players], compare.rows)}

${compare.notes.map(markdownish).join('\n\n')}

[Comparison sources and scope](${links.comparison}).

## FAQ

${faq.map((f) => `### ${f.q}\n\n${markdownish(f.a)}`).join('\n\n')}

## Latest release: ${latest.name} (${longDate(latest.date)})

${latest.body}

## Earlier releases

${releases.slice(1).map((r) => `- [${r.version}](${r.url}), ${longDate(r.date)}: ${releaseSummary(r)}`).join('\n')}

All releases: ${links.releases}

## Privacy, in short

Vespertine has no accounts, analytics, telemetry, crash reporting or advertising, and the developer receives no information about you or your music. It goes online only to check GitHub for updates (about once a day, can be turned off), and, when you ask it to, to look up MusicBrainz and the Cover Art Archive or scrobble to ListenBrainz; it also connects to the network shares you add. The full policy: ${SITE}/privacy.html

## Tested hardware

${app.tested.map((t) => `- ${t}`).join('\n')}

Channel-for-channel output to multichannel DACs and Dolby/DTS bitstream to receivers are experimental and untested on real hardware; device reports are welcome: ${links.dacReport}

## The feature guide (docs/FEATURES.md)

${features}

## Trademarks

Dolby, Dolby Atmos, Dolby Digital, Dolby Digital Plus and Dolby TrueHD are trademarks of Dolby Laboratories. DTS, DTS-HD Master Audio and DTS:X are trademarks of DTS, Inc. Apple, AirPods, AirPods Max, Mac, macOS and Spatial Audio are trademarks of Apple Inc. Vespertine names them only to describe what it plays and where; it isn't certified, licensed or endorsed by Dolby, DTS or Apple.
`;
}
