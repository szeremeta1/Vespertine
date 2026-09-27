//
// Nocturne — real-time audio primitives.
// SPDX-License-Identifier: GPL-3.0-or-later
//

#include "CNocturneRT.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// MARK: - Ring

struct NRTRing {
    float *data;
    uint32_t channels;
    uint32_t capacity; // frames, power of two
    uint32_t mask;
    _Alignas(64) _Atomic uint64_t writePos;
    _Alignas(64) _Atomic uint64_t readPos;
};

static uint32_t next_pow2(uint32_t v) {
    if (v < 2) return 2;
    v--;
    v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16;
    return v + 1;
}

NRTRing *nrt_ring_create(uint32_t minimumFrames, uint32_t channels) {
    if (channels == 0 || minimumFrames == 0 || minimumFrames > (1u << 30)) return NULL;
    NRTRing *ring = calloc(1, sizeof(NRTRing));
    if (!ring) return NULL;
    ring->channels = channels;
    ring->capacity = next_pow2(minimumFrames);
    ring->mask = ring->capacity - 1;
    ring->data = calloc((size_t)ring->capacity * channels, sizeof(float));
    if (!ring->data) { free(ring); return NULL; }
    atomic_init(&ring->writePos, 0);
    atomic_init(&ring->readPos, 0);
    return ring;
}

void nrt_ring_destroy(NRTRing *ring) {
    if (!ring) return;
    free(ring->data);
    free(ring);
}

uint32_t nrt_ring_channels(const NRTRing *ring) { return ring->channels; }
uint32_t nrt_ring_capacity(const NRTRing *ring) { return ring->capacity; }

uint32_t nrt_ring_readable(const NRTRing *ring) {
    uint64_t w = atomic_load_explicit(&ring->writePos, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&ring->readPos, memory_order_acquire);
    return (uint32_t)(w - r);
}

uint32_t nrt_ring_writable(const NRTRing *ring) { return ring->capacity - nrt_ring_readable(ring); }

uint32_t nrt_ring_write(NRTRing *ring, const float *src, uint32_t frames) {
    uint64_t w = atomic_load_explicit(&ring->writePos, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&ring->readPos, memory_order_acquire);
    uint32_t space = ring->capacity - (uint32_t)(w - r);
    if (frames > space) frames = space;
    if (frames == 0) return 0;
    uint32_t start = (uint32_t)(w & ring->mask);
    uint32_t first = ring->capacity - start;
    if (first > frames) first = frames;
    size_t ch = ring->channels;
    memcpy(ring->data + start * ch, src, first * ch * sizeof(float));
    if (frames > first) memcpy(ring->data, src + first * ch, (frames - first) * ch * sizeof(float));
    atomic_store_explicit(&ring->writePos, w + frames, memory_order_release);
    return frames;
}

uint32_t nrt_ring_read(NRTRing *ring, float *dst, uint32_t frames) {
    uint64_t r = atomic_load_explicit(&ring->readPos, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&ring->writePos, memory_order_acquire);
    uint32_t avail = (uint32_t)(w - r);
    if (frames > avail) frames = avail;
    if (frames == 0) return 0;
    uint32_t start = (uint32_t)(r & ring->mask);
    uint32_t first = ring->capacity - start;
    if (first > frames) first = frames;
    size_t ch = ring->channels;
    memcpy(dst, ring->data + start * ch, first * ch * sizeof(float));
    if (frames > first) memcpy(dst + first * ch, ring->data, (frames - first) * ch * sizeof(float));
    atomic_store_explicit(&ring->readPos, r + frames, memory_order_release);
    return frames;
}

uint64_t nrt_ring_total_written(const NRTRing *ring) { return atomic_load_explicit(&ring->writePos, memory_order_acquire); }
uint64_t nrt_ring_total_read(const NRTRing *ring) { return atomic_load_explicit(&ring->readPos, memory_order_acquire); }

void nrt_ring_reset(NRTRing *ring) {
    atomic_store(&ring->writePos, 0);
    atomic_store(&ring->readPos, 0);
}

// MARK: - Render context

struct NRTRenderContext {
    NRTRing *ring;
    float *scratch;
    uint32_t scratchFrames;

    _Atomic double gain;
    _Atomic uint32_t ditherBits;
    _Atomic bool passthrough;
    _Atomic bool draining;
    _Atomic uint32_t underruns;
    _Atomic uint64_t framesRendered;

    _Atomic float peak[2];

    float tap[NRT_TAP_SIZE];
    _Atomic uint32_t tapWrite;

    uint64_t rng; // render-thread only
};

