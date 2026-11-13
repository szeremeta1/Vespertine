//
// Vespertine: drives the web remote in a headless browser against the pretend Mac and checks what it sends and shows:
// pairing, the transport, sliders that don't flood the Mac, the queue's reordering, the library, playlists and search.
// SPDX-License-Identifier: GPL-3.0-or-later
//
//   node tests/web-remote/check.mjs [--engine chromium|webkit]
//
import { MockMac } from "./mock-mac.mjs";
import { playwright, phones } from "./browser.mjs";

const args = process.argv.slice(2);
const engines = args.includes("--engine") ? [args[args.indexOf("--engine") + 1]] : ["chromium", "webkit"];
let failed = 0, passed = 0;

function expect(condition, what) {
  if (condition) { passed += 1; return; }
  failed += 1;
  console.log(`    ✘ ${what}`);
}
const sent = (mac, name) => mac.log.map(e => e.command).filter(c => name in c).map(c => c[name]);
const settle = page => page.waitForTimeout(350);

async function check(engine, name, options, run) {
  const mac = new MockMac();
  mac.paired = options.paired !== false;
  const server = await mac.listen(0, options.lang || "en");
  const context = await engine.newContext({ ...phones.iphone, isMobile: undefined, colorScheme: options.scheme || "dark", reducedMotion: options.calm ? "reduce" : "no-preference" });
  const page = await context.newPage();
  const problems = [];
  page.on("console", message => { if (message.type() === "error" && !/status of 40[13]/.test(message.text())) problems.push(message.text()); });
  page.on("pageerror", error => problems.push(String(error)));
  const before = failed;
  try {
    await page.goto(`http://127.0.0.1:${server.address().port}/${options.hash || ""}`);
    await page.waitForTimeout(500);
    await run(page, mac);
  } catch (error) {
    expect(false, `threw: ${String(error).split("\n")[0]}`);
  }
  expect(problems.length === 0, `no script or policy errors (${problems.join(" | ")})`);
  console.log(`  ${failed === before ? "✔" : "✘"} ${name}`);
  await context.close();
  server.closeAllConnections();
  server.close();
}

async function drag(page, selector, from, to, steps = 20, pause = 12) {
  const box = await page.locator(selector).boundingBox();
  const y = box.y + box.height / 2;
  await page.mouse.move(box.x + box.width * from, y);
  await page.mouse.down();
  for (let i = 1; i <= steps; i++) {
    await page.mouse.move(box.x + box.width * (from + (to - from) * i / steps), y);
    await page.waitForTimeout(pause);
  }
  return { release: () => page.mouse.up() };
}

