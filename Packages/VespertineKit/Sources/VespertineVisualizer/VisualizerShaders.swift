//
// Vespertine — the visualizer's Metal shaders. Compiled from source when the first window opens, so the package
// builds the same with SwiftPM and Xcode.
// SPDX-License-Identifier: GPL-3.0-or-later
//

enum VisualizerShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

// Mirrors VisualizerUniforms in VisualizerRenderer.swift: float4s only, so both sides lay it out alike.
struct U {
    float4 a;        // width px, height px, time, points-to-pixels
    float4 b;        // bass, mid, treble, beat pulse
    float4 c;        // level, record angle, tonearm angle (radians from the pivot), tonearm shown 0/1
    float4 d;        // band count, fine count, history width, history head (column, with its fraction)
    float4 e;        // peak caps 0/1, has artwork 0/1, strobe 0…1, signal 0…1
    float4 f;        // laser angle, platter speed 0…1, unused, beat rings in use
    float4 g;        // per style (scope, meters, particles, mirrored bars): see each
    float4 h;
    float4 k;
    float4 stops[4]; // the theme, dark to bright
    float4 rings[16];// club: radius, strength, width, colour index
};

struct VOut {
    float4 position [[position]];
    float2 uv;
};

vertex VOut vz_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.position = float4(p * 2 - 1, 0, 1);
    o.uv = float2(p.x, 1 - p.y);
    return o;
}

constexpr sampler linearClamp(filter::linear, mip_filter::linear, address::clamp_to_edge);
constexpr sampler linearRepeatX(filter::linear, s_address::repeat, t_address::clamp_to_edge);

static float3 ramp(constant U &u, float t) {
    t = saturate(t) * 3;
    int i = min(int(t), 2);
    return mix(u.stops[i].rgb, u.stops[i + 1].rgb, t - float(i));
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3 - 2 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), w.x), mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), w.x), w.y);
}

static float4 overlayOver(float3 rgb, float4 overlay) {
    return float4(rgb * (1 - overlay.a) + overlay.rgb, 1);   // the overlay is premultiplied
}

static float dither(float2 px) { return (hash21(px) - 0.5) / 255.0; }

// MARK: Bars

fragment float4 vz_bars(VOut in [[stage_in]], constant U &u [[buffer(0)]], constant float *bands [[buffer(1)]],
                        constant float *peaks [[buffer(2)]], texture2d<float> overlay [[texture(0)]]) {
    float2 size = u.a.xy;
    float pt = u.a.w;
    float2 px = in.uv * size;
    // The plot, inside margins for the labels.
    float left = 64 * pt, right = 28 * pt, top = 36 * pt, bottom = 40 * pt;
    float2 lo = float2(left, top), hi = float2(size.x - right, size.y - bottom);
    float3 bg = mix(u.stops[0].rgb * 0.55, float3(0.012), saturate(in.uv.y * 1.1));
    float vignette = 1 - 0.35 * pow(length(in.uv - 0.5) * 1.3, 2.0);
    float3 col = bg * vignette;
    int n = int(u.d.x);
    if (px.x >= lo.x && px.x < hi.x && px.y < hi.y) {
        float w = (hi.x - lo.x) / float(n);
        float fx = (px.x - lo.x) / w;
        int i = clamp(int(fx), 0, n - 1);
        float within = fract(fx);
        float gap = clamp(0.18, 1.5 * pt / w, 0.45);
        float edge = 1.0 / w;
        float inside = smoothstep(gap * 0.5 - edge, gap * 0.5 + edge, within) * smoothstep(gap * 0.5 - edge, gap * 0.5 + edge, 1 - within);
        float plotH = hi.y - lo.y;
        float y = (hi.y - px.y) / plotH;            // 0 at the floor, 1 at the top
        float h = bands[i];
        float topEdge = 1.0 / plotH;
        float fill = smoothstep(h + topEdge, h - topEdge, y) * step(0.0, y);
        float3 barCol = ramp(u, 0.3 + 0.7 * saturate(y)) * (0.75 + 0.35 * h);
        // A brighter rim at the top of the bar.
        float rim = exp(-abs(y - h) * plotH / (3 * pt)) * step(y, h + topEdge);
        barCol += u.stops[3].rgb * rim * 0.35;
        col = mix(col, barCol, fill * inside);
        // Glow above the bar.
        float above = max(0.0, y - h) * plotH;
        col += ramp(u, 0.6 + 0.4 * h) * exp(-above / (14 * pt)) * 0.10 * h * inside * step(0.0, y);
        // The held peak: a thin cap.
        if (u.e.x > 0.5) {
            float p = peaks[i];
            float cap = 1 - smoothstep(1.0 * pt, 2.0 * pt, abs((y - p) * plotH - 1.5 * pt));
            col = mix(col, mix(u.stops[3].rgb, float3(1), 0.25), cap * inside * step(0.004, p));
        }
        // Reflection under the floor.
        if (y < 0) {
            float depth = -y * plotH;
            float r = smoothstep(h * plotH + topEdge, h * plotH - topEdge, depth);
            col += ramp(u, 0.4) * r * inside * 0.16 * exp(-depth / (18 * pt));
        }
    }
    float4 ov = overlay.sample(linearClamp, in.uv);
    return overlayOver(col + dither(px), ov);
}

// MARK: Spectrogram

static float3 colourMap(constant U &u, float v) {
    // Black for silence, then the theme from dark to bright, then a touch of white at the very top.
    float3 c = ramp(u, smoothstep(0.0, 1.0, v));
    c *= smoothstep(0.02, 0.25, v);
    return mix(c, float3(1), smoothstep(0.88, 1.0, v) * 0.35);
}

