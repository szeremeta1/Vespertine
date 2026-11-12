//
// Vespertine: Mac Sound Output (beta): the live router. What other apps play reaches the I/O cycle as the aggregate's
// input (the driver's capture side); it is routed onto the speaker group by a gain matrix and rendered through the same
// context as music (room correction, delays, trims), in the same cycle.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// No locks or allocation on the I/O thread. A matrix change is double-buffered: the setter writes the spare matrix and
// publishes it; the I/O thread crossfades from the old one to the new over the next cycle and acknowledges it.
//

#include "CVespertineRT.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct NRTLive {
    NRTCapture *capture;
    NRTRing *captureRing;
    NRTRenderContext *ctx;
    NRTRing *renderRing;
    uint32_t inChannels;        // the capture ring's
    uint32_t outChannels;       // the render ring's
    uint32_t maxFrames;
    float *in;                  // one slice of input
    float *out;                 // one slice routed
    float matrices[2][NRT_LIVE_MAX_CHANNELS * NRT_LIVE_MAX_CHANNELS];
    _Atomic uint32_t published; // the matrix the setter last published
    _Atomic uint32_t taken;     // the matrix the I/O thread uses now
    _Atomic bool diverted;
    _Atomic float peaks[NRT_LIVE_MAX_CHANNELS];
};

NRTLive *nrt_live_create(NRTCapture *capture, NRTRing *captureRing, NRTRenderContext *ctx, NRTRing *renderRing, uint32_t maxFramesPerSlice) {
    if (!capture || !captureRing || !ctx || !renderRing || maxFramesPerSlice == 0) return NULL;
    uint32_t inCh = nrt_ring_channels(captureRing), outCh = nrt_ring_channels(renderRing);
    if (inCh == 0 || outCh == 0 || inCh > NRT_LIVE_MAX_CHANNELS || outCh > NRT_LIVE_MAX_CHANNELS) return NULL;
    NRTLive *live = calloc(1, sizeof *live);
    if (!live) return NULL;
    live->capture = capture;
    live->captureRing = captureRing;
    live->ctx = ctx;
    live->renderRing = renderRing;
    live->inChannels = inCh;
    live->outChannels = outCh;
    live->maxFrames = maxFramesPerSlice;
    live->in = calloc((size_t)maxFramesPerSlice * inCh, sizeof(float));
    live->out = calloc((size_t)maxFramesPerSlice * outCh, sizeof(float));
    if (!live->in || !live->out) { nrt_live_destroy(live); return NULL; }
    // Until a matrix is set: channel for channel.
    for (uint32_t o = 0; o < outCh && o < inCh; o++) {
        live->matrices[0][o * inCh + o] = 1.f;
        live->matrices[1][o * inCh + o] = 1.f;
    }
    for (uint32_t c = 0; c < NRT_LIVE_MAX_CHANNELS; c++) atomic_init(&live->peaks[c], 0.f);
    atomic_init(&live->published, 0);
    atomic_init(&live->taken, 0);
    atomic_init(&live->diverted, false);
    return live;
}

void nrt_live_destroy(NRTLive *live) {
    if (!live) return;
    free(live->in);
    free(live->out);
    free(live);
}

bool nrt_live_set_matrix(NRTLive *live, const float *gains, uint32_t outChannels, uint32_t inChannels) {
    if (!live || !gains || outChannels != live->outChannels || inChannels != live->inChannels) return false;
    // The spare is free only once the I/O thread has taken the last published matrix. A stopped device never takes it,
    // so after a short wait the spare is written anyway (nothing reads it then).
    for (int i = 0; i < 200 && atomic_load_explicit(&live->taken, memory_order_acquire) != atomic_load_explicit(&live->published, memory_order_relaxed); i++) {
        usleep(1000);
    }
    uint32_t spare = 1u - atomic_load_explicit(&live->published, memory_order_relaxed);
    memcpy(live->matrices[spare], gains, (size_t)outChannels * inChannels * sizeof(float));
    atomic_store_explicit(&live->published, spare, memory_order_release);
    return true;
}