for (const engineName of engines) {
  console.log(engineName);
  const engine = await playwright()[engineName].launch();

  await check(engine, "pairs with the code and remembers the browser", { paired: false }, async (page, mac) => {
    expect(await page.locator("#pairing").isVisible(), "an unpaired browser sees the pairing screen");
    expect(!(await page.locator("#app").isVisible()), "and nothing of the remote");
    await page.locator("#code").pressSequentially("111111");
    await page.waitForTimeout(400);
    expect((await page.locator("#pairError").textContent()).length > 10, "a wrong code is refused in the Mac's words");
    await page.locator("#code").pressSequentially("123456");
    await page.waitForSelector("#view-now:not([hidden])");
    expect(/Safari|Chrome/.test(mac.pairedName || ""), `the browser names itself (${mac.pairedName})`);
    const cookies = await page.context().cookies();
    const cookie = cookies.find(c => c.name === "vespertine-remote");
    expect(cookie && cookie.httpOnly && cookie.sameSite === "Strict", "the pairing cookie is HttpOnly and SameSite=Strict");
    expect((await page.locator("#title").textContent()) === "Nocturne in Grey", "Now Playing shows the song");
  });

  await check(engine, "Now Playing: transport, modes, favorite, signal path", {}, async (page, mac) => {
    expect((await page.locator("#signal .chip.perfect").textContent()) === "BIT-PERFECT", "the bit-perfect badge");
    expect((await page.locator("#signal .chip").first().textContent()) === "FLAC · 24/96", "the format chip");
    await page.locator("#playpause").click();
    expect((await page.locator("#playpause").getAttribute("aria-label")) === "Play", "pause shows at once");
    await settle(page);
    expect(sent(mac, "playPause").length === 1 && mac.playback === "paused", "one playPause sent");
    await page.locator("#next").click(); await settle(page);
    expect((await page.locator("#title").textContent()) === "Glasswork I", "Next plays the Playing Next song");
    await page.locator("#shuffle").click(); await page.locator("#repeat").click(); await page.locator("#repeat").click(); await settle(page);
    expect(mac.shuffle === true && mac.repeatMode === "one", "shuffle on, repeat one");
    expect((await page.locator("#repeat").getAttribute("aria-label")).endsWith("One"), "repeat says its mode");
    await page.locator("#heart").click(); await settle(page);
    expect(sent(mac, "setFavorite").length === 1 && (await page.locator("#heart").getAttribute("aria-pressed")) === "true", "favorite toggles");
    await page.locator("#outputButton").click();
    await page.locator(".sheet-item").nth(2).click(); await settle(page);
    expect(mac.output.uid === "hdmi" && (await page.locator("#fixed").isVisible()) && !(await page.locator("#volumeRow").isVisible()), "a fixed-volume output hides the slider and says why");
    expect((await page.locator("#signal .chip.converted").count()) === 1, "a converted signal gets the ring badge");
  });

  await check(engine, "sliders move at once and pace what they send", {}, async (page, mac) => {
    const startLevel = mac.level;
    const began = Date.now();
    const hold = await drag(page, "#volume", 0.55, 0.9, 40, 10);
    const during = Number(await page.locator("#volume").getAttribute("aria-valuenow"));
    expect(during >= 88 && during <= 92, `the thumb follows the finger (${during})`);
    await hold.release();
    const most = Math.ceil((Date.now() - began) / 100) + 2;
    await page.waitForTimeout(500);
    const volumes = sent(mac, "setVolume"), times = mac.log.filter(e => "setVolume" in e.command).map(e => e.at);
    const gaps = times.slice(1).map((t, i) => t - times[i]);
    expect(volumes.length >= 2 && volumes.length <= most && volumes.length < 40, `40 moves became ${volumes.length} writes (at most ${most} for the time it took)`);
    expect(gaps.every(g => g >= 80), `writes are spaced (${gaps.join(", ")} ms)`);
    expect(Math.abs(volumes.at(-1).level - 0.9) < 0.02 && Math.abs(mac.level - 0.9) < 0.02 && mac.level !== startLevel, "the last value is the one that lands");
    // The Mac's own echoes arrive late and out of step: the thumb must not jump back to them.
    mac.level = 0.3; mac.push();
    await page.waitForTimeout(150);
    expect(Number(await page.locator("#volume").getAttribute("aria-valuenow")) >= 88, "a stale echo doesn't tug the thumb back");
    await page.waitForTimeout(1700);
    mac.push(); await page.waitForTimeout(150);
    expect(Number(await page.locator("#volume").getAttribute("aria-valuenow")) === 30, "once the finger is long gone, the Mac's level shows");

    const scrub = await drag(page, "#position", 0.2, 0.6, 15, 10);
    expect(sent(mac, "seek").length === 0, "scrubbing sends nothing until it's let go");
    expect(await page.locator("#position .bubble").isVisible(), "the time under the finger shows");
    await scrub.release(); await settle(page);
    const seeks = sent(mac, "seek"), duration = mac.current.track.duration;
    expect(seeks.length === 1 && Math.abs(seeks[0].seconds - duration * 0.6) < 4, `one seek, where it was dropped (${JSON.stringify(seeks)})`);
    const shown = Number(await page.locator("#position").getAttribute("aria-valuenow"));
    expect(Math.abs(shown - duration * 0.6) < 5, "the scrubber stays where it was dropped");
    await page.locator("#position").focus(); await page.keyboard.press("ArrowRight"); await settle(page);
    expect(sent(mac, "seek").length === 2, "the scrubber works from the keyboard");
  });

  await check(engine, "queue: jump, reorder, play next, remove, clear", { hash: "#/queue" }, async (page, mac) => {
    await page.waitForSelector(".row.upcoming");
    const order = () => page.locator(".row.upcoming").evaluateAll(rows => rows.map(r => r.dataset.entry));
    const start = await order();
    expect(start.length === 6 && (await page.locator(".section").count()) === 2, "Playing Next and Continue Playing are listed");
    // Drag the last song up over two rows.
    const grip = await page.locator(".row.upcoming .grip").nth(5).boundingBox();
    const row = await page.locator(".row.upcoming").nth(5).boundingBox();
    await page.mouse.move(grip.x + grip.width / 2, grip.y + grip.height / 2);
    await page.mouse.down();
    for (let i = 1; i <= 10; i++) { await page.mouse.move(grip.x + grip.width / 2, grip.y + grip.height / 2 - row.height * 2.4 * i / 10); await page.waitForTimeout(15); }
    await page.mouse.up(); await settle(page);
    const moves = sent(mac, "moveInQueue");
    expect(moves.length === 1 && moves[0].entries[0] === start[5] && moves[0].before === start[3], `one moveInQueue before the right song (${JSON.stringify(moves)})`);
    expect((await order()).join() === [start[0], start[1], start[2], start[5], start[3], start[4]].join(), "the list shows the new order");
    // The dots: play next, then remove.
    await page.locator(".row.upcoming .icon-btn").nth(4).click();
    await page.locator(".sheet-item").first().click(); await settle(page);
    expect((await order())[0] === start[3] && mac.playingNext[0].entry === start[3], "Play Next moves a queued song to the front");
    await page.locator(".row.upcoming .icon-btn").nth(1).click();
    await page.locator(".sheet-item.danger").click(); await settle(page);
    expect(sent(mac, "removeFromQueue").length === 1 && (await order()).length === 5, "Remove from Up Next");
    await page.locator(".row.upcoming .row-main").nth(2).click(); await settle(page);
    expect(sent(mac, "jump").length === 1, "tapping a song jumps to it");
    await page.locator("#clearQueue").click(); await settle(page);
    expect((await order()).length === 0 && mac.continuing.length === 0, "Clear Upcoming");
  });

  await check(engine, "library: albums, an album, artists, songs, favorites", { hash: "#/library" }, async (page, mac) => {
    await page.waitForSelector(".grid .card");
    expect((await page.locator(".grid .card").count()) === 10, "every album is in the grid");
    expect(await page.locator("#mini").isVisible(), "the mini player sits under the library");
    await page.locator(".grid .card").nth(2).click();
    await page.waitForSelector(".hero h2");
    expect((await page.locator(".hero h2").textContent()) === "Glasswork" && (await page.locator(".hero .meta").textContent()).includes("5 songs"), "an album opens with its songs counted");
    await page.locator(".list .row-main").nth(3).click(); await settle(page);
    expect(JSON.stringify(sent(mac, "playAlbum")[0]) === JSON.stringify({ key: "demo-album-3", startAt: 3, shuffled: false }), "a song plays the album from there");
    expect((await page.locator(".list .row.current").count()) === 1, "the song playing is marked in the list");
    await page.locator(".list .row .icon-btn").first().click();
    await page.locator(".sheet-item").nth(1).click(); await settle(page);
    expect(sent(mac, "addToQueue").length === 1 && mac.playingNext.length === 1, "Add to Queue from a song's menu");
    await page.locator(".actions .btn.quiet").click(); await settle(page);
    expect(sent(mac, "playAlbum").at(-1).shuffled === true, "Shuffle");
    await page.locator(".hero .by").click();
    await page.waitForSelector(".hero-art.round");
    expect((await page.locator("#detailBody .grid .card").count()) === 2, "the artist's albums");
    await page.goBack(); await page.waitForSelector(".hero .by");
    await page.locator("#detailBack").click(); await page.waitForSelector("#view-library:not([hidden])");
    expect((await page.locator("#view-library .grid .card").count()) === 10, "Back returns to the grid as it was");
    await page.locator("[data-seg=songs]").click(); await page.waitForSelector("#libraryBody .list .row");
    expect((await page.locator("#libraryBody .list .row").count()) === 57, "every song, by title");
    await page.locator("[data-seg=artists]").click(); await page.waitForSelector("#libraryBody .row.chevron");
    expect((await page.locator("#libraryBody .row.chevron").count()) === 6 && (await page.locator("#libraryBody .row-sub").first().textContent()) === "1 album", "artists with their albums counted, singular and plural");
    await page.locator("[data-seg=favorites]").click(); await page.waitForSelector("#libraryBody .list .row");
    await page.locator("#libraryBody .list .row-main").first().click(); await settle(page);
    expect(sent(mac, "playTracks").length === 1, "a favorite plays with the others after it");
  });

  await check(engine, "playlists: open, play, add songs, make a new one", { hash: "#/library" }, async (page, mac) => {
    await page.locator("[data-seg=playlists]").click();
    await page.waitForSelector(".grid .card >> nth=4");
    expect((await page.locator(".grid .card").count()) === 5, "New Playlist and the four playlists");
    await page.locator(".grid .card").nth(1).click(); await page.waitForSelector(".hero h2");
    expect((await page.locator(".hero h2").textContent()) === "Late Night" && (await page.locator(".list .row").count()) === 14, "a playlist opens with its songs");
    await page.locator(".actions .btn.brass").click(); await settle(page);
    expect(JSON.stringify(sent(mac, "playPlaylist")[0]) === JSON.stringify({ id: 1, shuffled: false }), "Play");
    await page.locator("#detailMore").click(); await page.locator(".sheet-item").nth(1).click(); await settle(page);
    expect(sent(mac, "addToQueue")[0].ids.length === 14, "the whole playlist goes to the queue");
    // A song into another playlist; smart playlists aren't offered.
    await page.locator(".list .row .icon-btn").nth(2).click();
    await page.locator(".sheet-item", { hasText: "Add to Playlist" }).click();
    await page.waitForSelector(".sheet-item .art");
    const offered = await page.locator(".sheet-item .row-title").allTextContents();
    expect(offered.join() === "Late Night,Sunday Morning,For the Drive", `only the playlists that take songs (${offered.join()})`);
    await page.locator(".sheet-item", { hasText: "For the Drive" }).click(); await settle(page);
    expect(sent(mac, "addToPlaylist")[0].id === 4 && mac.playlists[3].ids.length === 1, "addToPlaylist");
    expect(await page.locator("#toast").isVisible(), "and says so");
    await page.locator(".list .row .icon-btn").nth(4).click();
    await page.locator(".sheet-item", { hasText: "Add to Playlist" }).click();
    await page.locator(".sheet-item", { hasText: "New Playlist" }).click();
    expect(await page.locator(".sheet-form .btn.brass").isDisabled(), "a playlist needs a name");
    await page.locator(".sheet-form input").fill("Rainy Day");
    await page.locator(".sheet-form .btn.brass").click(); await settle(page);
    expect(sent(mac, "createPlaylist")[0].name === "Rainy Day" && sent(mac, "createPlaylist")[0].ids.length === 1 && mac.playlists.length === 5, "createPlaylist with the song in it");
    await page.locator("#detailBack").click(); await page.waitForSelector("#view-library:not([hidden])"); await settle(page);
    expect((await page.locator("#view-library .card-title").allTextContents()).includes("Rainy Day"), "the new playlist is in the list");
  });

  await check(engine, "search answers in groups", { hash: "#/search" }, async (page, mac) => {
    await page.locator("#search").pressSequentially("lind", { delay: 30 });
    await page.waitForSelector("#searchBody .section");
    expect(sent(mac, "find").length <= 2, `typing four letters asked ${sent(mac, "find").length} time(s)`);
    expect((await page.locator("#searchBody .section span:first-child").allTextContents()).join() === "Artists,Albums,Songs", "artists, albums and songs each under their heading");
    await page.locator("#searchBody .list .row-main").last().click(); await settle(page);
    expect(sent(mac, "playTracks")[0].ids.length === 10 && sent(mac, "playTracks")[0].startAt === 9, "a found song plays among the others found");
    await page.locator("#search").fill("late"); await page.waitForSelector("#searchBody .row.chevron:has-text('Late Night')");
    await page.locator("#searchBody .row.chevron .row-main").first().click(); await page.waitForSelector(".hero h2");
    expect((await page.locator(".hero h2").textContent()) === "Late Night", "a found playlist opens");
    expect((await page.locator("#tabs [aria-current=page]").getAttribute("data-tab")) === "search", "and Search stays lit");
    await page.locator("#detailBack").click(); await page.waitForSelector("#view-search:not([hidden])");
    await page.locator("#searchClear").click(); await page.locator("#search").fill("zzzz"); await page.waitForSelector("#searchBody .empty p");
    expect((await page.locator("#searchBody .empty p").textContent()) === "Nothing matches.", "nothing found is said plainly");
  });

  await check(engine, "accessible, installable, themed", { scheme: "light", calm: true, hash: "#/library" }, async (page, mac) => {
    await page.waitForSelector(".grid .card");
    for (const hash of ["#/now", "#/queue", "#/search", "#/library"]) {
      await page.evaluate(h => { location.hash = h; }, hash); await settle(page);
      const unnamed = await page.evaluate(() => [...document.querySelectorAll("button, a, [role=slider], input")]
        .filter(n => n.offsetParent !== null && !(n.getAttribute("aria-label") || n.textContent.trim() || n.getAttribute("placeholder")))
        .map(n => n.id || n.className));
      expect(unnamed.length === 0, `every control on ${hash} has a name (${unnamed.join(", ")})`);
    }
    for (const hash of ["#/now", "#/queue", "#/library"]) {
      await page.evaluate(h => { location.hash = h; }, hash); await settle(page);
      const small = await page.evaluate(() => [...document.querySelectorAll("#app button, #app a")]
        .filter(n => n.offsetParent !== null && !n.classList.contains("link")).map(n => ({ n: n.id || n.className, r: n.getBoundingClientRect() }))
        .filter(x => x.r.height < 36 || x.r.width < 36).map(x => `${x.n} ${Math.round(x.r.width)}×${Math.round(x.r.height)}`));
      expect(small.length === 0, `touch targets on ${hash} are finger-sized (${small.join(", ")})`);
    }
    expect(await page.evaluate(() => getComputedStyle(document.body).backgroundColor) === "rgb(244, 239, 230)", "light appearance follows the phone");
    const manifest = await page.evaluate(async () => { const link = document.querySelector("link[rel=manifest]"); const r = await fetch(link.href); return r.ok ? r.json() : null; });
    expect(manifest && manifest.display === "standalone" && manifest.icons.length > 0, "a manifest for the home screen");
    expect(await page.evaluate(() => document.documentElement.lang) === "en" && (await page.title()).length > 0, "the page says its language and has a title");
    await page.evaluate(() => { location.hash = "#/library"; }); await settle(page);
    await page.locator(".grid .card").first().click(); await page.waitForSelector(".list .row .icon-btn");
    await page.locator(".list .row .icon-btn").first().click();
    expect((await page.locator("#sheet").getAttribute("aria-modal")) === "true" && await page.evaluate(() => document.getElementById("sheet").contains(document.activeElement)), "a sheet takes the focus");
    await page.keyboard.press("Escape"); await settle(page);
    expect(!(await page.locator("#sheet").isVisible()), "Escape closes it");
  });

  await check(engine, "right-to-left and plurals in other languages", { lang: "ar", hash: "#/library" }, async (page) => {
    await page.waitForSelector(".grid .card");
    expect(await page.evaluate(() => document.documentElement.dir) === "rtl", "Arabic reads right to left");
    await page.locator("[data-seg=artists]").click(); await page.waitForSelector("#libraryBody .row.chevron");
    const counts = await page.locator("#libraryBody .row-sub").allTextContents();
    expect(new Set(counts).size >= 2 && counts.every(c => !c.includes("%")), `album counts use Arabic's own plural forms (${counts.slice(0, 3).join(" / ")})`);
    await page.evaluate(() => { location.hash = "#/now"; }); await settle(page);
    const prev = await page.locator("#prev").boundingBox(), next = await page.locator("#next").boundingBox();
    expect(prev.x < next.x, "playback controls keep their direction");
  });

  await check(engine, "comes back after losing the Mac, and unpairing returns to the code", {}, async (page, mac) => {
    mac.paired = false;
    await page.locator("#next").click();
    await page.waitForSelector("#pairing:not([hidden])");
    expect(!(await page.locator("#app").isVisible()), "an unpaired browser is sent back to pairing");
  });

  await engine.close();
}

console.log(`\n${passed} checks passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