NRTRenderContext *nrt_context_create(NRTRing *ring, uint32_t maxFramesPerSlice) {
    NRTRenderContext *ctx = calloc(1, sizeof(NRTRenderContext));
    if (!ctx) return NULL;
    ctx->ring = ring;
    ctx->scratchFrames = maxFramesPerSlice < 512 ? 512 : maxFramesPerSlice;
    ctx->scratch = calloc((size_t)ctx->scratchFrames * nrt_ring_channels(ring), sizeof(float));
    if (!ctx->scratch) { free(ctx); return NULL; }
    atomic_init(&ctx->gain, 1.0);
    atomic_init(&ctx->ditherBits, 24);
    atomic_init(&ctx->passthrough, false);
    atomic_init(&ctx->draining, false);
    atomic_init(&ctx->underruns, 0);
    atomic_init(&ctx->framesRendered, 0);
    atomic_init(&ctx->peak[0], 0.f);
    atomic_init(&ctx->peak[1], 0.f);
    atomic_init(&ctx->tapWrite, 0);
    ctx->rng = 0x9E3779B97F4A7C15ull;
    return ctx;
}

void nrt_context_destroy(NRTRenderContext *ctx) {
    if (!ctx) return;
    free(ctx->scratch);
    free(ctx);
}

void nrt_context_set_gain(NRTRenderContext *ctx, double gain, uint32_t ditherBits) {
    atomic_store(&ctx->ditherBits, ditherBits);
    atomic_store(&ctx->gain, gain);
}
double nrt_context_gain(const NRTRenderContext *ctx) { return atomic_load(&ctx->gain); }
void nrt_context_set_passthrough(NRTRenderContext *ctx, bool p) { atomic_store(&ctx->passthrough, p); }
void nrt_context_set_draining(NRTRenderContext *ctx, bool d) { atomic_store(&ctx->draining, d); }
uint32_t nrt_context_take_underruns(NRTRenderContext *ctx) { return atomic_exchange(&ctx->underruns, 0); }
uint64_t nrt_context_frames_rendered(const NRTRenderContext *ctx) { return atomic_load(&ctx->framesRendered); }

float nrt_context_take_peak(NRTRenderContext *ctx, uint32_t channel) {
    if (channel > 1) return 0.f;
    return atomic_exchange(&ctx->peak[channel], 0.f);
}

uint32_t nrt_context_copy_tap(const NRTRenderContext *ctx, float *out, uint32_t count) {
    if (count > NRT_TAP_SIZE) count = NRT_TAP_SIZE;
    uint32_t w = atomic_load_explicit(&ctx->tapWrite, memory_order_acquire);
    uint32_t start = (w - count) & (NRT_TAP_SIZE - 1);
    for (uint32_t i = 0; i < count; i++) out[i] = ctx->tap[(start + i) & (NRT_TAP_SIZE - 1)];
    return count;
}

static inline double tpdf(uint64_t *state) {
    // xorshift64*, two uniforms → triangular distribution in (-1, 1)
    uint64_t x = *state;
    x ^= x >> 12; x ^= x << 25; x ^= x >> 27; *state = x;
    uint64_t a = x * 0x2545F4914F6CDD1Dull;
    x ^= x >> 12; x ^= x << 25; x ^= x >> 27; *state = x;
    uint64_t b = x * 0x2545F4914F6CDD1Dull;
    return ((double)(a >> 11) - (double)(b >> 11)) * (1.0 / 9007199254740992.0);
}

static inline void store_peak_max(_Atomic float *slot, float v) {
    float cur = atomic_load_explicit(slot, memory_order_relaxed);
    while (v > cur && !atomic_compare_exchange_weak_explicit(slot, &cur, v, memory_order_relaxed, memory_order_relaxed)) {}
}

