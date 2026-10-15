//
// Vespertine — room measurement: sweep, deconvolution, frequency response and peaking-filter fit.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// None of this runs on the I/O thread: it allocates freely and takes as long as it takes (a second or so for a
// recording of several sweeps).
//

#include "CVespertineMeasure.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// MARK: - FFT

static size_t next_pow2(size_t n) {
    size_t p = 1;
    while (p < n) p <<= 1;
    return p;
}

// In-place radix-2 complex FFT of n points (a power of 2): forward e^(−iωt), inverse e^(+iωt), unscaled.
static bool fft(double *re, double *im, size_t n, bool inverse) {
    if (n < 2) return true;
    double *c = malloc(n / 2 * sizeof(double)), *s = malloc(n / 2 * sizeof(double));
    if (!c || !s) { free(c); free(s); return false; }
    for (size_t k = 0; k < n / 2; k++) { c[k] = cos(2 * M_PI * (double)k / (double)n); s[k] = sin(2 * M_PI * (double)k / (double)n); }
    for (size_t i = 1, j = 0; i < n; i++) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j |= bit;
        if (i < j) { double t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; }
    }
    for (size_t len = 2; len <= n; len <<= 1) {
        const size_t half = len / 2, stride = n / len;
        for (size_t i = 0; i < n; i += len) {
            for (size_t k = 0; k < half; k++) {
                const double wr = c[k * stride], wi = inverse ? s[k * stride] : -s[k * stride];
                const size_t a = i + k, b = a + half;
                const double tr = re[b] * wr - im[b] * wi, ti = re[b] * wi + im[b] * wr;
                re[b] = re[a] - tr; im[b] = im[a] - ti;
                re[a] += tr; im[a] += ti;
            }
        }
    }
    free(c); free(s);
    return true;
}

// MARK: - Sweep and impulse response

void nrt_sweep_generate(float *out, size_t frames, double rate, double f1, double f2, double fadeSeconds) {
    if (frames == 0 || rate <= 0 || f1 <= 0 || f2 <= f1) return;
    const double seconds = (double)frames / rate, k = log(f2 / f1), fade = fadeSeconds * rate;
    for (size_t i = 0; i < frames; i++) {
        const double t = (double)i / rate;
        double v = sin(2 * M_PI * f1 * seconds / k * (exp(t * k / seconds) - 1));
        const double fromStart = (double)i, fromEnd = (double)(frames - 1 - i);
        if (fade > 0 && fromStart < fade) v *= 0.5 - 0.5 * cos(M_PI * fromStart / fade);
        if (fade > 0 && fromEnd < fade) v *= 0.5 - 0.5 * cos(M_PI * fromEnd / fade);
        out[i] = (float)v;
    }
}

// How strongly the deconvolution is held back at `f`: barely in the swept band, fully half an octave outside it.
static double regularisation(double f, double f1, double f2) {
    const double inside = 1e-6, outside = 1.0;
    const double below = log2(f1 / f), above = log2(f / f2);   // octaves outside, if positive
    const double out = below > above ? below : above;
    if (out <= 0) return inside;
    if (out >= 0.5) return outside;
    const double w = 0.5 - 0.5 * cos(M_PI * out / 0.5);
    return inside + (outside - inside) * w;
}

bool nrt_measure_impulse(const float *recorded, size_t recordedFrames, const float *sweep, size_t sweepFrames,
                         double rate, double f1, double f2, float *impulse, size_t impulseFrames) {
    if (recordedFrames == 0 || sweepFrames == 0 || rate <= 0) return false;
    const size_t n = next_pow2(recordedFrames + sweepFrames);
    double *xr = calloc(n, sizeof(double)), *xi = calloc(n, sizeof(double));
    double *yr = calloc(n, sizeof(double)), *yi = calloc(n, sizeof(double));
    bool ok = xr && xi && yr && yi;
    if (ok) {
        for (size_t i = 0; i < sweepFrames; i++) xr[i] = sweep[i];
        for (size_t i = 0; i < recordedFrames; i++) yr[i] = recorded[i];
        ok = fft(xr, xi, n, false) && fft(yr, yi, n, false);
    }
    if (ok) {
        double peak = 0;
        for (size_t k = 0; k <= n / 2; k++) { const double p = xr[k] * xr[k] + xi[k] * xi[k]; if (p > peak) peak = p; }
        for (size_t k = 0; k < n; k++) {
            const size_t bin = k <= n / 2 ? k : n - k;
            const double f = (double)bin * rate / (double)n;
            const double eps = peak * regularisation(f > 0 ? f : 1e-3, f1, f2);
            const double p = xr[k] * xr[k] + xi[k] * xi[k] + eps;
            // H = Y · conj(X) / (|X|² + ε)
            const double hr = (yr[k] * xr[k] + yi[k] * xi[k]) / p, hi = (yi[k] * xr[k] - yr[k] * xi[k]) / p;
            yr[k] = hr; yi[k] = hi;
        }
        ok = fft(yr, yi, n, true);
    }
    if (ok) {
        for (size_t i = 0; i < impulseFrames; i++) impulse[i] = i < n ? (float)(yr[i] / (double)n) : 0.f;
    }
    free(xr); free(xi); free(yr); free(yi);
    return ok;
}

