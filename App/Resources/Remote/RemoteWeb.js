//
// Vespertine: the web remote's script. It follows the Mac over Server-Sent Events (/events) and sends the remote
// protocol's commands as JSON (/command), exactly as RemoteProtocol.swift writes them. `L` holds the page's words.
// SPDX-License-Identifier: GPL-3.0-or-later
//
"use strict";

const $ = id => document.getElementById(id);
const root = document.documentElement;
const lang = root.lang || "en";
const rtl = root.dir === "rtl";
const calm = matchMedia("(prefers-reduced-motion: reduce)");

let player = null, queue = null, outputs = null;
let route = { tab: "now" };
let online = true;

// MARK: Small tools

/** An element: `props` are properties, but `attrs` (attributes), `data` (dataset) and `on` (listeners). */
function el(tag, props, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v === undefined || v === null) continue;
    if (k === "attrs") for (const [a, x] of Object.entries(v)) { if (x !== undefined && x !== null && x !== false) e.setAttribute(a, x === true ? "" : x); }
    else if (k === "data") Object.assign(e.dataset, v);
    else if (k === "on") for (const [n, f] of Object.entries(v)) e.addEventListener(n, f);
    else e[k] = v;
  }
  for (const kid of kids.flat()) if (kid !== null && kid !== undefined && kid !== false) e.append(kid);
  return e;
}

function icon(name, className) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("class", "i" + (className ? " " + className : ""));
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS("http://www.w3.org/2000/svg", "use");
  use.setAttribute("href", "#i-" + name);
  svg.append(use);
  return svg;
}

function setIcon(button, name) {
  const use = button.querySelector("use");
  if (use && use.getAttribute("href") !== "#i-" + name) use.setAttribute("href", "#i-" + name);
}

function artURL(key, size) { return key ? "/artwork?key=" + encodeURIComponent(key) + "&size=" + size : ""; }

/** A cover that fades in once it has arrived; a missing one leaves the tile's own surface. */
function cover(key, size, lazy) {
  if (!key) return null;
  const img = el("img", { alt: "", decoding: "async", attrs: { loading: lazy === false ? null : "lazy" } });
  img.addEventListener("load", () => img.classList.add("loaded"));
  img.addEventListener("error", () => img.remove());
  img.src = artURL(key, size);
  return img;
}

function clock(seconds) {
  const s = Math.max(0, Math.floor(seconds || 0)), h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = String(s % 60).padStart(2, "0");
  return h ? h + ":" + String(m).padStart(2, "0") + ":" + x : m + ":" + x;
}

const numberFormat = (() => { try { return new Intl.NumberFormat(lang); } catch (e) { return { format: String }; } })();
const pluralRules = (() => { try { return new Intl.PluralRules(lang); } catch (e) { return { select: n => n === 1 ? "one" : "other" }; } })();

/** "12 songs" in the Mac's language: the form the Mac gave for a number of the same plural kind, with this number in. */
function counted(kind, n) {
  const forms = (L.plurals || {})[kind] || {};
  const kindOf = pluralRules.select(n);
  const sample = Object.keys(forms).find(k => pluralRules.select(Number(k)) === kindOf) || "100";
  const form = forms[sample] || forms["100"];
  if (!form) return numberFormat.format(n);
  return form.replace(/\p{Nd}+/u, numberFormat.format(n));
}

/** "46 min", "1 hr 12 min": how long an album or a playlist is. */
function length(seconds) {
  const minutes = Math.max(1, Math.round((seconds || 0) / 60));
  try {
    const unit = (value, name) => new Intl.NumberFormat(lang, { style: "unit", unit: name, unitDisplay: "short" }).format(value);
    if (minutes < 60) return unit(minutes, "minute");
    return unit(Math.floor(minutes / 60), "hour") + (minutes % 60 ? " " + unit(minutes % 60, "minute") : "");
  } catch (e) { return clock(seconds); }
}

function words(text, value) { return (text || "").replace("%@", value); }

/** A short tap on phones that have one (Android); iPhones give none to web pages. */
function buzz(ms) {
  if (calm.matches || !navigator.vibrate) return;
  try { navigator.vibrate(ms || 8); } catch (e) { /* not allowed here */ }
}

let toastTimer;
function toast(text, bad) {
  if (!text) return;
  const t = $("toast");
  t.replaceChildren(bad ? "" : icon("check"), text);
  t.classList.toggle("bad", !!bad);
  t.hidden = true; void t.offsetWidth; t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, bad ? 4500 : 1800);
}

function setOnline(now) {
  if (online === now) return;
  online = now;
  $("banner").textContent = L.offline;
  $("banner").hidden = now;
}

// MARK: Talking to the Mac

/** Sends one command; answers with the Mac's reply, or null when it couldn't be asked. A refusal is shown as it is. */
async function send(command, quiet) {
  let response;
  try {
    response = await fetch("/command", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(command), credentials: "same-origin" });
  } catch (e) {
    setOnline(false);
    return null;
  }
  if (response.status === 401) { start(); return null; }
  if (!response.ok) return null;
  setOnline(true);
  let reply;
  try { reply = await response.json(); } catch (e) { return null; }
  if (reply.failed) { if (!quiet) toast(reply.failed.reason, true); return null; }
  return reply;
}

/** Sends a command for a tap: a little feedback now, the Mac's own state when it answers. */
function act(command, done) {
  buzz();
  return send(command).then(reply => { if (reply && done) toast(done); return reply; });
}

// What the library said, kept for the visit: going back to a list shouldn't ask or wait again.
const cache = new Map();
async function ask(key, command, pick) {
  if (cache.has(key)) return cache.get(key);
  const reply = await send(command);
  const value = reply ? pick(reply) : null;
  if (value) cache.set(key, value);
  return value;
}
function forget(prefix) { for (const key of [...cache.keys()]) if (key.startsWith(prefix)) cache.delete(key); }

// MARK: Sliders

/**
 * A slider drawn by the page, so it moves with the finger at once: `input(value)` while it moves, `commit(value)` when
 * it's let go (or moved by a key). Values are 0…max.
 */
function slider(node, options) {
  let max = 1, value = 0, dragging = false, empty = false;
  const api = {
    get dragging() { return dragging; },
    get value() { return value; },
    setMax(m) { empty = !(m > 0); max = Math.max(m, 0.0001); if (empty) value = 0; node.setAttribute("aria-valuemax", Math.round(options.scale ? max * options.scale : max)); paint(); },
    set(v) { if (!dragging) { value = empty ? 0 : clamp(v); paint(); } },
  };
  function clamp(v) { return Math.min(Math.max(v, 0), max); }
  function paint() {
    node.style.setProperty("--v", empty ? 0 : (value / max).toFixed(5));
    node.setAttribute("aria-valuenow", Math.round(options.scale ? value * options.scale : value));
    if (options.text) node.setAttribute("aria-valuetext", options.text(value, max));
    if (options.paint) options.paint(value, max, dragging);
  }
  function fromPointer(event) {
    const box = node.getBoundingClientRect();
    // Left to right in every language, as playback controls are.
    return clamp((event.clientX - box.left) / Math.max(box.width, 1) * max);
  }
  node.addEventListener("pointerdown", event => {
    if (event.button > 0 || node.getAttribute("aria-disabled") === "true") return;
    dragging = true;
    node.classList.add("drag");
    try { node.setPointerCapture(event.pointerId); } catch (e) { /* an old browser */ }
    value = fromPointer(event); paint();
    if (options.input) options.input(value);
    event.preventDefault();
  });
  node.addEventListener("pointermove", event => {
    if (!dragging) return;
    value = fromPointer(event); paint();
    if (options.input) options.input(value);
  });
  const end = cancelled => () => {
    if (!dragging) return;
    dragging = false;
    node.classList.remove("drag");
    paint();
    if (cancelled) { if (options.cancel) options.cancel(); } else { buzz(6); options.commit(value); }
  };
  node.addEventListener("pointerup", end(false));
  node.addEventListener("pointercancel", end(true));
  node.addEventListener("keydown", event => {
    const step = options.step ? options.step(max) : max / 20;
    let next = null;
    if (event.key === "ArrowRight" || event.key === "ArrowUp") next = value + step;
    else if (event.key === "ArrowLeft" || event.key === "ArrowDown") next = value - step;
    else if (event.key === "PageUp") next = value + step * 4;
    else if (event.key === "PageDown") next = value - step * 4;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = max;
    if (next === null) return;
    event.preventDefault();
    value = clamp(next); paint();
    if (options.input) options.input(value);
    options.commit(value);
  });
  return api;
}

