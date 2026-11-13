//
// Vespertine: a pretend Mac for the web remote's page. It serves the page the way RemoteWebServer.swift does (the three
// RemoteWeb files as one, the words from the String Catalog) and answers /session, /pair, /events, /command and
// /artwork from a small made-up library, so the page can be opened, photographed and tested without the app.
// It listens on this computer only (127.0.0.1).
// SPDX-License-Identifier: GPL-3.0-or-later
//
//   node tests/web-remote/mock-mac.mjs [--port 47821] [--lang de] [--unpaired] [--code 123456]
//
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const read = path => readFileSync(join(root, path), "utf8");

/** The page's words: the keys RemoteWebPage.swift lists, in `lang` from the String Catalog. */
export function words(lang = "en") {
  const swift = read("App/Sources/Remote/RemoteWebPage.swift");
  const catalog = JSON.parse(read("App/Resources/Localizable.xcstrings")).strings;
  const translate = english => {
    const unit = lang === "en" ? null : catalog[english]?.localizations?.[lang]?.stringUnit;
    return unit ? unit.value : english;
  };
  const strings = {};
  for (const match of swift.matchAll(/^\s*"(\w+)": String\(localized: "((?:[^"\\]|\\.)*)"/gm)) {
    strings[match[1]] = translate(match[2].replace(/\\\(placeholder\)/g, "%@").replace(/\\"/g, '"'));
  }
  const plural = key => {
    const forms = {};
    // A language without plural forms (Japanese) has one string; the others have a variant for each form.
    const own = catalog[key]?.localizations?.[lang] || catalog[key]?.localizations?.en || {};
    const variants = own.variations?.plural || { other: own };
    const rules = new Intl.PluralRules(lang);
    for (const n of [0, 1, 2, 3, 5, 11, 20, 100]) {
      const form = (variants[rules.select(n)] || variants.other)?.stringUnit?.value || key;
      forms[n] = form.replace("%lld", new Intl.NumberFormat(lang).format(n));
    }
    return forms;
  };
  strings.plurals = { songs: plural("%lld songs"), albums: plural("%lld albums") };
  return strings;
}

export function page(lang = "en", mac = "Studio Mac mini") {
  const strings = { ...words(lang), mac };
  const json = JSON.stringify(strings).replace(/</g, "\\u003c");
  const rtl = ["ar", "fa", "he", "ur"].includes(lang);
  const unspaced = ["ar", "fa", "ur", "hi", "mr", "bn", "pa", "gu", "ta", "te", "kn", "ml", "th"].includes(lang);
  return read("App/Resources/Remote/RemoteWeb.html")
    .replace("/*__STYLE__*/", () => read("App/Resources/Remote/RemoteWeb.css"))
    .replace("/*__SCRIPT__*/", () => read("App/Resources/Remote/RemoteWeb.js"))
    .replace("__STRINGS__", () => json).replace("__LANG__", lang).replace("__DIR__", rtl ? "rtl" : "ltr").replace("__SPACED__", unspaced ? "unspaced" : "spaced");
}

/** The policy the Mac sends with the page, read from the Swift source so the page is tested under the real one. */
export const contentSecurityPolicy = [...read("App/Sources/Remote/RemoteWebPage.swift").matchAll(/^\s*(?:static let contentSecurityPolicy = |\+ )"([^"]+)"$/gm)].map(m => m[1]).join("");

// A cover drawn from its key: two tones and a few shapes, different for every album.
function coverSVG(key) {
  let h = 2166136261;
  for (const c of key) h = Math.imul(h ^ c.charCodeAt(0), 16777619) >>> 0;
  const next = () => { h = Math.imul(h ^ (h >>> 15), 2246822507) >>> 0; h = Math.imul(h ^ (h >>> 13), 3266489909) >>> 0; return (h >>> 0) / 4294967296; };
  const hue = Math.floor(next() * 360), other = (hue + 30 + Math.floor(next() * 120)) % 360, light = next() > 0.72;
  const shapes = [];
  const style = Math.floor(next() * 4);
  for (let i = 0; i < 5; i++) {
    const x = Math.floor(next() * 600), y = Math.floor(next() * 600), r = 60 + Math.floor(next() * 220), o = (0.12 + next() * 0.4).toFixed(2);
    const fill = `hsl(${(i % 2 ? hue : other) + i * 9} ${50 + i * 6}% ${light ? 38 + i * 6 : 46 + i * 7}%)`;
    if (style === 0) shapes.push(`<circle cx="${x}" cy="${y}" r="${r}" fill="${fill}" opacity="${o}"/>`);
    else if (style === 1) shapes.push(`<rect x="${x - r}" y="${i * 120}" width="${r * 3}" height="${40 + r / 3}" fill="${fill}" opacity="${o}" transform="rotate(${Math.floor(next() * 30) - 15} 300 300)"/>`);
    else if (style === 2) shapes.push(`<circle cx="300" cy="300" r="${280 - i * 52}" fill="none" stroke="${fill}" stroke-width="${10 + i * 5}" opacity="${o}"/>`);
    else shapes.push(`<path d="M0 ${y} Q 300 ${y - r} 600 ${y + r / 2} V600 H0Z" fill="${fill}" opacity="${o}"/>`);
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 600" width="600" height="600"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">`
    + `<stop offset="0" stop-color="hsl(${hue} 45% ${light ? 82 : 24}%)"/><stop offset="1" stop-color="hsl(${other} 55% ${light ? 62 : 10}%)"/></linearGradient></defs>`
    + `<rect width="600" height="600" fill="url(#g)"/>${shapes.join("")}</svg>`;
}

const iconSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><rect width="512" height="512" fill="#09090A"/><g transform="translate(128 128) scale(0.5)"><path fill="#C8A66A" d="M473.82 390.01C441.48 409.04 403.76 419.84 363.52 419.84C241.93 419.84 143.36 321.27 143.36 199.68C143.36 111.66 195.01 35.71 269.78 0.70C265.28 0.12 260.65 0 256 0C114.62 0 0 114.62 0 256C0 397.38 114.62 512 256 512C348.18 512 428.99 463.28 473.82 390.01Z"/></g></svg>`;

/** The pretend Mac: a library, a queue and a player that answer the remote protocol's commands like RemoteBridge. */
export class MockMac {
  constructor() {
    const catalog = [
      ["Nocturnes for a Small Room", "Ilse Varga", 2021, "FLAC · 24/96", true, false, false, ["First Light, Reversed", "Nocturne in Grey", "The Lamp and the Window", "Nocturne for Left Hand", "Slow Clocks", "Nocturne, Unfinished"]],
      ["Harbour Lights", "The Quiet Dials", 2019, "FLAC · 16/44.1", false, false, false, ["Tide Tables", "Harbour Lights", "Rope and Salt", "The Last Ferry", "Lanterns", "Breakwater", "Morning, Low Water"]],
      ["Glasswork", "Mara Oyelaran", 2023, "FLAC · 24/192", true, false, false, ["Annealing", "Glasswork I", "Glasswork II", "Kiln Song", "A Thousand Small Panes"]],
      ["Fieldwork", "Theo Lindqvist", 2024, "DSD64", true, true, false, ["Birch", "Meadow at Dusk", "Rain on Tin", "Fieldwork", "Hollow Oak"]],
      ["Night Trains", "The Quiet Dials", 2022, "FLAC · 24/48 · 5.1", true, false, true, ["Platform Nine", "Sleeper Car", "Signal Box", "Through the Tunnel", "Night Trains", "Terminus"]],
      ["Paper Moons", "Odile Marchetti Trio", 2017, "ALAC · 16/44.1", false, false, false, ["Paper Moons", "Blue Cardigan", "Half Past Late", "Two Chairs", "Rue des Lilas", "Encore, Maybe"]],
      ["Salt & Cedar", "Mara Oyelaran", 2020, "FLAC · 24/96", true, false, false, ["Cedar", "Salt", "The Long Shore", "Driftwood Choir", "Low Sun"]],
      ["Static Gardens", "Hollow Aerial", 2025, "FLAC · 24/44.1", false, false, false, ["Seedling", "Static Gardens", "Greenhouse Radio", "Pollen Count", "Perennial", "Overgrown", "Compost Heart", "Last Frost"]],
      ["Études in Brass", "Ilse Varga", 2018, "DSD128", true, true, false, ["Étude No. 1", "Étude No. 2", "Étude No. 3", "Étude No. 4"]],
      ["Understory", "Theo Lindqvist", 2022, "FLAC · 24/96 · 7.1.4", true, false, true, ["Canopy", "Understory", "Fern Light", "Mycelium", "Clearing"]],
    ];
    this.albums = []; this.tracks = new Map();
    let id = 1000;
    catalog.forEach(([title, artist, year, format, hiRes, dsd, multichannel, titles], index) => {
      const key = `demo-album-${index + 1}`, ids = [];
      let total = 0;
      titles.forEach((song, number) => {
        id += 1;
        const duration = 150 + (index * 37 + number * 53) % 190;
        total += duration;
        this.tracks.set(id, { id, title: song, artist, album: title, albumKey: key, duration, trackNumber: number + 1, discNumber: 1, format, artworkKey: key, favorite: (index + number) % 5 === 0 });
        ids.push(id);
      });
      this.albums.push({ key, title, artist, year, trackCount: ids.length, duration: total, format, artworkKey: key, hiRes, dsd, multichannel, ids });
    });
    const everything = this.albums.flatMap(a => a.ids);
    this.playlists = [
      { id: 1, name: "Late Night", smart: false, ids: everything.filter((_, i) => i % 4 === 1).slice(0, 14) },
      { id: 2, name: "Sunday Morning", smart: false, ids: everything.filter((_, i) => i % 7 === 2) },
      { id: 3, name: "Hi-Res", smart: true, ids: this.albums.filter(a => a.hiRes).flatMap(a => a.ids) },
      { id: 4, name: "For the Drive", smart: false, ids: [] },
    ];
    this.outputs = [
      { uid: null, name: "System Default", detail: "FOLLOWS SOUND SETTINGS", kind: "systemDefault", selected: false, ready: true },
      { uid: "dac", name: "FiiO K11", detail: "USB DAC · 44.1–384 kHz", kind: "device", selected: true, ready: true },
      { uid: "hdmi", name: "Living Room Receiver", detail: "HDMI · 8 CH · 32–192 kHz", kind: "device", selected: false, ready: true },
      { uid: "group", name: "Kitchen + Den", detail: "SPEAKER GROUP · 1 OF 2 CONNECTED", kind: "speakerGroup", selected: false, ready: false },
    ];
    this.entry = 0; this.revision = 1;
    this.playback = "playing"; this.shuffle = false; this.repeatMode = "off"; this.transitions = false; this.level = 0.55; this.muted = false;
    this.streams = new Set(); this.log = [];
    this.code = "123456"; this.tokens = new Set(); this.paired = true;
    this.load(this.albums[0].ids, 1);
    this.position = 74;
    this.playingNext = [this.item(this.albums[2].ids[1]), this.item(this.albums[5].ids[0])];
  }

  item(id) { this.entry += 1; return { entry: `E${this.entry}`, track: this.tracks.get(id) }; }
  load(ids, startAt) {
    const items = ids.map(id => this.item(id));
    this.current = items[startAt] || null; this.continuing = items.slice(startAt + 1); this.playingNext = [];
    this.position = 0; this.positionAt = Date.now() / 1000; this.revision += 1;
  }
  now() { return this.playback === "playing" ? Math.min(this.position + Date.now() / 1000 - this.positionAt, this.current?.track.duration || 0) : this.position; }
  get output() { return this.outputs.find(o => o.selected); }
  playerState() {
    const out = this.output, fixed = out.uid === "hdmi";
    const format = this.current?.track.format || "", perfect = out.uid === "dac";
    return {
      playback: this.playback, loading: false, nowPlaying: this.current ? { entry: this.current.entry, track: this.current.track } : undefined,
      position: this.now(), positionAt: Date.now() / 1000, duration: this.current?.track.duration || 0, shuffle: this.shuffle, repeatMode: this.repeatMode,
      signal: this.current ? { bitPerfect: perfect, badge: perfect ? "BIT-PERFECT" : "RESAMPLED", deviceFormat: perfect ? (format.match(/\d+\/[\d.]+/) || [""])[0] : "24/48", exclusive: perfect } : undefined,
      output: out.name, volume: fixed ? { route: "fixed", muted: false } : { route: perfect ? "hardware" : "software", level: this.level, muted: this.muted },
      transitions: this.transitions,
    };
  }
  queueState() {
    return { revision: this.revision, current: this.current || undefined, playingNext: this.playingNext, continuing: this.continuing, continuingTotal: this.continuing.length };
  }
  summary(p) {
    const covers = [...new Set(p.ids.map(id => this.tracks.get(id).artworkKey))].slice(0, 4);
    return { id: p.id, name: p.name, smart: p.smart, trackCount: p.ids.length, artworkKeys: covers };
  }
  album(a) { const { ids, ...summary } = a; return summary; }
  artists() {
    return [...new Set(this.albums.map(a => a.artist))].sort().map(name => {
      const theirs = this.albums.filter(a => a.artist === name);
      return { name, albumCount: theirs.length, artworkKey: theirs[0].artworkKey };
    });
  }
  push() {
    for (const stream of this.streams) {
      stream.write(`event: player\ndata: ${JSON.stringify(this.playerState())}\n\n`);
      stream.write(`event: queue\ndata: ${JSON.stringify(this.queueState())}\n\n`);
      stream.write(`event: outputs\ndata: ${JSON.stringify({ outputs: this.outputs })}\n\n`);
    }
  }

  perform(command) {
    const [name, args] = Object.entries(command)[0] || [];
    const known = ids => (ids || []).filter(id => this.tracks.has(id));
    const missing = { failed: { reason: "Those songs aren’t in the library anymore." } };
    const all = () => [...this.tracks.values()];
    const seekTo = seconds => { this.position = seconds; this.positionAt = Date.now() / 1000; };
    switch (name) {
      case "playPause": seekTo(this.now()); this.playback = this.playback === "playing" ? "paused" : "playing"; break;
      case "play": seekTo(this.now()); this.playback = "playing"; break;
      case "pause": seekTo(this.now()); this.playback = "paused"; break;
      case "stop": seekTo(0); this.playback = "stopped"; break;
      case "next": {
        const next = this.playingNext.shift() || this.continuing.shift();
        if (next) { this.current = next; seekTo(0); this.revision += 1; }
        break;
      }
      case "previous": seekTo(0); break;
      case "seek": seekTo(Math.max(0, args.seconds)); break;
      case "setShuffle": this.shuffle = args.on; break;
      case "setRepeat": this.repeatMode = args.mode; break;
      case "setTransitions": this.transitions = args.on; break;
      case "jump": {
        const list = this.playingNext.concat(this.continuing), at = list.findIndex(i => i.entry === args.entry);
        if (at < 0) return { failed: { reason: "That song is no longer in the queue." } };
        this.current = list[at];
        this.playingNext = this.playingNext.filter(i => list.indexOf(i) > at); this.continuing = this.continuing.filter(i => list.indexOf(i) > at);
        seekTo(0); this.playback = "playing"; this.revision += 1;
        break;
      }
      case "removeFromQueue":
        this.playingNext = this.playingNext.filter(i => !args.entries.includes(i.entry)); this.continuing = this.continuing.filter(i => !args.entries.includes(i.entry));
        this.revision += 1; break;
      case "moveInQueue": {
        // As PlayerController.moveUpcoming: the moved songs join Playing Next when they land inside it.
        const list = this.playingNext.concat(this.continuing), moving = list.filter(i => args.entries.includes(i.entry) && i.entry !== args.before);
        if (!moving.length) return { failed: { reason: "That song is no longer in the queue." } };
        const rest = list.filter(i => !moving.includes(i));
        const block = rest.filter(i => this.playingNext.includes(i)).length;
        let at = args.before ? rest.findIndex(i => i.entry === args.before) : rest.length;
        if (at < 0) at = rest.length;
        const joins = at < block || (at === block && block > 0 && moving.every(i => this.playingNext.includes(i)));
        rest.splice(at, 0, ...moving);
        const cut = block + (joins ? moving.length : 0);
        this.playingNext = rest.slice(0, cut); this.continuing = rest.slice(cut); this.revision += 1;
        break;
      }
      case "clearUpcoming": this.playingNext = []; this.continuing = []; this.revision += 1; break;
      case "playAlbum": {
        const album = this.albums.find(a => a.key === args.key);
        if (!album) return missing;
        this.load(album.ids, args.startAt || 0); this.playback = "playing"; if (args.shuffled) this.shuffle = true;
        break;
      }
      case "playTracks": {
        const ids = known(args.ids);
        if (!ids.length) return missing;
        this.load(ids, Math.min(args.startAt || 0, ids.length - 1)); this.playback = "playing"; if (args.shuffled) this.shuffle = true;
        break;
      }
      case "playPlaylist": {
        const playlist = this.playlists.find(p => p.id === args.id);
        if (!playlist || !playlist.ids.length) return missing;
        this.load(playlist.ids, 0); this.playback = "playing"; if (args.shuffled) this.shuffle = true;
        break;
      }
      case "playNext": if (!known(args.ids).length) return missing; this.playingNext.unshift(...known(args.ids).map(id => this.item(id))); this.revision += 1; break;
      case "addToQueue": if (!known(args.ids).length) return missing; this.playingNext.push(...known(args.ids).map(id => this.item(id))); this.revision += 1; break;
      case "setFavorite": for (const id of known(args.ids)) this.tracks.get(id).favorite = args.on; this.revision += 1; break;
      case "albums": {
        const start = Math.min(Math.max(0, args.offset), this.albums.length);
        return { albums: { items: this.albums.slice(start, start + Math.min(Math.max(1, args.limit), 500)).map(a => this.album(a)), total: this.albums.length } };
      }
      case "albumTracks": { const album = this.albums.find(a => a.key === args.key); return { tracks: { items: album ? album.ids.map(id => this.tracks.get(id)) : [] } }; }
      case "artists": return { artists: { items: this.artists() } };
      case "artistAlbums": { const items = this.albums.filter(a => a.artist === args.name).map(a => this.album(a)); return { albums: { items, total: items.length } }; }
      case "playlists": return { playlists: { items: this.playlists.map(p => this.summary(p)) } };
      case "playlistTracks": {
        const playlist = this.playlists.find(p => p.id === args.id);
        return playlist ? { tracks: { items: playlist.ids.map(id => this.tracks.get(id)) } } : missing;
      }
      case "favorites": return { tracks: { items: all().filter(t => t.favorite) } };
      case "songs": {
        const songs = all().sort((a, b) => a.title.localeCompare(b.title)), start = Math.min(Math.max(0, args.offset), songs.length);
        return { songs: { items: songs.slice(start, start + Math.min(Math.max(1, args.limit), 500)), total: songs.length } };
      }
      case "search": case "find": {
        const terms = String(args.text || "").toLowerCase().split(/\s+/).filter(Boolean), limit = Math.min(Math.max(1, args.limit), 500);
        const hit = text => terms.length > 0 && terms.every(term => text.toLowerCase().includes(term));
        const tracks = all().filter(t => hit(`${t.title} ${t.artist} ${t.album}`)).slice(0, limit);
        if (name === "search") return { tracks: { items: tracks } };
        // Swift writes an enum case's unnamed value as "_0".
        return { found: { _0: {
          tracks, albums: this.albums.filter(a => hit(`${a.title} ${a.artist}`)).slice(0, limit).map(a => this.album(a)),
          artists: this.artists().filter(a => hit(a.name)).slice(0, limit), playlists: this.playlists.filter(p => hit(p.name)).slice(0, limit).map(p => this.summary(p)),
        } } };
      }
      case "addToPlaylist": {
        const playlist = this.playlists.find(p => p.id === args.id);
        if (!playlist || !known(args.ids).length) return missing;
        if (playlist.smart) return { failed: { reason: "This command isn’t available here." } };
        playlist.ids.push(...known(args.ids));
        break;
      }
      case "createPlaylist": {
        const title = String(args.name || "").trim();
        if (!title) return { failed: { reason: "This command isn’t available here." } };
        this.playlists.push({ id: Math.max(...this.playlists.map(p => p.id)) + 1, name: title.slice(0, 200), smart: false, ids: known(args.ids) });
        return { playlists: { items: this.playlists.map(p => this.summary(p)) } };
      }
      case "selectOutput": {
        const output = this.outputs.find(o => o.uid === (args.uid ?? null));
        if (!output) return { failed: { reason: "That output isn’t connected to this Mac." } };
        for (const o of this.outputs) o.selected = o === output;
        break;
      }
      case "volume":
        if (args.action === "mute") this.muted = !this.muted; else { this.level = Math.min(1, Math.max(0, this.level + (args.action === "up" ? 0.05 : -0.05))); this.muted = false; }
        break;
      case "setVolume": this.level = Math.min(1, Math.max(0, args.level)); this.muted = false; break;
      default: return null;
    }
    return { ok: {} };
  }

  /** Answers one HTTP request as RemoteWebServer.swift does. */
  handle(request, response, lang) {
    const url = new URL(request.url, "http://mac");
    const cookie = /(?:^|;\s*)vespertine-remote=([^;]+)/.exec(request.headers.cookie || "");
    const signedIn = this.paired || (cookie && this.tokens.has(cookie[1]));
    const head = { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY", "Referrer-Policy": "no-referrer" };
    const reply = (status, type, body, extra = {}) => { response.writeHead(status, { ...head, "Content-Type": type, ...extra }); response.end(body); };
    const json = (value, status = 200) => reply(status, "application/json", JSON.stringify(value));
    const route = `${request.method} ${url.pathname}`;
    if (route === "GET /") return reply(200, "text/html; charset=utf-8", page(lang), { "Content-Security-Policy": contentSecurityPolicy });
    if (route === "GET /manifest.webmanifest") {
      return reply(200, "application/manifest+json", JSON.stringify({ name: "Vespertine Remote", short_name: "Vespertine", start_url: "/", scope: "/", display: "standalone",
        background_color: "#09090A", theme_color: "#09090A", icons: [{ src: "/icon.svg", sizes: "any", type: "image/svg+xml" }] }));
    }
    if (route === "GET /icon.svg") return reply(200, "image/svg+xml", iconSVG);
    if (route === "GET /session") return signedIn ? json({ name: "Studio Mac mini", serverID: "mock", appVersion: "1.1.0", protocolVersion: 1 }) : reply(401, "text/plain", "");
    if (route === "GET /events") {
      if (!signedIn) return reply(401, "text/plain", "");
      response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store", Connection: "keep-alive" });
      response.write("retry: 2000\n\n");
      this.streams.add(response);
      request.on("close", () => this.streams.delete(response));
      return this.push();
    }
    if (route === "GET /artwork") {
      if (!signedIn) return reply(401, "text/plain", "");
      const key = url.searchParams.get("key") || "";
      return /^[A-Za-z0-9_-]+$/.test(key) && this.albums.some(a => a.artworkKey === key)
        ? reply(200, "image/svg+xml", coverSVG(key), { "Cache-Control": "private, max-age=86400" }) : reply(404, "text/plain", "");
    }
    if (request.method !== "POST") return reply(404, "text/plain", "");
    let body = "";
    request.on("data", chunk => { body += chunk; });
    request.on("end", () => {
      let value;
      try { value = JSON.parse(body); } catch (e) { return reply(400, "text/plain", ""); }
      if (!(request.headers["content-type"] || "").startsWith("application/json")) return reply(400, "text/plain", "");
      if (route === "POST /pair") {
        if (String(value.code).replace(/\D/g, "") !== this.code) return json({ error: "That code didn’t work. Check the code on the Mac, or choose Pair a Phone there again for a new one." }, 403);
        const token = Math.random().toString(36).slice(2) + Date.now().toString(36);
        this.tokens.add(token); this.pairedName = value.name;
        return reply(200, "application/json", "{}", { "Set-Cookie": `vespertine-remote=${token}; Path=/; Max-Age=31536000; HttpOnly; SameSite=Strict` });
      }
      if (route === "POST /command") {
        if (!signedIn) return reply(401, "text/plain", "");
        this.log.push({ at: Date.now(), command: value });
        const result = this.perform(value);
        if (!result) return reply(400, "text/plain", "");
        json(result);
        return setTimeout(() => this.push(), 30);
      }
      reply(404, "text/plain", "");
    });
  }

  listen(port = 0, lang = "en") {
    const server = createServer((request, response) => this.handle(request, response, lang));
    return new Promise(resolve => server.listen(port, "127.0.0.1", () => resolve(server)));
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const option = (name, fallback) => { const at = process.argv.indexOf(`--${name}`); return at > 0 ? process.argv[at + 1] : fallback; };
  const mac = new MockMac();
  mac.paired = !process.argv.includes("--unpaired");
  mac.code = option("code", mac.code);
  const server = await mac.listen(Number(option("port", 47821)), option("lang", "en"));
  console.log(`Vespertine web remote (pretend Mac): http://127.0.0.1:${server.address().port}/` + (mac.paired ? "" : `  code ${mac.code}`));
}
