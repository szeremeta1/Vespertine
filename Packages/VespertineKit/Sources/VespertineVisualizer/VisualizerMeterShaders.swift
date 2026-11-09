//
// Vespertine: the shader for the meter designs modelled on real instruments: their cabinets (wood, brushed metal,
// moulded cases), faces lit by their lamps, needles and their shadows, the light band, the glass, the peak lights.
// Appended to VisualizerShaders.source (it uses that file's helpers and `struct U`).
// SPDX-License-Identifier: GPL-3.0-or-later
//

enum VisualizerMeterShaders {
    static let source = #"""

// MARK: Meter designs
// m[0]: design, unit (px), lamp warm-up 0…1, instruments in use
// m[1]: cabinet (wood case or desk) px rect; m[2]: front panel px rect; m[3]: balance needle angle, time
// m[4 + 4i …]: instrument i: window rect; housing rect; pivot x, y, needle from, to (band: left, right, centre y, half
//   height); angle A (band: lit fraction), angle B (none: -10), kind, pivot cover radius (units)
// m[20 + j]: peak light j: x, y, radius, level

struct MLook {
    float3 face;       // the face's paper where it's lit
    float3 ink;        // the main printing
    float3 red;        // the red printing
    float3 second;     // the second colour
    float3 legend;     // the panel's legends
    float3 panelInk;   // the main printing where it lands on the panel
    float3 needleA;
    float3 needleB;
    float3 lamp;       // the lamp's light
    float backlight;   // 0 lit from the room, 1 by its own lamp behind the face
    int panel;         // 0 grey hammer finish, 1 slate console bridge, 2 anthracite, 3 brushed silver, 4 BBC grey, 5 none
    int cabinet;       // 0 none, 1 teak, 2 walnut, 3 oak desk
    int bezel;         // 0 moulded black, 1 matt black (Sifam), 2 thin gloss black, 3 chrome rim, 4 mirrored well, 5 DIN case
    float needleWidth; // at its base, in units
    bool darkFace;
};

static MLook meterLook(int d) {
    MLook l;
    l.red = float3(0.78, 0.10, 0.07);
    l.second = float3(0.1, 0.25, 0.65);
    l.legend = float3(0.92, 0.91, 0.88);
    l.panelInk = float3(0.08);
    l.needleA = float3(0.04);
    l.needleB = float3(0.04);
    l.lamp = float3(1.0, 0.86, 0.62);
    l.backlight = 1;
    l.panel = 1;
    l.cabinet = 0;
    l.bezel = 2;
    l.needleWidth = 0.009;
    l.darkFace = false;
    l.ink = float3(0.05, 0.045, 0.04);
    l.face = float3(0.95, 0.9, 0.78);
    switch (d) {
    case 1: // broadcast: the 1940 card, light orange-yellow, in a black moulded case on a grey panel, lit by the room
        l.face = float3(0.96, 0.84, 0.55);
        l.backlight = 0.15;
        l.panel = 0;
        l.bezel = 0;
        l.legend = float3(0.06);
        l.second = float3(0.10, 0.36, 0.20);
        l.needleWidth = 0.011;
        break;
    case 2: // console: amber, lit hard from behind, a slate-grey bridge
        l.face = float3(1.0, 0.84, 0.26);
        l.lamp = float3(1.0, 0.95, 0.78);
        l.panel = 1;
        l.bezel = 2;
        l.second = float3(0.36, 0.62, 0.98);
        l.legend = float3(0.93, 0.93, 0.9);
        l.needleWidth = 0.009;
        break;
    case 3: // tape recorder: a white card lit warm from behind (the lamp, not the card, is yellow), anthracite panel, teak
        l.face = float3(0.97, 0.95, 0.89);
        l.lamp = float3(1.0, 0.86, 0.6);
        l.panel = 2;
        l.cabinet = 1;
        l.bezel = 3;
        l.second = float3(0.12, 0.33, 0.62);
        l.panelInk = float3(0.14);
        l.needleWidth = 0.010;
        break;
    case 4: // cassette deck: cream-white face, blue and red, mirrored wells in brushed silver, walnut case
        l.face = float3(0.95, 0.92, 0.82);
        l.lamp = float3(1.0, 0.9, 0.72);
        l.second = float3(0.10, 0.22, 0.66);
        l.red = float3(0.74, 0.12, 0.12);
        l.panel = 3;
        l.cabinet = 2;
        l.bezel = 4;
        l.panelInk = float3(0.10);
        l.needleWidth = 0.008;
        break;
    case 14: // DIN light-pointer: white scale in glossy black cases on an oak desk
        l.face = float3(0.9, 0.89, 0.85);
        l.backlight = 0.2;
        l.panel = 5;
        l.cabinet = 3;
        l.bezel = 5;
        l.legend = float3(0.75, 0.72, 0.66);
        l.lamp = float3(1.0, 0.93, 0.76);
        break;
    default: // the BBC family: matt black faces, white printing and needles, a grey panel, lit by the room
        l.face = float3(0.075, 0.075, 0.078);
        l.ink = float3(0.93, 0.92, 0.88);
        l.darkFace = true;
        l.backlight = 0.1;
        l.panel = 4;
        l.bezel = 1;
        l.needleA = float3(0.95, 0.94, 0.9);
        l.needleB = l.needleA;
        l.second = float3(0.16, 0.66, 0.26);
        l.needleWidth = 0.016;
        if (d == 12) {
            l.needleA = float3(0.92, 0.16, 0.10);   // A, red
            l.needleB = float3(0.16, 0.72, 0.28);   // B, green
        }
        break;
    }
    return l;
}

static float fbm(float2 p) {
    float v = 0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * noise(p); p = p * 2.03 + 17.1; a *= 0.5; }
    return v;
}