/** Sends the newest value at most once every `gap` ms, and never two at a time: a drag can't flood or reorder. */
function paced(gap, sendValue) {
  let waiting = null, busy = false, last = 0, timer = null;
  async function flush() {
    timer = null;
    if (busy || waiting === null) return;
    const value = waiting;
    waiting = null; busy = true; last = performance.now();
    try { await sendValue(value); } finally { busy = false; }
    if (waiting !== null) schedule();
  }
  function schedule() {
    if (timer !== null || busy) return;
    timer = setTimeout(flush, Math.max(0, gap - (performance.now() - last)));
  }
  return value => { waiting = value; schedule(); };
}

// MARK: Now Playing

let holdVolumeUntil = 0, localLevel = null, shownCover = null, backdropFront = false;

/** Where the song is now. The Mac's clock isn't this phone's: the page counts on from when the message arrived. */
function positionNow() {
  if (!player) return 0;
  let p = player.position;
  if (player.playback === "playing" && !player.loading) p += (performance.now() - player.receivedAt) / 1000;
  return player.duration > 0 ? Math.min(p, player.duration) : p;
}

const scrubber = slider($("position"), {
  step: max => Math.min(10, Math.max(max / 40, 1)),
  text: (v, max) => clock(v) + " / " + clock(max),
  paint: (v, max, dragging) => {
    $("elapsed").textContent = clock(v);
    $("remaining").textContent = "-" + clock(max - v);
    if (dragging) $("position").querySelector(".bubble").textContent = clock(v);
  },
  commit: seconds => {
    if (!player) return;
    // Shown where it was dropped until the Mac says where it is.
    player.position = seconds; player.receivedAt = performance.now();
    send({ seek: { seconds: Math.round(seconds * 10) / 10 } });
    tick();
  },
});

const sendVolume = paced(110, level => send({ setVolume: { level: Math.round(level * 1000) / 1000 } }, true));
const volume = slider($("volume"), {
  scale: 100,
  step: () => 0.02,
  text: v => Math.round(v * 100) + "%",
  paint: v => { $("volumeValue").textContent = Math.round(v * 100); },
  input: level => { localLevel = level; holdVolumeUntil = performance.now() + 1500; sendVolume(level); },
  commit: level => { localLevel = level; holdVolumeUntil = performance.now() + 1500; sendVolume(level); },
});
volume.setMax(1);

function tick() {
  if (!player) return;
  const now = positionNow(), duration = Math.max(player.duration || 0, 0);
  if (!scrubber.dragging) scrubber.set(now);
  $("miniFill").style.transform = "scaleX(" + (duration > 0 ? Math.min(now / duration, 1) : 0).toFixed(4) + ")";
}
let ticker = null;
function runTicker() {
  const wanted = !document.hidden && player && player.playback === "playing";
  if (wanted && ticker === null) ticker = setInterval(tick, 250);
  if (!wanted && ticker !== null) { clearInterval(ticker); ticker = null; }
}

function renderPlayer() {
  const p = player, track = p && p.nowPlaying ? p.nowPlaying.track : null, playing = !!p && p.playback === "playing";
  $("app").classList.toggle("paused", !playing);

  $("title").textContent = track ? track.title : L.nothing;
  $("subtitle").hidden = !track;
  if (track) {
    $("artistLink").textContent = track.artist;
    $("albumLink").textContent = track.album;
    $("subDash").hidden = !track.album; $("albumLink").hidden = !track.album;
  }
  const hasID = !!track && track.id !== undefined && track.id !== null;
  $("heart").hidden = !hasID;
  if (hasID) {
    $("heart").classList.toggle("on", !!track.favorite);
    setIcon($("heart"), track.favorite ? "heart-fill" : "heart");
    $("heart").setAttribute("aria-label", track.favorite ? L.unfavorite : L.favorite);
    $("heart").setAttribute("aria-pressed", track.favorite ? "true" : "false");
  }

  // The cover, and its colours far out of focus behind everything.
  const key = track && track.artworkKey ? track.artworkKey : "";
  if (key !== shownCover) {
    shownCover = key;
    const image = $("cover");
    image.classList.remove("loaded");
    if (key) image.src = artURL(key, 1000); else image.removeAttribute("src");
    const front = $(backdropFront ? "backdropA" : "backdropB"), back = $(backdropFront ? "backdropB" : "backdropA");
    backdropFront = !backdropFront;
    front.style.backgroundImage = key ? "url(\"" + artURL(key, 160) + "\")" : "none";
    front.classList.toggle("show", !!key); back.classList.remove("show");
    $("miniCover").hidden = !key;
    if (key) $("miniCover").src = artURL(key, 160);
  }

  // Signal path: what the file is, what happens to it, what the DAC receives.
  const chips = [];
  if (track && track.format) chips.push(el("span", { className: "chip", textContent: track.format }));
  if (track && p.signal) {
    chips.push(el("span", { className: "chip " + (p.signal.bitPerfect ? "perfect" : "converted"), textContent: p.signal.badge }));
    if (p.signal.deviceFormat && !(track.format || "").includes(p.signal.deviceFormat)) chips.push(el("span", { className: "chip", textContent: "→ " + p.signal.deviceFormat }));
  }
  $("signal").replaceChildren(...chips);
  $("signal").setAttribute("aria-label", L.signalPath);

  const duration = Math.max(p ? p.duration : 0, 0);
  scrubber.setMax(duration);
  $("position").setAttribute("aria-disabled", duration > 0 ? "false" : "true");

  for (const [button, glyph] of [["playpause", "playIcon"], ["miniPlay", null]]) {
    setIcon($(button), playing ? "pause" : "play");
    $(button).setAttribute("aria-label", playing ? L.pause : L.play);
    if (glyph) $(button).classList.toggle("loading", !!p && p.loading && playing);
  }
  $("shuffle").setAttribute("aria-pressed", p && p.shuffle ? "true" : "false");
  const mode = p ? p.repeatMode : "off";
  setIcon($("repeat"), mode === "one" ? "repeat1" : "repeat");
  $("repeat").setAttribute("aria-pressed", mode !== "off" ? "true" : "false");
  $("repeat").setAttribute("aria-label", L.repeat + ": " + (mode === "one" ? L.one : mode === "all" ? L.all : L.off));

  // Volume: a slider where the Mac can read the level, steps where it can't, a note where there's none to move.
  const v = p ? p.volume : null, fixed = !v || v.route === "fixed";
  $("volumeRow").hidden = fixed; $("fixed").hidden = !fixed || !p;
  if (v && !fixed) {
    const hasLevel = v.level !== null && v.level !== undefined;
    $("volume").hidden = !hasLevel; $("volumeValue").hidden = !hasLevel;
    $("volDown").hidden = hasLevel; $("volUp").hidden = hasLevel;
    // While a finger is on it (and just after), the page's own level stands: the Mac's echoes would tug the thumb back.
    if (hasLevel && !volume.dragging && performance.now() > holdVolumeUntil) { localLevel = null; volume.set(v.level); }
    const level = localLevel !== null ? localLevel : hasLevel ? v.level : 1;
    setIcon($("mute"), v.muted ? "muted" : level < 0.01 ? "quiet" : "speaker");
    $("mute").setAttribute("aria-label", v.muted ? L.unmute : L.mute);
    $("mute").classList.toggle("on", !!v.muted);
  }

  $("outputName").textContent = p && p.output ? p.output : L.output;
  const hasTransitions = !!p && p.transitions !== undefined && p.transitions !== null;
  $("transitions").hidden = !hasTransitions;
  if (hasTransitions) $("transitions").setAttribute("aria-pressed", p.transitions ? "true" : "false");
  $("waiting").hidden = !(p && p.waitingFor);
  if (p && p.waitingFor) $("waiting").textContent = words(L.waiting, p.waitingFor);
  $("playerError").hidden = !(p && p.error);
  if (p && p.error) $("playerError").textContent = p.error;

  $("miniTitle").textContent = track ? track.title : "";
  $("miniArtist").textContent = track ? track.artist : "";
  document.title = track ? track.title + " — " + track.artist : L.title + " · " + L.mac;
  showMini();
  markCurrent();
  tick();
  runTicker();
}

