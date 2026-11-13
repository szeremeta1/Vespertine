//
// Vespertine: finds Playwright for the web remote's checks. The repository doesn't install it for the app; the website's
// own copy (site/node_modules, after `npm ci` there) or any other is used: PLAYWRIGHT_CORE names its folder.
// SPDX-License-Identifier: GPL-3.0-or-later
//
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));

export function playwright() {
  const places = [process.env.PLAYWRIGHT_CORE, join(here, "../../site/node_modules/playwright-core"), "playwright-core", "playwright"].filter(Boolean);
  const require = createRequire(import.meta.url);
  for (const place of places) {
    try { return require(place); } catch (e) { /* try the next */ }
  }
  throw new Error("Playwright isn't installed. Run `npm ci` in site/ and `npx playwright-core install chromium webkit`, or set PLAYWRIGHT_CORE to a playwright-core folder.");
}

export const phones = {
  iphone: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true },
  small: { viewport: { width: 320, height: 568 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true },
  android: { viewport: { width: 412, height: 915 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true },
  landscape: { viewport: { width: 844, height: 390 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true },
  tablet: { viewport: { width: 1024, height: 768 }, deviceScaleFactor: 1, hasTouch: true },
};
