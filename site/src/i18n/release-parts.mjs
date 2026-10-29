// Splits a release's notes (docs/releases/TEMPLATE.md: a bold one-sentence summary, ### sections, - bullets) into the
// parts the site shows and translates. Plain JS so the build scripts and the pages share it.
import { createHash } from 'node:crypto';

/** Hash of the notes as GitHub serves them, ignoring line endings and trailing space. */
export const notesHash = (body) =>
  createHash('sha256').update(body.replace(/\r\n/g, '\n').split('\n').map((l) => l.trimEnd()).join('\n').trim()).digest('hex').slice(0, 12);

/** The summary sentence, and the notes after it without the Install section (the page has its own install line). */
export function releaseParts(body) {
  const text = body.replace(/\r\n/g, '\n').trim();
  const summary = (text.match(/^\*\*(.+?)\*\*/s)?.[1] ?? '').trim();
  const rest = text.replace(/^\*\*.+?\*\*\s*/s, '');
  const notes = rest.replace(/^#{2,4}\s+Install\s*\n[\s\S]*?(?=^#{2,4}\s|(?![\s\S]))/m, '').trim();
  return { hash: notesHash(text), summary, notes };
}
