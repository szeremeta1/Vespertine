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
    NRTRing *ring = NULL;
    if (posix_memalign((void **)&ring, _Alignof(NRTRing), sizeof(NRTRing))) return NULL;
    memset(ring, 0, sizeof(*ring));
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

bool nrt_ring_rewind(NRTRing *ring, uint64_t totalWritten, uint32_t margin) {
    uint64_t w = atomic_load_explicit(&ring->writePos, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&ring->readPos, memory_order_acquire);
    if (totalWritten > w || totalWritten < r + margin) return false;
    atomic_store_explicit(&ring->writePos, totalWritten, memory_order_release);
    return true;
}

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
    _Atomic bool dop;
    _Atomic bool muted;
    uint16_t dopPrevious[NRT_METER_CHANNELS > 2 ? NRT_METER_CHANNELS : 2];   // render thread only
    _Atomic bool dopPrimed;
    _Atomic bool draining;
    _Atomic bool integer;
    _Atomic uint32_t underruns;
    _Atomic uint64_t framesRendered;

    // Rebuffering (network streams): when the ring can't fill a slice, hold in silence without
    // consuming anything until `resumeFrames` are buffered. 0 = off (plain underruns).
    _Atomic uint32_t resumeFrames;
    _Atomic bool starved;
    _Atomic uint32_t stalls;

    _Atomic float peak[NRT_METER_CHANNELS];

    _Atomic float tap[NRT_TAP_SIZE];
    _Atomic uint32_t tapWrite;

    uint64_t rng; // render-thread only

    // Optional processor (set while stopped): scratch (ring channels) → processed (processedChannels).
    NRTProcessFn processor;
    void *processorUser;
    uint32_t processedChannels;
    float *processed;
};

NRTRenderContext *nrt_context_create(NRTRing *ring, uint32_t maxFramesPerSlice) {
    if (!ring) return NULL;
    NRTRenderContext *ctx = calloc(1, sizeof(NRTRenderContext));
    if (!ctx) return NULL;
    ctx->ring = ring;
    ctx->scratchFrames = maxFramesPerSlice < 512 ? 512 : maxFramesPerSlice;
    ctx->scratch = calloc((size_t)ctx->scratchFrames * nrt_ring_channels(ring), sizeof(float));
    if (!ctx->scratch) { free(ctx); return NULL; }
    atomic_init(&ctx->gain, 1.0);
    atomic_init(&ctx->ditherBits, 24);
    atomic_init(&ctx->passthrough, false);
    atomic_init(&ctx->dop, false);
    atomic_init(&ctx->muted, false);
    atomic_init(&ctx->draining, false);
    atomic_init(&ctx->integer, false);
    atomic_init(&ctx->underruns, 0);
    atomic_init(&ctx->framesRendered, 0);
    atomic_init(&ctx->resumeFrames, 0);
    atomic_init(&ctx->starved, false);
    atomic_init(&ctx->stalls, 0);
    for (uint32_t i = 0; i < NRT_METER_CHANNELS; i++) atomic_init(&ctx->peak[i], 0.f);
    atomic_init(&ctx->tapWrite, 0);
    for (uint32_t i = 0; i < NRT_TAP_SIZE; i++) atomic_init(&ctx->tap[i], 0.f);
    ctx->rng = 0x9E3779B97F4A7C15ull;
    return ctx;
}

bool nrt_context_set_processor(NRTRenderContext *ctx, NRTProcessFn fn, void *user, uint32_t outChannels) {
    free(ctx->processed);
    ctx->processed = NULL;
    ctx->processor = NULL;
    ctx->processorUser = NULL;
    ctx->processedChannels = 0;
    if (!fn || outChannels == 0) return true;
    ctx->processed = calloc((size_t)ctx->scratchFrames * outChannels, sizeof(float));
    if (!ctx->processed) return false;
    ctx->processedChannels = outChannels;
    ctx->processorUser = user;
    ctx->processor = fn;
    return true;
}

void nrt_context_destroy(NRTRenderContext *ctx) {
    if (!ctx) return;
    free(ctx->processed);
    free(ctx->scratch);
    free(ctx);
}