// Wood, its grain running across (p in units: x along the grain, y across it). `light` and `dark` are the early and
// late wood of each growth ring.
static float3 wood(float2 p, float3 light, float3 dark) {
    float2 q = p * float2(0.16, 1.0);
    // The rings, cut at a slant through a log that wanders: long arches and stripes, never evenly spaced.
    float warp = fbm(q * float2(1.0, 0.9) + 3.1) * 1.9 + 0.4 * sin(p.x * 0.38 + 2.2 * fbm(q * 0.6 + 7.0));
    float ring = fract(p.y * 2.6 + warp);
    float late = smoothstep(0.45, 0.92, ring) * (1 - smoothstep(0.92, 1.0, ring));
    // Fine fibres along the grain, and the colour drifting from board to board.
    float fibre = noise(float2(p.x * 0.9, p.y * 64)) * 0.55 + noise(float2(p.x * 3.1, p.y * 190)) * 0.45;
    float tone = fbm(float2(p.x * 0.12, p.y * 0.5) + 11.0);
    float3 c = mix(light, dark, saturate(0.55 * late + 0.28 * fibre + 0.5 * (tone - 0.45)));
    // Pores: short dark dashes along the grain.
    float pore = step(0.94, hash21(floor(float2(p.x * 7.0 + floor(p.y * 240) * 0.37, p.y * 240))));
    return c * (1 - 0.1 * pore);
}

// Brushed metal, the strokes running across (px, u: the unit in px).
static float3 brushed(float2 px, float u, float3 base) {
    float row = px.y / max(1.0, 0.0035 * u);
    float strokes = noise(float2(px.x / (0.9 * u), row)) * 0.6 + noise(float2(px.x / (0.12 * u), row * 1.7 + 3)) * 0.4;
    float v = 0.86 + 0.16 * (strokes - 0.5);
    // A soft band of the room's light across it, as brushed metal spreads a highlight along its grain.
    return base * v;
}

// Light from the upper left, toward the viewer: x right, y down, z out of the screen.
constant float3 roomLight = float3(-0.32, -0.78, 0.54);

// A raised edge: within `bevel` px of the shape's edge (distance d, negative inside, gradient n) the surface rolls
// over. Returns the light on it (1 flat).
static float bevelLight(float d, float2 n, float bevel, float gloss, thread float &spec) {
    float e = saturate(-d / max(bevel, 1e-3));
    float tilt = 1 - e * e;
    float3 normal = normalize(float3(n * tilt * 0.9, 1 - 0.6 * tilt));
    float diffuse = dot(normal, normalize(roomLight));
    float3 h = normalize(normalize(roomLight) + float3(0, 0, 1));
    spec = pow(saturate(dot(normal, h)), 40) * gloss;
    return 0.55 + 0.65 * diffuse;
}

// The outward direction from a rounded box's nearest edge (exact, so it's never undefined on the box's middle lines).
static float2 boxGradient(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    float2 sgn = float2(p.x < 0 ? -1.0 : 1.0, p.y < 0 ? -1.0 : 1.0);
    if (q.x > 0 && q.y > 0) return sgn * normalize(q);
    return q.x > q.y ? float2(sgn.x, 0) : float2(0, sgn.y);
}

// A screw head: domed, with a slot at `slot` radians.
static float3 screw(float2 px, float2 c, float r, float slot, float3 metal, float3 col) {
    float d = length(px - c);
    if (d > r + 1.5) return col;
    float2 q = rotate(px - c, slot);
    float3 s = metal * (0.6 + 0.5 * saturate(dot(normalize(float3((px - c) / r * 0.8, 0.6)), normalize(roomLight))));
    s = mix(s * 0.25, s, smoothstep(r * 0.07, r * 0.14, abs(q.y)) );
    s += float3(0.35) * pow(saturate(1 - length((px - c) / r - float2(-0.3, -0.35)) * 1.6), 3);
    // The countersink's shadow round it.
    col *= 1 - 0.45 * (1 - smoothstep(r, r + 0.12 * r + 1.5, d)) * step(r, d);
    return mix(col, s, 1 - smoothstep(r - 0.75, r + 0.75, d));
}

