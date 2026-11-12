//
// Vespertine: the web remote's page (one file: markup, style and script). Its words come from the String Catalog, so
// the page speaks the Mac's language like the rest of Vespertine.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum RemoteWebPage {
    /// The page's words, by key, in this Mac's language.
    static var strings: [String: String] {
        [
            "title": String(localized: "Vespertine Remote", comment: "Web remote: page title."),
            "pairTitle": String(localized: "Pair This Browser", comment: "Web remote: heading of the pairing screen."),
            "pairHelp": String(localized: "On the Mac, open Vespertine › Settings › Remote and choose Pair a Phone. Type the 6-digit code it shows.", comment: "Web remote: how to pair a browser."),
            "pair": String(localized: "Pair", comment: "Web remote: button that pairs the browser with the code typed."),
            "nowPlaying": String(localized: "Now Playing", comment: "Web remote: tab."),
            "library": String(localized: "Library", comment: "Web remote: tab."),
            "queue": String(localized: "Queue", comment: "Web remote: tab."),
            "output": String(localized: "Output", comment: "Web remote: tab (the Mac's audio outputs)."),
            "nothing": String(localized: "Nothing playing", comment: "Web remote: nothing is playing."),
            "albums": String(localized: "Albums", comment: "Web remote: library section."),
            "search": String(localized: "Search songs, artists, albums", comment: "Web remote: search field placeholder."),
            "more": String(localized: "More", comment: "Web remote: loads more albums."),
            "back": String(localized: "Back", comment: "Web remote: back from an album to the list."),
            "play": String(localized: "Play", comment: "Web remote: plays an album."),
            "shuffle": String(localized: "Shuffle", comment: "Web remote: shuffles an album, or the shuffle switch."),
            "repeat": String(localized: "Repeat", comment: "Web remote: the repeat button."),
            "playNext": String(localized: "Play Next", comment: "Web remote: puts a song next in the queue."),
            "addToQueue": String(localized: "Add to Queue", comment: "Web remote: adds a song at the end of the queue."),
            "remove": String(localized: "Remove", comment: "Web remote: removes a song from the queue."),
            "clear": String(localized: "Clear Upcoming", comment: "Web remote: clears the songs after the one playing."),
            "playingNext": String(localized: "Playing Next", comment: "Web remote: queue section."),
            // The same headings as the Mac's Up Next panel: "Up Next" alone, "Continue Playing" under "Playing Next".
            "upNext": String(localized: "Up Next"),
            "continuePlaying": String(localized: "Continue Playing"),
            "empty": String(localized: "The queue is empty.", comment: "Web remote: the queue has nothing in it."),
            "fixedVolume": String(localized: "Fixed volume: set the level on your amplifier or DAC", comment: "Web remote: the output's volume can't be changed from Vespertine."),
            "volume": String(localized: "Volume", comment: "Web remote: the volume slider."),
            "offline": String(localized: "Can’t reach the Mac. Trying again…", comment: "Web remote: the page lost the Mac."),
            "waiting": String(localized: "Waiting for \(placeholder) to connect", comment: "Web remote: playback waits for the chosen output; %@ is its name."),
        ]
    }

    /// Left in the words for the page to fill in (with the output's name).
    private static let placeholder = "%@"

    static func html(serverName: String) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: strings.merging(["mac": serverName]) { a, _ in a }, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        // Inside <script>, "<" must not end the element early.
        let safe = json.replacingOccurrences(of: "<", with: "\\u003c")
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let rtl = Locale.Language(identifier: language).characterDirection == .rightToLeft
        return template
            .replacingOccurrences(of: "__STRINGS__", with: safe)
            .replacingOccurrences(of: "__LANG__", with: language)
            .replacingOccurrences(of: "__DIR__", with: rtl ? "rtl" : "ltr")
    }

    private static let template = #"""