function showMini() {
  const has = !!(player && player.nowPlaying);
  $("mini").hidden = !has || route.tab === "now";
}

/** The song playing, wherever it's listed. */
function markCurrent() {
  const track = player && player.nowPlaying ? player.nowPlaying.track : null;
  const id = track && track.id !== undefined && track.id !== null ? String(track.id) : null;
  for (const row of document.querySelectorAll(".row[data-track]")) row.classList.toggle("current", id !== null && row.dataset.track === id);
}

$("playpause").onclick = $("miniPlay").onclick = () => {
  // Shown at once; the Mac's word follows within a moment.
  if (player) { player.position = positionNow(); player.receivedAt = performance.now(); player.playback = player.playback === "playing" ? "paused" : "playing"; renderPlayer(); }
  act({ playPause: {} });
};
$("prev").onclick = () => act({ previous: {} });
$("next").onclick = $("miniNext").onclick = () => act({ next: {} });
$("shuffle").onclick = () => { const on = !(player && player.shuffle); if (player) { player.shuffle = on; renderPlayer(); } act({ setShuffle: { on: on } }); };
$("repeat").onclick = () => {
  const mode = player ? player.repeatMode : "off", next = mode === "off" ? "all" : mode === "all" ? "one" : "off";
  if (player) { player.repeatMode = next; renderPlayer(); }
  act({ setRepeat: { mode: next } });
};
$("transitions").onclick = () => act({ setTransitions: { on: !(player && player.transitions) } });
$("mute").onclick = () => act({ volume: { action: "mute" } });
$("volDown").onclick = () => act({ volume: { action: "down" } });
$("volUp").onclick = () => act({ volume: { action: "up" } });
$("heart").onclick = () => {
  const track = player && player.nowPlaying ? player.nowPlaying.track : null;
  if (!track || track.id === undefined || track.id === null) return;
  track.favorite = !track.favorite;
  $("heart").classList.remove("pop"); void $("heart").offsetWidth; $("heart").classList.add("pop");
  renderPlayer();
  act({ setFavorite: { ids: [track.id], on: track.favorite } }).then(() => stale("favorites"));
};
$("artistLink").onclick = () => { const t = player && player.nowPlaying && player.nowPlaying.track; if (t) go("artist", t.artist); };
$("albumLink").onclick = () => { const t = player && player.nowPlaying && player.nowPlaying.track; if (t && t.albumKey) go("album", t.albumKey); };
$("miniOpen").onclick = () => go("now");
$("outputButton").onclick = () => outputSheet();
$("cover").addEventListener("load", () => $("cover").classList.add("loaded"));
$("cover").addEventListener("error", () => $("cover").classList.remove("loaded"));

// MARK: Rows, cards and lists

function hasID(track) { return track.id !== undefined && track.id !== null; }
function idsOf(tracks) { return tracks.filter(hasID).map(t => t.id); }

/** A song in a list: tap to play, the dots for everything else. */
function trackRow(track, options) {
  const lead = options.number !== undefined
    ? el("span", { className: "row-num", textContent: options.number === null ? "·" : String(options.number), attrs: { "aria-hidden": "true" } })
    : el("span", { className: "art" }, cover(track.artworkKey, 160));
  const sub = options.sub !== undefined ? options.sub : track.artist + (track.album && !options.hideAlbum ? " — " + track.album : "");
  const main = el("button", { className: "row-main", attrs: { "aria-label": track.title + ", " + track.artist }, on: { click: () => { buzz(); options.play(); } } },
    lead,
    el("span", { className: "row-text" }, el("span", { className: "row-title ell", textContent: track.title }), sub ? el("span", { className: "row-sub ell", textContent: sub }) : null),
    track.favorite ? icon("heart-fill", "fav") : null,
    el("span", { className: "row-time", textContent: clock(track.duration) }));
  return el("div", { className: "row" + (options.number !== undefined ? " numbered" : ""), data: hasID(track) ? { track: String(track.id) } : {} },
    options.before || null, main,
    el("button", { className: "icon-btn", attrs: { "aria-label": L.options + ": " + track.title, "aria-haspopup": "dialog" }, on: { click: () => trackSheet(track, options.queue) } }, icon("more")));
}

function tags(album) {
  const list = [];
  if (album.dsd) list.push("DSD"); else if (album.hiRes) list.push(L.hiRes);
  if (album.multichannel) list.push(L.multichannel);
  return list.length ? el("span", { className: "card-tags" }, list.map(text => el("span", { className: "chip tiny", textContent: text }))) : null;
}

function albumCard(album) {
  return el("button", { className: "card", attrs: { "aria-label": album.title + ", " + album.artist }, on: { click: () => go("album", album.key) } },
    el("span", { className: "card-art" + (album.artworkKey ? "" : " glyph") }, album.artworkKey ? cover(album.artworkKey, 600) : icon("album")),
    el("span", { className: "card-title ell", textContent: album.title }),
    el("span", { className: "card-sub ell", textContent: album.artist + (album.year ? " · " + album.year : "") }),
    tags(album));
}

function mosaic(playlist, className) {
  const keys = (playlist.artworkKeys || []).slice(0, 4);
  if (!keys.length) return el("span", { className: className + " glyph" }, icon("playlist"));
  if (keys.length < 4) return el("span", { className: className }, cover(keys[0], 600));
  return el("span", { className: className + " mosaic" }, keys.map(key => cover(key, 160)));
}

function playlistSub(playlist) {
  const parts = [];
  if (playlist.smart) parts.push(L.smartPlaylist);
  if (playlist.trackCount !== undefined && playlist.trackCount !== null) parts.push(counted("songs", playlist.trackCount));
  return parts.join(" · ");
}

function playlistCard(playlist) {
  return el("button", { className: "card", attrs: { "aria-label": playlist.name }, on: { click: () => go("playlist", String(playlist.id)) } },
    mosaic(playlist, "card-art"),
    el("span", { className: "card-title ell", textContent: playlist.name }),
    el("span", { className: "card-sub ell", textContent: playlistSub(playlist) }));
}

function artistRow(artist) {
  return el("div", { className: "row chevron" },
    el("button", { className: "row-main", on: { click: () => go("artist", artist.name) } },
      el("span", { className: "art round" + (artist.artworkKey ? "" : " glyph") }, artist.artworkKey ? cover(artist.artworkKey, 160) : icon("person")),
      el("span", { className: "row-text" }, el("span", { className: "row-title ell", textContent: artist.name }), el("span", { className: "row-sub ell", textContent: counted("albums", artist.albumCount) })),
      icon("chevron", "go flip")));
}

function playlistRow(playlist) {
  return el("div", { className: "row chevron" },
    el("button", { className: "row-main", on: { click: () => go("playlist", String(playlist.id)) } },
      mosaic(playlist, "art"),
      el("span", { className: "row-text" }, el("span", { className: "row-title ell", textContent: playlist.name }), el("span", { className: "row-sub ell", textContent: playlistSub(playlist) })),
      icon("chevron", "go flip")));
}