static float3 panelMaterial(int kind, float2 px, float u, float4 panel) {
    float2 p = px / u;
    float y = (px.y - panel.y) / max(panel.w, 1.0);
    float3 c;
    switch (kind) {
    case 0: { // grey hammer finish: shallow dimples catching the light, a fine metallic flake
        float2 cell = p * 26;
        float dimple = noise(cell) - noise(cell + float2(0.08, 0.11));
        float flake = hash21(floor(px / max(1.0, 0.003 * u)));
        c = float3(0.60, 0.61, 0.605) * (0.95 + 0.35 * dimple + 0.04 * (flake - 0.5)) * (0.97 + 0.05 * noise(p * 3));
        break;
    }
    case 1: { // a console's meter bridge: dark slate-blue hammer finish
        float2 cell = p * 30;
        float dimple = noise(cell) - noise(cell + float2(0.08, 0.11));
        c = float3(0.115, 0.13, 0.155) * (0.94 + 0.3 * dimple + 0.06 * noise(p * 140)) + float3(0.015) * (1 - y);
        break;
    }
        break;
    case 2: // anthracite paint
        c = float3(0.17, 0.175, 0.18) * (0.92 + 0.12 * noise(p * 160) + 0.05 * fbm(p * 4));
        break;
    case 3: // brushed silver
        c = brushed(px, u, float3(0.74, 0.74, 0.72));
        c += float3(0.08) * exp(-((y - 0.18) / 0.22) * ((y - 0.18) / 0.22));
        break;
    default: // the BBC's dark grey
        c = float3(0.23, 0.235, 0.24) * (0.93 + 0.1 * noise(p * 120) + 0.04 * fbm(p * 3));
        break;
    }
    // The panel's light falls off toward the bottom.
    return c * (1.06 - 0.16 * y);
}

// The needle: a tapering blade from `r0` to `r1` px along `angle` (radians from upright, clockwise).
static float needleMask(float2 px, float2 pivot, float angle, float r0, float r1, float base, float tip) {
    float2 dir = float2(sin(angle), -cos(angle));
    float2 a = pivot + dir * r0, b = pivot + dir * r1;
    float along = saturate(dot(px - a, dir) / max(r1 - r0, 1.0));
    float w = mix(base, tip, along);
    float d = segmentDistance(px, a, b);
    return 1 - smoothstep(w - 0.6, w + 0.6, d);
}

// The glass over a window: a broad reflection of the room across its upper part and a thin line of light at its top.
static float3 glass(float3 f, float2 px, float4 w, float u, float strength) {
    float2 local = (px - w.xy) / w.zw;
    float sheen = smoothstep(0.0, 0.18, local.y + 0.25 * local.x - 0.05) * (1 - smoothstep(0.18, 0.42, local.y + 0.25 * local.x - 0.05));
    f += float3(0.10) * sheen * strength;
    f += float3(0.05) * (1 - smoothstep(0.0, 0.5, local.y)) * strength;
    f += float3(0.18) * exp(-abs(px.y - (w.y + 0.025 * u)) / (0.004 * u)) * smoothstep(0.02, 0.2, local.x) * (1 - smoothstep(0.7, 0.95, local.x)) * strength;
    return f;
}

// The DIN scale where the band runs: the grey track, lit up to `level` (0…1 of the scale) by the lamp's image, with
// the printing over it (ink stays dark in the light; the red zone glows red where it's lit). b: left, right, centre y,
// half height.
static float3 bandFace(float2 px, MLook l, float4 b, float level, float3 face, float room, float su, float lamp, float4 printing) {
    float trackD = max(abs(px.y - b.z) - b.w, max(b.x - px.x, px.x - b.y));
    float reach = b.x + (b.y - b.x) * level;
    float on = step(0.002, level);
    float3 track = float3(0.6, 0.6, 0.58) * room;
    float edge = (1 - smoothstep(-0.008 * su, 0.008 * su, px.x - reach)) * on;
    float across = 1 - pow(saturate(abs(px.y - b.z) / b.w), 4);
    float3 light = l.lamp * (0.92 + 0.12 * across) * lamp;
    float inTrack = 1 - smoothstep(-0.5, 0.5, trackD);
    float3 f = mix(face, mix(track, light, edge), inTrack);
    f = mix(f, l.ink, printing.r * 0.95);
    f = mix(f, mix(l.red * 0.75 * room, float3(1.0, 0.18, 0.1) * 1.3 * lamp, edge), printing.g * inTrack * 0.92);
    f = mix(f, l.red * room, printing.g * (1 - inTrack) * 0.95);
    // A glow spilling past the band's tip.
    f += l.lamp * 0.12 * exp(-abs(px.x - reach) / (0.04 * su)) * exp(-abs(px.y - b.z) / b.w) * on * lamp;
    return f;
}

