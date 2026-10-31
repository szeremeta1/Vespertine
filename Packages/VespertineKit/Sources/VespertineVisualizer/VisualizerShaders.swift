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
    float4 f;        // laser angle, platter speed 0…1, hue drift, unused
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
    if (showArm) {
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
    float laserAngle = u.f.x;
    const int beams = 10;
    for (int i = 0; i < beams; i++) {
        float a = laserAngle * (i % 2 == 0 ? 1.0 : -0.7) + float(i) * (2 * M_PI_F / float(beams));
        float diff = fmod(theta - a + 3 * M_PI_F, 2 * M_PI_F) - M_PI_F;
        float d = abs(diff) * r;
        float width = 0.004 + 0.004 * r;
        float beam = exp(-pow(d / width, 2.0)) * smoothstep(0.08, 0.3, r) * exp(-r * 0.6);
        float flicker = 0.55 + 0.45 * sin(time * 17.0 + float(i) * 2.1);
        float3 c = i % 2 == 0 ? u.stops[2].rgb : u.stops[3].rgb;
        col += c * beam * (0.25 + 1.6 * treble) * flicker * signal;
        col += c * exp(-d / (0.06 + 0.1 * treble)) * 0.035 * treble * signal * smoothstep(0.1, 0.4, r);
    }

    // Rings sent out by each beat.
    for (int i = 0; i < 16; i++) {
        float4 ring = u.rings[i];
        if (ring.y <= 0.001) continue;
        float d = abs(r - ring.x);
        float shape = exp(-pow(d / ring.z, 2.0));
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
"""#
}
