//
// Vespertine: the visualizer's Metal shaders. Compiled from source when the first window opens, so the package
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
    float4 f;        // laser angle, platter speed 0…1, Album Art ramp weight 0…1, beat rings in use
    float4 g;        // per style (scope, meters, particles, mirrored bars): see each
    float4 h;
    float4 k;
    float4 stops[4]; // the theme, dark to bright
    float4 rings[16];// club: radius, strength, width, colour index
    float4 palette[6]; // Album Art: the cover's colours, dark to bright, six along the gradients
    float4 m[24];    // the meter designs (VisualizerMeterShaders): see there
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
    t = saturate(t);
    float s = t * 3;
    int i = min(int(s), 2);
    float3 base = mix(u.stops[i].rgb, u.stops[i + 1].rgb, s - float(i));
    if (u.f.z <= 0) return base;
    // Album Art: the gradient runs through all of the cover's colours.
    float p = t * 5;
    int j = min(int(p), 4);
    return mix(base, mix(u.palette[j].rgb, u.palette[j + 1].rgb, p - float(j)), u.f.z);
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
// Spectrum's Smooth mode is the same function specialized (a function constant), so Classic and No Peaks compile
// without it.
constant bool smoothBars [[function_constant(0)]];

static float boxDistance(float2 p, float2 halfSize, float radius);

// A Catmull-Rom curve through p1 and p2 (t 0…1 between them), and its slope.
static float2 catmullRom(float p0, float p1, float p2, float p3, float t) {
    float a = -p0 + 3 * p1 - 3 * p2 + p3, b = 2 * p0 - 5 * p1 + 4 * p2 - p3, c = -p0 + p2;
    return 0.5 * float2(((a * t + b) * t + c) * t + 2 * p1, (3 * a * t + 2 * b) * t + c);
}

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
        bool smoothMode = smoothBars;
        float fill = smoothstep(h + topEdge, h - topEdge, y) * step(0.0, y);
        float bar = fill * inside;
        float curve = 0;
        if (smoothMode) {
            // Smooth: the bar's top is rounded (as round as it is wide, once it's that tall), and a curve through the
            // tops of all the bars, with a soft veil under it, joins them into one shape.
            float hw = 0.5 * (1 - gap) * w;
            float cx = lo.x + (float(i) + 0.5) * w;
            float topPx = hi.y - h * plotH;
            float2 c = float2(cx, (topPx + hi.y + hw) * 0.5);
            float d = boxDistance(px - c, float2(hw, (hi.y + hw - topPx) * 0.5), min(hw, h * plotH));
            bar = (1 - smoothstep(-0.7, 0.7, d)) * step(0.0, y) * step(0.5, h * plotH);
            float fc = fx - 0.5;
            int j = int(floor(fc));
            float2 cr = catmullRom(bands[clamp(j - 1, 0, n - 1)], bands[clamp(j, 0, n - 1)], bands[clamp(j + 1, 0, n - 1)],
                                   bands[clamp(j + 2, 0, n - 1)], fc - floor(fc));
            curve = max(cr.x, 0.0);
            float slope = cr.y * plotH / w;                 // px per px
            float dy = (y - curve) * plotH / sqrt(1 + slope * slope);
            float shown = smoothstep(0.004, 0.04, curve) * step(0.0, y);
            float veil = smoothstep(curve + topEdge, curve - topEdge, y) * (1 - bar);
            col += ramp(u, 0.35 + 0.5 * saturate(y)) * veil * 0.13 * shown;
            col += ramp(u, 0.8 + 0.2 * curve) * (exp(-dy * dy / (2.2 * pt * pt)) * 0.55 + exp(-abs(dy) / (9 * pt)) * 0.12) * shown;
        }
        float3 barCol = ramp(u, 0.3 + 0.7 * saturate(y)) * (0.75 + 0.35 * h);
        // A brighter rim at the top of the bar.
        float rim = exp(-abs(y - h) * plotH / (3 * pt)) * step(y, h + topEdge);
        barCol += u.stops[3].rgb * rim * (smoothMode ? 0.2 : 0.35);
        col = mix(col, barCol, bar);
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
            col += ramp(u, 0.4) * r * inside * 0.16 * exp(-depth / (18 * pt)) * (smoothMode ? step(0.5, h * plotH) : 1.0);
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