// The light on a face at px: its lamp, low behind the bezel's lower edge, and the room.
static float faceRoom(float2 px, float4 w) { return 0.82 + 0.18 * (1 - (px.y - w.y) / w.w); }

static float3 drawInstrument(float2 px, constant U &u, int i, MLook l, int design, float unit, float lamp, float4 printing,
                             float3 col, bool needles) {
    float4 w = u.m[4 + 4 * i], hs = u.m[5 + 4 * i], pv = u.m[6 + 4 * i], nd = u.m[7 + 4 * i];
    int kind = int(nd.z + 0.5);
    float2 hc = hs.xy + hs.zw * 0.5, hh = hs.zw * 0.5;
    float2 wc = w.xy + w.zw * 0.5, wh = w.zw * 0.5;
    bool small = kind == 4;
    float su = small ? unit * 0.55 : unit;

    // The housing, and its shadow on what's behind it.
    float housingR, bevel, gloss;
    float3 housingCol;
    switch (l.bezel) {
    case 0: housingR = 0.12 * su; bevel = 0.07 * su; gloss = 0.9; housingCol = float3(0.035, 0.032, 0.03); break;
    case 1: housingR = 0.03 * su; bevel = 0.025 * su; gloss = 0.15; housingCol = float3(0.06, 0.06, 0.062); break;
    case 3: housingR = 0.04 * su; bevel = 0.03 * su; gloss = 1.0; housingCol = float3(0.55, 0.56, 0.58); break;
    case 4: housingR = 0.02 * su; bevel = 0.02 * su; gloss = 0.6; housingCol = float3(0.5, 0.5, 0.5); break;
    case 5: housingR = 0.22 * su; bevel = 0.2 * su; gloss = 1.0; housingCol = float3(0.03, 0.028, 0.027); break;
    default: housingR = 0.05 * su; bevel = 0.03 * su; gloss = 0.8; housingCol = float3(0.03, 0.03, 0.032); break;
    }
    float hd = boxDistance(px - hc, hh, housingR);
    float shadowSoft = (l.bezel == 5 ? 0.12 : 0.05) * su;
    float sd = boxDistance(px - hc - float2(0.01, 0.035) * su, hh, housingR);
    if (l.bezel != 4 && l.bezel != 3) col *= 1 - 0.6 * (1 - smoothstep(-shadowSoft * 0.3, shadowSoft, sd)) * step(-0.5, hd);
    float wd = boxDistance(px - wc, wh, (l.bezel == 0 ? 0.06 : 0.02) * su);
    if (hd > 1 && wd > 1) return col;

    if (wd > -0.5) {
        // On the housing: shade its roll-over edge, lit from the upper left.
        float spec = 0;
        float2 n = boxGradient(px - hc, hh, housingR);
        float3 c;
        if (l.bezel == 4) {
            // A well: four mirrored walls leaning back to the face. The side walls show the lit face again, fading
            // with depth; the top wall is in the shade of the panel's edge; the bottom catches the lamp.
            float2 q = (px - wc) / wh;
            float ox = max(abs(q.x) - 1.0, 0.0) * wh.x / max(hh.x - wh.x, 1.0);
            float oy = max(abs(q.y) - 1.0, 0.0) * wh.y / max(hh.y - wh.y, 1.0);
            bool side = ox > oy;
            float depth = side ? ox : oy;   // 0 at the face, 1 at the panel
            float3 reflected = l.face * l.lamp * lamp * (0.95 - 0.55 * depth);
            float3 wall = side ? reflected * 0.9 : (q.y < 0 ? reflected * 0.42 : reflected * 1.05);
            c = mix(wall, float3(0.62), 0.18) + float3(0.25) * exp(-(1 - depth) * 18.0) * (side ? 0.6 : 1.0);
            // The corners where two walls meet.
            c *= 1 - 0.25 * exp(-abs(ox - oy) * 30.0) * step(0.02, min(ox, oy) + 0.02);
        } else if (l.bezel == 3) {
            // A polished chrome rim: it reflects a bright band and a dark one.
            float lightTerm = bevelLight(hd, n, bevel, gloss, spec);
            float band = sin((px.y - hs.y) / hs.w * 6.0 + (px.x - hs.x) / hs.z * 1.5);
            c = housingCol * (0.6 + 0.5 * band) * lightTerm + spec * 0.8;
        } else {
            float lightTerm = bevelLight(hd, n, bevel, gloss, spec);
            c = housingCol * lightTerm + float3(spec) * (l.bezel == 1 ? 0.15 : 0.7);
            if (l.bezel == 1) c *= 0.9 + 0.15 * noise(px / (0.004 * su));   // matt moulding
            if (l.bezel == 5) {
                // The DIN case's top slopes back: lighter toward the top, with the room's reflection along it.
                float t = saturate((px.y - hs.y) / (w.y - hs.y));
                c += float3(0.12) * (1 - t) * (1 - smoothstep(0.0, 0.5, abs((px.x - hc.x) / hh.x)));
                c += float3(0.4) * exp(-abs(px.y - (hs.y + 0.06 * su)) / (0.012 * su)) * smoothstep(-1.0, -0.6, -abs((px.x - hc.x) / hh.x));
            }
        }
        // The window's own edge: a lip of shadow where the bezel meets the glass.
        c *= 1 - 0.5 * (1 - smoothstep(0.0, 0.025 * su, wd));
        col = mix(col, c, 1 - smoothstep(-0.5, 0.5, hd));
        if (wd > 0.5) return col;
    }

    // The face, lit by its lamp (low, behind the bezel's lower edge) and by the room.
    float2 lampAt = float2(wc.x, w.y + w.w * 1.1);
    float glow = exp(-length((px - lampAt) / float2(1.5, 1.0)) / (0.75 * w.w));
    float room = 0.82 + 0.18 * (1 - (px.y - w.y) / w.w);
    float lit = mix(room, (0.42 + 0.9 * glow) * lamp, l.backlight);
    float3 tint = mix(float3(1), l.lamp, l.backlight);
    float3 face = l.face * tint * lit;
    face *= 0.985 + 0.03 * noise(px / (0.006 * su));   // the paper's grain
    float3 f;
    if (kind == 3) {
        // DIN: the white scale, a grey track across it, and the light where the band reaches.
        f = bandFace(px, l, pv, needles ? nd.x : 0.0, face, room, su, lamp, printing);
    } else {
        float3 inkC = l.darkFace ? l.ink * mix(room, 1.0, 0.3) : l.ink;
        f = mix(face, inkC, printing.r * 0.95);
        f = mix(f, l.red * (l.darkFace ? 1.0 : lit * tint), printing.g * 0.95);
        float3 sec = l.second;
        if (design == 12 && px.x > u.m[2].x + u.m[2].z * 0.5 && u.m[2].z > u.m[2].w) sec = float3(0.95, 0.80, 0.18);
        if (design == 12 && u.m[2].z <= u.m[2].w && px.y > u.m[2].y + u.m[2].w * 0.5) sec = float3(0.95, 0.80, 0.18);
        f = mix(f, sec * (l.darkFace ? 1.0 : lit * tint), printing.b * 0.95);

        // The needles (A over B, so the left one is on top), and their shadows on the face.
        float2 pivot = pv.xy;
        if (!needles) nd.xy = float2(-10, -10);
        float r0 = pv.z, r1 = pv.w;
        float base = max(0.6, l.needleWidth * su), tip = max(0.45, base * 0.35);
        float2 shadowOffset = (l.backlight > 0.5 ? float2(0.004, -0.012) : float2(0.012, 0.02)) * su;
        float shadow = 0;
        float3 colA = l.needleA, colB = l.needleB;
        if (kind == 2) { colA = float3(0.96, 0.95, 0.92); colB = float3(0.98, 0.82, 0.16); }   // M white, S yellow
        if (kind == 4) { colA = l.darkFace ? l.ink : float3(0.05); }
        bool twin = nd.y > -9, single = nd.x > -9;
        if (twin) shadow = max(shadow, needleMask(px - shadowOffset, pivot, nd.y, r0, r1, base * 2.2, tip * 3));
        if (single) shadow = max(shadow, needleMask(px - shadowOffset, pivot, nd.x, r0, r1, base * 2.2, tip * 3));
        f *= 1 - (l.darkFace ? 0.5 : 0.25) * shadow;
        if (twin) {
            float nb = needleMask(px, pivot, nd.y, r0, r1, base, tip);
            f = mix(f, colB * (0.85 + 0.15 * room), nb);
        }
        if (single) f = mix(f, colA * (0.85 + 0.15 * room), needleMask(px, pivot, nd.x, r0, r1, base, tip));

        // The cover over the pivot, where the window shows it.
        float cover = nd.w * su;
        if (cover > 0) {
            float cd = length(px - pivot) - cover;
            float3 cc = mix(float3(0.07, 0.065, 0.06), float3(0.015), saturate((px.y - (pivot.y - cover)) / (0.3 * cover)));
            cc += float3(0.25) * (1 - smoothstep(0.0, 0.012 * su, abs(cd + 0.008 * su))) * step(px.y, pivot.y - cover * 0.6);
            f *= 1 - 0.3 * (1 - smoothstep(0.0, 0.03 * su, cd));
            f = mix(f, cc, 1 - smoothstep(-0.6, 0.6, cd));
        }
    }

    // The face sits back from the glass: the bezel's lip shades its edge, more along the top.
    float lip = boxDistance(px - wc - float2(0, 0.02 * su), wh, 0.02 * su);
    f *= 0.62 + 0.38 * smoothstep(0.0, 0.07 * su, -lip);
    f = glass(f, px, w, su, l.darkFace ? 0.7 : 1.0);
    return mix(col, f, 1 - smoothstep(-0.5, 0.5, wd));
}