function empty(text, glyph) { return el("div", { className: "empty" }, icon(glyph || "mark"), el("p", { textContent: text })); }
function loading() { return el("div", { className: "loading", attrs: { role: "status", "aria-busy": "true" } }); }
function section(text, count) {
  return el("h2", { className: "section" }, el("span", { textContent: text }), count !== undefined ? el("span", { className: "count", textContent: numberFormat.format(count) }) : null);
}

/** Calls `more` when the end of a list scrolls into view, until it answers false. */
function endless(container, more) {
  const sentinel = el("div", { className: "sentinel" });
  container.after(sentinel);
  let busy = false;
  const watcher = new IntersectionObserver(async entries => {
    if (busy || !entries.some(e => e.isIntersecting)) return;
    busy = true;
    const again = await more();
    busy = false;
    if (!again) { watcher.disconnect(); sentinel.remove(); return; }
    // Still on screen (a tall phone, a short page): ask again.
    watcher.unobserve(sentinel); watcher.observe(sentinel);
  }, { root: container.closest(".view"), rootMargin: "600px 0px" });
  watcher.observe(sentinel);
}

/** A long list drawn a part at a time, so a library of thousands opens at once. */
function inParts(container, items, make, size) {
  let shown = 0;
  const add = () => { container.append(...items.slice(shown, shown + size).map(make)); shown += size; return shown < items.length; };
  if (add()) endless(container, async () => add());
}

// MARK: Library

const segments = ["albums", "artists", "songs", "playlists", "favorites"];
let segment = "albums", libraryDrawn = null;

function drawLibrary(force) {
  for (const button of $("segments").children) {
    const on = button.dataset.seg === segment;
    button.setAttribute("aria-selected", on ? "true" : "false");
    button.tabIndex = on ? 0 : -1;
    if (on && button.scrollIntoView) button.scrollIntoView({ block: "nearest", inline: "center" });
  }
  if (libraryDrawn === segment && !force) return;
  libraryDrawn = segment;
  const body = $("libraryBody");
  body.replaceChildren(loading());
  $("view-library").scrollTop = 0;
  ({ albums: drawAlbums, artists: drawArtists, songs: drawSongs, playlists: drawPlaylists, favorites: drawFavorites })[segment](body, segment);
}
function stillOn(name) { return libraryDrawn === name; }

/** What a part of the library showed has changed on the Mac: asked for again, now or when the library is next opened. */
function stale(name) {
  forget(name === "playlists" ? "playlist" : name);
  if (segment !== name) return;
  if (route.tab === "library") drawLibrary(true); else libraryDrawn = null;
}

async function drawAlbums(body, name) {
  const first = await ask("albums:0", { albums: { offset: 0, limit: 120 } }, r => r.albums);
  if (!stillOn(name)) return;
  if (!first) return body.replaceChildren(empty(L.offline));
  if (!first.items.length) return body.replaceChildren(empty(L.emptyLibrary, "album"));
  const grid = el("div", { className: "grid" }, first.items.map(albumCard));
  body.replaceChildren(grid);
  let loaded = first.items.length;
  if (loaded < first.total) endless(grid, async () => {
    const page = await ask("albums:" + loaded, { albums: { offset: loaded, limit: 120 } }, r => r.albums);
    if (!page || !page.items.length || !grid.isConnected) return false;
    grid.append(...page.items.map(albumCard));
    loaded += page.items.length;
    return loaded < page.total;
  });
}

async function drawArtists(body, name) {
  const artists = await ask("artists", { artists: {} }, r => r.artists && r.artists.items);
  if (!stillOn(name)) return;
  if (!artists) return body.replaceChildren(empty(L.offline));
  if (!artists.length) return body.replaceChildren(empty(L.emptyLibrary, "person"));
  const list = el("div", { className: "list" });
  body.replaceChildren(list);
  inParts(list, artists, artistRow, 120);
}

async function drawSongs(body, name) {
  const songs = [];
  const page = async () => {
    const reply = await ask("songs:" + songs.length, { songs: { offset: songs.length, limit: 150 } }, r => r.songs);
    if (reply) songs.push(...reply.items);
    return reply;
  };
  const first = await page();
  if (!stillOn(name)) return;
  if (!first) return body.replaceChildren(empty(L.offline));
  if (!first.items.length) return body.replaceChildren(empty(L.emptyLibrary));
  const list = el("div", { className: "list" });
  // A song plays with the songs around it after it, as far as the list has been read.
  const row = track => { const at = songs.indexOf(track); return trackRow(track, { play: () => playList(songs, at) }); };
  list.append(...first.items.map(row));
  body.replaceChildren(el("div", { className: "actions" }, shuffleButton(() => send({ playTracks: { ids: idsOf(songs).slice(0, 500), startAt: 0, shuffled: true } }))),
    section(L.songs, first.total), list);
  markCurrent();
  if (songs.length < first.total) endless(list, async () => {
    const next = await page();
    if (!next || !next.items.length || !list.isConnected) return false;
    list.append(...next.items.map(row));
    markCurrent();
    return songs.length < next.total;
  });
}

async function drawPlaylists(body, name) {
  const playlists = await ask("playlists", { playlists: {} }, r => r.playlists && r.playlists.items);
  if (!stillOn(name)) return;
  if (!playlists) return body.replaceChildren(empty(L.offline));
  const grid = el("div", { className: "grid" },
    el("button", { className: "card", on: { click: () => newPlaylistSheet([]) } },
      el("span", { className: "card-art glyph" }, icon("plus")), el("span", { className: "card-title ell", textContent: L.newPlaylist })),
    playlists.map(playlistCard));
  body.replaceChildren(grid);
}

async function drawFavorites(body, name) {
  const tracks = await ask("favorites", { favorites: {} }, r => r.tracks && r.tracks.items);
  if (!stillOn(name)) return;
  if (!tracks) return body.replaceChildren(empty(L.offline));
  if (!tracks.length) return body.replaceChildren(empty(L.noFavorites, "heart-fill"));
  const list = el("div", { className: "list" });
  body.replaceChildren(el("div", { className: "actions" }, playButton(() => playList(tracks, 0)), shuffleButton(() => playList(tracks, 0, true))), section(L.favorites, tracks.length), list);
  inParts(list, tracks, (track) => trackRow(track, { play: () => playList(tracks, tracks.indexOf(track)) }), 150);
  markCurrent();
}

function playButton(run) { return el("button", { className: "btn brass", on: { click: () => { buzz(12); run(); } } }, icon("play"), L.play); }
function shuffleButton(run) { return el("button", { className: "btn quiet", on: { click: () => { buzz(12); run(); } } }, icon("shuffle"), L.shuffle); }

/** Plays a list from one of its songs. The Mac takes up to a few thousand IDs in a request: 500 around the song is plenty. */
function playList(tracks, at, shuffled) {
  const withID = tracks.filter(hasID);
  let start = Math.max(0, withID.indexOf(tracks[at]));
  let from = 0;
  if (withID.length > 500) { from = Math.max(0, Math.min(start - 20, withID.length - 500)); start -= from; }
  return send({ playTracks: { ids: withID.slice(from, from + 500).map(t => t.id), startAt: start, shuffled: !!shuffled } });
}

$("segments").addEventListener("click", event => {
  const button = event.target.closest("button[data-seg]");
  if (!button) return;
  buzz();
  segment = button.dataset.seg;
  try { sessionStorage.setItem("segment", segment); } catch (e) { /* private browsing */ }
  drawLibrary();
});
$("segments").addEventListener("keydown", event => {
  const step = event.key === (rtl ? "ArrowLeft" : "ArrowRight") ? 1 : event.key === (rtl ? "ArrowRight" : "ArrowLeft") ? -1 : 0;
  if (!step) return;
  segment = segments[(segments.indexOf(segment) + step + segments.length) % segments.length];
  drawLibrary();
  $("segments").querySelector("[aria-selected=true]").focus();
});