// The album's sleeve, beside the record (record units, y up): its centre `centreX` along from the record's (level with
// it) and turned `tilt` anticlockwise. As in MD Vinyl: a square card a touch larger than the record, with slightly
// rounded corners and a soft shadow that falls mostly straight down.
struct Sleeve {
    float coverage;
    float3 colour;
    float shadow;   // the shadow it casts, a little down and to the right
};

static Sleeve sleeve(float2 q, float aa, float centreX, float tilt, constant U &u, texture2d<float> art) {
    const float halfSize = 0.883;
    const float2 shadowAt = float2(0.008, -0.035);
    Sleeve s = {0, float3(0), 0};
    // Past the sleeve (turned, its corners reach a little further) and its shadow.
    float2 w = q - float2(centreX, 0);
    if (any(abs(w - shadowAt) > halfSize * (cos(tilt) + abs(sin(tilt))) + 0.14)) return s;
    float2 sq = rotate(w, -tilt);                  // the sleeve's own frame
    float d = boxDistance(sq, float2(halfSize), 0.017);
    s.coverage = 1 - smoothstep(-aa, aa, d);
    s.shadow = (1 - smoothstep(-0.06, 0.10, boxDistance(rotate(w - shadowAt, -tilt), float2(halfSize), 0.03))) * 0.45;
    float2 lq = sq / halfSize;
    float3 c;
    if (u.e.y > 0.5) {
        c = art.sample(linearClamp, float2(sq.x, -sq.y) / (2 * halfSize) + 0.5).rgb;
    } else {
        // No cover: the theme's colours, printed with a ring.
        c = mix(u.stops[1].rgb, u.stops[2].rgb, saturate(0.5 + 0.5 * lq.y)) * 0.85;
        c *= 0.85 + 0.15 * (1 - smoothstep(0.012, 0.03, abs(length(lq) - 0.55)));
    }
    // Ring wear: the record inside has rubbed a faint circle into the card.
    c *= 1 + 0.10 * (1 - smoothstep(0.0, 0.035, abs(length(sq) - 0.82))) * smoothstep(0.75, 0.9, length(sq) / 0.86);
    // Card: lit from the top left, a broad soft gloss across it, and its edge catching the light.
    c *= 0.92 + 0.08 * saturate(0.5 - 0.35 * lq.x + 0.35 * lq.y);
    c += float3(0.05) * pow(saturate(1 - abs(lq.x * 0.7 + lq.y + 0.25) * 1.6), 3.0);
    c = mix(c, c * 0.6 + 0.25, (1 - smoothstep(0.0, 0.006, -d)) * 0.5);
    s.colour = c;
    return s;
}