fragment float4 vz_spectrogram(VOut in [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> history [[texture(1)]],
                               texture2d<float> overlay [[texture(0)]]) {
    float2 size = u.a.xy;
    float pt = u.a.w;
    float2 px = in.uv * size;
    float left = 64 * pt, right = 28 * pt, top = 36 * pt, bottom = 40 * pt;
    float2 lo = float2(left, top), hi = float2(size.x - right, size.y - bottom);
    float3 col = float3(0.008) + u.stops[0].rgb * 0.25 * (1 - in.uv.y);
    if (all(px >= lo) && all(px < hi)) {
        float2 t = (px - lo) / (hi - lo);
        float width = u.d.z;
        // Newest at the right; the head's fraction scrolls the picture smoothly between columns.
        float column = u.d.w - (1 - t.x) * (width - 2);
        float x = (column + 0.5) / width;
        float v = history.sample(linearRepeatX, float2(x, 1 - t.y)).r;
        col = colourMap(u, v);
        // Fade in from the left edge.
        col *= smoothstep(0.0, 0.04, t.x);
    }
    float4 ov = overlay.sample(linearClamp, in.uv);
    return overlayOver(col + dither(px), ov);
}

// MARK: Vinyl

static float2 rotate(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

static float segmentDistance(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / dot(ba, ba));
    return length(pa - ba * h);
}

static float boxDistance(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

// The circular spectrum: an angle (0 at the top, clockwise) to a fine bin, low at the top and mirrored left/right.
static float circular(constant float *fine, int count, float angle) {
    float a = fract(angle / (2 * M_PI_F));
    float m = a < 0.5 ? a * 2 : (1 - a) * 2;     // 0 at the top, 1 at the bottom
    float f = m * float(count - 1);
    int i = int(f);
    return mix(fine[i], fine[min(i + 1, count - 1)], f - float(i));
}

struct Tonearm {
    float shape;   // coverage 0…1
    float3 colour;
    float shadow;
};

static Tonearm tonearm(float2 q, float aa, float armAngle, float2 pivot, float reach, float3 metal) {
    Tonearm t = {0, float3(0), 0};
    float2 dir = float2(cos(armAngle), sin(armAngle));
    float2 stylus = pivot + dir * reach;
    // The headshell, offset from the arm's line as on most arms, with the cartridge under its tip.
    float2 headDir = rotate(dir, 0.38);
    float headAngle = atan2(headDir.y, headDir.x);
    float2 headCentre = stylus - headDir * 0.05;
    float2 armEnd = stylus - headDir * 0.10;
    float2 back = pivot - dir * 0.08;
    float armD = segmentDistance(q, back, armEnd) - 0.011;
    float2 hq = rotate(q - headCentre, -headAngle);
    float headD = boxDistance(hq, float2(0.068, 0.028), 0.012);
    float cartD = boxDistance(hq - float2(0.03, 0), float2(0.03, 0.017), 0.004);
    float liftD = segmentDistance(hq, float2(0.06, 0.02), float2(0.085, 0.045)) - 0.004;
    float weightD = boxDistance(rotate(q - (pivot - dir * 0.15), -armAngle), float2(0.06, 0.042), 0.012);
    float plateD = length(q - pivot) - 0.105;
    float capD = length(q - pivot) - 0.045;
    float d = min(min(min(armD, headD), min(weightD, plateD)), liftD);
    t.shape = 1 - smoothstep(-aa, aa, d);
    float along = saturate(dot(q - back, dir) / (reach + 0.08));
    float tubeLight = 1 - 0.55 * smoothstep(0.0, 0.011, abs(segmentDistance(q, back, armEnd) - 0.004));
    float3 tube = metal * (0.78 + 0.22 * sin(along * 7.0)) * tubeLight;
    float3 plate = float3(0.075, 0.075, 0.08) + metal * 0.25 * (1 - smoothstep(0.0, 0.006, abs(plateD + 0.006)));
    float3 cap = metal * (0.55 + 0.45 * smoothstep(0.045, 0.0, length(q - pivot - float2(-0.012, 0.012))));
    float ridges = 0.75 + 0.25 * sin(dot(q - pivot, dir) * 260.0);
    float3 weight = metal * 0.62 * ridges;
    float3 head = metal * 0.85 * (0.85 + 0.15 * smoothstep(0.03, -0.03, hq.y));
    float3 c = tube;
    if (d == plateD) c = capD < 0 ? cap : plate;
    if (d == weightD) c = weight;
    if (d == headD) c = cartD < 0 ? float3(0.05, 0.05, 0.055) : head;
    if (d == liftD) c = metal * 0.7;
    t.colour = c;
    // A soft shadow, cast down and to the right.
    float2 sq = q - float2(0.025, -0.035);
    float sd = min(min(segmentDistance(sq, back, armEnd) - 0.011, length(sq - pivot) - 0.105),
                   boxDistance(rotate(sq - headCentre, -headAngle), float2(0.068, 0.028), 0.012));
    t.shadow = (1 - smoothstep(-0.03, 0.05, sd)) * 0.55;
    return t;
}

fragment float4 vz_vinyl(VOut in [[stage_in]], constant U &u [[buffer(0)]], constant float *fine [[buffer(3)]],
                         texture2d<float> art [[texture(2)]], texture2d<float> overlay [[texture(0)]]) {
    float2 size = u.a.xy;
    float unit = 0.5 * min(size.x, size.y) * 0.92;
    bool showArm = u.c.w > 0.5;
    float2 centre = size * 0.5 - float2(showArm ? unit * 0.18 * min(1.0, size.x / size.y) : 0, 0);
    float2 px = in.uv * size;
    float2 q = (px - centre) / unit;
    q.y = -q.y;                                    // y up
    float r = length(q);
    float theta = atan2(q.x, q.y);                 // 0 at the top, clockwise
    float aa = 1.5 / unit;
    int fineCount = int(u.d.y);
    float bass = u.b.x, treble = u.b.z, pulse = u.b.w;
    float signal = u.e.w;

    // Background: a dark plinth with a soft light from the top left, warmed by the theme.
    float3 col = mix(float3(0.018, 0.017, 0.02), u.stops[0].rgb * 0.9, 0.5) * (1.1 - 0.5 * length(in.uv - float2(0.3, 0.2)));
    col += u.stops[1].rgb * 0.05 * exp(-r * 1.2) * (0.6 + 0.8 * bass);

    const float recordR = 0.86, platterR = 0.95, ledR = 0.985, labelR = 0.31;

    // Rim lights: a ring of light around the platter, each angle lit by its part of the spectrum.
    float spec = circular(fine, fineCount, theta) * signal;
    float ledBand = exp(-pow((r - ledR) / 0.010, 2.0));
    float ledGlow = exp(-abs(r - ledR) / (0.035 + 0.05 * spec));
    float3 ledCol = ramp(u, 0.45 + 0.55 * spec);
    col += ledCol * (ledBand * (0.15 + 1.2 * spec) + ledGlow * (0.05 + 0.6 * spec) * (0.7 + 0.6 * pulse));

    // Platter: brushed aluminium with strobe dots that turn with it, lit by a lamp at the bottom right.
    if (r < platterR + aa) {
        float edge = 1 - smoothstep(platterR - aa, platterR + aa, r);
        float brushed = 0.55 + 0.08 * noise(float2(r * 900, 0)) + 0.18 * pow(abs(cos(theta - 0.9)), 6.0);
        float3 metal = float3(0.62, 0.62, 0.64) * brushed;
        float spinTheta = theta - u.c.y;
        float dots = 0;
        for (int row = 0; row < 3; row++) {
            float rr = 0.885 + float(row) * 0.022;
            float count = 180 + float(row) * 4;
            float cell = fract(spinTheta / (2 * M_PI_F) * count);
            float2 dq = float2((cell - 0.5) * 2 * M_PI_F * rr / count, r - rr);
            dots = max(dots, 1 - smoothstep(0.0035, 0.0035 + aa, length(dq)));
        }
        float lamp = exp(-pow((theta - 2.3) / 0.35, 2.0));
        metal = mix(metal, float3(0.25), dots * 0.6) + dots * lamp * float3(1.0, 0.45, 0.1) * 0.9;
        col = mix(col, metal, edge);
        // The record's shadow on the platter.
        col *= 1 - 0.45 * smoothstep(recordR + 0.03, recordR, r) * edge;
    }

    // The record.
    if (r < recordR + aa) {
        float coverage = 1 - smoothstep(recordR - aa, recordR + aa, r);
        float2 rq = rotate(q, u.c.y);              // the record's own frame, turning with it
        float rt = atan2(rq.x, rq.y);
        // Where music is cut (grooves), and the smooth lead-in, gaps between songs and run-out.
        float grooved = smoothstep(0.835, 0.83, r) * smoothstep(0.385, 0.39, r);
        float gaps = 0;
        for (int k = 0; k < 4; k++) {
            float gr = 0.47 + float(k) * 0.085 + 0.012 * sin(float(k) * 7.0);
            gaps = max(gaps, 1 - smoothstep(0.0025, 0.0045, abs(r - gr)));
        }
        grooved *= 1 - gaps;
        float wobble = 0.0006 * noise(float2(rt * 3, r * 40));
        // Grooves finer than the pixels would shimmer (moiré): their contrast fades out as they get that fine.
        float gx = (r + wobble) * 1100.0;
        float grooves = 0.5 + 0.5 * sin(gx) * saturate(1.6 - fwidth(gx) * 0.45);
        float3 vinyl = float3(0.028, 0.028, 0.032) + float3(0.012) * grooves * grooved;
        // The sheen: light catches the grooves in two opposite wedges that stay put as the record turns.
        float sheenAngle = theta - 0.75;
        float wedge = pow(abs(cos(sheenAngle)), 18.0);
        float sheen = wedge * (0.25 + 0.75 * grooved * (0.6 + 0.4 * grooves)) * smoothstep(recordR, 0.5, r * 0.8);
        float3 sheenCol = mix(float3(0.85, 0.86, 0.9), u.stops[3].rgb, 0.25);
        vinyl += sheenCol * sheen * (0.16 + 0.10 * treble);
        // A fainter wide glow across the surface.
        vinyl += sheenCol * 0.025 * pow(abs(cos(sheenAngle)), 2.0);
        // Dust, which turns with the record.
        float speck = step(0.9975, hash21(floor(rq * 380.0))) * grooved;
        vinyl += speck * 0.10;
        // The bevelled edge.
        vinyl += float3(0.10) * smoothstep(recordR - 0.012, recordR - 0.002, r) * (0.4 + 0.6 * wedge);
        col = mix(col, vinyl, coverage);
    }

    // The label: the album cover, turning with the record.
    if (r < labelR + aa) {
        float coverage = 1 - smoothstep(labelR - aa, labelR + aa, r);
        float2 rq = rotate(q, u.c.y);
        float3 label;
        if (u.e.y > 0.5) {
            float2 auv = float2(rq.x, -rq.y) / (2 * labelR) + 0.5;
            label = art.sample(linearClamp, auv).rgb;
        } else {
            float2 lq = rq / labelR;
            label = mix(u.stops[1].rgb, u.stops[2].rgb, saturate(0.5 + 0.5 * lq.y));
            label *= 0.8 + 0.2 * smoothstep(0.62, 0.6, length(lq)) + 0.15 * (1 - smoothstep(0.01, 0.02, abs(length(lq) - 0.8)));
        }
        // Paper: slightly darker at the edge, with the sheen passing over it.
        label *= 0.86 + 0.14 * smoothstep(labelR, labelR * 0.6, r);
        label += float3(0.06) * pow(abs(cos(theta - 0.75)), 8.0);
        col = mix(col, label, coverage);
        // A thin ring where the label meets the vinyl.
        col *= 1 - 0.5 * (1 - smoothstep(0.0, 0.004, abs(r - labelR)));
    }

    // The spindle.
    float spindle = 1 - smoothstep(0.022 - aa, 0.022 + aa, r);
    float3 spindleCol = float3(0.75, 0.75, 0.78) * (0.6 + 0.4 * smoothstep(0.022, 0.0, length(q - float2(-0.006, 0.006))));
    col = mix(col, spindleCol, spindle);

    // The tonearm.
    // (Only near the arm: everywhere else it can't reach, shadow included.)
    float2 armDir = float2(cos(u.c.z), sin(u.c.z));
    if (showArm && segmentDistance(q, float2(1.08, 0.72) - armDir * 0.25, float2(1.08, 0.72) + armDir * 1.02) < 0.22) {
        float2 pivot = float2(1.08, 0.72);
        Tonearm t = tonearm(q, aa, u.c.z, pivot, 1.02, float3(0.78, 0.78, 0.8));
        col *= 1 - t.shadow;
        col = mix(col, t.colour, t.shape);
    }

    // On a beat, a breath of the theme's light over everything.
    col += u.stops[2].rgb * pulse * 0.03 * signal;
    col *= 1 - 0.25 * pow(length(in.uv - 0.5) * 1.25, 2.5);
    float4 ov = overlay.sample(linearClamp, in.uv);
    return overlayOver(col + dither(px), ov);
}

// MARK: Club

fragment float4 vz_club(VOut in [[stage_in]], constant U &u [[buffer(0)]], constant float *fine [[buffer(3)]],
                        texture2d<float> overlay [[texture(0)]]) {
    float2 size = u.a.xy;
    float unit = 0.5 * min(size.x, size.y);
    float2 px = in.uv * size;
    float2 q = (px - size * 0.5) / unit;
    q.y = -q.y;
    float r = length(q);
    float theta = atan2(q.x, q.y);
    float time = u.a.z;
    float bass = u.b.x, mid = u.b.y, treble = u.b.z, pulse = u.b.w;
    float signal = u.e.w;
    int fineCount = int(u.d.y);

    // Haze and a tunnel of rings rushing outwards, faster with the music.
    float3 col = u.stops[0].rgb * (0.35 + 0.25 * noise(q * 2.0 + time * 0.05));
    float tunnel = fract(log(max(r, 0.02)) * 2.2 - time * (0.25 + 0.6 * mid) - pulse * 0.15);
    float tunnelLine = exp(-pow((tunnel - 0.5) / 0.04, 2.0)) * smoothstep(0.1, 0.6, r) * 0.18;
    col += ramp(u, 0.5) * tunnelLine * (0.4 + 0.6 * mid) * signal;

    // Lasers: thin beams turning around the centre, brighter with the highs.
    // Two fans of five beams, turning opposite ways. Only the nearest beam of each fan can light a pixel, so each
    // fan is one evaluation rather than five.
    float laserAngle = u.f.x;
    const float spacing = 2 * M_PI_F / 5;
    float reach = smoothstep(0.08, 0.3, r) * exp(-r * 0.6);
    float haze = smoothstep(0.1, 0.4, r) * 0.035 * treble;
    for (int fan = 0; fan < 2; fan++) {
        float a0 = fan == 0 ? laserAngle : -0.7 * laserAngle + spacing * 0.5;
        float rel = theta - a0;
        float index = floor(rel / spacing + 0.5);
        float d = abs(rel - index * spacing) * r;
        float width = 0.004 + 0.004 * r;
        float x = d / width;
        float flicker = 0.55 + 0.45 * sin(time * 17.0 + (index * 2 + float(fan)) * 2.1);
        float3 c = fan == 0 ? u.stops[2].rgb : u.stops[3].rgb;
        col += c * (exp(-x * x) * reach * (0.25 + 1.6 * treble) * flicker + exp(-d / (0.06 + 0.1 * treble)) * haze) * signal;
    }

    // Rings sent out by each beat.
    int ringCount = min(int(u.f.w), 16);
    for (int i = 0; i < ringCount; i++) {
        float4 ring = u.rings[i];
        float d = abs(r - ring.x);
        if (d > ring.z * 30) continue;      // too far for its halo to show
        float x = d / ring.z;
        float shape = exp(-x * x);
        float halo = exp(-d / (ring.z * 6));
        float3 c = ramp(u, ring.w);
        col += c * (shape * 1.1 + halo * 0.25) * ring.y;
    }

    // The circular spectrum around the core.
    float base = 0.22 + 0.05 * bass;
    float spec = circular(fine, fineCount, theta) * signal;
    float barMask = smoothstep(0.35, 0.2, abs(fract(theta / (2 * M_PI_F) * 128) - 0.5));
    float outer = base + spec * 0.42;
    float bar = smoothstep(base - 0.004, base, r) * (1 - smoothstep(outer - 0.004, outer + 0.004, r)) * barMask;
    col += ramp(u, 0.5 + 0.5 * spec) * bar * (0.6 + 0.8 * spec);
    col += ramp(u, 0.7) * exp(-max(0.0, r - outer) / 0.03) * smoothstep(base, outer, r) * 0.0;

    // The core: an orb that swells with the bass.
    float core = 0.09 + 0.10 * bass + 0.05 * pulse;
    float orb = 1 - smoothstep(core - 0.01, core + 0.01, r);
    float glow = exp(-max(0.0, r - core) / (0.05 + 0.15 * bass));
    col = mix(col, mix(u.stops[2].rgb, float3(1), 0.35 + 0.4 * pulse), orb * (0.6 + 0.4 * signal));
    col += u.stops[2].rgb * glow * (0.25 + 0.75 * bass) * (0.3 + 0.7 * signal);

    // Strobe (only when switched on, never with Reduce Motion).
    col += float3(u.e.z) * 0.85;
    col *= 1 - 0.3 * pow(length(in.uv - 0.5) * 1.2, 2.0);
    col = col / (1 + max(max(col.r, col.g), col.b) * 0.25);   // soft roll-off instead of clipping
    float4 ov = overlay.sample(linearClamp, in.uv);
    return overlayOver(col + dither(px), ov);
}
// MARK: Trails (scope and particles)
// Both draw light additively into a half-float texture that fades a little every frame, as phosphor or a long
// exposure would, and the style's own pass then lays it over its background.

// Drawn with blending that keeps `blend colour` of what was there: the fade.
fragment float4 vz_fade(VOut in [[stage_in]]) { return float4(0); }

constant float2 quadCorners[6] = { float2(0, -1), float2(1, -1), float2(0, 1), float2(0, 1), float2(1, -1), float2(1, 1) };

static float3 phosphor(float3 light) {
    // Light to colour: saturating like film, and running to white where it's brightest.
    float3 c = 1 - exp(-light * 1.25);
    float hot = smoothstep(1.2, 4.0, max(max(light.r, light.g), light.b));
    return mix(c, float3(1), hot * 0.45);
}

// MARK: Scope
// g: beam width (sigma, px), mode (0 goniometer, 1 oscilloscope), correlation, unused
// h: goniometer: centre x, centre y, radius (px); oscilloscope: the screen's left, top, right, bottom (px)
// k: the correlation bar: left, centre y, right, height (px)

struct BeamOut {
    float4 position [[position]];
    float2 px;
    float2 a;
    float2 b;
    float3 colour;
    float intensity;
};

// One segment of the trace per instance: points[i] to points[i + 1] (x, y in px, brightness, colour 0…2).
vertex BeamOut vz_beam_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], const device float4 *points [[buffer(0)]],
                              constant U &u [[buffer(1)]]) {
    float4 p0 = points[iid], p1 = points[iid + 1];
    float2 size = u.a.xy;
    float sigma = u.g.x;
    float reach = sigma * 4;
    float2 a = p0.xy, b = p1.xy, d = b - a;
    float len = length(d);
    float2 t = len > 1e-3 ? d / len : float2(1, 0);
    float2 n = float2(-t.y, t.x);
    float2 c = quadCorners[vid];
    float2 pos = mix(a, b, c.x) + t * (c.x * 2 - 1) * reach + n * c.y * reach;
    BeamOut o;
    o.position = float4(pos.x / size.x * 2 - 1, 1 - pos.y / size.y * 2, 0, 1);
    o.px = pos;
    o.a = a;
    o.b = b;
    // The beam leaves the same light in every step: a long, fast step spreads it thin.
    o.intensity = p0.z * min(1.0, sigma * 2.5 / max(len, 1e-3));
    int colour = int(p0.w + 0.5);
    o.colour = colour == 1 ? u.stops[2].rgb : colour == 2 ? u.stops[3].rgb : mix(u.stops[2].rgb, u.stops[3].rgb, 0.45);
    return o;
}