// MARK: An album, an artist, a playlist

let detailToken = 0, detailMenu = null;
const scrolls = new Map();

async function drawDetail() {
  const token = ++detailToken, body = $("detailBody"), view = $("view-detail");
  const key = route.kind + ":" + route.id;
  detailMenu = null;
  $("detailMore").hidden = true;
  $("detailBarTitle").textContent = "";
  body.replaceChildren(loading());
  const drawn = await ({ album: drawAlbum, artist: drawArtist, playlist: drawPlaylist })[route.kind](body, route.id, () => token === detailToken);
  if (token !== detailToken) return;
  if (drawn === false) body.replaceChildren(empty(L.noMatches));
  view.scrollTop = scrolls.get(key) || 0;
  markCurrent();
}

function hero(art, title, by, meta, extra) {
  return el("div", { className: "hero" }, art,
    el("div", null, el("h2", { textContent: title }), by || null, meta ? el("p", { className: "meta", textContent: meta }) : null, extra || null));
}

async function drawAlbum(body, key, current) {
  const tracks = await ask("album:" + key, { albumTracks: { key: key } }, r => r.tracks && r.tracks.items);
  if (!current()) return;
  if (!tracks || !tracks.length) return false;
  // The album's own line, if a list or a search has shown it; otherwise what its songs say.
  let album = null;
  for (const [name, value] of cache) {
    const items = name.startsWith("albums:") || name.startsWith("artist:") ? value.items : name.startsWith("find:") ? value.albums : null;
    album = items ? items.find(a => a.key === key) : null;
    if (album) break;
  }
  const first = tracks[0];
  const title = album ? album.title : first.album, artist = album ? album.artist : first.artist;
  const total = tracks.reduce((sum, t) => sum + (t.duration || 0), 0);
  const artKey = album && album.artworkKey ? album.artworkKey : first.artworkKey;
  const meta = [album && album.year ? String(album.year) : null, counted("songs", tracks.length), length(total)].filter(Boolean).join(" · ");
  const format = album ? album.format : first.format;
  const extra = el("span", { className: "card-tags" }, format ? el("span", { className: "chip tiny", textContent: format }) : null,
    album && album.multichannel ? el("span", { className: "chip tiny", textContent: L.multichannel }) : null);
  $("detailBarTitle").textContent = title;
  const discs = new Set(tracks.map(t => t.discNumber || 1)).size > 1;
  const list = el("div", { className: "list" });
  let disc = null;
  tracks.forEach((track, index) => {
    if (discs && (track.discNumber || 1) !== disc) { disc = track.discNumber || 1; list.append(el("h3", { className: "section" }, el("span", { className: "mono", textContent: "DISC " + disc }))); }
    list.append(trackRow(track, {
      number: track.trackNumber !== undefined ? track.trackNumber : null, sub: track.artist !== artist ? track.artist : "",
      play: () => send({ playAlbum: { key: key, startAt: index, shuffled: false } }),
    }));
  });
  body.replaceChildren(
    hero(el("div", { className: "hero-art" + (artKey ? "" : " glyph") }, artKey ? cover(artKey, 600, false) : icon("album")), title,
      el("button", { className: "link by", textContent: artist, on: { click: () => go("artist", artist) } }), meta, extra),
    el("div", { className: "actions" }, playButton(() => send({ playAlbum: { key: key, startAt: 0, shuffled: false } })), shuffleButton(() => send({ playAlbum: { key: key, startAt: 0, shuffled: true } }))),
    list);
  setMenu(title, artist, artKey, idsOf(tracks));
}

async function drawArtist(body, name, current) {
  const albums = await ask("artist:" + name, { artistAlbums: { name: name } }, r => r.albums);
  if (!current()) return;
  if (!albums || !albums.items.length) return false;
  const artKey = (albums.items.find(a => a.artworkKey) || {}).artworkKey;
  $("detailBarTitle").textContent = name;
  body.replaceChildren(
    hero(el("div", { className: "hero-art round" + (artKey ? "" : " glyph") }, artKey ? cover(artKey, 600, false) : icon("person")), name, null, counted("albums", albums.items.length)),
    section(L.albums), el("div", { className: "grid" }, albums.items.map(albumCard)));
}

async function drawPlaylist(body, id, current) {
  const number = Number(id);
  const [tracks, playlists] = await Promise.all([
    ask("playlist:" + id, { playlistTracks: { id: number } }, r => r.tracks && r.tracks.items),
    ask("playlists", { playlists: {} }, r => r.playlists && r.playlists.items),
  ]);
  if (!current()) return;
  if (!tracks) return false;
  const playlist = (playlists || []).find(p => p.id === number) || { id: number, name: "", smart: false };
  const total = tracks.reduce((sum, t) => sum + (t.duration || 0), 0);
  const meta = [counted("songs", tracks.length), tracks.length ? length(total) : null].filter(Boolean).join(" · ");
  $("detailBarTitle").textContent = playlist.name;
  const list = el("div", { className: "list" });
  const head = [
    hero(mosaic(Object.assign({}, playlist, { artworkKeys: playlist.artworkKeys || tracks.map(t => t.artworkKey).filter((k, i, all) => k && all.indexOf(k) === i).slice(0, 4) }), "hero-art"),
      playlist.name, null, meta, playlist.smart ? el("span", { className: "card-tags" }, el("span", { className: "chip tiny", textContent: L.smart })) : null),
  ];
  if (tracks.length) {
    head.push(el("div", { className: "actions" }, playButton(() => send({ playPlaylist: { id: number, shuffled: false } })), shuffleButton(() => send({ playPlaylist: { id: number, shuffled: true } }))));
  } else {
    head.push(empty(L.nothingQueued, "playlist"));
  }
  body.replaceChildren(...head, list);
  inParts(list, tracks, track => trackRow(track, { play: () => playList(tracks, tracks.indexOf(track)) }), 150);
  if (tracks.length) setMenu(playlist.name, meta, (playlist.artworkKeys || [])[0] || (tracks[0] || {}).artworkKey, idsOf(tracks), number);
}

/** The dots at the top of an album or a playlist: all of its songs, next, later or into a playlist. */
function setMenu(title, sub, artKey, ids, playlistID) {
  if (!ids.length) return;
  detailMenu = () => openSheet(sheetHeader(title, sub, artKey), [
    sheetItem("playnext", L.playNext, () => act({ playNext: { ids: ids } }, L.added)),
    sheetItem("addqueue", L.addToQueue, () => act({ addToQueue: { ids: ids } }, L.added)),
    sheetItem("playlist", L.addToPlaylist, () => playlistSheet(ids, playlistID), true),
  ]);
  $("detailMore").hidden = false;
  $("detailMore").setAttribute("aria-label", L.options + ": " + title);
}
$("detailMore").onclick = () => detailMenu && detailMenu();
$("detailBack").onclick = () => back();
$("view-detail").addEventListener("scroll", () => {
  const view = $("view-detail");
  view.querySelector(".bar").classList.toggle("scrolled", view.scrollTop > 150);
  if (route.kind) scrolls.set(route.kind + ":" + route.id, view.scrollTop);
}, { passive: true });

// MARK: Search

let searchTimer, searchCount = 0;

function drawSearchIdle() { $("searchBody").replaceChildren(el("div", { className: "empty" }, icon("search"))); }

