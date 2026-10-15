// Room measurement on simulated rooms: two speakers measured in one take, each a delay, a level and room modes (peaks
// and a dip) with noise on top. The measurement has to find each speaker's delay and level, its response, and filters
// that flatten its peaks.

#include "CVespertineMeasure.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RATE 48000.0
#define SWEEP_SECONDS 4.0
#define GAP_SECONDS 1.5
#define F1 10.0
#define F2 20000.0

typedef struct {
    double delayFrames;
    double levelDB;
    uint32_t modes;
    NRTPeakFilter mode[4];
} Speaker;

static const Speaker left = {158, 0, 4, {{45, 12, 6}, {87, 8, 8}, {131, -10, 5}, {210, 5, 4}}};
static const Speaker right = {203, -2, 3, {{52, 10, 5}, {120, 7, 6}, {170, -8, 4}}};

static uint32_t seed = 99;
static double noise(void) {   // −0.5 ..< 0.5
    seed = seed * 1664525u + 1013904223u;
    return (double)(seed >> 8) / 16777216.0 - 0.5;
}

// A speaker in the room: its modes (RBJ peaking biquads, run directly), then its level and delay.
static void play(const Speaker *s, const float *in, size_t frames, float *out, size_t at, size_t outFrames) {
    double *x = malloc(frames * sizeof(double));
    for (size_t i = 0; i < frames; i++) x[i] = in[i];
    for (uint32_t k = 0; k < s->modes; k++) {
        const NRTPeakFilter *p = &s->mode[k];
        const double a = pow(10, p->gainDB / 40), w0 = 2 * M_PI * p->frequency / RATE, alpha = sin(w0) / (2 * p->q);
        const double a0 = 1 + alpha / a;
        const double b0 = (1 + alpha * a) / a0, b1 = -2 * cos(w0) / a0, b2 = (1 - alpha * a) / a0;
        const double a1 = -2 * cos(w0) / a0, a2 = (1 - alpha / a) / a0;
        double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
        for (size_t i = 0; i < frames; i++) {
            const double y = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
            x2 = x1; x1 = x[i]; y2 = y1; y1 = y;
            x[i] = y;
        }
    }
    const double gain = pow(10, s->levelDB / 20) * 0.25;
    for (size_t i = 0; i < frames; i++) {
        const size_t t = at + (size_t)s->delayFrames + i;
        if (t < outFrames) out[t] += (float)(x[i] * gain);
    }
    free(x);
}

