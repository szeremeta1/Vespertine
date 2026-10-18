// Small text helpers shared by the pages, llms.txt and the JSON-LD.

const ESC: Record<string, string> = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' };
export const escapeHtml = (s: string) => s.replace(/[&<>"]/g, (c) => ESC[c]);

/** HTML (as written in src/data/content.ts) to plain text, for meta descriptions, JSON-LD and llms.txt. */
export const plain = (html: string) =>
  html
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/\s+/g, ' ')
    .trim();

/** HTML to Markdown-ish text with links kept, for llms.txt. */
export const markdownish = (html: string) =>
  plain(html.replace(/<a [^>]*href="([^"]+)"[^>]*>(.*?)<\/a>/g, (_, href, text) => `[${text}](${href.startsWith('/') ? `https://vespertineapp.com${href}` : href})`));

const inline = (s: string) =>
  escapeHtml(s)
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
    .replace(/\*(.+?)\*/g, '<em>$1</em>')
    .replace(/\[([^\]]+)\]\((https:\/\/[^)\s]+)\)/g, '<a href="$2">$1</a>');

/**
 * The release-notes Markdown GitHub stores (docs/releases/TEMPLATE.md: a bold summary, ### sections, - bullets)
 * to HTML. Only that subset; everything is escaped first. Headings become <h4> under the release's own heading.
 */
export function notesToHtml(md: string, { skip = [] as string[] } = {}) {
  const out: string[] = [];
  let list = false;
  let skipping = false;
  const close = () => { if (list) { out.push('</ul>'); list = false; } };
  for (const raw of md.split('\n')) {
    const line = raw.trimEnd();
    const h = line.match(/^#{2,4}\s+(.*)$/);
    if (h) {
      close();
      skipping = skip.includes(h[1].trim());
      if (!skipping) out.push(`<h4>${inline(h[1])}</h4>`);
      continue;
    }
    if (skipping) continue;
    const li = line.match(/^\s*[-*]\s+(.*)$/);
    if (li) {
      if (!list) { out.push('<ul>'); list = true; }
      out.push(`<li>${inline(li[1])}</li>`);
      continue;
    }
    close();
    if (line.trim()) out.push(`<p>${inline(line.trim())}</p>`);
  }
  close();
  return out.join('\n');
}