async function runSearch() {
  const text = $("search").value.trim(), token = ++searchCount, body = $("searchBody");
  $("searchClear").hidden = !$("search").value;
  if (!text) return drawSearchIdle();
  const found = await ask("find:" + text.toLowerCase(), { find: { text: text, limit: 60 } }, r => r.found && (r.found._0 || r.found));
  if (token !== searchCount) return;
  if (!found) return body.replaceChildren(empty(L.offline));
  const parts = [];
  if (found.artists.length) parts.push(section(L.artists, found.artists.length), el("div", { className: "list" }, found.artists.slice(0, 6).map(artistRow)));
  if (found.albums.length) parts.push(section(L.albums, found.albums.length), el("div", { className: "shelf" }, found.albums.map(albumCard)));
  if (found.playlists.length) parts.push(section(L.playlists, found.playlists.length), el("div", { className: "list" }, found.playlists.map(playlistRow)));
  if (found.tracks.length) {
    parts.push(section(L.songs, found.tracks.length),
      el("div", { className: "list" }, found.tracks.map((track, index) => trackRow(track, { play: () => playList(found.tracks, index) }))));
  }
  body.replaceChildren(...(parts.length ? parts : [empty(L.noMatches, "search")]));
  $("view-search").scrollTop = 0;
  markCurrent();
}
$("search").addEventListener("input", () => { clearTimeout(searchTimer); $("searchClear").hidden = !$("search").value; searchTimer = setTimeout(runSearch, 220); });
$("search").addEventListener("keydown", event => { if (event.key === "Enter") { clearTimeout(searchTimer); runSearch(); $("search").blur(); } });
$("searchClear").onclick = () => { $("search").value = ""; runSearch(); $("search").focus(); };

// MARK: Queue

let queueHeld = false, queueLate = false;

function upcoming() { return queue ? queue.playingNext.concat(queue.continuing) : []; }

function drawQueue() {
  if (queueHeld) { queueLate = true; return; }
  const body = $("queueBody");
  const next = queue ? queue.playingNext : [], rest = queue ? queue.continuing : [];
  $("clearQueue").hidden = !(next.length || rest.length);
  if (!queue || (!queue.current && !next.length && !rest.length)) return body.replaceChildren(empty(L.nothingQueued, "queue"));
  const parts = [];
  if (queue.current) {
    const track = queue.current.track;
    parts.push(el("div", { className: "queue-now" }, trackRow(track, {
      play: () => go("now"), queue: { entry: queue.current.entry, current: true },
      before: null,
    })));
  }
  const all = upcoming();
  const row = item => {
    const grip = el("span", { className: "grip", attrs: { "aria-hidden": "true" } }, icon("grip"));
    grip.addEventListener("pointerdown", event => startDrag(event, item.entry));
    const node = trackRow(item.track, { play: () => send({ jump: { entry: item.entry } }), queue: { entry: item.entry }, before: grip });
    node.classList.add("upcoming");
    node.dataset.entry = item.entry;
    return node;
  };
  if (next.length) parts.push(section(L.playingNext, next.length), el("div", { className: "list" }, next.map(row)));
  if (rest.length) {
    const list = el("div", { className: "list" });
    parts.push(section(next.length ? L.continuePlaying : L.upNext, queue.continuingTotal), list);
    body.replaceChildren(...parts);
    inParts(list, rest, row, 120);
    if (queue.continuingTotal > rest.length) list.after(el("p", { className: "more-count", textContent: "+ " + counted("songs", queue.continuingTotal - rest.length) }));
  } else {
    body.replaceChildren(...parts);
  }
  if (!all.length && queue.current) body.append(el("p", { className: "more-count", textContent: L.empty }));
  markCurrent();
}

/** Moves an upcoming song before another (nothing: to the end), here at once and on the Mac. */
function moveEntry(entry, before) {
  if (!queue || entry === before) return;
  const all = upcoming(), item = all.find(i => i.entry === entry);
  if (!item) return;
  const without = all.filter(i => i.entry !== entry);
  const at = before ? without.findIndex(i => i.entry === before) : without.length;
  // Until the Mac sends the queue as it now is: the same split between the two headings, the new order.
  const cut = Math.min(queue.playingNext.length, without.length + 1);
  without.splice(at < 0 ? without.length : at, 0, item);
  queue.playingNext = without.slice(0, cut); queue.continuing = without.slice(cut);
  drawQueue();
  const command = { entries: [entry] };
  if (before) command.before = before;
  send({ moveInQueue: command });
}

/** Dragging a song by its grip: the row follows the finger, the others make room, and the drop is one moveInQueue. */
function startDrag(event, entry) {
  if (event.button > 0 || queueHeld) return;
  const view = $("view-queue"), body = $("queueBody");
  const rows = [...body.querySelectorAll(".row.upcoming")];
  const dragged = rows.find(r => r.dataset.entry === entry);
  if (!dragged || rows.length < 2) return;
  event.preventDefault();
  const grip = event.currentTarget;
  try { grip.setPointerCapture(event.pointerId); } catch (e) { /* an old browser */ }
  queueHeld = true;
  buzz(10);
  const from = rows.indexOf(dragged);
  const tops = rows.map(r => r.offsetTop), height = dragged.offsetHeight;
  const startY = event.clientY, startScroll = view.scrollTop;
  let to = from, pointerY = startY, frame = null;
  dragged.classList.add("dragging");
  body.classList.add("reordering");

  const place = () => {
    const moved = pointerY - startY + (view.scrollTop - startScroll);
    dragged.style.transform = "translateY(" + moved + "px)";
    const middle = tops[from] + moved + height / 2;
    to = from;
    for (let i = 0; i < rows.length; i++) {
      const other = tops[i] + rows[i].offsetHeight / 2;
      if (i < from && middle < other) { to = Math.min(to, i); }
      if (i > from && middle > other) { to = i; }
    }
    rows.forEach((r, i) => {
      if (r === dragged) return;
      const shift = i >= to && i < from ? height : i <= to && i > from ? -height : 0;
      r.style.transform = shift ? "translateY(" + shift + "px)" : "";
    });
  };
  // Near the top or the bottom edge, the list scrolls under the finger.
  const edge = () => {
    const box = view.getBoundingClientRect(), margin = 70;
    const speed = pointerY < box.top + margin ? -Math.ceil((box.top + margin - pointerY) / 6) : pointerY > box.bottom - margin ? Math.ceil((pointerY - (box.bottom - margin)) / 6) : 0;
    if (speed) { view.scrollTop += speed; place(); }
    frame = requestAnimationFrame(edge);
  };
  frame = requestAnimationFrame(edge);

  const move = e => { pointerY = e.clientY; place(); };
  const finish = cancelled => () => {
    grip.removeEventListener("pointermove", move);
    grip.removeEventListener("pointerup", up);
    grip.removeEventListener("pointercancel", cancel);
    cancelAnimationFrame(frame);
    body.classList.remove("reordering");
    rows.forEach(r => { r.style.transform = ""; r.classList.remove("dragging"); });
    queueHeld = false;
    if (!cancelled && to !== from) {
      buzz(10);
      const order = rows.map(r => r.dataset.entry).filter(e => e !== entry);
      moveEntry(entry, order[to] || null);
    } else if (queueLate) {
      drawQueue();
    }
    queueLate = false;
  };
  const up = finish(false), cancel = finish(true);
  grip.addEventListener("pointermove", move);
  grip.addEventListener("pointerup", up);
  grip.addEventListener("pointercancel", cancel);
}

$("clearQueue").onclick = () => act({ clearUpcoming: {} });

// MARK: Sheets

let sheetReturn = null, sheetLive = null;

function sheetHeader(title, sub, artKey) {
  return el("div", { className: "row-main", style: "min-height:0;padding:0" },
    artKey ? el("span", { className: "art" }, cover(artKey, 160, false)) : null,
    el("span", { className: "row-text" }, el("h2", { className: "serif ell", id: "sheetTitle", textContent: title }), sub ? el("span", { className: "row-sub ell", textContent: sub }) : null));
}

function sheetItem(glyph, text, run, keepOpen, className) {
  return el("button", { className: "sheet-item" + (className ? " " + className : ""), on: { click: () => { if (!keepOpen) closeSheet(); run(); } } }, icon(glyph), el("span", { className: "grow ell", textContent: text }));
}

