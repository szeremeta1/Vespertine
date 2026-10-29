// A static server for dist/ that answers like GitHub Pages: /de/ → de/index.html, /press → press.html, anything
// missing → 404.html with status 404. For scripts/test-i18n.mjs and local checks.
//   node scripts/serve-dist.mjs [port]
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { join, extname, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const DIST = fileURLToPath(new URL('../dist/', import.meta.url));
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.xml': 'application/xml', '.txt': 'text/plain; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.webp': 'image/webp', '.avif': 'image/avif', '.woff2': 'font/woff2', '.mp4': 'video/mp4', '.ico': 'image/x-icon', '.webmanifest': 'application/manifest+json' };

const isFile = async (p) => { try { return (await stat(p)).isFile(); } catch { return false; } };

export function serve(port = 4399) {
  const server = createServer(async (req, res) => {
    const path = normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname)).replace(/^(\.\.[/\\])+/, '');
    let file = join(DIST, path);
    for (const c of [file, join(file, 'index.html'), `${file}.html`]) if (await isFile(c)) { file = c; break; }
    let status = 200;
    if (!(await isFile(file))) { file = join(DIST, '404.html'); status = 404; }
    res.writeHead(status, { 'Content-Type': TYPES[extname(file)] ?? 'application/octet-stream' });
    res.end(await readFile(file));
  });
  return new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve(server)));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const port = Number(process.argv[2] ?? 4399);
  await serve(port);
  console.log(`dist/ on http://127.0.0.1:${port}/`);
}
