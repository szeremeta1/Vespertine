//
// Vespertine — room measurement: the test sweep, the impulse response from a recording of it, the frequency response,
// and peaking filters fitted to bring a response to a target. Never on the I/O thread (these allocate).
// SPDX-License-Identifier: GPL-3.0-or-later
//

#ifndef CVESPERTINE_MEASURE_H
#define CVESPERTINE_MEASURE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// An exponential (logarithmic) sine sweep from f1 to f2 Hz over `frames` samples at `rate`, peak 1, faded in and out
/// over `fadeSeconds` (at its ends, below f1 and above f2, where the fades don't touch what's measured).
void nrt_sweep_generate(float *_Nonnull out, size_t frames, double rate, double f1, double f2, double fadeSeconds);

/// The impulse response of whatever played and recorded `sweep`: `recorded` deconvolved by the sweep, regularised
/// outside f1…f2 so noise there isn't amplified. `impulse` (impulseFrames) gets the response from sample 0 of the
/// recording on, so the sweep played at recording sample t shows up at impulse sample t (plus the path's delay). A
/// recording of several sweeps, one after another, gives each one's response at its own offset. Returns false if out
/// of memory or the input is empty.
bool nrt_measure_impulse(const float *_Nonnull recorded, size_t recordedFrames, const float *_Nonnull sweep, size_t sweepFrames,
                         double rate, double f1, double f2, float *_Nonnull impulse, size_t impulseFrames);

/// Where an impulse response peaks (the direct sound) in [from, to), to a fraction of a sample (parabolic fit), and
/// that peak's absolute value.
double nrt_impulse_peak(const float *_Nonnull impulse, size_t from, size_t to, float *_Nullable peakValue);

/// The magnitude response in dB of `impulse` (frames samples, at `rate`) at each of `count` frequencies, power-averaged
/// over `smoothingOctaves` around each (0: none). The impulse should already be windowed.
bool nrt_response_db(const float *_Nonnull impulse, size_t frames, double rate, const double *_Nonnull frequencies, size_t count,
                     double smoothingOctaves, double *_Nonnull db);

/// One peaking filter (RBJ cookbook, as the equalizer runs it).
typedef struct {
    double frequency;
    double gainDB;
    double q;
} NRTPeakFilter;

/// What the fit may do.
typedef struct {
    double low, high;            // Hz: the range corrected
    double maxBoostDB;           // the most any filter may boost (dips are usually cancellation, which boosting can't fix)
    double maxCutDB;             // the most any filter may cut (positive)
    double minQ, maxQ;
    uint32_t maxFilters;
    double toleranceDB;          // stop when nothing in range is further than this from the target
} NRTFitLimits;

/// Peaking filters that bring `db` (the response at `frequencies`, log-spaced) to `target` across limits->low…high,
/// best first. Returns how many were written to `out` (at most limits->maxFilters).
uint32_t nrt_fit_peaks(const double *_Nonnull frequencies, const double *_Nonnull db, const double *_Nonnull target, size_t count,
                       double rate, const NRTFitLimits *_Nonnull limits, NRTPeakFilter *_Nonnull out);

/// The response in dB of `filters` at `frequency`.
double nrt_peaks_db(const NRTPeakFilter *_Nonnull filters, uint32_t count, double frequency, double rate);

#endif