double nrt_impulse_peak(const float *impulse, size_t from, size_t to, float *peakValue) {
    size_t at = from;
    float best = -1;
    for (size_t i = from; i < to; i++) if (fabsf(impulse[i]) > best) { best = fabsf(impulse[i]); at = i; }
    if (peakValue) *peakValue = best < 0 ? 0 : best;
    if (best <= 0 || at == 0 || at + 1 >= to) return (double)at;
    // A parabola through the peak and its neighbours, for a fraction of a sample.
    const double a = fabs((double)impulse[at - 1]), b = fabs((double)impulse[at]), c = fabs((double)impulse[at + 1]);
    const double d = a - 2 * b + c;
    return d == 0 ? (double)at : (double)at + 0.5 * (a - c) / d;
}

// MARK: - Frequency response

bool nrt_response_db(const float *impulse, size_t frames, double rate, const double *frequencies, size_t count,
                     double smoothingOctaves, double *db) {
    if (frames == 0 || rate <= 0) return false;
    const size_t n = next_pow2(frames < 65536 ? 65536 : frames);   // fine bins even for short windows
    double *re = calloc(n, sizeof(double)), *im = calloc(n, sizeof(double)), *sum = calloc(n / 2 + 2, sizeof(double));
    bool ok = re && im && sum;
    if (ok) {
        for (size_t i = 0; i < frames; i++) re[i] = impulse[i];
        ok = fft(re, im, n, false);
    }
    if (ok) {
        // Running sum of power, so any band's average costs two lookups.
        for (size_t k = 0; k <= n / 2; k++) sum[k + 1] = sum[k] + re[k] * re[k] + im[k] * im[k];
        const double binHz = rate / (double)n;
        for (size_t i = 0; i < count; i++) {
            const double f = frequencies[i];
            size_t lo = (size_t)floor(f * pow(2, -smoothingOctaves / 2) / binHz + 0.5);
            size_t hi = (size_t)floor(f * pow(2, smoothingOctaves / 2) / binHz + 0.5);
            if (hi > n / 2) hi = n / 2;
            if (lo > hi) lo = hi;
            const double power = (sum[hi + 1] - sum[lo]) / (double)(hi - lo + 1);
            db[i] = 10 * log10(power > 1e-30 ? power : 1e-30);
        }
    }
    free(re); free(im); free(sum);
    return ok;
}

// MARK: - Peaking filter fit

static double peak_db(const NRTPeakFilter *p, double f, double rate) {
    if (p->gainDB == 0) return 0;
    const double a = pow(10, p->gainDB / 40), w0 = 2 * M_PI * p->frequency / rate, alpha = sin(w0) / (2 * p->q);
    const double cw = cos(w0);
    const double b0 = 1 + alpha * a, b1 = -2 * cw, b2 = 1 - alpha * a;
    const double a0 = 1 + alpha / a, a1 = -2 * cw, a2 = 1 - alpha / a;
    const double w = 2 * M_PI * f / rate, c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w);
    const double nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2);
    const double dr = a0 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2);
    return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di));
}

double nrt_peaks_db(const NRTPeakFilter *filters, uint32_t count, double frequency, double rate) {
    double total = 0;
    for (uint32_t i = 0; i < count; i++) total += peak_db(&filters[i], frequency, rate);
    return total;
}

typedef struct {
    const double *f, *error;     // the points in range, and response − target there before any filter
    size_t count;
    double rate;
    const NRTFitLimits *limits;
    double *others;              // the other filters' sum at each point
} Fit;

// Squared error over the range with filter p added to the others, plus a steep penalty wherever the filters together
// boost more than allowed (filters stacked on one dip would otherwise add up past the limit).
static double fit_cost(Fit *fit, const NRTPeakFilter *p) {
    double cost = 0;
    for (size_t i = 0; i < fit->count; i++) {
        const double filters = fit->others[i] + peak_db(p, fit->f[i], fit->rate);
        const double e = fit->error[i] + filters, over = filters - fit->limits->maxBoostDB;
        cost += e * e;
        if (over > 0) cost += 100 * over * over;
    }
    return cost / (double)fit->count;
}