void nrt_context_set_gain(NRTRenderContext *ctx, double gain, uint32_t ditherBits) {
    atomic_store(&ctx->ditherBits, ditherBits);
    atomic_store(&ctx->gain, isfinite(gain) && gain >= 0 ? gain : 0.0);
}
double nrt_context_gain(const NRTRenderContext *ctx) { return atomic_load(&ctx->gain); }
void nrt_context_set_passthrough(NRTRenderContext *ctx, bool p) { atomic_store(&ctx->passthrough, p); }
void nrt_context_set_muted(NRTRenderContext *ctx, bool m) { atomic_store(&ctx->muted, m); }
void nrt_context_set_dop(NRTRenderContext *ctx, bool d) { atomic_store(&ctx->dopPrimed, false); atomic_store(&ctx->dop, d); }
void nrt_context_set_draining(NRTRenderContext *ctx, bool d) { atomic_store(&ctx->draining, d); }
void nrt_context_set_integer(NRTRenderContext *ctx, bool i) { atomic_store(&ctx->integer, i); if (i) atomic_store(&ctx->passthrough, true); }
uint32_t nrt_context_take_underruns(NRTRenderContext *ctx) { return atomic_exchange(&ctx->underruns, 0); }
void nrt_context_set_rebuffer(NRTRenderContext *ctx, uint32_t resumeFrames) {
    const uint32_t limit = nrt_ring_capacity(ctx->ring) / 4 * 3;
    atomic_store(&ctx->resumeFrames, resumeFrames > limit ? limit : resumeFrames);
    if (resumeFrames == 0) atomic_store(&ctx->starved, false);
}
bool nrt_context_is_starved(const NRTRenderContext *ctx) { return atomic_load(&ctx->starved); }
uint32_t nrt_context_take_stalls(NRTRenderContext *ctx) { return atomic_exchange(&ctx->stalls, 0); }
uint64_t nrt_context_frames_rendered(const NRTRenderContext *ctx) { return atomic_load(&ctx->framesRendered); }

float nrt_context_take_peak(NRTRenderContext *ctx, uint32_t channel) {
    if (channel >= NRT_METER_CHANNELS) return 0.f;
    return atomic_exchange(&ctx->peak[channel], 0.f);
}