function openSheet(head, items, live) {
  const sheet = $("sheet"), scrim = $("scrim");
  if (sheet.hidden) sheetReturn = document.activeElement;
  sheetLive = live || null;
  $("sheetHead").replaceChildren(typeof head === "string" ? el("h2", { className: "serif", id: "sheetTitle", textContent: head }) : head);
  $("sheetBody").replaceChildren(...items.filter(Boolean));
  $("sheetBody").scrollTop = 0;
  sheet.classList.remove("closing"); scrim.classList.remove("closing");
  sheet.hidden = false; scrim.hidden = false;
  $("app").inert = true;
  const first = $("sheetBody").querySelector("input, button");
  (first || $("sheetClose")).focus({ preventScroll: true });
}

function closeSheet() {
  const sheet = $("sheet"), scrim = $("scrim");
  if (sheet.hidden) return;
  sheetLive = null;
  $("app").inert = false;
  const done = () => { sheet.hidden = true; scrim.hidden = true; sheet.classList.remove("closing"); scrim.classList.remove("closing"); };
  if (calm.matches) done(); else { sheet.classList.add("closing"); scrim.classList.add("closing"); setTimeout(done, 200); }
  if (sheetReturn && sheetReturn.isConnected) sheetReturn.focus({ preventScroll: true });
  sheetReturn = null;
}
$("scrim").onclick = closeSheet;
$("sheetClose").onclick = closeSheet;
document.addEventListener("keydown", event => {
  if (event.key === "Escape" && !$("sheet").hidden) { closeSheet(); return; }
  // Keep the keyboard inside an open sheet.
  if (event.key === "Tab" && !$("sheet").hidden) {
    const stops = [...$("sheet").querySelectorAll("button, input")].filter(n => !n.hidden && !n.disabled);
    if (!stops.length) return;
    const first = stops[0], last = stops[stops.length - 1];
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    return;
  }
  const typing = /^(INPUT|TEXTAREA)$/.test(document.activeElement.tagName) || document.activeElement.getAttribute("role") === "slider";
  if (typing || $("app").hidden || event.metaKey || event.ctrlKey || event.altKey) return;
  if (event.key === " " && document.activeElement.tagName !== "BUTTON" && document.activeElement.tagName !== "A") { event.preventDefault(); $("playpause").click(); }
  if (event.key === "/") { event.preventDefault(); go("search"); $("search").focus(); }
});

/** A song's actions. In the queue it can also move and leave. */
function trackSheet(track, inQueue) {
  const id = hasID(track) ? [track.id] : null, items = [];
  if (inQueue && !inQueue.current) {
    const all = upcoming(), at = all.findIndex(i => i.entry === inQueue.entry);
    if (at > 0) items.push(sheetItem("playnext", L.playNext, () => { buzz(); moveEntry(inQueue.entry, all[0].entry); }));
    if (at > 0) items.push(sheetItem("up", words(L.moveEarlier, track.title), () => { buzz(); moveEntry(inQueue.entry, all[at - 1].entry); }));
    if (at >= 0 && at < all.length - 1) items.push(sheetItem("down", words(L.moveLater, track.title), () => { buzz(); moveEntry(inQueue.entry, all[at + 2] ? all[at + 2].entry : null); }));
    items.push(sheetItem("trash", L.removeFromUpNext, () => act({ removeFromQueue: { entries: [inQueue.entry] } }), false, "danger"));
    if (id) items.push(el("div", { className: "sheet-rule" }));
  } else if (id && !inQueue) {
    items.push(sheetItem("playnext", L.playNext, () => act({ playNext: { ids: id } }, L.added)));
    items.push(sheetItem("addqueue", L.addToQueue, () => act({ addToQueue: { ids: id } }, L.added)));
  }
  if (id) {
    items.push(sheetItem("playlist", L.addToPlaylist, () => playlistSheet(id), true));
    items.push(sheetItem(track.favorite ? "heart-fill" : "heart", track.favorite ? L.unfavorite : L.favorite, () => {
      track.favorite = !track.favorite;
      act({ setFavorite: { ids: id, on: track.favorite } }).then(() => stale("favorites"));
    }));
  }
  if (track.albumKey && !(route.kind === "album" && route.id === track.albumKey)) items.push(sheetItem("album", L.goToAlbum, () => go("album", track.albumKey)));
  if (track.artist && !(route.kind === "artist" && route.id === track.artist)) items.push(sheetItem("person", track.artist, () => go("artist", track.artist)));
  openSheet(sheetHeader(track.title, track.artist + (track.album ? " — " + track.album : ""), track.artworkKey), items);
}

/** Where to add songs: a new playlist, or one of the Mac's own (a smart playlist chooses its songs itself). */
async function playlistSheet(ids, except) {
  openSheet(L.addToPlaylist, [loading()]);
  const playlists = await ask("playlists", { playlists: {} }, r => r.playlists && r.playlists.items);
  if ($("sheet").hidden) return;
  const mine = (playlists || []).filter(p => !p.smart && p.id !== except);
  openSheet(L.addToPlaylist, [
    sheetItem("plus", L.newPlaylist, () => newPlaylistSheet(ids), true),
    mine.length ? el("div", { className: "sheet-rule" }) : null,
    ...mine.map(playlist => el("button", { className: "sheet-item", on: { click: async () => {
      closeSheet(); buzz();
      const reply = await send({ addToPlaylist: { id: playlist.id, ids: ids } });
      if (!reply) return;
      stale("playlists"); toast(L.added);
    } } }, mosaic(playlist, "art"), el("span", { className: "row-text" }, el("span", { className: "row-title ell", textContent: playlist.name }), el("span", { className: "row-sub ell", textContent: playlistSub(playlist) })))),
  ]);
}

function newPlaylistSheet(ids) {
  const input = el("input", { type: "text", maxLength: 200, placeholder: L.name, autocomplete: "off", enterKeyHint: "done", attrs: { "aria-label": L.name } });
  const create = el("button", { className: "btn brass", type: "submit", textContent: L.create, disabled: true });
  input.addEventListener("input", () => { create.disabled = !input.value.trim(); });
  const form = el("form", { className: "sheet-form", on: { submit: async event => {
    event.preventDefault();
    const name = input.value.trim();
    if (!name) return;
    create.disabled = true;
    const reply = await send({ createPlaylist: { name: name, ids: ids } });
    if (!reply) { create.disabled = false; return; }
    closeSheet(); buzz(12); toast(L.added);
    stale("playlists");
  } } }, input, el("div", { className: "actions" }, el("button", { className: "btn quiet", type: "button", textContent: L.cancel, on: { click: closeSheet } }), create));
  openSheet(L.newPlaylist, [form]);
}

/** The Mac's outputs, as its own list shows them. */
function outputSheet() {
  const draw = () => {
    const list = outputs ? outputs.outputs : [];
    return list.map(output => el("button", {
      className: "sheet-item" + (output.ready ? "" : " unready"), attrs: { "aria-pressed": output.selected ? "true" : "false" },
      on: { click: () => { closeSheet(); act({ selectOutput: output.uid === null || output.uid === undefined ? {} : { uid: output.uid } }); } },
    }, icon(output.kind === "speakerGroup" ? "library" : "output"),
      el("span", { className: "row-text" }, el("span", { className: "row-title ell", textContent: output.name }), el("span", { className: "row-sub ell", textContent: output.detail })),
      output.selected ? icon("check", "check") : null));
  };
  openSheet(L.output, draw(), () => $("sheetBody").replaceChildren(...draw()));
}

// MARK: Getting around