static void clamp_filter(NRTPeakFilter *p, const NRTFitLimits *l) {
    if (p->frequency < l->low) p->frequency = l->low;
    if (p->frequency > l->high) p->frequency = l->high;
    if (p->gainDB > l->maxBoostDB) p->gainDB = l->maxBoostDB;
    if (p->gainDB < -l->maxCutDB) p->gainDB = -l->maxCutDB;
    if (p->q < l->minQ) p->q = l->minQ;
    if (p->q > l->maxQ) p->q = l->maxQ;
}

// Coordinate descent on one filter's frequency (in octaves), gain and Q (in octaves), the others held.
static double fit_refine(Fit *fit, NRTPeakFilter *p, double cost) {
    double steps[3] = {1.0 / 12, 0.5, 0.25};
    for (int round = 0; round < 200 && (steps[0] > 1e-3 || steps[1] > 0.01 || steps[2] > 1e-3); round++) {
        bool improved = false;
        for (int which = 0; which < 3; which++) {
            for (int sign = -1; sign <= 1; sign += 2) {
                NRTPeakFilter t = *p;
                if (which == 0) t.frequency *= pow(2, sign * steps[0]);
                if (which == 1) t.gainDB += sign * steps[1];
                if (which == 2) t.q *= pow(2, sign * steps[2]);
                clamp_filter(&t, fit->limits);
                const double c = fit_cost(fit, &t);
                if (c < cost - 1e-12) { *p = t; cost = c; improved = true; break; }
            }
        }
        if (!improved) { steps[0] /= 2; steps[1] /= 2; steps[2] /= 2; }
    }
    return cost;
}

uint32_t nrt_fit_peaks(const double *frequencies, const double *db, const double *target, size_t count, double rate,
                       const NRTFitLimits *limits, NRTPeakFilter *out) {
    size_t first = count, last = 0;
    for (size_t i = 0; i < count; i++) {
        if (frequencies[i] >= limits->low && frequencies[i] <= limits->high) { if (first == count) first = i; last = i; }
    }
    if (first == count || limits->maxFilters == 0 || rate <= 0) return 0;
    const size_t m = last - first + 1;
    double *error = malloc(m * sizeof(double)), *others = calloc(m, sizeof(double));
    if (!error || !others) { free(error); free(others); return 0; }
    for (size_t i = 0; i < m; i++) error[i] = db[first + i] - target[first + i];
    Fit fit = {frequencies + first, error, m, rate, limits, others};
    const NRTPeakFilter none = {limits->low, 0, 1};
    double cost = fit_cost(&fit, &none);
    uint32_t made = 0;
    while (made < limits->maxFilters) {
        // The worst point left that a filter may fix: peaks fully, dips only as far as the boost allowed.
        size_t worst = m;
        double worstBy = limits->toleranceDB;
        for (size_t i = 0; i < m; i++) {
            const double e = error[i] + others[i], headroom = limits->maxBoostDB - others[i];
            const double fixable = e > 0 ? e : (-e < headroom ? -e : headroom);
            if (fixable > worstBy) { worstBy = fixable; worst = i; }
        }
        if (worst == m) break;
        const double e = error[worst] + others[worst];
        // Its width: where the error falls to half on either side, in octaves, gives the starting Q.
        size_t lo = worst, hi = worst;
        while (lo > 0 && (error[lo - 1] + others[lo - 1]) * e > e * e / 4) lo--;
        while (hi + 1 < m && (error[hi + 1] + others[hi + 1]) * e > e * e / 4) hi++;
        const double octaves = log2(fit.f[hi] / fit.f[lo]) + 1.0 / 24;
        NRTPeakFilter p = {fit.f[worst], -e, 1 / (2 * sinh(log(2) / 2 * octaves))};
        clamp_filter(&p, limits);
        const double before = cost;
        cost = fit_refine(&fit, &p, fit_cost(&fit, &p));
        if (cost > before * 0.99) break;   // a filter that barely helps isn't worth running
        out[made++] = p;
        for (size_t i = 0; i < m; i++) others[i] += peak_db(&p, fit.f[i], rate);
        // Every filter again, with the new one in place.
        for (uint32_t j = 0; j < made; j++) {
            for (size_t i = 0; i < m; i++) others[i] -= peak_db(&out[j], fit.f[i], rate);
            cost = fit_refine(&fit, &out[j], fit_cost(&fit, &out[j]));
            for (size_t i = 0; i < m; i++) others[i] += peak_db(&out[j], fit.f[i], rate);
        }
    }
    free(error); free(others);
    return made;
}