// The parts that move, over the cached picture of the rest: the needles and their shadows (under the pivot's cover),
// and the light band, with the bezel's lip and the glass over them as over the face.
static float3 movingParts(float2 px, constant U &u, int i, MLook l, float unit, float lamp, float4 printing, float vignette,
                          float3 col) {
    float4 w = u.m[4 + 4 * i], pv = u.m[6 + 4 * i], nd = u.m[7 + 4 * i];
    int kind = int(nd.z + 0.5);
    float su = kind == 4 ? unit * 0.55 : unit;
    float2 wc = w.xy + w.zw * 0.5, wh = w.zw * 0.5;
    float wd = boxDistance(px - wc, wh, (l.bezel == 0 ? 0.06 : 0.02) * su);
    if (wd > 0.5) return col;
    float inside = 1 - smoothstep(-0.5, 0.5, wd);
    float room = faceRoom(px, w);
    float3 colA = l.needleA, colB = l.needleB;
    float na = 0, nb = 0, shadow = 0;
    float3 f;
    if (kind == 3) {
        if (abs(px.y - pv.z) > pv.w * 3) return col;
        float2 lampAt = float2(wc.x, w.y + w.w * 1.1);
        float glow = exp(-length((px - lampAt) / float2(1.5, 1.0)) / (0.75 * w.w));
        float lit = mix(room, (0.42 + 0.9 * glow) * lamp, l.backlight);
        float3 face = l.face * mix(float3(1), l.lamp, l.backlight) * lit * (0.985 + 0.03 * noise(px / (0.006 * su)));
        f = bandFace(px, l, pv, nd.x, face, room, su, lamp, printing);
    } else {
        float2 pivot = pv.xy;
        float r0 = pv.z, r1 = pv.w;
        // Only near the needles: anything farther from the pivot's line than a shadow's width is left as it is.
        float base = max(0.6, l.needleWidth * su), tip = max(0.45, base * 0.35);
        float2 shadowOffset = (l.backlight > 0.5 ? float2(0.004, -0.012) : float2(0.012, 0.02)) * su;
        if (kind == 2) { colA = float3(0.96, 0.95, 0.92); colB = float3(0.98, 0.82, 0.16); }   // M white, S yellow
        if (kind == 4) colA = l.darkFace ? l.ink : float3(0.05);
        bool twin = nd.y > -9;
        float cover = nd.w * su;
        float open = cover > 0 ? smoothstep(-0.6, 0.6, length(px - pivot) - cover) : 1.0;
        shadow = needleMask(px - shadowOffset, pivot, nd.x, r0, r1, base * 2.2, tip * 3);
        na = needleMask(px, pivot, nd.x, r0, r1, base, tip);
        if (twin) {
            shadow = max(shadow, needleMask(px - shadowOffset, pivot, nd.y, r0, r1, base * 2.2, tip * 3));
            nb = needleMask(px, pivot, nd.y, r0, r1, base, tip);
        }
        shadow *= open * inside;
        na *= open * inside;
        nb *= open * inside;
        if (max(shadow, max(na, nb)) < 1e-3) return col;
        col *= 1 - (l.darkFace ? 0.5 : 0.25) * shadow;
        if (max(na, nb) < 1e-3) return col;
    }
    // What's drawn over the face sits under the bezel's lip and the glass, as the face does.
    float lip = boxDistance(px - wc - float2(0, 0.02 * su), wh, 0.02 * su);
    float lipLight = (0.62 + 0.38 * smoothstep(0.0, 0.07 * su, -lip)) * vignette;
    float3 sheen = glass(float3(0), px, w, su, l.darkFace ? 0.7 : 1.0) * vignette;
    if (kind == 3) return mix(col, f * lipLight + sheen, inside);
    col = mix(col, colB * (0.85 + 0.15 * room) * lipLight + sheen, nb);
    return mix(col, colA * (0.85 + 0.15 * room) * lipLight + sheen, na);
}