function parse(hash) {
  const parts = (hash || "").replace(/^#\/?/, "").split("/");
  const id = parts.length > 1 ? decodeURIComponent(parts.slice(1).join("/")) : "";
  if (["album", "artist", "playlist"].includes(parts[0]) && id) return { tab: "detail", kind: parts[0], id: id };
  if (["library", "search", "queue"].includes(parts[0])) return { tab: parts[0] };
  return { tab: "now" };
}

let parentTab = "library";

function show() {
  const before = route;
  route = parse(location.hash);
  if (route.tab !== "detail" && route.tab !== "now") parentTab = route.tab;
  if (route.tab === "detail" && before.tab !== "detail" && (before.tab === "search" || before.tab === "library")) parentTab = before.tab;
  for (const name of ["now", "library", "detail", "search", "queue"]) $("view-" + name).hidden = name !== route.tab;
  $("app").classList.toggle("on-now", route.tab === "now");
  const lit = route.tab === "detail" ? parentTab : route.tab;
  for (const link of $("tabs").children) { if (link.dataset.tab === lit) link.setAttribute("aria-current", "page"); else link.removeAttribute("aria-current"); }
  closeSheet();
  showMini();
  if (route.tab === "library") drawLibrary();
  if (route.tab === "detail") drawDetail();
  if (route.tab === "queue") drawQueue();
  if (route.tab === "search" && !$("searchBody").childElementCount) drawSearchIdle();
}

/** Opens a screen. Each one is a step in the browser's history, so the phone's Back goes where it should. */
function go(kind, id) {
  const hash = "#/" + kind + (id !== undefined ? "/" + encodeURIComponent(id) : "");
  if (hash === location.hash) return;
  buzz();
  history.pushState({ inside: true }, "", hash);
  show();
}

function back() {
  if (history.state && history.state.inside) history.back(); else { history.replaceState(null, "", "#/" + parentTab); show(); }
}

window.addEventListener("popstate", show);
window.addEventListener("hashchange", show);
$("tabs").addEventListener("click", event => {
  const link = event.target.closest("a[data-tab]");
  if (!link) return;
  event.preventDefault();
  // The same tab again: back to its top, or out of the album it's showing.
  if (link.dataset.tab === route.tab) { $("view-" + route.tab).scrollTo({ top: 0, behavior: calm.matches ? "auto" : "smooth" }); return; }
  go(link.dataset.tab);
});

// MARK: Pairing and the connection

function deviceName() {
  const ua = navigator.userAgent || "";
  const device = /iPhone/.test(ua) ? "iPhone" : /iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1) ? "iPad" : /Android/.test(ua) ? "Android"
    : /Macintosh/.test(ua) ? "Mac" : /Windows/.test(ua) ? "Windows" : /CrOS/.test(ua) ? "Chromebook" : /Linux/.test(ua) ? "Linux" : "";
  const browser = /EdgA?\//.test(ua) ? "Edge" : /SamsungBrowser/.test(ua) ? "Samsung Internet" : /FxiOS|Firefox/.test(ua) ? "Firefox" : /CriOS|Chrome/.test(ua) ? "Chrome" : /Safari/.test(ua) ? "Safari" : "";
  return [device, browser].filter(Boolean).join(" · ") || navigator.platform || "";
}

let pairing = false;
async function pair() {
  const code = $("code").value.replace(/\D/g, "");
  if (code.length < 6 || pairing) return;
  pairing = true;
  $("pairButton").disabled = true;
  $("pairError").textContent = "";
  try {
    const response = await fetch("/pair", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ code: code, name: deviceName(), touchPoints: navigator.maxTouchPoints || 0 }), credentials: "same-origin" });
    if (response.ok) { buzz(14); $("code").value = ""; await start(); }
    else {
      let reason = "";
      try { reason = (await response.json()).error || ""; } catch (e) { /* no reason given */ }
      $("pairError").textContent = reason;
      $("code").value = "";
      $("code").focus();
    }
  } catch (e) {
    $("pairError").textContent = L.offline;
  }
  pairing = false;
  $("pairButton").disabled = false;
}
$("pairForm").addEventListener("submit", event => { event.preventDefault(); pair(); });
$("code").addEventListener("input", () => {
  const digits = $("code").value.replace(/\D/g, "").slice(0, 6);
  $("code").value = digits.length > 3 ? digits.slice(0, 3) + " " + digits.slice(3) : digits;
  if (digits.length === 6) pair();
});

let events = null, retry = null, lostTimer = null;

function listen() {
  if (events) events.close();
  events = new EventSource("/events");
  const stream = events;
  stream.addEventListener("player", event => {
    const state = JSON.parse(event.data);
    state.receivedAt = performance.now();
    player = state;
    renderPlayer();
  });
  stream.addEventListener("queue", event => { queue = JSON.parse(event.data); if (route.tab === "queue") drawQueue(); });
  stream.addEventListener("outputs", event => { outputs = JSON.parse(event.data); if (sheetLive) sheetLive(); });
  stream.onopen = () => { clearTimeout(lostTimer); lostTimer = null; setOnline(true); };
  stream.onerror = () => {
    // A blink of Wi-Fi reconnects by itself; only a real gap is worth a banner.
    if (!lostTimer) lostTimer = setTimeout(() => { lostTimer = null; if (stream.readyState !== 1) setOnline(false); }, 2500);
    // Closed for good (unpaired, or the remote was turned off): find out which.
    if (stream.readyState === 2 && events === stream) { events = null; clearTimeout(retry); retry = setTimeout(start, 2500); }
  };
}

/** Shows the pairing screen or the remote, by whether this browser is paired. */
async function start() {
  clearTimeout(retry);
  let response;
  try { response = await fetch("/session", { credentials: "same-origin" }); }
  catch (e) { setOnline(false); retry = setTimeout(start, 3000); return; }
  setOnline(true);
  if (response.status === 401) {
    if (events) { events.close(); events = null; }
    closeSheet();
    $("app").hidden = true; $("pairing").hidden = false;
    document.title = L.title + " · " + L.mac;
    $("code").focus();
    return;
  }
  if (!response.ok) { retry = setTimeout(start, 3000); return; }
  const wasHidden = $("app").hidden;
  $("pairing").hidden = true; $("app").hidden = false;
  if (wasHidden) show();
  if (!events || events.readyState === 2) listen();
}

document.addEventListener("visibilitychange", () => {
  runTicker();
  if (document.hidden) return;
  tick();
  // A phone that slept may have dropped the stream without saying so.
  if (!$("app").hidden && (!events || events.readyState === 2)) start();
});
window.addEventListener("online", () => { if (!$("app").hidden) start(); });
window.addEventListener("pageshow", event => { if (event.persisted) start(); });

// MARK: Words

for (const node of document.querySelectorAll("[data-t]")) node.textContent = L[node.dataset.t] || "";
document.title = L.title + " · " + L.mac;
$("macName").textContent = L.mac;
$("search").placeholder = L.search;
$("search").setAttribute("aria-label", L.search);
$("searchClear").setAttribute("aria-label", L.clearSearch);
$("code").setAttribute("aria-label", L.pairTitle);
$("position").setAttribute("aria-label", L.position);
$("volume").setAttribute("aria-label", L.volume);
$("prev").setAttribute("aria-label", L.previous);
$("next").setAttribute("aria-label", L.next);
$("miniNext").setAttribute("aria-label", L.next);
$("miniOpen").setAttribute("aria-label", L.nowPlaying);
$("shuffle").setAttribute("aria-label", L.shuffle);
$("volDown").setAttribute("aria-label", L.volumeDown);
$("volUp").setAttribute("aria-label", L.volumeUp);
$("outputButton").setAttribute("aria-label", L.output);
$("detailBack").setAttribute("aria-label", L.back);
$("sheetClose").setAttribute("aria-label", L.close);
$("tabs").setAttribute("aria-label", L.title);
try { segment = segments.includes(sessionStorage.getItem("segment")) ? sessionStorage.getItem("segment") : "albums"; } catch (e) { /* private browsing */ }

start();