static double true_db(const Speaker *s, double f) {
    return nrt_peaks_db(s->mode, s->modes, f, RATE) + s->levelDB + 20 * log10(0.25);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    const size_t sweepFrames = (size_t)(SWEEP_SECONDS * RATE), gap = (size_t)(GAP_SECONDS * RATE);
    const size_t offset = sweepFrames + gap;                       // the right speaker's sweep starts here
    const size_t recordedFrames = 2 * offset;
    float *sweep = malloc(sweepFrames * sizeof(float));
    nrt_sweep_generate(sweep, sweepFrames, RATE, F1, F2, 0.05);
    float peak = 0;
    for (size_t i = 0; i < sweepFrames; i++) if (fabsf(sweep[i]) > peak) peak = fabsf(sweep[i]);
    assert(peak <= 1.f && peak > 0.99f && fabsf(sweep[0]) < 1e-6f && fabsf(sweep[sweepFrames - 1]) < 1e-6f);

    // One take: left, a gap, right, a gap; background noise at −70 dB under it all.
    float *recorded = calloc(recordedFrames, sizeof(float));
    play(&left, sweep, sweepFrames, recorded, 0, recordedFrames);
    play(&right, sweep, sweepFrames, recorded, offset, recordedFrames);
    for (size_t i = 0; i < recordedFrames; i++) recorded[i] += (float)(noise() * 2 * pow(10, -70 / 20.0));

    float *impulse = malloc(recordedFrames * sizeof(float));
    assert(nrt_measure_impulse(recorded, recordedFrames, sweep, sweepFrames, RATE, F1, F2, impulse, recordedFrames));

    // Delays: each speaker's direct sound where it was put, to a tenth of a sample.
    float lv, rv;
    const double lp = nrt_impulse_peak(impulse, 0, offset / 2, &lv);
    const double rp = nrt_impulse_peak(impulse, offset, offset + offset / 2, &rv) - (double)offset;
    printf("delays: left %.3f, right %.3f samples\n", lp, rp);
    assert(fabs(lp - left.delayFrames) < 0.1 && fabs(rp - right.delayFrames) < 0.1);

    // Responses: 500 ms from 5 ms before the direct sound, faded out over its last half (what the wizard does).
    const size_t pre = (size_t)(0.005 * RATE), length = (size_t)(0.5 * RATE);
    enum { POINTS = 240 };
    double f[POINTS], db[POINTS], target[POINTS];
    for (int i = 0; i < POINTS; i++) f[i] = 20 * pow(2, i / 48.0);  // 20 Hz up, 1/48 octave apart
    const Speaker *speakers[2] = {&left, &right};
    const double starts[2] = {lp, rp + (double)offset};
    double levels[2], trueLevels[2];
    for (int s = 0; s < 2; s++) {
        float *window = calloc(length, sizeof(float));
        const size_t from = (size_t)starts[s] > pre ? (size_t)starts[s] - pre : 0;
        for (size_t i = 0; i < length; i++) {
            const double fade = i < length / 2 ? 1 : 0.5 + 0.5 * cos(M_PI * (double)(i - length / 2) / (double)(length / 2));
            window[i] = (float)(impulse[from + i] * fade);
        }
        assert(nrt_response_db(window, length, RATE, f, POINTS, 0, db));
        double worst = 0;
        for (int i = 0; i < POINTS; i++) {
            if (f[i] < 30 || f[i] > 250) continue;
            const double d = fabs(db[i] - true_db(speakers[s], f[i]));
            if (d > worst) worst = d;
        }
        printf("speaker %d: response within %.2f dB of the truth (30-250 Hz)\n", s, worst);
        assert(worst < 1.0);

        // Level: the average from 300 to 600 Hz, above the modes. Then the fit, bass only: a flat target at that
        // level, 30-250 Hz, boosts up to 3 dB.
        double sum = 0, trueSum = 0; int n = 0;
        for (int i = 0; i < POINTS; i++) if (f[i] >= 300 && f[i] <= 600) { sum += db[i]; trueSum += true_db(speakers[s], f[i]); n++; }
        const double reference = sum / n;
        levels[s] = reference; trueLevels[s] = trueSum / n;
        for (int i = 0; i < POINTS; i++) target[i] = reference;
        NRTFitLimits limits = {.low = 30, .high = 250, .maxBoostDB = 3, .maxCutDB = 15, .minQ = 0.5, .maxQ = 12,
                               .maxFilters = 10, .toleranceDB = 1};
        NRTPeakFilter filters[10];
        const uint32_t made = nrt_fit_peaks(f, db, target, POINTS, RATE, &limits, filters);
        double before = 0, after = 0, worstPeak = 0;
        int counted = 0;
        for (int i = 0; i < POINTS; i++) {
            if (f[i] < 30 || f[i] > 250) continue;
            const double e0 = true_db(speakers[s], f[i]) - reference;
            const double e1 = e0 + nrt_peaks_db(filters, made, f[i], RATE);
            // Peaks are what gets corrected; dips (cancellations, in a real room) only get the little boost allowed.
            before += e0 > 0 ? e0 * e0 : 0; after += e1 > 0 ? e1 * e1 : 0; counted++;
            if (e1 > worstPeak) worstPeak = e1;
        }
        before = sqrt(before / counted); after = sqrt(after / counted);
        printf("speaker %d: %u filters, RMS of peaks %.2f -> %.2f dB, highest peak left %.2f dB\n", s, made, before, after, worstPeak);
        for (uint32_t k = 0; k < made; k++) printf("  PK %.1f Hz %.1f dB Q %.2f\n", filters[k].frequency, filters[k].gainDB, filters[k].q);
        assert(made > 0 && made <= 10);
        assert(after < before / 4);
        assert(worstPeak < 2.0);
        for (uint32_t k = 0; k < made; k++) assert(filters[k].gainDB <= 3 + 1e-9 && filters[k].gainDB >= -15 - 1e-9);
        // Together, the filters boost no more than one may: a dip isn't filled by stacking boosts.
        for (double g = 20; g < 20000; g *= 1.01) assert(nrt_peaks_db(filters, made, g, RATE) < 3.2);
        free(window);
    }

    // Levels: each speaker's, and the difference between them, as put.
    printf("levels: %.2f, %.2f dB (truth %.2f, %.2f)\n", levels[0], levels[1], trueLevels[0], trueLevels[1]);
    assert(fabs(levels[0] - trueLevels[0]) < 0.2 && fabs(levels[1] - trueLevels[1]) < 0.2);
    (void)lv; (void)rv;
    free(sweep); free(recorded); free(impulse);
    return 0;
}