fragment float4 vz_vinyl(VOut in [[stage_in]], constant U &u [[buffer(0)]], constant float *fine [[buffer(3)]],
                         texture2d<float> art [[texture(2)]], texture2d<float> overlay [[texture(0)]]) {
    // g: the record's centre (px, y down), px per unit; h: the sleeve's centre (x, record units), in front 0 or 1,
    // opacity 0…1, its turn (radians, anticlockwise)
    float2 size = u.a.xy;
    float unit = max(u.g.z, 1.0);
    bool showArm = u.c.w > 0.5;
    float2 centre = u.g.xy;
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

    // The sleeve, when it's behind the record: over the platter, under the record, which casts its shadow on it.
    float sleeveOpacity = u.h.z, sleeveFront = u.h.y;
    Sleeve sl = {0, float3(0), 0};
    if (sleeveOpacity > 0.001) {
        sl = sleeve(q, aa, u.h.x, u.h.w, u, art);
        float behind = sleeveOpacity * (1 - sleeveFront);
        if (behind > 0) {
            col *= 1 - sl.shadow * behind;
            // In the record's shade, a little darker than in front.
            col = mix(col, sl.colour * 0.92, sl.coverage * behind);
            // The record's own shadow on it: soft, all round its edge, a little more below.
            float recordShadow = 1 - smoothstep(recordR - 0.02, recordR + 0.09, length(q - float2(0.004, -0.022)));
            col *= 1 - 0.5 * recordShadow * sl.coverage * behind;
        }
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

    // The sleeve in front: the record is half out of it.
    float inFront = sleeveOpacity * sleeveFront;
    if (inFront > 0.001) {
        col *= 1 - sl.shadow * inFront;
        col = mix(col, sl.colour, sl.coverage * inFront);
    }

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

// The beat strobe: the whole window toward white, up to 85 % of the way, over everything else (after the picture's
// own roll-off, so a flash is as bright in a dark scene as in a bright one). `u.e.z` is 0 unless the strobe is switched
// on, its warning accepted, and neither Reduce Motion nor Dim Flashing Lights is on (the renderer sees to that).
static float3 strobed(float3 col, constant U &u) {
    return mix(col, float3(1), saturate(u.e.z) * 0.85);
}

// Classic.
// g: the beat's punch (0 at rest, about 1 on a hard beat, springing back), unused, the tunnel's run (0…1), the
//    colours' turn (0…1, a step on every beat)
// h: sudden sounds in the lows, mids and highs (0…1 each)
// f.x: the lasers' angle; rings[]: the rings each beat sends out (radius, strength, width, colour)

static float fbm2(float2 p) { return 0.65 * noise(p) + 0.35 * noise(p * 2.03 + float2(1.7, 9.2)); }

// The spectrum round the whole circle: lows at the top, mirrored left and right, up to about 9 kHz at the bottom
// (above that music has too little for the ring to close).
static float circularFull(constant float *fine, int count, float angle) {
    float m = abs(angle) / M_PI_F;                  // 0 at the top, 1 at the bottom
    float f = (0.03 + 0.85 * m) * float(count - 1);
    int i = int(f);
    return mix(fine[i], fine[min(i + 1, count - 1)], f - float(i));
}

// A colour from the theme's brighter half, `t` round it (it wraps).
static float3 clubColour(constant U &u, float t) {
    float x = fract(t);
    return ramp(u, 0.5 + 0.5 * (x < 0.5 ? x * 2 : 2 - x * 2));
}

fragment float4 vz_club(VOut in [[stage_in]], constant U &u [[buffer(0)]], constant float *fine [[buffer(3)]],
                        texture2d<float> overlay [[texture(0)]]) {
    float2 size = u.a.xy;
    float unit = 0.5 * min(size.x, size.y);
    float2 px = in.uv * size;
    float punch = u.g.x, kick = max(punch, 0.0);
    // The whole room comes a little nearer on a beat.
    float2 q = (px - size * 0.5) / unit / (1 + 0.045 * punch);
    q.y = -q.y;
    float r = length(q);
    float theta = atan2(q.x, q.y);                 // 0 at the top, clockwise
    float time = u.a.z;
    float bass = u.b.x, mid = u.b.y, treble = u.b.z, pulse = u.b.w;
    float signal = u.e.w;
    float turn = u.g.w;
    float3 hits = u.h.xyz;
    int fineCount = int(u.d.y);

    // Haze, drifting, lit from the middle by the bass.
    float fog = fbm2(q * 1.4 + float2(time * 0.03, -time * 0.02));
    float3 col = u.stops[0].rgb * (0.30 + 0.30 * fog);
    col += clubColour(u, turn + 0.5) * exp(-r * 1.7) * (0.05 + 0.22 * bass * signal + 0.25 * kick) * (0.6 + 0.8 * fog);

    // The ring of the spectrum, and where it starts: round the core, pushed out by the bass and the punch.
    float base = 0.25 + 0.03 * bass * signal + 0.05 * punch;
    float spec = circularFull(fine, fineCount, theta) * signal;
    float loud = spec * spec;

    // Rays: each part of the spectrum thrown out across the room as light, as far as it is loud.
    float streak = 0.55 + 0.45 * noise(float2(theta * 28.0, 3.0 + floor(time * 0.5) * 0.0));
    float rays = loud * exp(-max(r - base, 0.0) / (0.12 + 1.1 * spec)) * smoothstep(base - 0.02, base + 0.12, r);
    col += ramp(u, 0.4 + 0.6 * spec) * rays * streak * 0.5;

    // The tunnel: rings of light running outward, a surge after every beat.
    float run = fract(log(max(r, 0.05)) * 1.5 - u.g.z);
    float tunnel = exp(-pow((run - 0.5) / 0.045, 2.0)) * smoothstep(0.35, 0.9, r);
    col += clubColour(u, turn + 0.25) * tunnel * (0.03 + 0.10 * mid * signal + 0.10 * kick);

    // Lasers: two fans of six beams from the middle, turning opposite ways. Each beam is lit by its own part of the
    // spectrum, so they flash one by one with the music, and all of them with a hit in the highs. Only the nearest
    // beam of a fan can light a pixel, so a fan is one evaluation.
    float laserAngle = u.f.x;
    const float spacing = 2 * M_PI_F / 6;
    float reach = smoothstep(base * 0.6, base + 0.15, r) * exp(-r * 0.45);
    for (int fan = 0; fan < 2; fan++) {
        float a0 = fan == 0 ? laserAngle : -0.8 * laserAngle + spacing * 0.5;
        float rel = theta - a0;
        float index = floor(rel / spacing + 0.5);
        float d = abs(rel - index * spacing) * r;
        float which = fract((index + 6.0 + float(fan) * 0.5) * 0.381966);          // the beam's own place in the spectrum
        int bin = clamp(int((0.25 + 0.6 * which) * float(fineCount - 1)), 0, fineCount - 1);
        float level = fine[bin] * signal;
        float lit = 0.10 + 1.5 * level * level + 0.9 * hits.z + 0.3 * treble * signal;
        float width = (0.0035 + 0.005 * r) * (1 + 0.6 * kick);
        float x = d / width;
        float3 c = clubColour(u, turn + which * 0.5 + float(fan) * 0.33);
        col += c * (exp(-x * x) * lit + exp(-d / 0.05) * 0.10 * lit * (0.5 + fog)) * reach * (0.35 + 0.65 * signal);
    }

    // The rings each beat sends out.
    int ringCount = min(int(u.f.w), 16);
    for (int i = 0; i < ringCount; i++) {
        float4 ring = u.rings[i];
        float d = abs(r - ring.x);
        if (d > ring.z * 30) continue;      // too far for its halo to show
        float x = d / ring.z;
        col += ramp(u, ring.w) * (exp(-x * x) * 1.2 + exp(-d / (ring.z * 6)) * 0.3) * ring.y;
    }

    // The spectrum itself: 96 bars round the ring, their tips bright.
    float cell = fract(theta / (2 * M_PI_F) * 96);
    float barMask = smoothstep(0.42, 0.22, abs(cell - 0.5));
    float outer = base + 0.01 + spec * 0.40;
    float bar = smoothstep(base - 0.004, base + 0.002, r) * (1 - smoothstep(outer - 0.004, outer + 0.004, r)) * barMask;
    float tip = exp(-abs(r - outer) / 0.012) * step(r, outer + 0.004);
    col += (ramp(u, 0.45 + 0.55 * spec) * (0.55 + 0.75 * spec) + u.stops[3].rgb * tip * 0.5) * bar;
    col += ramp(u, 0.75) * exp(-max(r - outer, 0.0) / 0.035) * step(outer, r) * loud * 0.28;

    // The core: a speaker of light. It swells with the bass and jumps with the punch; rings run out across it.
    float core = base - 0.045;
    float orb = 1 - smoothstep(core - 0.006, core + 0.006, r);
    float cone = 0.5 + 0.5 * cos((r / max(core, 0.01)) * 9.0 - time * 3.0 - 7.0 * kick);
    float3 coreCol = mix(clubColour(u, turn), float3(1), 0.25 + 0.45 * saturate(kick) + 0.2 * hits.x);
    coreCol *= 0.55 + 0.45 * (1 - r / max(core, 0.01)) + 0.18 * cone * (0.3 + bass * signal);
    col = mix(col, coreCol * (0.45 + 0.55 * signal) * (0.75 + 0.5 * bass * signal + 0.4 * kick), orb);
    float glow = exp(-max(0.0, r - core) / (0.04 + 0.10 * bass * signal + 0.10 * kick));
    col += clubColour(u, turn) * glow * (0.12 + 0.45 * bass * signal + 0.5 * kick) * (1 - orb) * (0.4 + 0.6 * signal);

    // What is lit is a little brighter on the beat (the dark stays dark: this is not the strobe).
    col *= 1 + 0.15 * pulse * signal;
    col *= 1 - 0.3 * pow(length(in.uv - 0.5) * 1.2, 2.0);
    col = col / (1 + max(max(col.r, col.g), col.b) * 0.25);   // soft roll-off instead of clipping
    col = strobed(col, u);
    float4 ov = overlay.sample(linearClamp, in.uv);
    return overlayOver(col + dither(px), ov);
}
// MARK: Club: Waves
// g: calm (Reduce Motion) 0/1, ripple phase (radians), sway clock (s), ripple size (units of half the window's height)
// h: the three ribbons' sizes (lows, mids, highs; 0…1), the beat's punch
// k: the three ribbons' travel (radians)
// rings[0…14]: the beams, worked out on the CPU each frame: aim (radians from straight up, clockwise), ripple
// wavenumber, ripple phase at the emitter, level 0…1 (its part of the spectrum). Seven from the floor in the middle,
// four from each top corner.

static float3 beamFan(float2 v, int first, int count, float amp, float haze, constant U &u) {
    float3 light = float3(0);
    float rho = length(v);
    if (rho < 0.005) return light;
    float theta = atan2(v.x, v.y);
    float near = smoothstep(0.0, 0.1, rho) * exp(-rho * 0.4);
    float grow = smoothstep(0.0, 0.7, rho);
    float treble = u.b.z, sway = u.g.z;
    float glowWidth = 0.025 + 0.03 * treble;
    float coreWidth = 0.0025 + 0.004 * rho;
    for (int i = first; i < first + count; i++) {
        float4 beam = u.rings[i];
        float da = theta - beam.x;
        da -= 2 * M_PI_F * floor(da / (2 * M_PI_F) + 0.5);
        if (abs(da) > 1.4) continue;                         // behind the emitter, or far round
        // A beam ripples more the louder its own part of the spectrum is.
        float size = amp * (0.45 + 1.1 * beam.w);
        float across = rho * sin(da);
        if (abs(across) > size + 7 * glowWidth) continue;    // too far for even its glow (under 0.1 %)
        float phase = beam.y * rho + beam.z;
        float lateral = size * sin(phase) * grow;
        float slope = size * beam.y * cos(phase) * grow;
        float d = abs(across - lateral) * rsqrt(1 + slope * slope);
        float x = d / coreWidth;
        float3 c = ramp(u, 0.62 + 0.36 * sin(float(i) * 2.3 + sway * 0.35));
        light += c * (exp(-x * x) * (0.40 + 1.4 * beam.w * beam.w) + exp(-d / glowWidth) * haze * (0.05 + 0.3 * beam.w));
    }
    return light * near;
}

// A ribbon of light across the room: a wave of two sines travelling at unrelated speeds, largest in the middle of the
// window, a bright line with a glow and a veil hanging under it.
static float3 ribbon(float2 q, float halfW, float y0, float size, float phase, float k, float3 colour, float haze) {
    float taper = 0.35 + 0.65 * smoothstep(halfW + 0.1, halfW * 0.15, abs(q.x));
    float a1 = q.x * k - phase, a2 = q.x * k * 2.3 + phase * 1.7 + 1.3;
    float y = y0 + size * taper * (0.68 * sin(a1) + 0.32 * sin(a2));
    float slope = size * taper * k * (0.68 * cos(a1) + 0.32 * 2.3 * cos(a2));
    float below = y - q.y;
    float d = abs(below) * rsqrt(1 + slope * slope);
    float line = exp(-d * d / 0.00006) * 0.9 + exp(-d / 0.035) * 0.20 * haze;
    float veil = step(0.0, below) * exp(-below / (0.10 + 0.5 * size)) * 0.10 * haze;
    return colour * (line + veil);
}

fragment float4 vz_club_waves(VOut in [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> overlay [[texture(0)]]) {
    float2 size = u.a.xy;
    float unit = 0.5 * min(size.x, size.y);
    float2 px = in.uv * size;
    float2 q = (px - size * 0.5) / unit;
    q.y = -q.y;
    float halfW = 0.5 * size.x / unit, halfH = 0.5 * size.y / unit;
    float bass = u.b.x, pulse = u.b.w;
    float signal = u.e.w;
    float calm = u.g.x;
    float sway = u.g.z;
    float amp = u.g.w;
    float kick = max(u.h.w, 0.0);

    // Haze drifting slowly through the room (round a wide circle, so it repeats with the clock); the beams light it.
    float drift = sway * 0.35 / 30;
    float fog = fbm2(q * 1.2 + 30 * float2(cos(drift), 0.63 * sin(drift)));
    float haze = 0.35 + 1.1 * fog * fog;
    float3 col = u.stops[0].rgb * (0.30 + 0.35 * fog);

    // From the floor in the middle, fanning up; from the top corners, crossing down.
    float2 floorAt = float2(0, -halfH - 0.05);
    float3 light = beamFan(q - floorAt, 0, 7, amp, haze, u);
    light += beamFan(q - float2(-halfW + 0.15, halfH + 0.05), 7, 4, amp, haze, u);
    light += beamFan(q - float2(halfW - 0.15, halfH + 0.05), 11, 4, amp, haze, u);

    // Three ribbons across the room, one each for the lows, the mids and the highs: each as tall as its part of the
    // music is loud, jumping with that part's hits and running faster the louder it is. At rest they are nearly
    // level lines.
    float3 sizes = (0.012 + u.h.xyz * float3(0.40, 0.25, 0.13)) * halfH;
    float fade = 0.35 + 0.65 * signal;
    light += ribbon(q, halfW, -0.22 * halfH, sizes.x, u.k.x, 2.1, ramp(u, 0.62), haze) * (0.45 + 0.9 * u.h.x) * fade;
    light += ribbon(q, halfW, 0.18 * halfH, sizes.y, u.k.y, 4.4, ramp(u, 0.80), haze) * (0.40 + 0.9 * u.h.y) * fade;
    light += ribbon(q, halfW, 0.52 * halfH, sizes.z, u.k.z, 9.0, ramp(u, 0.97), haze) * (0.35 + 0.9 * u.h.z) * fade;

    // Paused or silent, the beams rest faintly where they are (as Classic keeps its core), so the window isn't black.
    col += light * (0.7 + 0.45 * bass + 0.3 * pulse * (1 - calm)) * (0.4 + 0.6 * signal);
    // The emitter on the floor glows with the bass and jumps with the beat.
    col += ramp(u, 0.6) * exp(-length(q - floorAt) * 2.2) * (0.15 + 0.6 * bass + 0.5 * kick) * (0.35 + 0.65 * signal);

    col *= 1 - 0.3 * pow(length(in.uv - 0.5) * 1.2, 2.0);
    col = col / (1 + max(max(col.r, col.g), col.b) * 0.25);
    col = strobed(col, u);
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
// h: the bass (how hard the field is drawn in), the beat's punch, sudden sounds in the highs (sparkle), unused
// rings[]: the rings each beat sends out (radius, strength, width, colour), f.w of them

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

// How hard the beats' rings push at a distance `r` from the middle (each is a wave front `width` wide).
static float shock(constant U &u, float r, float width) {
    float k = 0;
    int count = min(int(u.f.w), 16);
    for (int i = 0; i < count; i++) {
        float d = (r - u.rings[i].x) / width;
        // A ring spends itself as it spreads.
        k += exp(-d * d) * u.rings[i].y * exp(-u.rings[i].x * 1.3);
    }
    return k;
}

kernel void vz_particles_step(device Particle *particles [[buffer(0)]], constant U &u [[buffer(1)]],
                              uint id [[thread_position_in_grid]]) {
    if (id >= uint(u.g.w)) return;
    Particle p = particles[id];
    float dt = u.g.x, aspect = u.g.y, calm = u.g.z;
    float time = u.a.z;
    float mid = u.b.y;
    float signal = u.e.w;
    float pull = u.h.x, sparkle = u.h.z;
    float2 x = p.pv.xy, v = p.pv.zw;
    float r = length(x);
    float2 dir = r > 1e-4 ? x / r : float2(0, 1);
    // A flow that turns slowly on its own, faster with the mids. It's the curl of a noise field, so it neither
    // gathers the particles into lines nor thins them out; the whole field also swirls gently.
    float2 flow = curl(x * 0.9 + float2(time * 0.045, -time * 0.03)) + 0.5 * curl(x * 2.2 - time * 0.08);
    float2 target = flow * (0.05 + 0.34 * mid * signal) * (1 - 0.6 * calm);
    target += float2(-dir.y, dir.x) * 0.06 * min(r, 1.0);
    // Between beats the bass draws the field back toward the middle (so it breathes, and the beats' bursts don't
    // empty it).
    target -= dir * min(r, 1.2) * 0.12 * pull * (1 - calm);
    // Little inertia: heavy particles would be flung out of the eddies and gather in bright seams.
    v += (target - v) * (1 - exp(-dt / 0.08));
    // Each beat is a blast from the middle: its ring carries the particles it passes outward with it (the harder the
    // beat, the further), and lights them. Not with Reduce Motion.
    float heat = p.m.x * exp(-dt / 0.20);
    float2 blast = float2(0);
    if (calm < 0.5) {
        // (Well under the ring's own speed, so it leaves them behind rather than sweeping them into a bright seam.)
        float k = min(shock(u, r, 0.10), 1.0);
        blast = dir * k * 0.5;
        heat = max(heat, k);
    }
    // The highs' hits make a few of them flare: a different few each time.
    float pick = hash21(float2(float(id) * 0.0173 + floor(time * 24.0) * 0.37, p.m.z));
    if (pick > 1 - 0.035 * sparkle) heat = max(heat, 0.75);
    x += (v + blast) * dt;
    float life = p.m.y - dt;
    // Gone past the window's edges (its half width and height in the field's units, a unit being half its shorter
    // side: so a tall window is taller than 1, not narrower).
    float2 halfSize = float2(max(aspect, 1.0), max(1.0 / max(aspect, 1e-3), 1.0));
    if (life <= 0 || abs(x.x) > halfSize.x + 0.15 || abs(x.y) > halfSize.y + 0.15) {
        // Born again somewhere in the disc.
        float h1 = hash21(float2(float(id) * 0.0131, fract(time * 0.173) * 97.0 + p.m.z));
        float h2 = hash21(float2(fract(time * 0.371) * 53.0 + p.m.z, float(id) * 0.0713));
        float h3 = hash21(float2(h1 * 91.7, h2 * 37.3));
        float a = h1 * 2 * M_PI_F;
        float2 out = float2(cos(a), sin(a));
        // (A little denser toward the middle, which the beats keep emptying.)
        x = out * 1.5 * pow(h2, 0.72);
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
    float calm = u.g.z, signal = u.e.w;
    float kick = max(u.h.y, 0.0);
    // The whole field jumps outward with the beat's punch and settles back (drawn only: the motion itself isn't
    // disturbed), and swells a little with the bass.
    float breath = 1 + (0.05 * u.b.x * signal + 0.09 * u.h.y) * (1 - calm);
    float r = length(p.pv.xy);
    float2 at = p.pv.xy * breath;
    float2 px = size * 0.5 + float2(at.x, -at.y) * unit;
    float speed = length(p.pv.zw);
    float heat = p.m.x;
    float fade = smoothstep(0.0, 0.8, p.m.y) * smoothstep(0.0, 0.6, p.m.w - p.m.y);
    float seed = fract(p.m.z * 0.6180339);
    float radius = (0.6 + 0.6 * seed + 1.3 * heat + 0.5 * u.b.z * signal + 0.4 * kick) * pt;
    float2 corner = quadCorners[vid] * float2(2, 1) - float2(1, 0);   // -1…1 both ways
    float2 pos = px + corner * radius * 2.5;
    SpriteOut o;
    o.position = float4(pos.x / size.x * 2 - 1, 1 - pos.y / size.y * 2, 0, 1);
    o.q = corner * 2.5;
    float t = saturate(0.25 + 0.5 * seed + speed * 0.5 + heat * 0.45);
    // Brightest in the middle, fading out towards the edges, so the field has no rim.
    float falloff = exp(-r * r * 0.8);
    // Dim between the beats, so that a beat's flare is seen: the field's own light follows how loud the music is.
    float own = 0.012 + 0.025 * u.c.x * signal + 0.07 * speed + 0.04 * kick;
    o.colour = ramp(u, t) * (own + 0.5 * heat) * fade * falloff * (0.4 + 0.6 * signal);
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
    float signal = u.e.w, kick = max(u.h.y, 0.0);
    float3 col = u.stops[0].rgb * (0.25 + 0.3 * exp(-r * 1.4));
    // A glow in the middle: the bass, and the beat's burst.
    col += u.stops[1].rgb * exp(-r * 2.0) * (0.10 * u.b.x + 0.16 * kick) * signal;
    col += u.stops[2].rgb * exp(-r * r * 22.0) * 0.35 * kick * signal;
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