void nrt_live_set_diverted(NRTLive *live, bool diverted) {
    if (live) atomic_store_explicit(&live->diverted, diverted, memory_order_release);
}

float nrt_live_take_peak(NRTLive *live, uint32_t channel) {
    if (!live || channel >= NRT_LIVE_MAX_CHANNELS) return 0.f;
    return atomic_exchange_explicit(&live->peaks[channel], 0.f, memory_order_relaxed);
}

static void note_peaks(NRTLive *live, const float *in, uint32_t frames) {
    const uint32_t ch = live->inChannels;
    for (uint32_t c = 0; c < ch; c++) {
        float peak = 0.f;
        for (uint32_t f = 0; f < frames; f++) {
            float v = in[(size_t)f * ch + c];
            if (v < 0) v = -v;
            if (v > peak) peak = v;
        }
        float held = atomic_load_explicit(&live->peaks[c], memory_order_relaxed);
        if (peak > held) atomic_store_explicit(&live->peaks[c], peak, memory_order_relaxed);
    }
}

// `from` and `to` are the same matrix except during a change, when each frame's gains move from one to the other.
static void route(const NRTLive *live, const float *from, const float *to, const float *in, float *out, uint32_t frames) {
    const uint32_t inCh = live->inChannels, outCh = live->outChannels;
    const bool fading = from != to;
    for (uint32_t f = 0; f < frames; f++) {
        const float *x = in + (size_t)f * inCh;
        float *y = out + (size_t)f * outCh;
        const float t = fading ? (float)(f + 1) / (float)frames : 1.f;
        for (uint32_t o = 0; o < outCh; o++) {
            const float *a = from + (size_t)o * inCh, *b = to + (size_t)o * inCh;
            float sum = 0.f;
            for (uint32_t i = 0; i < inCh; i++) {
                const float g = fading ? a[i] + (b[i] - a[i]) * t : b[i];
                sum += g * x[i];
            }
            y[o] = sum;
        }
    }
}

void nrt_live_route(NRTLive *live, const float *in, float *out, uint32_t frames) {
    if (!live || !in || !out) return;
    const float *m = live->matrices[atomic_load_explicit(&live->published, memory_order_acquire)];
    note_peaks(live, in, frames);
    route(live, m, m, in, out, frames);
}

OSStatus nrt_live_ioproc(AudioObjectID inDevice, const AudioTimeStamp *inNow, const AudioBufferList *inInputData,
                         const AudioTimeStamp *inInputTime, AudioBufferList *outOutputData,
                         const AudioTimeStamp *inOutputTime, void *inClientData) {
    NRTLive *live = (NRTLive *)inClientData;
    if (!live) return noErr;

    // 1. Record what arrived.
    if (inInputData && inInputData->mNumberBuffers > 0) {
        nrt_capture_ioproc(inDevice, inNow, inInputData, inInputTime, outOutputData, inOutputTime, live->capture);
    }

    // 2. Route it onto the group, unless the worker does (the upmixer).
    if (!atomic_load_explicit(&live->diverted, memory_order_acquire)) {
        const uint32_t published = atomic_load_explicit(&live->published, memory_order_acquire);
        const uint32_t taken = atomic_load_explicit(&live->taken, memory_order_relaxed);
        const float *from = live->matrices[taken], *to = live->matrices[published];
        uint32_t frames;
        bool first = true;
        while ((frames = nrt_ring_read(live->captureRing, live->in, live->maxFrames)) > 0) {
            note_peaks(live, live->in, frames);
            route(live, first ? from : to, to, live->in, live->out, frames);
            first = false;
            nrt_ring_write(live->renderRing, live->out, frames);
        }
        if (published != taken) atomic_store_explicit(&live->taken, published, memory_order_release);
    } else {
        // The worker routes; the matrix it reads is the published one.
        atomic_store_explicit(&live->taken, atomic_load_explicit(&live->published, memory_order_acquire), memory_order_release);
    }

    // 3. Play it: room correction, delays, trims, then the DACs.
    return nrt_device_ioproc(inDevice, inNow, inInputData, inInputTime, outOutputData, inOutputTime, live->ctx);
}