// A peak light's lens, lit to `level`, and its glow.
static float3 peakLight(float2 px, float4 led, float3 col, bool lit) {
    float d = length(px - led.xy);
    float level = lit ? led.w : 0.0;
    if (d < led.z + 1) {
        float3 lens = mix(float3(0.22, 0.02, 0.02), float3(1.0, 0.16, 0.08) * 1.25, level);
        lens *= 0.75 + 0.35 * (1 - saturate(d / led.z));
        lens += float3(0.5) * exp(-length(px - led.xy + led.z * float2(0.35, 0.4)) / (0.18 * led.z));
        col = mix(col, lens, 1 - smoothstep(-0.5, 0.5, d - led.z));
    }
    return col + float3(1.0, 0.15, 0.08) * level * 0.35 * exp(-d / (led.z * 2.2));
}

// m[3].z: 1 draws everything that stays still (into a texture kept until the window's size or the design changes),
// 2 lays what moves over that.
fragment float4 vz_meters_real(VOut in [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> overlay [[texture(0)]],
                               texture2d<float> printingTex [[texture(4)]], texture2d<float> still [[texture(5)]]) {
    float2 size = u.a.xy;
    float2 px = in.uv * size;
    int design = int(u.m[0].x + 0.5);
    float unit = max(u.m[0].y, 1.0);
    float lamp = u.m[0].z;
    int count = int(u.m[0].w + 0.5);
    MLook l = meterLook(design);
    float4 printing = printingTex.sample(linearClamp, in.uv);
    float vignette = 1 - 0.25 * pow(length(in.uv - 0.5) * 1.25, 2.5);

    if (u.m[3].z > 1.5) {
        float3 col = still.sample(linearClamp, in.uv).rgb;
        for (int i = 0; i < min(count, 4); i++) col = movingParts(px, u, i, l, unit, lamp, printing, vignette, col);
        for (int j = 0; j < 4; j++) {
            float4 led = u.m[20 + j];
            if (led.z > 0 && length(px - led.xy) < led.z * 10) col = peakLight(px, led, col, true);
        }
        float4 ov = overlay.sample(linearClamp, in.uv);
        return overlayOver(col, ov);
    }

    // The room: dark, warmed by the theme, lit from above.
    float3 col = mix(float3(0.03, 0.028, 0.03), u.stops[0].rgb * 0.8, 0.5) * (1.15 - 0.6 * in.uv.y);
    col += u.stops[1].rgb * 0.02 * exp(-length(in.uv - float2(0.5, 0.35)) * 2.5);

    float4 cab = u.m[1], panel = u.m[2];
    if (l.cabinet == 3) {
        // The desk: oak, its front edge toward us, the instruments standing on it.
        if (px.y > cab.y) {
            float t = (px.y - cab.y) / max(cab.w, 1.0);
            float3 oak = wood(float2(px.x / unit * 0.35, px.y / unit * 0.9 + 3), float3(0.62, 0.43, 0.24), float3(0.36, 0.22, 0.11));
            oak *= 0.75 + 0.35 * (1 - t);
            oak += float3(0.12, 0.09, 0.06) * exp(-(px.y - cab.y) / (0.03 * unit));
            // The cases' shadow on the desk, close under them.
            float under = boxDistance(float2(px.x - (panel.x + panel.z * 0.5), 0), float2(panel.z * 0.5 - 0.1 * unit, 1), 0);
            oak *= 1 - 0.7 * exp(-(px.y - cab.y) / (0.09 * unit)) * (1 - smoothstep(-0.1 * unit, 0.25 * unit, under));
            col = oak * (1 - 0.35 * smoothstep(0.7, 1.0, t));
        }
    } else if (l.cabinet > 0) {
        float2 cc = cab.xy + cab.zw * 0.5;
        float cd = boxDistance(px - cc, cab.zw * 0.5, 0.05 * unit);
        col *= 1 - 0.65 * (1 - smoothstep(-0.05 * unit, 0.12 * unit, boxDistance(px - cc - float2(0, 0.05 * unit), cab.zw * 0.5, 0.05 * unit)));
        if (cd < 1) {
            float3 w = l.cabinet == 1
                ? wood(float2(px.x / unit * 0.6, px.y / unit), float3(0.60, 0.36, 0.17), float3(0.36, 0.19, 0.08))
                : wood(float2(px.x / unit * 0.6, px.y / unit), float3(0.36, 0.22, 0.13), float3(0.16, 0.09, 0.05));
            // The case's sides run up and down: turn the grain where the side boards are.
            bool side = px.x < panel.x || px.x > panel.x + panel.z;
            if (side) w = l.cabinet == 1
                ? wood(float2(px.y / unit * 0.6, px.x / unit + 7), float3(0.60, 0.36, 0.17), float3(0.36, 0.19, 0.08))
                : wood(float2(px.y / unit * 0.6, px.x / unit + 7), float3(0.36, 0.22, 0.13), float3(0.16, 0.09, 0.05));
            float spec = 0;
            float lightTerm = bevelLight(cd, boxGradient(px - cc, cab.zw * 0.5, 0.05 * unit), 0.06 * unit, 0.5, spec);
            w = w * lightTerm + spec * 0.25;
            // Oiled wood: a soft sheen from the room's light along the top.
            w += float3(0.05, 0.035, 0.02) * exp(-(px.y - cab.y) / (0.4 * unit));
            col = mix(col, w, 1 - smoothstep(-0.5, 0.5, cd));
        }
    }

    // The front panel, where there is one.
    if (l.panel != 5) {
        float2 pc = panel.xy + panel.zw * 0.5;
        float r = (l.cabinet > 0 ? 0.01 : 0.04) * unit;
        float pd = boxDistance(px - pc, panel.zw * 0.5, r);
        if (l.cabinet == 0) col *= 1 - 0.6 * (1 - smoothstep(-0.04 * unit, 0.14 * unit, boxDistance(px - pc - float2(0, 0.05 * unit), panel.zw * 0.5, r)));
        if (pd < 1) {
            float3 p = panelMaterial(l.panel, px, unit, panel);
            if (design == 3) {
                // The tape recorder's aluminium strip across the top.
                if (px.y < panel.y + 0.42 * unit) {
                    p = brushed(px, unit, float3(0.72, 0.72, 0.7)) * (1.05 - 0.2 * (px.y - panel.y) / (0.42 * unit));
                    p *= 1 - 0.5 * exp(-(panel.y + 0.42 * unit - px.y) / (0.008 * unit));
                }
            }
            float spec = 0;
            float lightTerm = bevelLight(pd, boxGradient(px - pc, panel.zw * 0.5, r), 0.015 * unit, 0.4, spec);
            p = p * lightTerm + spec * 0.15;
            // Its printing and legends.
            p = mix(p, l.panelInk, printing.r * 0.92);
            p = mix(p, l.red * 1.05, printing.g * 0.95);
            float3 sec = l.second;
            if (design == 12 && ((panel.z > panel.w && px.x > pc.x) || (panel.z <= panel.w && px.y > pc.y))) sec = float3(0.95, 0.80, 0.18);
            p = mix(p, sec, printing.b * 0.95);
            p = mix(p, l.legend, printing.a * 0.95);
            col = mix(col, p, 1 - smoothstep(-0.5, 0.5, pd));
            // Screws in its corners (not on wood-cased panels, which are held from behind).
            if (l.cabinet == 0 && l.panel != 3) {
                float sr = 0.035 * unit, inset = 0.11 * unit;
                float3 metal = l.panel == 1 ? float3(0.12) : float3(0.6, 0.6, 0.62);
                col = screw(px, panel.xy + inset, sr, 0.5, metal, col);
                col = screw(px, panel.xy + float2(panel.z - inset, inset), sr, 1.2, metal, col);
                col = screw(px, panel.xy + float2(inset, panel.w - inset), sr, 2.1, metal, col);
                col = screw(px, panel.xy + panel.zw - inset, sr, 0.2, metal, col);
            }
        }
    }

    for (int i = 0; i < min(count, 4); i++) col = drawInstrument(px, u, i, l, design, unit, lamp, printing, col, false);

    // Screws on the cases: the moulded case's four, the Sifam's zero adjuster under the window.
    for (int i = 0; i < min(count, 4); i++) {
        float4 hs = u.m[5 + 4 * i], w = u.m[4 + 4 * i];
        int kind = int(u.m[7 + 4 * i].z + 0.5);
        if (l.bezel == 0 && kind != 4) {
            float sr = 0.04 * unit, inset = 0.085 * unit;
            float3 nickel = float3(0.62, 0.6, 0.56);
            col = screw(px, hs.xy + inset, sr, 0.4, nickel, col);
            col = screw(px, hs.xy + float2(hs.z - inset, inset), sr, 1.1, nickel, col);
            col = screw(px, hs.xy + float2(inset, hs.w - inset), sr, 2.3, nickel, col);
            col = screw(px, hs.xy + hs.zw - inset, sr, 0.9, nickel, col);
        }
        if (l.bezel == 1) col = screw(px, float2(w.x + w.z * 0.5, w.y + w.w + 0.34 * unit), 0.07 * unit, 1.45, float3(0.09), col);
        if (l.bezel == 5) {
            // The DIN case's knob on top.
            float2 k = float2(hs.x + hs.z * 0.5, hs.y + 0.02 * unit);
            float kd = length((px - k) / float2(1.0, 0.45)) - 0.32 * unit;
            float3 knob = float3(0.03) + float3(0.35) * exp(-length((px - k - float2(-0.08, -0.05) * unit) / float2(1, 0.4)) / (0.06 * unit));
            col = mix(col, knob, (1 - smoothstep(-0.5, 0.5, kd)) * step(px.y, k.y + 0.08 * unit));
        }
    }

    // The peak lights: a red lens in a bright ring (unlit here; lit over this as they come on).
    for (int j = 0; j < 4; j++) {
        float4 led = u.m[20 + j];
        if (led.z <= 0) continue;
        float d = length(px - led.xy);
        float ring = led.z * 1.45;
        if (d < ring + 1) {
            float spec = 0;
            float3 bezel = float3(0.7, 0.7, 0.72) * bevelLight(d - ring, normalize(px - led.xy + 1e-4), led.z * 0.4, 1.0, spec) + spec;
            col = mix(col, bezel, 1 - smoothstep(-0.5, 0.5, d - ring));
            col = peakLight(px, led, col, false);
        }
    }

    return float4(col * vignette + dither(px), 1);
}
"""#
}