// Pulls `frames` source frames into ctx->scratch (zero-filled if dry) and applies gain/meters.
static void pull(NRTRenderContext *ctx, uint32_t frames) {
    const uint32_t ch = nrt_ring_channels(ctx->ring);
    uint32_t got = nrt_ring_read(ctx->ring, ctx->scratch, frames);
    if (got < frames) {
        memset(ctx->scratch + (size_t)got * ch, 0, (size_t)(frames - got) * ch * sizeof(float));
        if (!atomic_load_explicit(&ctx->draining, memory_order_relaxed))
            atomic_fetch_add_explicit(&ctx->underruns, 1, memory_order_relaxed);
    }
    if (atomic_load_explicit(&ctx->passthrough, memory_order_relaxed)) return;

    const double gain = atomic_load_explicit(&ctx->gain, memory_order_relaxed);
    if (gain != 1.0) {
        const uint32_t bits = atomic_load_explicit(&ctx->ditherBits, memory_order_relaxed);
        const double lsb = bits > 1 && bits < 32 ? 1.0 / (double)(1u << (bits - 1)) : 0.0;
        const size_t n = (size_t)got * ch;
        for (size_t i = 0; i < n; i++) {
            double s = (double)ctx->scratch[i] * gain;
            if (lsb > 0) s += tpdf(&ctx->rng) * lsb;
            ctx->scratch[i] = (float)s;
        }
    }

    // Meters and spectrum tap (post-gain, what the DAC receives).
    float p0 = 0.f, p1 = 0.f;
    uint32_t tw = atomic_load_explicit(&ctx->tapWrite, memory_order_relaxed);
    for (uint32_t f = 0; f < got; f++) {
        const float l = ctx->scratch[(size_t)f * ch];
        const float r = ch > 1 ? ctx->scratch[(size_t)f * ch + 1] : l;
        const float al = fabsf(l), ar = fabsf(r);
        if (al > p0) p0 = al;
        if (ar > p1) p1 = ar;
        ctx->tap[tw & (NRT_TAP_SIZE - 1)] = 0.5f * (l + r);
        tw++;
    }
    atomic_store_explicit(&ctx->tapWrite, tw, memory_order_release);
    store_peak_max(&ctx->peak[0], p0);
    store_peak_max(&ctx->peak[1], p1);
}

void nrt_context_render_interleaved(NRTRenderContext *ctx, float *out, uint32_t frames, uint32_t outChannels) {
    const uint32_t ch = nrt_ring_channels(ctx->ring);
    uint32_t done = 0;
    while (done < frames) {
        uint32_t n = frames - done;
        if (n > ctx->scratchFrames) n = ctx->scratchFrames;
        pull(ctx, n);
        for (uint32_t f = 0; f < n; f++) {
            float *o = out + (size_t)(done + f) * outChannels;
            const float *s = ctx->scratch + (size_t)f * ch;
            for (uint32_t c = 0; c < outChannels; c++) o[c] = c < ch ? s[c] : 0.f;
        }
        done += n;
    }
    atomic_fetch_add_explicit(&ctx->framesRendered, frames, memory_order_relaxed);
}

OSStatus nrt_device_ioproc(AudioObjectID inDevice, const AudioTimeStamp *inNow, const AudioBufferList *inInputData,
                           const AudioTimeStamp *inInputTime, AudioBufferList *outOutputData,
                           const AudioTimeStamp *inOutputTime, void *inClientData) {
    (void)inDevice; (void)inNow; (void)inInputData; (void)inInputTime; (void)inOutputTime;
    NRTRenderContext *ctx = (NRTRenderContext *)inClientData;
    if (!ctx || !outOutputData || outOutputData->mNumberBuffers == 0) return noErr;

    // Fast path: one interleaved buffer (the common case for USB DACs).
    if (outOutputData->mNumberBuffers == 1) {
        AudioBuffer *b = &outOutputData->mBuffers[0];
        const uint32_t outCh = b->mNumberChannels ? b->mNumberChannels : 1;
        const uint32_t frames = b->mDataByteSize / (uint32_t)(sizeof(float) * outCh);
        nrt_context_render_interleaved(ctx, (float *)b->mData, frames, outCh);
        return noErr;
    }

    // General case: several buffers (non-interleaved or multi-stream). Map source
    // channels onto the device channels in order; silence the remainder.
    const uint32_t ch = nrt_ring_channels(ctx->ring);
    AudioBuffer *first = &outOutputData->mBuffers[0];
    const uint32_t firstCh = first->mNumberChannels ? first->mNumberChannels : 1;
    const uint32_t frames = first->mDataByteSize / (uint32_t)(sizeof(float) * firstCh);
    uint32_t done = 0;
    while (done < frames) {
        uint32_t n = frames - done;
        if (n > ctx->scratchFrames) n = ctx->scratchFrames;
        pull(ctx, n);
        uint32_t deviceChannel = 0;
        for (uint32_t bi = 0; bi < outOutputData->mNumberBuffers; bi++) {
            AudioBuffer *b = &outOutputData->mBuffers[bi];
            const uint32_t bch = b->mNumberChannels ? b->mNumberChannels : 1;
            float *o = (float *)b->mData;
            if (!o) { deviceChannel += bch; continue; }
            for (uint32_t f = 0; f < n; f++) {
                for (uint32_t c = 0; c < bch; c++) {
                    const uint32_t src = deviceChannel + c;
                    o[(size_t)(done + f) * bch + c] = src < ch ? ctx->scratch[(size_t)f * ch + src] : 0.f;
                }
            }
            deviceChannel += bch;
        }
        done += n;
    }
    atomic_fetch_add_explicit(&ctx->framesRendered, frames, memory_order_relaxed);
    return noErr;
}