fragment float4 vz_beam_fragment(BeamOut in [[stage_in]], constant U &u [[buffer(0)]]) {
    float sigma = u.g.x;
    float d = segmentDistance(in.px, in.a, in.b);
    float core = exp(-(d * d) / (sigma * sigma));
    float halo = exp(-d / (sigma * 3)) * 0.10;
    return float4(in.colour * (core + halo) * in.intensity, 1);
}

static float lineMask(float d, float halfWidth) { return 1 - smoothstep(halfWidth, halfWidth + 1.0, d); }

fragment float4 vz_scope(VOut in [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> overlay [[texture(0)]],
                         texture2d<float> trail [[texture(3)]]) {
    float2 size = u.a.xy;
    float pt = u.a.w;
    float2 px = in.uv * size;
    float3 col = mix(float3(0.012, 0.012, 0.014), u.stops[0].rgb * 0.6, 0.6);
    col *= 1.05 - 0.45 * length(in.uv - 0.5);
    float3 ink = mix(u.stops[3].rgb, float3(0.8), 0.5);
    float grid = 0;
    if (u.g.y < 0.5) {
        // Goniometer: the full-scale circle, half scale, the L and R axes (diagonal), M (upright) and S (across).
        float2 c = u.h.xy;
        float radius = u.h.z;
        float2 q = px - c;
        float r = length(q);
        float w = 0.5 * pt;
        grid = max(grid, lineMask(abs(r - radius), w) * 0.55);
        grid = max(grid, lineMask(abs(r - radius * 0.5), w) * 0.22 * step(0.5, fract(atan2(q.y, q.x) * 24 / M_PI_F)));
        float inside = 1 - smoothstep(radius, radius + 1, r);
        float diag1 = abs(q.x - q.y) * M_SQRT1_2_F, diag2 = abs(q.x + q.y) * M_SQRT1_2_F;
        grid = max(grid, max(lineMask(diag1, w), lineMask(diag2, w)) * 0.32 * inside);
        grid = max(grid, max(lineMask(abs(q.x), w), lineMask(abs(q.y), w)) * 0.18 * inside);
        // A faint glass disc.
        col += u.stops[1].rgb * 0.035 * inside * (1 - r / max(radius, 1.0));
        // The correlation bar: -1 to +1, the out-of-phase half tinted red, a marker where it reads.
        float4 bar = u.k;
        float2 bq = px - float2((bar.x + bar.z) * 0.5, bar.y);
        float halfLength = (bar.z - bar.x) * 0.5, halfHeight = bar.w * 0.5;
        float trackD = boxDistance(bq, float2(halfLength, halfHeight), halfHeight);
        float track = 1 - smoothstep(-0.5, 0.5, trackD);
        float3 trackCol = bq.x < 0 ? mix(float3(0.06), float3(0.32, 0.06, 0.05), 0.55) : float3(0.07, 0.07, 0.075);
        col = mix(col, trackCol, track);
        for (int i = -2; i <= 2; i++) {
            float x = float(i) * 0.5 * halfLength;
            grid = max(grid, lineMask(abs(bq.x - x), 0.4 * pt) * step(abs(bq.y), halfHeight + 4 * pt) * (i == 0 ? 0.7 : 0.35));
        }
        float corr = u.g.z;
        float mx = corr * halfLength;
        float marker = 1 - smoothstep(-0.5, 0.5, boxDistance(bq - float2(mx, 0), float2(2.0 * pt, halfHeight + 3 * pt), 1.0 * pt));
        float3 markerCol = corr < 0 ? float3(1.0, 0.32, 0.22) : mix(u.stops[2].rgb, float3(1), 0.3);
        float fill = (1 - smoothstep(-0.5, 0.5, trackD)) * step(min(0.0, mx), bq.x) * step(bq.x, max(0.0, mx));
        col = mix(col, markerCol * 0.55, fill * 0.8);
        col = mix(col, markerCol, marker);
    } else {
        // Oscilloscope: ten by eight divisions, the centre lines ticked in fifths.
        float4 s = u.h;
        float2 lo = s.xy, hi = s.zw;
        float div = (hi.x - lo.x) / 10;
        float2 g = (px - lo) / div;
        bool inside = all(px >= lo - 1) && all(px <= hi + 1);
        if (inside) {
            float2 f = abs(fract(g + 0.5) - 0.5) * div;
            grid = max(lineMask(f.x, 0.5 * pt), lineMask(f.y, 0.5 * pt)) * 0.20;
            float2 centre = (lo + hi) * 0.5;
            float2 dc = abs(px - centre);
            float2 tick = abs(fract(g * 5 + 0.5) - 0.5) * div / 5;
            grid = max(grid, lineMask(dc.y, 0.5 * pt) * 0.32);
            grid = max(grid, lineMask(dc.x, 0.5 * pt) * 0.32);
            grid = max(grid, lineMask(tick.x, 0.5 * pt) * step(dc.y, 4 * pt) * 0.4);
            grid = max(grid, lineMask(tick.y, 0.5 * pt) * step(dc.x, 4 * pt) * 0.4);
            // The two channels' own zero lines, at a quarter and three quarters of the way down.
            float q1 = abs(px.y - mix(lo.y, hi.y, 0.25)), q3 = abs(px.y - mix(lo.y, hi.y, 0.75));
            grid = max(grid, lineMask(min(q1, q3), 0.5 * pt) * 0.14);
            col += u.stops[1].rgb * 0.03;
        }
        float frame = abs(boxDistance(px - (lo + hi) * 0.5, (hi - lo) * 0.5, 2 * pt));
        grid = max(grid, lineMask(frame, 0.6 * pt) * 0.5);
    }
    col = mix(col, ink, grid * 0.6);
    col += phosphor(trail.sample(linearClamp, in.uv).rgb);
    float4 ov = overlay.sample(linearClamp, in.uv);
    return overlayOver(col + dither(px), ov);
}

// MARK: Meters
// g, h: the two faces (left, top, width, height in px); k: needle travel left, right, meter (0 VU, 1 PPM), unused;
// c: the peak lights, left and right (0…1).

static float3 meterFace(float2 px, float4 rect, float travel, float led, bool ppm, constant U &u,
                        float4 face, float pt, float3 col) {
    float h = rect.w;
    float2 centre = rect.xy + rect.zw * 0.5;
    float2 halfSize = rect.zw * 0.5;
    float bezelD = boxDistance(px - centre, halfSize + 0.07 * h, 0.1 * h);
    float faceD = boxDistance(px - centre, halfSize, 0.035 * h);
    // A soft shadow under the bezel.
    col *= 1 - 0.55 * (1 - smoothstep(-0.02 * h, 0.08 * h, boxDistance(px - centre - float2(0, 0.025 * h), halfSize + 0.07 * h, 0.1 * h)));
    if (bezelD > 1) return col;
    // The bezel: dark, with light along its top edge and the theme's darker colour in its sheen.
    float y = (px.y - (rect.y - 0.07 * h)) / (h * 1.14);
    float3 bezel = mix(float3(0.10, 0.10, 0.11), float3(0.035), y) + u.stops[1].rgb * 0.06 * (1 - y);
    bezel += float3(0.22) * (1 - smoothstep(0.0, 1.5, abs(bezelD + 1.0))) * (1 - y);
    float3 c = mix(col, bezel, 1 - smoothstep(-0.5, 0.5, bezelD));
    if (faceD > 1) return c;

    // The face, lit from behind by a lamp low in the middle.
    float2 lamp = float2(centre.x, rect.y + h * 1.05);
    float light = 0.62 + 0.5 * exp(-length((px - lamp) / float2(1.25, 1)) / (0.9 * h));
    float3 paper, ink, needleCol;
    if (ppm) {
        paper = float3(0.025, 0.025, 0.03) + u.stops[1].rgb * 0.035 * light;
        ink = mix(float3(0.96, 0.95, 0.92), u.stops[3].rgb, 0.25);
        needleCol = mix(float3(1.0, 0.98, 0.92), u.stops[3].rgb, 0.2);
    } else {
        paper = mix(float3(0.95, 0.84, 0.58), u.stops[3].rgb, 0.4) * light;
        paper = mix(paper, paper * u.stops[2].rgb * 1.6, 0.12);
        ink = float3(0.04, 0.035, 0.03);
        needleCol = float3(0.05, 0.045, 0.04);
    }
    float3 f = mix(paper, ink, face.r * 0.94);
    f = mix(f, float3(0.78, 0.09, 0.07) * (ppm ? 1.0 : light), face.g * 0.95);

    // The needle, and its shadow on the face.
    float2 pivot = float2(centre.x, rect.y + 1.25 * h);
    float angle = -0.733038 + 1.466077 * travel;   // ±42°
    float2 dir = float2(sin(angle), -cos(angle));
    float2 a = pivot + dir * 0.45 * h, b = pivot + dir * 1.03 * h;
    float2 shadowOffset = float2(0.012, 0.02) * h;
    float sd = segmentDistance(px - shadowOffset, a, b);
    f *= 1 - 0.28 * (1 - smoothstep(0.0, 0.025 * h, sd));
    float along = saturate(dot(px - a, dir) / (0.58 * h));
    float width = max(0.6 * pt, h * mix(0.006, 0.0028, along));
    float nd = segmentDistance(px, a, b);
    f = mix(f, needleCol, 1 - smoothstep(width - 0.6, width + 0.6, nd));

    // The cover over the pivot, with a highlight along its top.
    float coverD = length(px - pivot) - 0.5 * h;
    float3 cover = mix(float3(0.075, 0.075, 0.08), float3(0.025), saturate((px.y - (pivot.y - 0.5 * h)) / (0.25 * h)));
    cover += u.stops[1].rgb * 0.05;
    cover += float3(0.2) * (1 - smoothstep(0.0, 1.5 * pt, abs(coverD + 0.8 * pt)));
    f = mix(f, cover, 1 - smoothstep(-0.6, 0.6, coverD));

    // The peak light, top right.
    float2 ledAt = float2(rect.x + rect.z - 0.09 * h, rect.y + 0.1 * h);
    float ledD = length(px - ledAt);
    float ledR = 0.024 * h;
    float3 ledCol = mix(float3(0.16, 0.03, 0.03), float3(1.0, 0.18, 0.1), led);
    f = mix(f, ledCol, 1 - smoothstep(ledR - 0.6, ledR + 0.6, ledD));
    f += float3(1.0, 0.2, 0.1) * led * 0.35 * exp(-ledD / (0.05 * h));

    // Glass: the face's edge in the bezel's shadow, and a reflection across the top.
    f *= 0.72 + 0.28 * smoothstep(0.0, 0.06 * h, -faceD);
    float2 local = (px - rect.xy) / h;
    float sheen = smoothstep(0.05, 0.0, abs(local.y - 0.18 - 0.12 * local.x / 1.55) - 0.09);
    f += float3(0.07) * sheen * (1 - local.y);
    return mix(c, f, 1 - smoothstep(-0.5, 0.5, faceD));
}

fragment float4 vz_meters(VOut in [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> overlay [[texture(0)]],
                          texture2d<float> face [[texture(4)]]) {
    float2 size = u.a.xy;
    float pt = u.a.w;
    float2 px = in.uv * size;
    // A dark panel, lit softly from above, warmed by the theme.
    float3 col = mix(float3(0.03, 0.028, 0.03), u.stops[0].rgb * 0.8, 0.5) * (1.15 - 0.6 * in.uv.y);
    col += u.stops[1].rgb * 0.025 * exp(-length(in.uv - float2(0.5, 0.35)) * 2.5);
    float4 printing = face.sample(linearClamp, in.uv);
    bool ppm = u.k.z > 0.5;
    col = meterFace(px, u.g, u.k.x, u.c.x, ppm, u, printing, pt, col);
    col = meterFace(px, u.h, u.k.y, u.c.y, ppm, u, printing, pt, col);
    col *= 1 - 0.25 * pow(length(in.uv - 0.5) * 1.25, 2.5);
    float4 ov = overlay.sample(linearClamp, in.uv);
    return overlayOver(col + dither(px), ov);
}

// MARK: Particles
// g: dt, width over height, calm (Reduce Motion) 0/1, particle count

struct Particle {
    float4 pv;   // position (units of half the shorter side, y up), velocity
    float4 m;    // heat (a beat's flash), life left (s), seed, life at birth (s)
};

static float2 curl(float2 p) {
    const float e = 0.02;
    float dx = noise(p + float2(e, 0)) - noise(p - float2(e, 0));
    float dy = noise(p + float2(0, e)) - noise(p - float2(0, e));
    return float2(dy, -dx) / (2 * e);
}

kernel void vz_particles_step(device Particle *particles [[buffer(0)]], constant U &u [[buffer(1)]],
                              uint id [[thread_position_in_grid]]) {
    if (id >= uint(u.g.w)) return;
    Particle p = particles[id];
    float dt = u.g.x, aspect = u.g.y, calm = u.g.z;
    float time = u.a.z;
    float mid = u.b.y;
    float signal = u.e.w;
    float2 x = p.pv.xy, v = p.pv.zw;
    float r = length(x);
    float2 dir = r > 1e-4 ? x / r : float2(0, 1);
    // A flow that turns slowly on its own, faster with the mids. It's the curl of a noise field, so it neither
    // gathers the particles into lines nor thins them out; the whole field also swirls gently.
    float2 flow = curl(x * 0.9 + float2(time * 0.045, -time * 0.03)) + 0.5 * curl(x * 2.2 - time * 0.08);
    float2 target = flow * (0.06 + 0.40 * mid * signal) * (1 - 0.6 * calm);
    target += float2(-dir.y, dir.x) * 0.06 * min(r, 1.0);
    // Little inertia: heavy particles would be flung out of the eddies and gather in bright seams.
    v += (target - v) * (1 - exp(-dt / 0.08));
    // Each beat's ring makes the particles it passes flare, and stirs them a little (the ripple itself is drawn: see
    // the sprites).
    float heat = p.m.x * exp(-dt / 0.45);
    if (calm < 0.5) {
        int count = min(int(u.f.w), 16);
        for (int i = 0; i < count; i++) {
            float4 ring = u.rings[i];
            float d = (r - ring.x) / 0.07;
            float k = exp(-d * d) * ring.y;
            v += dir * k * 0.8 * dt;
            heat = max(heat, k);
        }
    }
    x += v * dt;
    float life = p.m.y - dt;
    if (life <= 0 || abs(x.x) > aspect + 0.15 || abs(x.y) > 1.15) {
        // Born again somewhere in the disc.
        float h1 = hash21(float2(float(id) * 0.0131, fract(time * 0.173) * 97.0 + p.m.z));
        float h2 = hash21(float2(fract(time * 0.371) * 53.0 + p.m.z, float(id) * 0.0713));
        float h3 = hash21(float2(h1 * 91.7, h2 * 37.3));
        float a = h1 * 2 * M_PI_F;
        float2 out = float2(cos(a), sin(a));
        x = out * 1.5 * sqrt(h2);
        v = float2(0);
        life = 3 + 7 * h3;
        p.m.w = life;
        heat = 0;
    }
    p.pv = float4(x, v);
    p.m.x = heat;
    p.m.y = life;
    particles[id] = p;
}

struct SpriteOut {
    float4 position [[position]];
    float2 q;
    float3 colour;
};

vertex SpriteOut vz_sprite_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], const device Particle *particles [[buffer(0)]],
                                  constant U &u [[buffer(1)]]) {
    Particle p = particles[iid];
    float2 size = u.a.xy;
    float pt = u.a.w;
    float unit = 0.5 * min(size.x, size.y);
    // The bass breathes the whole field in and out (drawn only: the motion itself isn't disturbed).
    float breath = 1 + 0.07 * u.b.x * u.e.w * (1 - 0.7 * u.g.z);
    // Beats ripple outwards: a particle rides each ring's crest out a little and settles back as it passes.
    float r = length(p.pv.xy);
    float ripple = 0;
    if (u.g.z < 0.5) {
        int count = min(int(u.f.w), 16);
        for (int i = 0; i < count; i++) {
            float d = (r - u.rings[i].x) / 0.09;
            ripple += exp(-d * d) * u.rings[i].y * 0.07;
        }
    }
    float2 at = p.pv.xy * breath + (r > 1e-4 ? p.pv.xy / r : float2(0)) * ripple;
    float2 px = size * 0.5 + float2(at.x, -at.y) * unit;
    float speed = length(p.pv.zw);
    float heat = p.m.x;
    float fade = smoothstep(0.0, 0.8, p.m.y) * smoothstep(0.0, 0.6, p.m.w - p.m.y);
    float seed = fract(p.m.z * 0.6180339);
    float radius = (0.6 + 0.6 * seed + 1.8 * heat + 0.8 * u.b.z * u.e.w) * pt;
    float2 corner = quadCorners[vid] * float2(2, 1) - float2(1, 0);   // -1…1 both ways
    float2 pos = px + corner * radius * 2.5;
    SpriteOut o;
    o.position = float4(pos.x / size.x * 2 - 1, 1 - pos.y / size.y * 2, 0, 1);
    o.q = corner * 2.5;
    float t = saturate(0.2 + 0.55 * seed + speed * 0.5 + heat * 0.5);
    // Brightest in the middle, fading out towards the edges, so the field has no rim.
    float falloff = exp(-r * r * 0.9);
    o.colour = ramp(u, t) * (0.05 + 1.0 * heat + 0.2 * speed) * fade * falloff * (0.4 + 0.6 * u.e.w);
    return o;
}

