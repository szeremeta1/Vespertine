//
// Vespertine: photographs the web remote at phone sizes, in dark and light, against the pretend Mac.
// SPDX-License-Identifier: GPL-3.0-or-later
//
//   node tests/web-remote/shoot.mjs [folder] [--engine webkit]        (default folder: shots)
//
import { mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { MockMac } from "./mock-mac.mjs";
import { playwright, phones } from "./browser.mjs";

const args = process.argv.slice(2);
const engineName = args.includes("--engine") ? args[args.indexOf("--engine") + 1] : "chromium";
const folder = resolve(args.find((a, i) => !a.startsWith("--") && args[i - 1] !== "--engine") || "shots");
mkdirSync(folder, { recursive: true });

const browser = await playwright()[engineName].launch();
const taken = [];

/** Opens the remote on a pretend Mac of its own, runs `steps`, and saves what the screen shows. */
async function shot(name, { phone = "iphone", scheme = "dark", lang = "en", hash = "#/now", paired = true, setup, steps } = {}) {
  const mac = new MockMac();
  mac.paired = paired;
  if (setup) setup(mac);
  const server = await mac.listen(0, lang);
  const options = { ...phones[phone], colorScheme: scheme, locale: lang };
  if (engineName !== "chromium") delete options.isMobile;
  const context = await browser.newContext(options);
  const page = await context.newPage();
  const problems = [];
  page.on("console", message => { if (message.type() === "error") problems.push(message.text()); });
  page.on("pageerror", error => problems.push(String(error)));
  await page.goto(`http://127.0.0.1:${server.address().port}/${hash}`);
  await page.waitForTimeout(700);
  if (steps) await steps(page, mac);
  await page.waitForTimeout(600);
  const file = join(folder, `${name}.png`);
  await page.screenshot({ path: file });
  taken.push(`${name}.png`);
  if (problems.length) console.log(`  ${name}: ${problems.join(" | ")}`);
  await context.close();
  server.closeAllConnections();
  server.close();
}

const album = async page => { await page.locator(".grid .card").nth(2).click(); await page.waitForSelector(".hero h2"); };
const playlists = async page => { await page.locator("[data-seg=playlists]").click(); await page.waitForSelector(".grid .card >> nth=1"); };
const playlist = async page => { await playlists(page); await page.locator(".grid .card").nth(1).click(); await page.waitForSelector(".hero h2"); };
const search = text => async page => { await page.locator("#search").fill(text); await page.waitForSelector("#searchBody .section"); };

for (const scheme of ["dark", "light"]) {
  await shot(`now-playing-${scheme}`, { scheme });
  await shot(`queue-${scheme}`, { scheme, hash: "#/queue" });
  await shot(`library-albums-${scheme}`, { scheme, hash: "#/library" });
  await shot(`album-${scheme}`, { scheme, hash: "#/library", steps: album });
  await shot(`playlist-${scheme}`, { scheme, hash: "#/library", steps: playlist });
  await shot(`search-${scheme}`, { scheme, hash: "#/search", steps: search("glass") });
}
await shot("pairing-dark", { paired: false });
await shot("pairing-light", { paired: false, scheme: "light" });
await shot("pairing-wrong-code", { paired: false, steps: async page => { await page.locator("#code").pressSequentially("654321"); await page.waitForTimeout(400); } });
await shot("now-playing-paused", { setup: mac => { mac.playback = "paused"; } });
await shot("now-playing-fixed-volume", { setup: mac => { mac.perform({ selectOutput: { uid: "hdmi" } }); mac.perform({ playAlbum: { key: "demo-album-5", startAt: 3 } }); } });
await shot("now-playing-nothing", { setup: mac => { mac.current = null; mac.playingNext = []; mac.continuing = []; mac.playback = "stopped"; } });
await shot("now-playing-android", { phone: "android" });
await shot("now-playing-small-phone", { phone: "small" });
await shot("now-playing-landscape", { phone: "landscape" });
await shot("now-playing-tablet", { phone: "tablet" });
await shot("library-tablet", { phone: "tablet", hash: "#/library" });
await shot("library-artists", { hash: "#/library", steps: async page => { await page.locator("[data-seg=artists]").click(); await page.waitForSelector(".list .row"); } });
await shot("library-songs", { hash: "#/library", steps: async page => { await page.locator("[data-seg=songs]").click(); await page.waitForSelector(".list .row"); } });
await shot("library-playlists", { hash: "#/library", steps: playlists });
await shot("library-favorites", { hash: "#/library", steps: async page => { await page.locator("[data-seg=favorites]").click(); await page.waitForSelector(".list .row"); } });
await shot("artist", { hash: "#/library", steps: async page => { await page.locator("[data-seg=artists]").click(); await page.locator(".list .row-main").nth(1).click(); await page.waitForSelector(".hero h2"); } });
await shot("sheet-song-actions", { hash: "#/library", steps: async page => { await album(page); await page.locator(".list .row .icon-btn").nth(1).click(); } });
await shot("sheet-add-to-playlist", { hash: "#/library", steps: async page => { await album(page); await page.locator("#detailMore").click(); await page.locator(".sheet-item").nth(2).click(); await page.waitForSelector(".sheet-item .art"); } });
await shot("sheet-new-playlist", { hash: "#/library", steps: async page => { await playlists(page); await page.locator(".grid .card").first().click(); await page.locator(".sheet-form input").fill("Rainy Day"); } });
await shot("sheet-outputs", { steps: async page => { await page.locator("#outputButton").click(); } });
await shot("sheet-queue-song", { hash: "#/queue", steps: async page => { await page.locator(".row.upcoming .icon-btn").nth(2).click(); } });
await shot("queue-dragging", { hash: "#/queue", steps: async page => {
  const grip = await page.locator(".row.upcoming .grip").nth(3).boundingBox();
  await page.mouse.move(grip.x + grip.width / 2, grip.y + grip.height / 2);
  await page.mouse.down();
  await page.mouse.move(grip.x + grip.width / 2, grip.y - 95, { steps: 8 });
} });
await shot("scrubbing", { steps: async page => {
  const bar = await page.locator("#position").boundingBox();
  await page.mouse.move(bar.x + bar.width * 0.3, bar.y + bar.height / 2);
  await page.mouse.down();
  await page.mouse.move(bar.x + bar.width * 0.62, bar.y + bar.height / 2, { steps: 6 });
} });
await shot("search-no-results", { hash: "#/search", steps: async page => { await page.locator("#search").fill("zzzz"); await page.waitForSelector("#searchBody .empty p"); } });
await shot("offline-banner", { steps: async (page, mac) => { for (const stream of mac.streams) stream.destroy(); mac.paired = true; await page.route("**/events", route => route.abort()); await page.waitForTimeout(5200); } });
await shot("german-now-playing", { lang: "de" });
await shot("german-album", { lang: "de", hash: "#/library", steps: album });
await shot("arabic-now-playing", { lang: "ar" });
await shot("arabic-queue", { lang: "ar", hash: "#/queue" });
await shot("japanese-library", { lang: "ja", hash: "#/library", steps: playlists });

await browser.close();
console.log(`${taken.length} screenshots in ${folder}`);