uint32_t nrt_context_copy_tap(const NRTRenderContext *ctx, float *out, uint32_t count) {
    if (count > NRT_TAP_SIZE) count = NRT_TAP_SIZE;
    uint32_t w = atomic_load_explicit(&ctx->tapWrite, memory_order_acquire);
    uint32_t start = (w - count) & (NRT_TAP_SIZE - 1);
    for (uint32_t i = 0; i < count; i++) out[i] = atomic_load_explicit(&ctx->tap[(start + i) & (NRT_TAP_SIZE - 1)], memory_order_relaxed);
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

// DoP frames carry a marker byte and 16 DSD bits per channel (oldest bit first). A triangular window over
// this frame's bits and the previous frame's (a sinc² decimation by 16) turns them into a level good enough
// for meters and the spectrum: it keeps most of DSD's ultrasonic noise from folding into the audio band.
// Reads only; the frames go out as they are.
static float dop_level(uint16_t previous, uint16_t current) {
    uint32_t sum = 0;
    for (uint32_t i = 0; i < 16; i++) {
        sum += ((previous >> (15 - i)) & 1u) * (i + 1);     // rising half
        sum += ((current >> (15 - i)) & 1u) * (16 - i);     // falling half
    }
    return ((float)sum * 2.f - 272.f) / 272.f;
}

static void meter_dop(NRTRenderContext *ctx, uint32_t got, uint32_t ch, bool integer) {
    float peaks[NRT_METER_CHANNELS] = {0};
    const uint32_t metered = ch < NRT_METER_CHANNELS ? ch : NRT_METER_CHANNELS;
    uint32_t tw = atomic_load_explicit(&ctx->tapWrite, memory_order_relaxed);
    bool primed = atomic_load_explicit(&ctx->dopPrimed, memory_order_relaxed);
    for (uint32_t f = 0; f < got; f++) {
        const float *frame = ctx->scratch + (size_t)f * ch;
        float values[NRT_METER_CHANNELS > 2 ? NRT_METER_CHANNELS : 2];
        for (uint32_t c = 0; c < metered || c < 2; c++) {
            const uint32_t src = c < ch ? c : 0;
            uint32_t bits;
            if (integer) { int32_t v; memcpy(&v, &frame[src], sizeof v); bits = ((uint32_t)v >> 8) & 0xFFFF; }
            else bits = (uint32_t)lrintf(frame[src] * 8388608.f) & 0xFFFF;
            if (!primed) ctx->dopPrevious[c] = (uint16_t)bits;     // start the window on real data, not zeros
            values[c] = dop_level(ctx->dopPrevious[c], (uint16_t)bits);
            ctx->dopPrevious[c] = (uint16_t)bits;
        }
        for (uint32_t c = 0; c < metered; c++) {
            const float a = fabsf(values[c]);
            if (a > peaks[c]) peaks[c] = a;
        }
        const float l = values[0], r = ch > 1 ? values[1] : l;
        atomic_store_explicit(&ctx->tap[tw & (NRT_TAP_SIZE - 1)], 0.5f * (l + r), memory_order_relaxed);
        tw++;
        primed = true;
    }
    if (got > 0) atomic_store_explicit(&ctx->dopPrimed, true, memory_order_relaxed);
    atomic_store_explicit(&ctx->tapWrite, tw, memory_order_release);
    for (uint32_t c = 0; c < metered; c++) store_peak_max(&ctx->peak[c], peaks[c]);
}

// Pulls `frames` source frames into ctx->scratch (zero-filled if dry) and applies gain/meters.
static void pull(NRTRenderContext *ctx, uint32_t frames) {
    const uint32_t ch = nrt_ring_channels(ctx->ring);
    if (atomic_load_explicit(&ctx->muted, memory_order_relaxed)) {
        memset(ctx->scratch, 0, (size_t)frames * ch * sizeof(float));
        for (uint32_t c = 0; c < ch && c < NRT_METER_CHANNELS; c++) atomic_store_explicit(&ctx->peak[c], 0.f, memory_order_relaxed);
        return;
    }
    const uint32_t resume = atomic_load_explicit(&ctx->resumeFrames, memory_order_relaxed);
    if (resume > 0 && !atomic_load_explicit(&ctx->draining, memory_order_relaxed)) {
        const uint32_t readable = nrt_ring_readable(ctx->ring);
        bool starved = atomic_load_explicit(&ctx->starved, memory_order_relaxed);
        if (starved && readable >= resume) {
            atomic_store_explicit(&ctx->starved, false, memory_order_relaxed);
            starved = false;
        } else if (!starved && readable < frames) {
            atomic_store_explicit(&ctx->starved, true, memory_order_relaxed);
            atomic_fetch_add_explicit(&ctx->stalls, 1, memory_order_relaxed);
            starved = true;
        }
        if (starved) {
            // Hold: silence, nothing consumed, so playback resumes exactly where it stopped.
            memset(ctx->scratch, 0, (size_t)frames * ch * sizeof(float));
            for (uint32_t c = 0; c < ch && c < NRT_METER_CHANNELS; c++) atomic_store_explicit(&ctx->peak[c], 0.f, memory_order_relaxed);
            return;
        }
    }
    uint32_t got = nrt_ring_read(ctx->ring, ctx->scratch, frames);
    if (got < frames) {
        memset(ctx->scratch + (size_t)got * ch, 0, (size_t)(frames - got) * ch * sizeof(float));
        if (!atomic_load_explicit(&ctx->draining, memory_order_relaxed))
            atomic_fetch_add_explicit(&ctx->underruns, 1, memory_order_relaxed);
    }
    const bool integer = atomic_load_explicit(&ctx->integer, memory_order_relaxed);
    if (atomic_load_explicit(&ctx->dop, memory_order_relaxed)) { meter_dop(ctx, got, ch, integer); return; }
    if (atomic_load_explicit(&ctx->passthrough, memory_order_relaxed) && !integer) return;

    const double gain = integer ? 1.0 : atomic_load_explicit(&ctx->gain, memory_order_relaxed);
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

    // Meters (every decoded channel, up to NRT_METER_CHANNELS) and spectrum tap (L/R), post-gain.
    float peaks[NRT_METER_CHANNELS] = {0};
    const uint32_t metered = ch < NRT_METER_CHANNELS ? ch : NRT_METER_CHANNELS;
    uint32_t tw = atomic_load_explicit(&ctx->tapWrite, memory_order_relaxed);
    for (uint32_t f = 0; f < got; f++) {
        const float *frame = ctx->scratch + (size_t)f * ch;
        float values[NRT_METER_CHANNELS > 2 ? NRT_METER_CHANNELS : 2];
        for (uint32_t c = 0; c < metered || c < 2; c++) {
            const uint32_t src = c < ch ? c : 0;
            if (integer) { int32_t v; memcpy(&v, &frame[src], sizeof v); values[c] = (float)((double)v / 2147483648.0); }
            else values[c] = frame[src];
        }
        for (uint32_t c = 0; c < metered; c++) {
            const float a = fabsf(values[c]);
            if (a > peaks[c]) peaks[c] = a;
        }
        const float l = values[0], r = ch > 1 ? values[1] : l;
        atomic_store_explicit(&ctx->tap[tw & (NRT_TAP_SIZE - 1)], 0.5f * (l + r), memory_order_relaxed);
        tw++;
    }
    atomic_store_explicit(&ctx->tapWrite, tw, memory_order_release);
    for (uint32_t c = 0; c < metered; c++) store_peak_max(&ctx->peak[c], peaks[c]);
}

void nrt_context_render_interleaved(NRTRenderContext *ctx, float *out, uint32_t frames, uint32_t outChannels) {
    if (!out || outChannels == 0) return;
    const uint32_t ch = nrt_ring_channels(ctx->ring);
    uint32_t done = 0;
    while (done < frames) {
        uint32_t n = frames - done;
        if (n > ctx->scratchFrames) n = ctx->scratchFrames;
        pull(ctx, n);
        const float *src = ctx->scratch;
        uint32_t srcCh = ch;
        if (ctx->processor) {
            ctx->processor(ctx->processorUser, ctx->scratch, ch, ctx->processed, ctx->processedChannels, n);
            src = ctx->processed;
            srcCh = ctx->processedChannels;
        }
        if (atomic_load_explicit(&ctx->integer, memory_order_relaxed)) {
            // Integer samples: copy the 32-bit words as integers so no bit pattern is touched.
            for (uint32_t f = 0; f < n; f++) {
                uint32_t *o = (uint32_t *)(out + (size_t)(done + f) * outChannels);
                const uint32_t *s = (const uint32_t *)(src + (size_t)f * srcCh);
                for (uint32_t c = 0; c < outChannels; c++) o[c] = c < srcCh ? s[c] : 0u;
            }
        } else {
            for (uint32_t f = 0; f < n; f++) {
                float *o = out + (size_t)(done + f) * outChannels;
                const float *s = src + (size_t)f * srcCh;
                for (uint32_t c = 0; c < outChannels; c++) o[c] = c < srcCh ? s[c] : 0.f;
            }
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
        const float *src = ctx->scratch;
        uint32_t srcCh = ch;
        if (ctx->processor) {
            ctx->processor(ctx->processorUser, ctx->scratch, ch, ctx->processed, ctx->processedChannels, n);
            src = ctx->processed;
            srcCh = ctx->processedChannels;
        }
        uint32_t deviceChannel = 0;
        for (uint32_t bi = 0; bi < outOutputData->mNumberBuffers; bi++) {
            AudioBuffer *b = &outOutputData->mBuffers[bi];
            const uint32_t bch = b->mNumberChannels ? b->mNumberChannels : 1;
            const uint32_t capacity = b->mDataByteSize / (uint32_t)(sizeof(float) * bch);
            float *o = (float *)b->mData;
            if (!o) { deviceChannel += bch; continue; }
            for (uint32_t f = 0; f < n && done + f < capacity; f++) {
                for (uint32_t c = 0; c < bch; c++) {
                    const uint32_t from = deviceChannel + c;
                    // memcpy keeps integer-mode words bit-exact (floats are copied the same way).
                    const float zero = 0.f;
                    memcpy(&o[(size_t)(done + f) * bch + c], from < srcCh ? &src[(size_t)f * srcCh + from] : &zero, sizeof(float));
                }
            }
            deviceChannel += bch;
        }
        done += n;
    }
    atomic_fetch_add_explicit(&ctx->framesRendered, frames, memory_order_relaxed);
    return noErr;
}

// MARK: - Spatial audio bridge

struct NRTSpatial {
    AudioUnit au;
    uint32_t inChannels;
    uint32_t maxFrames;
    float *in;            // inChannels planes of maxFrames
    float *outL, *outR;   // maxFrames each
    AudioBufferList *outList;
    AudioTimeStamp time;
};

NRTSpatial *nrt_spatial_create(AudioUnit au, uint32_t inChannels, uint32_t maxFrames) {
    if (!au || inChannels == 0 || maxFrames == 0) return NULL;
    NRTSpatial *s = calloc(1, sizeof(NRTSpatial));
    if (!s) return NULL;
    s->au = au;
    s->inChannels = inChannels;
    s->maxFrames = maxFrames;
    s->in = calloc((size_t)inChannels * maxFrames, sizeof(float));
    s->outL = calloc(maxFrames, sizeof(float));
    s->outR = calloc(maxFrames, sizeof(float));
    s->outList = calloc(1, offsetof(AudioBufferList, mBuffers) + 2 * sizeof(AudioBuffer));
    if (!s->in || !s->outL || !s->outR || !s->outList) { nrt_spatial_destroy(s); return NULL; }
    s->outList->mNumberBuffers = 2;
    s->time.mFlags = kAudioTimeStampSampleTimeValid;
    s->time.mSampleTime = 0;
    return s;
}

void nrt_spatial_destroy(NRTSpatial *s) {
    if (!s) return;
    free(s->in); free(s->outL); free(s->outR); free(s->outList);
    free(s);
}

// The mixer pulls its input here: copy the planes the bridge prepared for this slice.
static OSStatus spatial_input(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                              UInt32 bus, UInt32 frames, AudioBufferList *io) {
    (void)flags; (void)time; (void)bus;
    NRTSpatial *s = (NRTSpatial *)refCon;
    if (!s || !io) return noErr;
    const uint32_t n = frames <= s->maxFrames ? frames : s->maxFrames;
    for (UInt32 b = 0; b < io->mNumberBuffers; b++) {
        float *plane = b < s->inChannels ? s->in + (size_t)b * s->maxFrames : NULL;
        AudioBuffer *buf = &io->mBuffers[b];
        if (buf->mData && plane) memcpy(buf->mData, plane, (size_t)n * sizeof(float));
        else if (buf->mData) memset(buf->mData, 0, (size_t)n * sizeof(float));
        else buf->mData = plane;
        buf->mDataByteSize = (UInt32)(n * sizeof(float));
    }
    return noErr;
}

OSStatus nrt_spatial_install(NRTSpatial *s) {
    AURenderCallbackStruct cb = { .inputProc = spatial_input, .inputProcRefCon = s };
    return AudioUnitSetProperty(s->au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb));
}

void nrt_spatial_process(void *user, const float *in, uint32_t inChannels, float *out, uint32_t outChannels, uint32_t frames) {
    NRTSpatial *s = (NRTSpatial *)user;
    if (!s || frames == 0) return;
    uint32_t done = 0;
    while (done < frames) {
        uint32_t n = frames - done;
        if (n > s->maxFrames) n = s->maxFrames;
        // De-interleave this slice into the mixer's input planes.
        for (uint32_t c = 0; c < s->inChannels; c++) {
            float *plane = s->in + (size_t)c * s->maxFrames;
            if (c < inChannels) for (uint32_t f = 0; f < n; f++) plane[f] = in[(size_t)(done + f) * inChannels + c];
            else memset(plane, 0, (size_t)n * sizeof(float));
        }
        s->outList->mBuffers[0] = (AudioBuffer){ 1, (UInt32)(n * sizeof(float)), s->outL };
        s->outList->mBuffers[1] = (AudioBuffer){ 1, (UInt32)(n * sizeof(float)), s->outR };
        AudioUnitRenderActionFlags flags = 0;
        OSStatus err = AudioUnitRender(s->au, &flags, &s->time, 0, n, s->outList);
        s->time.mSampleTime += n;
        const float *l = (const float *)s->outList->mBuffers[0].mData;
        const float *r = (const float *)s->outList->mBuffers[1].mData;
        for (uint32_t f = 0; f < n; f++) {
            float *o = out + (size_t)(done + f) * outChannels;
            o[0] = err == noErr && l ? l[f] : 0.f;
            if (outChannels > 1) o[1] = err == noErr && r ? r[f] : 0.f;
            for (uint32_t c = 2; c < outChannels; c++) o[c] = 0.f;
        }
        done += n;
    }
}
