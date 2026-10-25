// @ts-check
import { defineConfig } from 'astro/config';
import { createHash } from 'node:crypto';
import * as inlineScripts from './src/inline-scripts.mjs';

const sha256 = (text) => `sha256-${createHash('sha256').update(text).digest('base64')}`;

export default defineConfig({
  site: 'https://vespertineapp.com',
  // GitHub Pages serves /press.html at /press too. Keeping the .html files keeps every URL the old site had
  // (and that release notes, the README and search engines link to) working, with no redirects needed.
  build: { format: 'file', inlineStylesheets: 'always' },
  trailingSlash: 'never',
  security: {
    csp: {
      directives: [
        "default-src 'self'",
        "img-src 'self' data:",
        "media-src 'self'",
        "font-src 'self'",
        "connect-src 'self' https://stats.szeremeta.org",
        "object-src 'none'",
        "base-uri 'self'",
        "form-action 'self'",
      ],
      scriptDirective: {
        // stats.szeremeta.org: the self-hosted Umami script (cookieless visitor counts; see privacy.html).
        resources: ["'self'", 'https://stats.szeremeta.org'],
        // Astro hashes its bundled scripts; the is:inline ones are hashed here from their single source.
        hashes: Object.values(inlineScripts).map(sha256),
      },
      styleDirective: {
        // Inline style attributes (CSS custom properties) and the styles GSAP sets.
        resources: ["'self'", "'unsafe-inline'"],
      },
    },
  },
});