fragment float4 vz_sprite_fragment(SpriteOut in [[stage_in]]) {
    return float4(in.colour * exp(-dot(in.q, in.q) * 1.3), 1);
}

fragment float4 vz_particles(VOut in [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> overlay [[texture(0)]],
                             texture2d<float> trail [[texture(3)]]) {
    float2 size = u.a.xy;
    float2 px = in.uv * size;
    float unit = 0.5 * min(size.x, size.y);
    float2 q = (px - size * 0.5) / unit;
    float r = length(q);
    float3 col = u.stops[0].rgb * (0.25 + 0.3 * exp(-r * 1.4));
    col += u.stops[1].rgb * exp(-r * 2.0) * 0.12 * u.b.x * u.e.w;
    col += phosphor(trail.sample(linearClamp, in.uv).rgb);
    col *= 1 - 0.3 * pow(length(in.uv - 0.5) * 1.2, 2.0);
    float4 ov = overlay.sample(linearClamp, in.uv);
    return overlayOver(col + dither(px), ov);
}

// MARK: Mirrored bars
// g: layout (0 circle, 1 line), bass swell of the circle, unused, unused

fragment float4 vz_mirror(VOut in [[stage_in]], constant U &u [[buffer(0)]], constant float *bands [[buffer(1)]],
                          constant float *peaks [[buffer(2)]], texture2d<float> overlay [[texture(0)]],
                          texture2d<float> art [[texture(2)]]) {
    float2 size = u.a.xy;
    float pt = u.a.w;
    float2 px = in.uv * size;
    int n = int(u.d.x);
    float bass = u.b.x, pulse = u.b.w, signal = u.e.w;
    float3 col = mix(float3(0.012), u.stops[0].rgb * 0.7, 0.6) * (1.1 - 0.5 * length(in.uv - 0.5));
    bool caps = u.e.x > 0.5;
    if (u.g.x < 0.5) {
        // Around a circle: low notes at the top, mirrored left and right, the album in the middle.
        float unit = 0.5 * min(size.x, size.y);
        float2 q = (px - size * 0.5) / unit;
        q.y = -q.y;
        float r = length(q);
        float theta = atan2(q.x, q.y);
        float m = abs(theta) / M_PI_F;                  // 0 at the top, 1 at the bottom
        float fi = m * float(n);
        int i = clamp(int(fi), 0, n - 1);
        float within = fract(fi);
        float inner = 0.34 + 0.025 * u.g.y;
        float reach = 0.56;
        float barPx = max(1.0, r * M_PI_F / float(n) * unit);
        float edge = 1.0 / barPx;
        float gap = 0.28;
        float inside = smoothstep(gap * 0.5 - edge, gap * 0.5 + edge, within) * smoothstep(gap * 0.5 - edge, gap * 0.5 + edge, 1 - within);
        float h = bands[i];
        float y = (r - inner) / reach;                  // 0 at the circle, 1 at full height
        float aa = 1.0 / (reach * unit);
        float fill = smoothstep(h + aa, h - aa, y) * smoothstep(-aa, aa, y);
        float3 barCol = ramp(u, 0.35 + 0.65 * saturate(y)) * (0.75 + 0.4 * h);
        barCol += u.stops[3].rgb * exp(-abs(y - h) * reach * unit / (3 * pt)) * step(y, h + aa) * 0.3;
        col = mix(col, barCol, fill * inside);
        col += ramp(u, 0.6 + 0.4 * h) * exp(-max(0.0, y - h) * reach * unit / (16 * pt)) * 0.12 * h * inside * step(0.0, y);
        if (caps) {
            float p = peaks[i];
            float cap = 1 - smoothstep(1.0 * pt, 2.0 * pt, abs((y - p) * reach * unit - 1.5 * pt));
            col = mix(col, mix(u.stops[3].rgb, float3(1), 0.25), cap * inside * step(0.004, p) * step(0.0, y));
        }
        // A faint reflection of each bar inside the ring.
        if (y < 0) {
            float depth = -y * reach * unit;
            float rfl = smoothstep(h * reach * unit * 0.4 + 1, h * reach * unit * 0.4 - 1, depth);
            col += ramp(u, 0.4) * rfl * inside * 0.12 * exp(-depth / (12 * pt));
        }
        // The album (or the theme's colours), a little larger on the beat.
        float discR = inner - 0.03;
        float ring = 1 - smoothstep(0.0, 1.5 / unit, abs(r - (discR + 0.008)));
        col = mix(col, u.stops[2].rgb * (0.8 + 0.4 * pulse * signal), ring * 0.9);
        if (r < discR + 1.0 / unit) {
            float coverage = 1 - smoothstep(discR - 1.0 / unit, discR + 1.0 / unit, r);
            float zoom = 1 - 0.03 * pulse * signal;
            float3 disc;
            if (u.e.y > 0.5) {
                float2 auv = float2(q.x, -q.y) * zoom / (2 * discR) + 0.5;
                disc = art.sample(linearClamp, auv).rgb;
            } else {
                disc = mix(u.stops[1].rgb, u.stops[2].rgb, saturate(0.5 + 0.5 * q.y / discR)) * 0.8;
            }
            disc *= 0.82 + 0.18 * smoothstep(discR, discR * 0.5, r);
            col = mix(col, disc, coverage);
        }
        col += u.stops[2].rgb * exp(-max(0.0, r - inner) / 0.08) * 0.10 * bass * signal * step(discR, r);
    } else {
        // Up and down from a line across the middle: low notes at the centre, high at the edges.
        float margin = 36 * pt;
        float cx = size.x * 0.5, cy = size.y * 0.5;
        float halfWidth = cx - margin;
        float dx = abs(px.x - cx) / halfWidth;
        float maxH = size.y * 0.40;
        float dy = abs(px.y - cy) / maxH;              // 0 on the line, 1 at full height
        if (dx < 1) {
            float fi = dx * float(n);
            int i = clamp(int(fi), 0, n - 1);
            float within = fract(fi);
            float w = halfWidth / float(n);
            float edge = 1.0 / w;
            float gap = clamp(0.2, 1.5 * pt / w, 0.45);
            float inside = smoothstep(gap * 0.5 - edge, gap * 0.5 + edge, within) * smoothstep(gap * 0.5 - edge, gap * 0.5 + edge, 1 - within);
            float h = bands[i];
            float aa = 1.0 / maxH;
            float fill = smoothstep(h + aa, h - aa, dy);
            float below = px.y > cy ? 0.62 : 1.0;      // the lower half a little darker, as if lit from above
            float3 barCol = ramp(u, 0.3 + 0.7 * saturate(dy)) * (0.75 + 0.4 * h) * below;
            barCol += u.stops[3].rgb * exp(-abs(dy - h) * maxH / (3 * pt)) * step(dy, h + aa) * 0.3 * below;
            col = mix(col, barCol, fill * inside);
            col += ramp(u, 0.6 + 0.4 * h) * exp(-max(0.0, dy - h) * maxH / (16 * pt)) * 0.10 * h * inside * below;
            if (caps) {
                float p = peaks[i];
                float cap = 1 - smoothstep(1.0 * pt, 2.0 * pt, abs((dy - p) * maxH - 1.5 * pt));
                col = mix(col, mix(u.stops[3].rgb, float3(1), 0.25) * below, cap * inside * step(0.004, p));
            }
        }
        // The line itself, glowing with the bass.
        float lineD = abs(px.y - cy);
        col += u.stops[2].rgb * (1 - smoothstep(0.5 * pt, 1.5 * pt, lineD)) * 0.5 * step(dx, 1.0);
        col += u.stops[2].rgb * exp(-lineD / (30 * pt)) * 0.08 * (0.3 + bass * signal) * (1 - smoothstep(0.6, 1.0, dx));
    }
    col += u.stops[2].rgb * pulse * 0.025 * signal;
    float4 ov = overlay.sample(linearClamp, in.uv);
    return overlayOver(col + dither(px), ov);
}
"""#
}