<!doctype html>
<html lang="__LANG__" dir="__DIR__">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="dark">
<title>Vespertine</title>
<style>
:root { --bg:#141417; --panel:#1e1e23; --line:#2c2c33; --text:#ecebe8; --dim:#9a988f; --accent:#c8a66a; }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--text); font:16px/1.4 -apple-system, system-ui, sans-serif; padding-bottom:72px; }
button { font:inherit; color:inherit; background:none; border:0; cursor:pointer; padding:0; }
input { font:inherit; color:var(--text); background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:10px 12px; width:100%; }
.wrap { max-width:720px; margin:0 auto; padding:16px; }
.hidden { display:none !important; }
nav { position:fixed; bottom:0; left:0; right:0; display:flex; background:var(--panel); border-top:1px solid var(--line); padding-bottom:env(safe-area-inset-bottom); }
nav button { flex:1; padding:14px 4px; color:var(--dim); font-size:13px; }
nav button.on { color:var(--accent); }
.banner { background:#3a2f1c; color:var(--accent); padding:8px 16px; text-align:center; font-size:14px; }
.cover { width:100%; max-width:420px; aspect-ratio:1; border-radius:12px; background:var(--panel); display:block; margin:8px auto 16px; object-fit:cover; }
h1 { font-size:22px; margin:0 0 4px; } .dim { color:var(--dim); } .small { font-size:13px; }
.row { display:flex; align-items:center; gap:12px; }
.transport { justify-content:center; gap:36px; margin:16px 0; font-size:30px; }
.transport .big { font-size:48px; }
.modes { justify-content:center; gap:24px; color:var(--dim); }
.modes .on { color:var(--accent); }
input[type=range] { width:100%; padding:0; border:0; background:none; accent-color:var(--accent); }
.times { display:flex; justify-content:space-between; font-size:12px; color:var(--dim); font-variant-numeric:tabular-nums; }
.list > * { display:flex; align-items:center; gap:12px; padding:10px 0; border-bottom:1px solid var(--line); width:100%; text-align:start; }
.list img, .thumb { width:44px; height:44px; border-radius:4px; object-fit:cover; background:var(--panel); flex:none; }
.grow { flex:1; min-width:0; } .ell { white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.grid { display:grid; grid-template-columns:repeat(auto-fill, minmax(140px, 1fr)); gap:16px; }
.grid button { text-align:start; } .grid img { width:100%; aspect-ratio:1; border-radius:6px; object-fit:cover; background:var(--panel); }
.pill { border:1px solid var(--line); border-radius:999px; padding:8px 16px; }
.check { color:var(--accent); }
h2 { font-size:13px; text-transform:uppercase; letter-spacing:.06em; color:var(--dim); margin:20px 0 4px; }
.code { font:600 32px ui-monospace, monospace; text-align:center; letter-spacing:.2em; }
.toast { position:fixed; left:16px; right:16px; bottom:84px; background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:12px; text-align:center; }
</style>
</head>
<body>
<div id="banner" class="banner hidden"></div>
<div id="pairing" class="wrap hidden">
  <h1 data-t="pairTitle"></h1>
  <p class="dim" data-t="pairHelp"></p>
  <input id="code" class="code" inputmode="numeric" autocomplete="one-time-code" maxlength="7" placeholder="123 456">
  <p><button id="pairButton" class="pill" data-t="pair"></button></p>
  <p id="pairError" class="dim"></p>
</div>
<main id="app" class="hidden">
  <section id="tab-now" class="wrap">
    <img id="cover" class="cover" alt="">
    <h1 id="title"></h1>
    <div id="subtitle" class="dim ell"></div>
    <div id="format" class="dim small"></div>
    <input id="position" type="range" min="0" max="1" step="0.1" value="0" aria-label="">
    <div class="times"><span id="elapsed">0:00</span><span id="remaining">0:00</span></div>
    <div class="row transport">
      <button id="prev" aria-label="Previous">⏮</button>
      <button id="playpause" class="big" aria-label="Play">▶</button>
      <button id="next" aria-label="Next">⏭</button>
    </div>
    <div class="row modes">
      <button id="shuffle" data-t="shuffle"></button>
      <button id="repeat" data-t="repeat"></button>
    </div>
    <div id="volumeRow" class="row" style="margin-top:16px">
      <button id="mute">🔈</button>
      <input id="volume" type="range" min="0" max="1" step="0.01">
      <button id="volDown" class="pill">−</button><button id="volUp" class="pill">+</button>
    </div>
    <p id="fixed" class="dim small hidden" data-t="fixedVolume"></p>
    <p id="waiting" class="dim small"></p>
    <p id="outputName" class="dim small"></p>
  </section>
  <section id="tab-library" class="wrap hidden">
    <input id="search" type="search">
    <div id="albumView" class="hidden">
      <p><button id="backButton" class="pill" data-t="back"></button></p>
      <h1 id="albumTitle"></h1><div id="albumArtist" class="dim"></div>
      <p class="row"><button id="albumPlay" class="pill" data-t="play"></button><button id="albumShuffle" class="pill" data-t="shuffle"></button></p>
      <div id="albumTracks" class="list"></div>
    </div>
    <div id="searchResults" class="list hidden"></div>
    <div id="albumGrid">
      <h2 data-t="albums"></h2>
      <div id="albums" class="grid"></div>
      <p><button id="moreAlbums" class="pill" data-t="more"></button></p>
    </div>
  </section>
  <section id="tab-queue" class="wrap hidden">
    <p><button id="clearQueue" class="pill" data-t="clear"></button></p>
    <div id="queue"></div>
  </section>
  <section id="tab-output" class="wrap hidden">
    <div id="outputs" class="list"></div>
  </section>
  <nav>
    <button data-tab="now" class="on" data-t="nowPlaying"></button>
    <button data-tab="library" data-t="library"></button>
    <button data-tab="queue" data-t="queue"></button>
    <button data-tab="output" data-t="output"></button>
  </nav>
</main>
<div id="toast" class="toast hidden"></div>
<script>
const L = __STRINGS__;
const $ = id => document.getElementById(id);
document.title = L.title + " · " + L.mac;
document.querySelectorAll("[data-t]").forEach(e => { e.textContent = L[e.dataset.t] || ""; });
$("search").placeholder = L.search; $("position").setAttribute("aria-label", L.nowPlaying); $("volume").setAttribute("aria-label", L.volume);
let player = null, queue = null, outputs = null, albums = [], albumTotal = null, openAlbum = null, scrubbing = false;

function el(tag, attrs, ...kids) { const e = document.createElement(tag); Object.assign(e, attrs || {}); kids.forEach(k => e.append(k)); return e; }
function art(key, size) { return key ? "/artwork?key=" + encodeURIComponent(key) + "&size=" + size : ""; }
function time(s) { s = Math.max(0, Math.floor(s || 0)); const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = String(s % 60).padStart(2, "0"); return h ? h + ":" + String(m).padStart(2, "0") + ":" + x : m + ":" + x; }
function toast(text) { if (!text) return; const t = $("toast"); t.textContent = text; t.classList.remove("hidden"); clearTimeout(toast.timer); toast.timer = setTimeout(() => t.classList.add("hidden"), 4000); }

async function send(command) {
  try {
    const r = await fetch("/command", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(command) });
    if (r.status === 401) return start();
    const reply = await r.json();
    if (reply.failed) toast(reply.failed.reason);
    return reply;
  } catch (e) { toast(L.offline); }
}

function position() {
  if (!player) return 0;
  let p = player.position;
  if (player.playback === "playing" && !player.loading) p += Date.now() / 1000 - player.positionAt;
  return player.duration > 0 ? Math.min(p, player.duration) : p;
}

function renderPlayer() {
  const p = player, t = p && p.nowPlaying && p.nowPlaying.track;
  $("title").textContent = t ? t.title : L.nothing;
  $("subtitle").textContent = t ? t.artist + " — " + t.album : "";
  $("format").textContent = t ? t.format + (p.signal ? " · " + p.signal.badge : "") : "";
  const src = t ? art(t.artworkKey, 900) : "";
  if ($("cover").dataset.src !== src) { $("cover").dataset.src = src; if (src) $("cover").src = src; else $("cover").removeAttribute("src"); }
  $("playpause").textContent = p && p.playback === "playing" ? "⏸" : "▶";
  $("shuffle").classList.toggle("on", !!(p && p.shuffle));
  $("repeat").classList.toggle("on", !!(p && p.repeatMode !== "off"));
  $("repeat").textContent = L.repeat + (p && p.repeatMode === "one" ? " 1" : "");
  const v = p && p.volume, fixed = !v || v.route === "fixed";
  $("volumeRow").classList.toggle("hidden", fixed); $("fixed").classList.toggle("hidden", !fixed);
  if (v && !fixed) {
    const hasLevel = v.level !== null && v.level !== undefined;
    $("volume").classList.toggle("hidden", !hasLevel); $("volDown").classList.toggle("hidden", hasLevel); $("volUp").classList.toggle("hidden", hasLevel);
    if (hasLevel && document.activeElement !== $("volume")) $("volume").value = v.level;
    $("mute").textContent = v.muted ? "🔇" : "🔈";
  }
  $("waiting").textContent = p && p.waitingFor ? L.waiting.replace("%@", p.waitingFor) : "";
  $("outputName").textContent = p && p.output ? p.output : "";
  tick();
}

function tick() {
  if (!player || scrubbing) return;
  $("position").max = Math.max(player.duration, 1); $("position").value = position();
  $("elapsed").textContent = time(position()); $("remaining").textContent = "-" + time(player.duration - position());
}
setInterval(tick, 500);

function trackRow(t, onPlay, extra) {
  const row = el("button", { onclick: onPlay }, el("img", { src: art(t.artworkKey, 120), alt: "" }),
    el("div", { className: "grow" }, el("div", { className: "ell", textContent: t.title }), el("div", { className: "dim small ell", textContent: t.artist + " — " + t.album })),
    el("span", { className: "dim small", textContent: time(t.duration) }));
  if (extra) row.append(extra);
  return row;
}

function renderQueue() {
  const box = $("queue"); box.replaceChildren();
  if (!queue) return;
  const section = (title, items) => {
    if (!items.length) return;
    box.append(el("h2", { textContent: title }));
    const list = el("div", { className: "list" });
    items.forEach(i => list.append(trackRow(i.track, () => send({ jump: { entry: i.entry } }),
      el("span", { className: "dim small", textContent: "✕", title: L.remove, onclick: e => { e.stopPropagation(); send({ removeFromQueue: { entries: [i.entry] } }); } }))));
    box.append(list);
  };
  if (queue.current) section(L.nowPlaying, [queue.current]);
  section(L.playingNext, queue.playingNext);
  section(queue.playingNext.length ? L.continuePlaying : L.upNext, queue.continuing);
  if (!queue.current && !queue.playingNext.length && !queue.continuing.length) box.append(el("p", { className: "dim", textContent: L.empty }));
}

function renderOutputs() {
  const box = $("outputs"); box.replaceChildren();
  (outputs ? outputs.outputs : []).forEach(o => box.append(el("button", { onclick: () => send({ selectOutput: o.uid === null || o.uid === undefined ? {} : { uid: o.uid } }) },
    el("div", { className: "grow" }, el("div", { textContent: o.name }), el("div", { className: "dim small", textContent: o.detail })),
    el("span", { className: "check", textContent: o.selected ? "✓" : "" }))));
}

async function loadAlbums() {
  if (albumTotal !== null && albums.length >= albumTotal) return;
  const r = await send({ albums: { offset: albums.length, limit: 120 } });
  if (!r || !r.albums) return;
  albums = albums.concat(r.albums.items); albumTotal = r.albums.total;
  r.albums.items.forEach(a => $("albums").append(el("button", { onclick: () => showAlbum(a) },
    el("img", { src: art(a.artworkKey, 300), alt: "", loading: "lazy" }), el("div", { className: "ell", textContent: a.title }), el("div", { className: "dim small ell", textContent: a.artist }))));
  $("moreAlbums").classList.toggle("hidden", albums.length >= albumTotal);
}

async function showAlbum(a) {
  openAlbum = a; $("albumGrid").classList.add("hidden"); $("albumView").classList.remove("hidden");
  $("albumTitle").textContent = a.title; $("albumArtist").textContent = a.artist; $("albumTracks").replaceChildren();
  const r = await send({ albumTracks: { key: a.key } });
  (r && r.tracks ? r.tracks.items : []).forEach((t, i) => $("albumTracks").append(trackRow(t, () => send({ playAlbum: { key: a.key, startAt: i, shuffled: false } }), queueMenu(t))));
}

function queueMenu(t) {
  if (t.id === null || t.id === undefined) return null;
  return el("span", { className: "row small dim" },
    el("span", { textContent: "⤴", title: L.playNext, onclick: e => { e.stopPropagation(); send({ playNext: { ids: [t.id] } }); } }),
    el("span", { textContent: "＋", title: L.addToQueue, onclick: e => { e.stopPropagation(); send({ addToQueue: { ids: [t.id] } }); } }));
}

let searchTimer;
$("search").oninput = () => {
  clearTimeout(searchTimer);
  const text = $("search").value.trim();
  $("searchResults").classList.toggle("hidden", !text); $("albumGrid").classList.toggle("hidden", !!text || !!openAlbum);
  if (!text) return;
  searchTimer = setTimeout(async () => {
    const r = await send({ search: { text: text, limit: 200 } });
    const items = r && r.tracks ? r.tracks.items : [];
    $("searchResults").replaceChildren(...items.map((t, i) => trackRow(t, () => send({ playTracks: { ids: items.map(x => x.id).filter(x => x !== null && x !== undefined), startAt: i } }), queueMenu(t))));
  }, 300);
};

$("backButton").onclick = () => { openAlbum = null; $("albumView").classList.add("hidden"); $("albumGrid").classList.remove("hidden"); };
$("albumPlay").onclick = () => openAlbum && send({ playAlbum: { key: openAlbum.key, startAt: 0, shuffled: false } });
$("albumShuffle").onclick = () => openAlbum && send({ playAlbum: { key: openAlbum.key, startAt: 0, shuffled: true } });
$("moreAlbums").onclick = loadAlbums;
$("clearQueue").onclick = () => send({ clearUpcoming: {} });
$("prev").onclick = () => send({ previous: {} });
$("next").onclick = () => send({ next: {} });
$("playpause").onclick = () => send({ playPause: {} });
$("shuffle").onclick = () => send({ setShuffle: { on: !(player && player.shuffle) } });
$("repeat").onclick = () => { const m = player ? player.repeatMode : "off"; send({ setRepeat: { mode: m === "off" ? "all" : m === "all" ? "one" : "off" } }); };
$("mute").onclick = () => send({ volume: { action: "mute" } });
$("volDown").onclick = () => send({ volume: { action: "down" } });
$("volUp").onclick = () => send({ volume: { action: "up" } });
$("volume").onchange = () => send({ setVolume: { level: parseFloat($("volume").value) } });
$("position").oninput = () => { scrubbing = true; $("elapsed").textContent = time($("position").value); };
$("position").onchange = () => { send({ seek: { seconds: parseFloat($("position").value) } }); setTimeout(() => { scrubbing = false; }, 800); };
document.querySelectorAll("nav button").forEach(b => b.onclick = () => {
  document.querySelectorAll("nav button").forEach(x => x.classList.toggle("on", x === b));
  ["now", "library", "queue", "output"].forEach(t => $("tab-" + t).classList.toggle("hidden", t !== b.dataset.tab));
  if (b.dataset.tab === "library" && !albums.length) loadAlbums();
});

$("pairButton").onclick = async () => {
  $("pairError").textContent = "";
  const r = await fetch("/pair", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ code: $("code").value, name: navigator.platform || "" }) });
  if (r.ok) return start();
  try { $("pairError").textContent = (await r.json()).error; } catch (e) {}
};
$("code").onkeydown = e => { if (e.key === "Enter") $("pairButton").click(); };

let events;
async function start() {
  if (events) { events.close(); events = null; }
  let r;
  try { r = await fetch("/session"); } catch (e) { $("banner").textContent = L.offline; $("banner").classList.remove("hidden"); return setTimeout(start, 3000); }
  if (r.status === 401) { $("pairing").classList.remove("hidden"); $("app").classList.add("hidden"); $("code").focus(); return; }
  $("pairing").classList.add("hidden"); $("app").classList.remove("hidden"); $("banner").classList.add("hidden");
  events = new EventSource("/events");
  events.addEventListener("player", e => { player = JSON.parse(e.data); renderPlayer(); });
  events.addEventListener("queue", e => { queue = JSON.parse(e.data); renderQueue(); });
  events.addEventListener("outputs", e => { outputs = JSON.parse(e.data); renderOutputs(); });
  events.onopen = () => $("banner").classList.add("hidden");
  events.onerror = () => { $("banner").textContent = L.offline; $("banner").classList.remove("hidden"); };
}
start();
</script>
</body>
</html>
"""#
}
