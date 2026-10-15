#include "CVespertineRT.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// MARK: - DoP: the markers never break, and silence is DSD idle, never zeros
//
// Music frames are numbered: frame n carries n (left) and n + 0x8000 (right) as its 16 DSD bits, below 0x6969 on the
// left, so music never reads as idle, and each frame out can be traced to the frame written.

#define DOP_MAX_FRAMES 26000u
#define DOP_IDLE_BITS (NRT_DOP_IDLE << 8 | NRT_DOP_IDLE)

typedef struct {
    bool integer;
    uint64_t next;              // number of the next frame written
    uint64_t decoderFrame;      // the decoder's own position: its parity picks the marker, as RawDoPDecoder does
    float samples[DOP_MAX_FRAMES][2];
} DopWriter;

typedef struct {
    const DopWriter *w;
    uint32_t last;              // marker of the previous frame out
    uint64_t expect;            // number of the next music frame
    bool forwardOnly;           // two threads (seeks drop frames): music only has to move forward
    uint64_t frames, idle, music;
} DopCheck;

static float dop_encode(uint32_t marker, uint32_t bits, bool integer) {
    const uint32_t word = (marker << 16 | bits) << 8;
    float f;
    if (integer) { memcpy(&f, &word, sizeof f); return f; }
    int32_t s;
    memcpy(&s, &word, sizeof s);
    return (float)s / 2147483648.f;
}

static uint32_t dop_decode(float s, bool integer) {   // the 24-bit DoP word
    if (integer) { uint32_t v; memcpy(&v, &s, sizeof v); return v >> 8; }
    return (uint32_t)lrintf(s * 8388608.f) & 0xFFFFFFu;
}

static bool same_bits(float a, float b) { return memcmp(&a, &b, sizeof a) == 0; }

// Writes `frames` music frames (the ring must have room).
static void dop_write(NRTRing *ring, DopWriter *w, uint32_t frames) {
    float chunk[2 * 512];
    while (frames > 0) {
        const uint32_t n = frames < 512 ? frames : 512;
        for (uint32_t i = 0; i < n; i++) {
            const uint64_t f = w->next + i;
            assert(f < DOP_MAX_FRAMES);
            const uint32_t marker = (w->decoderFrame + i) & 1 ? 0xFAu : 0x05u;
            for (uint32_t c = 0; c < 2; c++)
                w->samples[f][c] = chunk[2 * i + c] = dop_encode(marker, (uint32_t)f + (c ? 0x8000u : 0u), w->integer);
        }
        const uint32_t wrote = nrt_ring_write(ring, chunk, n);
        assert(wrote == n); (void)wrote;
        w->next += n;
        w->decoderFrame += n;
        frames -= n;
    }
}

static void dop_check(DopCheck *k, const float *out, uint32_t frames) {
    const bool integer = k->w->integer;
    for (uint32_t f = 0; f < frames; f++) {
        const float *frame = out + 2 * f;
        const uint32_t left = dop_decode(frame[0], integer), right = dop_decode(frame[1], integer);
        const uint32_t marker = left >> 16;
        assert(marker == 0x05 || marker == 0xFA);
        assert(right >> 16 == marker);                  // one marker per frame, on every channel
        assert(marker != k->last);                      // never twice in a row: the DAC stays in DSD
        k->last = marker;
        k->frames++;
        if ((left & 0xFFFF) == DOP_IDLE_BITS) {
            // DSD silence on every channel, exactly as a DoP idle sample (not zeros).
            const float idle = dop_encode(marker, DOP_IDLE_BITS, integer);
            assert(same_bits(frame[0], idle) && same_bits(frame[1], idle));
            k->idle++;
        } else {
            const uint64_t n = left & 0xFFFF;
            if (k->forwardOnly) assert(n >= k->expect);
            else assert(n == k->expect);                // nothing lost, repeated or reordered
            assert(n < DOP_MAX_FRAMES);
            // Untouched: the very bits written (marker included).
            assert(same_bits(frame[0], k->w->samples[n][0]) && same_bits(frame[1], k->w->samples[n][1]));
            k->expect = n + 1;
            k->music++;
        }
    }
}

static void dop_render(NRTRenderContext *ctx, DopCheck *k, uint32_t frames) {
    static float out[2 * 2048];
    assert(frames <= 2048);
    for (uint32_t i = 0; i < 2 * frames; i++) out[i] = 1.f;    // nothing left over from before passes as output
    nrt_context_render_interleaved(ctx, out, frames, 2);
    dop_check(k, out, frames);
}

// Renders exactly what's buffered (plus the idle frames the markers need).
static void dop_render_all(NRTRenderContext *ctx, NRTRing *ring, DopCheck *k) {
    while (nrt_ring_readable(ring) > 0) {
        const uint32_t n = nrt_ring_readable(ring);
        dop_render(ctx, k, n < 2048 ? n : 2048);
    }
}

static void test_dop_silence(bool integer) {
    NRTRing *ring = nrt_ring_create(4096, 2);
    assert(ring);
    NRTRenderContext *ctx = nrt_context_create(ring, 512);
    assert(ctx);
    nrt_context_set_passthrough(ctx, true);
    nrt_context_set_integer(ctx, integer);
    nrt_context_set_dop(ctx, true);
    DopWriter *w = calloc(1, sizeof *w);
    assert(w);
    w->integer = integer;
    DopCheck k = {.w = w};

    // Music, in uneven slices: out untouched, no idle frame.
    dop_write(ring, w, 1001);                       // an odd count: ends on 0x05
    dop_render(ctx, &k, 300);
    dop_render(ctx, &k, 701);
    assert(k.music == 1001 && k.idle == 0 && nrt_context_take_underruns(ctx) == 0);

    // Pause (muted): idle frames carry the sequence on, nothing is taken from the ring.
    dop_write(ring, w, 600);
    dop_render(ctx, &k, 100);
    nrt_context_set_muted(ctx, true);
    uint64_t idle = k.idle;
    dop_render(ctx, &k, 257);
    assert(k.idle - idle == 257 && nrt_ring_readable(ring) == 500);
    assert(nrt_context_take_peak(ctx, 0) == 0.f);   // meters read silence
    // Resume: carries on from the frame it stopped at. 257 idle frames after frame 1100 (0x05) end on 0xFA, and
    // frame 1101 carries 0xFA too: one idle frame (0x05) goes first.
    nrt_context_set_muted(ctx, false);
    idle = k.idle;
    dop_render(ctx, &k, 250);
    assert(k.idle - idle == 1 && k.expect == 1101 + 249);
    // An even pause after 0xFA: the next frame (0x05) follows on without one.
    nrt_context_set_muted(ctx, true);
    dop_render(ctx, &k, 256);
    nrt_context_set_muted(ctx, false);
    idle = k.idle;
    dop_render(ctx, &k, 100);
    assert(k.idle == idle && k.expect == 1450);
    assert(nrt_context_take_underruns(ctx) == 0);

    // Running dry (a stall the decoder didn't cover): idle frames after the last one, counted as an underrun; the music
    // that arrives next follows on.
    dop_render(ctx, &k, 400);                       // 151 music, 249 idle
    assert(k.expect == 1601 && nrt_context_take_underruns(ctx) == 1);
    dop_write(ring, w, 300);
    dop_render_all(ctx, ring, &k);
    assert(k.expect == 1901);
    dop_render(ctx, &k, 3);
    (void)nrt_context_take_underruns(ctx);

    // Network hold (rebuffering): idle while too little is buffered, nothing consumed; resumes where it stopped.
    nrt_context_set_rebuffer(ctx, 200);
    dop_write(ring, w, 50);
    idle = k.idle;
    dop_render(ctx, &k, 128);
    assert(nrt_context_is_starved(ctx) && k.idle - idle == 128 && nrt_ring_readable(ring) == 50 && k.expect == 1901);
    assert(nrt_context_take_stalls(ctx) == 1 && nrt_context_take_underruns(ctx) == 0);
    dop_write(ring, w, 200);                        // 250 ≥ 200: resume from the first held frame
    dop_render(ctx, &k, 128);
    assert(!nrt_context_is_starved(ctx) && k.expect >= 1901 + 127);
    nrt_context_set_rebuffer(ctx, 0);
    dop_render_all(ctx, ring, &k);
    assert(k.expect == 2151);

    // A join that breaks the sequence (the next track starts on 0x05 right after one that ended on 0x05, as a decoder
    // does when nothing lines it up): one idle frame goes between them, mid-slice; every music frame still goes out.
    w->decoderFrame = 0;
    dop_write(ring, w, 101);                        // ends on 0x05
    w->decoderFrame = 0;
    dop_write(ring, w, 100);                        // starts on 0x05
    idle = k.idle;
    uint64_t music = k.music;
    dop_render(ctx, &k, 210);
    assert(k.music - music == 201 && k.expect == 2352 && k.idle - idle >= 1);
    (void)nrt_context_take_underruns(ctx);

    // A seek or skip with the device running: muted, the I/O thread drops the old position's look-ahead (idle
    // meanwhile), and the new position's music follows.
    dop_write(ring, w, 700);
    dop_render(ctx, &k, 64);
    nrt_context_set_muted(ctx, true);
    uint64_t target = nrt_context_discard(ctx);
    assert(target == nrt_ring_total_written(ring));
    idle = k.idle;
    dop_render(ctx, &k, 64);
    assert(k.idle - idle == 64 && nrt_ring_total_read(ring) == target && nrt_ring_readable(ring) == 0);
    uint64_t start = w->next;
    w->decoderFrame = 12345;                        // the new position: starts on 0xFA
    dop_write(ring, w, 400);
    nrt_context_set_muted(ctx, false);
    k.expect = start;                               // the old music is gone
    dop_render_all(ctx, ring, &k);
    assert(k.expect == start + 400 && nrt_context_take_underruns(ctx) == 0);

    // What's written after asking for the discard, before the I/O thread gets to it, is kept.
    dop_write(ring, w, 100);
    nrt_context_set_muted(ctx, true);
    target = nrt_context_discard(ctx);
    start = w->next;
    w->decoderFrame = 0;
    dop_write(ring, w, 200);
    dop_render(ctx, &k, 32);
    assert(nrt_ring_total_read(ring) == target && nrt_ring_readable(ring) == 200);
    nrt_context_set_muted(ctx, false);
    k.expect = start;
    dop_render_all(ctx, ring, &k);
    assert(k.expect == start + 200);

    // A discard withdrawn (the device was stopped instead) drops nothing.
    dop_write(ring, w, 10);
    (void)nrt_context_discard(ctx);
    nrt_context_cancel_discard(ctx);
    dop_render_all(ctx, ring, &k);
    assert(k.expect == start + 210);

    // The end of the queue (draining): the ring runs dry into idle frames, not an underrun.
    (void)nrt_context_take_underruns(ctx);
    nrt_context_set_draining(ctx, true);
    dop_write(ring, w, 50);
    dop_render(ctx, &k, 200);
    assert(k.expect == start + 260 && nrt_context_take_underruns(ctx) == 0);
    nrt_context_set_draining(ctx, false);

    // The device's own buffers (two mono streams): idle and music reach both channels, the markers alternating.
    AudioTimeStamp timestamp = {0};
    AudioBufferList input = {.mNumberBuffers = 0};
    AudioBufferList *list = calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
    assert(list);
    float left[96], right[96], frames[2 * 96];
    list->mNumberBuffers = 2;
    list->mBuffers[0] = (AudioBuffer){.mNumberChannels = 1, .mDataByteSize = sizeof left, .mData = left};
    list->mBuffers[1] = (AudioBuffer){.mNumberChannels = 1, .mDataByteSize = sizeof right, .mData = right};
    nrt_context_set_muted(ctx, true);
    nrt_device_ioproc(0, &timestamp, &input, &timestamp, list, &timestamp, ctx);
    for (uint32_t i = 0; i < 96; i++) { frames[2 * i] = left[i]; frames[2 * i + 1] = right[i]; }
    idle = k.idle;
    dop_check(&k, frames, 96);
    assert(k.idle - idle == 96);
    nrt_context_set_muted(ctx, false);
    dop_write(ring, w, 50);
    nrt_device_ioproc(0, &timestamp, &input, &timestamp, list, &timestamp, ctx);
    for (uint32_t i = 0; i < 96; i++) { frames[2 * i] = left[i]; frames[2 * i + 1] = right[i]; }
    dop_check(&k, frames, 96);
    assert(k.expect == start + 310);
    free(list);

    assert(k.frames == k.idle + k.music);
    free(w);
    nrt_context_destroy(ctx);
    nrt_ring_destroy(ring);
}

// PCM is unchanged: its silence is zeros.
static void test_pcm_silence_is_zeros(void) {
    NRTRing *ring = nrt_ring_create(256, 2);
    assert(ring);
    NRTRenderContext *ctx = nrt_context_create(ring, 64);
    assert(ctx);
    float data[128], out[128];
    for (int i = 0; i < 128; i++) data[i] = 0.25f;
    const uint32_t wrote = nrt_ring_write(ring, data, 64);
    assert(wrote == 64); (void)wrote;
    nrt_context_set_muted(ctx, true);
    nrt_context_render_interleaved(ctx, out, 32, 2);
    for (int i = 0; i < 64; i++) assert(out[i] == 0.f);
    nrt_context_set_muted(ctx, false);
    nrt_context_render_interleaved(ctx, out, 64, 2);
    for (int i = 0; i < 128; i++) assert(out[i] == 0.25f);
    nrt_context_render_interleaved(ctx, out, 16, 2);
    for (int i = 0; i < 32; i++) assert(out[i] == 0.f);
    nrt_context_destroy(ctx);
    nrt_ring_destroy(ring);
}

// Two threads, as in the app: the engine writes and seeks (mute, discard, wait for the I/O thread to drop it, write the
// new position) while the I/O thread renders. The markers must never break.
static NRTRing *dop_ring;
static NRTRenderContext *dop_ctx;
static DopWriter *dop_writer;
static atomic_bool dop_done;

static void *dop_engine(void *unused) {
    (void)unused;
    for (unsigned chunk = 0; dop_writer->next + 256 < DOP_MAX_FRAMES; chunk++) {
        while (nrt_ring_writable(dop_ring) < 256) sched_yield();
        if (chunk % 7 == 6) {
            // A seek: silenced, the look-ahead dropped by the I/O thread (waited for, as OutputSession.flush does),
            // then the new position.
            nrt_context_set_muted(dop_ctx, true);
            const uint64_t to = nrt_context_discard(dop_ctx);
            while (nrt_ring_total_read(dop_ring) < to) sched_yield();
            dop_writer->decoderFrame += chunk % 2;      // the new position, either parity
            dop_write(dop_ring, dop_writer, 256);
            nrt_context_set_muted(dop_ctx, false);
        } else if (chunk % 11 == 10) {
            // A pause: a few hundred idle frames, then on.
            nrt_context_set_muted(dop_ctx, true);
            const uint64_t from = nrt_context_frames_rendered(dop_ctx);
            while (nrt_context_frames_rendered(dop_ctx) < from + 300) sched_yield();
            nrt_context_set_muted(dop_ctx, false);
            dop_write(dop_ring, dop_writer, 256);
        } else {
            dop_write(dop_ring, dop_writer, 256);
        }
    }
    atomic_store(&dop_done, true);
    return NULL;
}

static void test_dop_threads(void) {
    dop_ring = nrt_ring_create(2048, 2);
    assert(dop_ring);
    dop_ctx = nrt_context_create(dop_ring, 512);
    assert(dop_ctx);
    nrt_context_set_passthrough(dop_ctx, true);
    nrt_context_set_dop(dop_ctx, true);
    dop_writer = calloc(1, sizeof *dop_writer);
    assert(dop_writer);
    DopCheck k = {.w = dop_writer, .forwardOnly = true};
    atomic_store(&dop_done, false);
    pthread_t thread;
    const int started = pthread_create(&thread, NULL, dop_engine, NULL);
    assert(!started); (void)started;
    float out[2 * 64];
    while (!atomic_load(&dop_done) || nrt_ring_readable(dop_ring) > 0) {
        nrt_context_render_interleaved(dop_ctx, out, 64, 2);
        dop_check(&k, out, 64);
    }
    pthread_join(thread, NULL);
    assert(k.music > 0 && k.frames == k.idle + k.music);
    free(dop_writer);
    nrt_context_destroy(dop_ctx);
    nrt_ring_destroy(dop_ring);
}

// Rewinding the look-ahead (as replanUpcoming does) while the I/O thread renders: frame n carries n, so anything the
// reader takes past the write position, or from a slot being rewritten, shows up as a wrong value. After a rewind that
// went through, the reader is never past the point taken back to.
#define REWIND_ROUNDS 300u
static NRTRing *rewind_ring;
static NRTRenderContext *rewind_ctx;
static atomic_bool rewind_done;

static void *rewind_reader(void *unused) {
    (void)unused;
    static float out[2 * 256];
    uint64_t checked = 0;
    while (!atomic_load(&rewind_done) || nrt_ring_readable(rewind_ring) > 0) {
        const uint64_t before = nrt_ring_total_read(rewind_ring);    // only this thread moves it
        nrt_context_render_interleaved(rewind_ctx, out, 256, 2);
        const uint64_t got = nrt_ring_total_read(rewind_ring) - before;
        assert(got <= 256 && nrt_ring_readable(rewind_ring) <= nrt_ring_capacity(rewind_ring));
        for (uint64_t i = 0; i < got; i++) assert(out[2 * i] == (float)(before + i) && out[2 * i + 1] == out[2 * i]);
        checked += got;
        sched_yield();
    }
    assert(checked > 0);
    return NULL;
}

static void test_concurrent_rewind(void) {
    rewind_ring = nrt_ring_create(8192, 1);
    assert(rewind_ring);
    rewind_ctx = nrt_context_create(rewind_ring, 512);
    assert(rewind_ctx);
    nrt_context_set_passthrough(rewind_ctx, true);
    nrt_context_set_draining(rewind_ctx, true);         // running dry between writes isn't what's tested here
    atomic_store(&rewind_done, false);
    pthread_t thread;
    const int started = pthread_create(&thread, NULL, rewind_reader, NULL);
    assert(!started); (void)started;
    static float chunk[512];
    unsigned rewound = 0;
    for (unsigned round = 0; round < REWIND_ROUNDS; round++) {
        while (nrt_ring_writable(rewind_ring) < 4096) sched_yield();
        for (unsigned k = 0; k < 8; k++) {
            const uint64_t w = nrt_ring_total_written(rewind_ring);
            assert(w + 512 < (1u << 24));               // exact as floats
            for (uint32_t i = 0; i < 512; i++) chunk[i] = (float)(w + i);
            const uint32_t wrote = nrt_ring_write(rewind_ring, chunk, 512);
            assert(wrote == 512); (void)wrote;
        }
        const uint64_t to = nrt_ring_total_written(rewind_ring) - 1024;
        if (nrt_ring_rewind(rewind_ring, to, 64)) {
            rewound++;
            assert(nrt_ring_total_written(rewind_ring) == to && nrt_ring_total_read(rewind_ring) <= to);
        }
    }
    atomic_store(&rewind_done, true);
    pthread_join(thread, NULL);
    assert(rewound > 0);
    nrt_context_destroy(rewind_ctx);
    nrt_ring_destroy(rewind_ring);
}

// The equalizer is replaced from another thread while the I/O thread renders: every slice must come out with one
// whole setting (here a preamp and a matching number of pass-through sections), never a mix of two.
#define EQ_ROUNDS 20000u
static NRTRenderContext *eq_ctx;
static atomic_bool eq_done;

static void *eq_writer(void *unused) {
    (void)unused;
    NRTBiquad unity[NRT_EQ_MAX_SECTIONS];
    for (uint32_t i = 0; i < NRT_EQ_MAX_SECTIONS; i++) unity[i] = (NRTBiquad){.b0 = 1};
    for (uint32_t round = 0; round < EQ_ROUNDS; round++) {
        const uint32_t k = 1 + round % 8;   // k sections, preamp 1/k: a slice reads k from both or it mixed two settings
        nrt_context_set_eq(eq_ctx, unity, k, 1.0 / k);
    }
    atomic_store(&eq_done, true);
    return NULL;
}

static void test_concurrent_eq(void) {
    NRTRing *ring = nrt_ring_create(1024, 2);
    eq_ctx = nrt_context_create(ring, 256);
    assert(ring && eq_ctx);
    nrt_context_set_gain(eq_ctx, 1.0, 32);   // no dither, so the output is exactly input × preamp
    atomic_store(&eq_done, false);
    pthread_t thread;
    const int started = pthread_create(&thread, NULL, eq_writer, NULL);
    assert(!started); (void)started;
    float in[512], out[512];
    for (uint32_t i = 0; i < 512; i++) in[i] = 1.0f;
    while (!atomic_load(&eq_done)) {
        nrt_ring_write(ring, in, 256);
        nrt_context_render_interleaved(eq_ctx, out, 256, 2);
        for (uint32_t i = 1; i < 512; i++) assert(out[i] == out[0]);   // one setting for the whole slice
        const float k = 1.0f / out[0];
        assert(out[0] == 1.0f || fabsf(k - roundf(k)) < 1e-4f);
    }
    pthread_join(thread, NULL);
    nrt_context_destroy(eq_ctx);
    nrt_ring_destroy(ring);
}

// Room correction: each channel gets its own delay, gain and sections; channels past the count are untouched; off
// (or integer samples) leaves the samples bit-exact.
static void test_room(void) {
    NRTRing *ring = nrt_ring_create(4096, 3);
    NRTRenderContext *ctx = nrt_context_create(ring, 512);
    assert(ring && ctx);
    nrt_context_set_gain(ctx, 1.0, 32);
    NRTRoomChannel room[2];
    memset(room, 0, sizeof room);
    room[0] = (NRTRoomChannel){.delayFrames = 5, .gain = 0.5, .count = 0};
    room[1] = (NRTRoomChannel){.delayFrames = 0, .gain = 1.0, .count = 1};
    room[1].sections[0] = (NRTBiquad){.b0 = 2};
    nrt_context_set_room(ctx, room, 2);

    float in[3 * 64] = {0}, out[3 * 64];
    for (uint32_t f = 0; f < 64; f++) { in[f * 3] = f == 0 ? 1.0f : 0.0f; in[f * 3 + 1] = 0.25f; in[f * 3 + 2] = 0.125f; }
    nrt_ring_write(ring, in, 64);
    nrt_context_render_interleaved(ctx, out, 64, 3);
    for (uint32_t f = 0; f < 64; f++) {
        assert(out[f * 3] == (f == 5 ? 0.5f : 0.0f));   // the impulse, 5 frames late, at half level
        assert(out[f * 3 + 1] == 0.5f);                  // doubled by its section
        assert(out[f * 3 + 2] == 0.125f);                // past the count: untouched
    }
    // The delay line carries across slices: an impulse at the last frame comes out 5 frames into the next slice.
    memset(in, 0, sizeof in);
    in[63 * 3] = 1.0f;
    nrt_ring_write(ring, in, 64);
    nrt_context_render_interleaved(ctx, out, 64, 3);
    memset(in, 0, sizeof in);
    nrt_ring_write(ring, in, 64);
    nrt_context_render_interleaved(ctx, out, 64, 3);
    for (uint32_t f = 0; f < 64; f++) assert(out[f * 3] == (f == 4 ? 0.5f : 0.0f));

    // Off: the samples pass bit-exact again, and turning it back on starts the delay line from silence (it last held
    // ones, which would otherwise come out first).
    for (uint32_t f = 0; f < 64; f++) in[f * 3] = 1.0f;
    nrt_ring_write(ring, in, 64);
    nrt_context_render_interleaved(ctx, out, 64, 3);
    assert(out[63 * 3] == 0.5f);
    nrt_context_set_room(ctx, NULL, 0);
    for (uint32_t f = 0; f < 64; f++) { in[f * 3] = 0.3f; in[f * 3 + 1] = -0.7f; in[f * 3 + 2] = 0.9f; }
    nrt_ring_write(ring, in, 64);
    nrt_context_render_interleaved(ctx, out, 64, 3);
    assert(!memcmp(in, out, sizeof in));
    nrt_context_set_room(ctx, room, 2);
    memset(in, 0, sizeof in);
    nrt_ring_write(ring, in, 64);
    nrt_context_render_interleaved(ctx, out, 64, 3);
    for (uint32_t f = 0; f < 64; f++) assert(out[f * 3] == 0.0f);

    // Integer samples are never touched.
    nrt_context_set_integer(ctx, true);
    for (uint32_t f = 0; f < 64; f++) { in[f * 3] = 0.3f; in[f * 3 + 1] = -0.7f; in[f * 3 + 2] = 0.9f; }
    nrt_ring_write(ring, in, 64);
    nrt_context_render_interleaved(ctx, out, 64, 3);
    assert(!memcmp(in, out, sizeof in));
    nrt_context_destroy(ctx);
    nrt_ring_destroy(ring);
}

// Room correction replaced from another thread while the I/O thread renders: every slice gets one whole setting.
static NRTRenderContext *room_ctx;
static atomic_bool room_done;

static void *room_writer(void *unused) {
    (void)unused;
    NRTRoomChannel room[2];
    memset(room, 0, sizeof room);
    for (uint32_t round = 0; round < EQ_ROUNDS; round++) {
        const uint32_t k = 1 + round % 8;   // k unity sections and gain 1/k on both channels
        for (uint32_t c = 0; c < 2; c++) {
            room[c].gain = 1.0 / k;
            room[c].count = k;
            for (uint32_t i = 0; i < k; i++) room[c].sections[i] = (NRTBiquad){.b0 = 1};
        }
        nrt_context_set_room(room_ctx, room, 2);
    }
    atomic_store(&room_done, true);
    return NULL;
}

static void test_concurrent_room(void) {
    NRTRing *ring = nrt_ring_create(1024, 2);
    room_ctx = nrt_context_create(ring, 256);
    assert(ring && room_ctx);
    nrt_context_set_gain(room_ctx, 1.0, 32);
    atomic_store(&room_done, false);
    pthread_t thread;
    const int started = pthread_create(&thread, NULL, room_writer, NULL);
    assert(!started); (void)started;
    float in[512], out[512];
    for (uint32_t i = 0; i < 512; i++) in[i] = 1.0f;
    while (!atomic_load(&room_done)) {
        nrt_ring_write(ring, in, 256);
        nrt_context_render_interleaved(room_ctx, out, 256, 2);
        for (uint32_t i = 1; i < 512; i++) assert(out[i] == out[0]);
        const float k = 1.0f / out[0];
        assert(out[0] == 1.0f || fabsf(k - roundf(k)) < 1e-4f);
    }
    pthread_join(thread, NULL);
    nrt_context_destroy(room_ctx);
    nrt_ring_destroy(ring);
}

// MARK: - FIR filters: convolution matches direct convolution, unfiltered channels are a bit-exact delayed copy, new
// filters fade in over one block, and a seek starts from silence

static uint32_t fir_seed = 12345;
static float fir_random(void) {   // −0.5 ..< 0.5
    fir_seed = fir_seed * 1664525u + 1013904223u;
    return (float)(fir_seed >> 8) / 16777216.f - 0.5f;
}

#define FIR_TEST_FRAMES 12000u
#define FIR_TEST_TAPS 1500u

static void test_fir(void) {
    NRTRing *ring = nrt_ring_create(4096, 3);
    NRTRenderContext *ctx = nrt_context_create(ring, 1024);
    assert(ring && ctx);
    nrt_context_set_gain(ctx, 1.0, 32);
    assert(nrt_context_fir_latency(ctx) == 0);
    assert(nrt_context_set_fir(ctx, NULL, 0, 0));          // nothing to filter: no convolver, no latency
    assert(nrt_context_fir_latency(ctx) == 0);

    static float h[FIR_TEST_TAPS];
    for (uint32_t i = 0; i < FIR_TEST_TAPS; i++) h[i] = fir_random() / 8;
    const float *impulses[2] = {h, NULL};                  // left filtered, middle unfiltered, right past the count
    assert(nrt_context_set_fir(ctx, impulses, 2, FIR_TEST_TAPS));
    assert(nrt_context_fir_latency(ctx) == NRT_FIR_BLOCK);

    static float in[FIR_TEST_FRAMES * 3], out[FIR_TEST_FRAMES * 3];
    for (uint32_t i = 0; i < FIR_TEST_FRAMES * 3; i++) in[i] = fir_random();
    const uint32_t slices[] = {37, 300, 511, 512, 513, 1024, 1, 900};
    uint32_t done = 0;
    for (uint32_t s = 0; done < FIR_TEST_FRAMES; s++) {
        uint32_t n = slices[s % 8];
        if (n > FIR_TEST_FRAMES - done) n = FIR_TEST_FRAMES - done;
        assert(nrt_ring_write(ring, in + done * 3, n) == n);
        nrt_context_render_interleaved(ctx, out + done * 3, n, 3);
        done += n;
    }
    double worst = 0;
    for (uint32_t f = 0; f < FIR_TEST_FRAMES; f++) {
        double want = 0;
        if (f >= NRT_FIR_BLOCK)
            for (uint32_t k = 0; k < FIR_TEST_TAPS && k <= f - NRT_FIR_BLOCK; k++) want += (double)h[k] * in[(f - NRT_FIR_BLOCK - k) * 3];
        const double error = fabs(out[f * 3] - want);
        if (f >= 2 * NRT_FIR_BLOCK && error > worst) worst = error;   // the block before fades in from unfiltered
        const float late1 = f >= NRT_FIR_BLOCK ? in[(f - NRT_FIR_BLOCK) * 3 + 1] : 0.f;
        const float late2 = f >= NRT_FIR_BLOCK ? in[(f - NRT_FIR_BLOCK) * 3 + 2] : 0.f;
        assert(same_bits(out[f * 3 + 1], late1) && same_bits(out[f * 3 + 2], late2));
    }
    assert(worst < 1e-6);

    // Filters off: the convolver stays, so the latency doesn't jump, and after the fade every channel is a bit-exact
    // copy, a block late.
    assert(nrt_context_set_fir(ctx, NULL, 0, 0));
    assert(nrt_context_fir_latency(ctx) == NRT_FIR_BLOCK);
    for (uint32_t i = 0; i < 4 * NRT_FIR_BLOCK * 3; i++) in[i] = fir_random();
    for (uint32_t b = 0; b < 4; b++) {
        nrt_ring_write(ring, in + b * NRT_FIR_BLOCK * 3, NRT_FIR_BLOCK);
        nrt_context_render_interleaved(ctx, out + b * NRT_FIR_BLOCK * 3, NRT_FIR_BLOCK, 3);
    }
    for (uint32_t f = 2 * NRT_FIR_BLOCK; f < 4 * NRT_FIR_BLOCK; f++)
        for (uint32_t c = 0; c < 3; c++) assert(same_bits(out[f * 3 + c], in[(f - NRT_FIR_BLOCK) * 3 + c]));

    // A new filter fades in over one block: steady 0.5 into a gain of 1 then 2 ramps from 0.5 to 1 with no step.
    static float one[1] = {1.f}, two[1] = {2.f};
    const float *gain1[1] = {one}, *gain2[1] = {two};
    assert(nrt_context_set_fir(ctx, gain1, 1, 1));
    for (uint32_t i = 0; i < 6 * NRT_FIR_BLOCK * 3; i++) in[i] = 0.5f;
    for (uint32_t b = 0; b < 6; b++) {
        if (b == 3) assert(nrt_context_set_fir(ctx, gain2, 1, 1));
        nrt_ring_write(ring, in, NRT_FIR_BLOCK);
        nrt_context_render_interleaved(ctx, out + b * NRT_FIR_BLOCK * 3, NRT_FIR_BLOCK, 3);
    }
    assert(fabsf(out[(3 * NRT_FIR_BLOCK - 1) * 3] - 0.5f) < 1e-6f);
    assert(fabsf(out[(6 * NRT_FIR_BLOCK - 1) * 3] - 1.0f) < 1e-6f);
    for (uint32_t f = 3 * NRT_FIR_BLOCK; f < 6 * NRT_FIR_BLOCK; f++)
        assert(fabsf(out[f * 3] - out[(f - 1) * 3]) < 0.5f / NRT_FIR_BLOCK + 1e-5f);

    // A seek: nothing from before comes out after, whatever was half-collected.
    nrt_ring_write(ring, in, 200);
    nrt_context_render_interleaved(ctx, out, 200, 3);
    nrt_ring_reset(ring);
    nrt_context_reset_history(ctx);
    memset(in, 0, 4 * NRT_FIR_BLOCK * 3 * sizeof(float));
    nrt_ring_write(ring, in, 2 * NRT_FIR_BLOCK);
    nrt_context_render_interleaved(ctx, out, 2 * NRT_FIR_BLOCK, 3);
    for (uint32_t i = 0; i < 2 * NRT_FIR_BLOCK * 3; i++) assert(out[i] == 0.f);

    // Integer samples skip the convolver altogether.
    nrt_context_set_integer(ctx, true);
    for (uint32_t i = 0; i < 64 * 3; i++) in[i] = fir_random();
    nrt_ring_write(ring, in, 64);
    nrt_context_render_interleaved(ctx, out, 64, 3);
    assert(!memcmp(in, out, 64 * 3 * sizeof(float)));
    nrt_context_destroy(ctx);
    nrt_ring_destroy(ring);
}

// Filters replaced from another thread while the I/O thread renders: both channels always play the same setting
// (or the same fade between two), never a mix of a bank half-written.
static NRTRenderContext *fir_ctx;
static atomic_bool fir_done;

static void *fir_writer(void *unused) {
    (void)unused;
    static float taps[8][64];
    for (uint32_t round = 0; round < EQ_ROUNDS; round++) {
        const uint32_t k = 1 + round % 8, length = 1 + (round * 7) % 64;
        for (uint32_t i = 0; i < length; i++) taps[k - 1][i] = i == length - 1 ? 1.f / k : 0.f;
        const float *impulses[2] = {taps[k - 1], taps[k - 1]};
        assert(nrt_context_set_fir(fir_ctx, impulses, 2, length));
    }
    atomic_store(&fir_done, true);
    return NULL;
}

static void test_concurrent_fir(void) {
    NRTRing *ring = nrt_ring_create(1024, 2);
    fir_ctx = nrt_context_create(ring, 256);
    assert(ring && fir_ctx);
    nrt_context_set_gain(fir_ctx, 1.0, 32);
    const float unit[1] = {1.f};
    const float *impulses[2] = {unit, unit};
    assert(nrt_context_set_fir(fir_ctx, impulses, 2, 1));
    atomic_store(&fir_done, false);
    pthread_t thread;
    const int started = pthread_create(&thread, NULL, fir_writer, NULL);
    assert(!started); (void)started;
    float in[512], out[512];
    for (uint32_t i = 0; i < 512; i++) in[i] = 1.0f;
    uint64_t rendered = 0;
    while (!atomic_load(&fir_done)) {
        nrt_ring_write(ring, in, 256);
        nrt_context_render_interleaved(fir_ctx, out, 256, 2);
        rendered += 256;
        for (uint32_t f = 0; f < 256; f++) {
            assert(out[2 * f] == out[2 * f + 1]);
            if (rendered > 4096) assert(isfinite(out[2 * f]) && out[2 * f] > 0.12f && out[2 * f] < 1.0001f);
        }
    }
    pthread_join(thread, NULL);
    nrt_context_destroy(fir_ctx);
    nrt_ring_destroy(ring);
}

static NRTRing *concurrent_ring;
static NRTRenderContext *concurrent_context;
static void *producer(void *unused) {
    (void)unused;
    for (unsigned i = 0; i < 200000; i++) {
        float sample = (float)i;
        while (!nrt_ring_write(concurrent_ring, &sample, 1)) {}
    }
    return NULL;
}
static void *tap_reader(void *unused) {
    (void)unused;
    float tap[1024];
    for (int i = 0; i < 10000; i++) nrt_context_copy_tap(concurrent_context, tap, 1024);
    return NULL;
}
// MARK: - Capture: the recorder interleaves every input stream, and reports jumps in the input's sample time

static void capture_audit(void) {
    NRTRing *ring = nrt_ring_create(4096, 2);
    NRTCapture *capture = nrt_capture_create(ring, 512);
    assert(ring && capture);
    float left[512], right[512];
    AudioBufferList *list = calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
    list->mNumberBuffers = 2;
    list->mBuffers[0] = (AudioBuffer){.mNumberChannels = 1, .mDataByteSize = sizeof left, .mData = left};
    list->mBuffers[1] = (AudioBuffer){.mNumberChannels = 1, .mDataByteSize = sizeof right, .mData = right};
    AudioTimeStamp time = {.mSampleTime = 1000, .mFlags = kAudioTimeStampSampleTimeValid};
    AudioBufferList none = {.mNumberBuffers = 0};
    for (int slice = 0; slice < 6; slice++) {
        for (int i = 0; i < 512; i++) { left[i] = (float)(slice * 512 + i); right[i] = -(float)(slice * 512 + i); }
        if (slice == 4) time.mSampleTime += 100;   // the recorder missed 100 frames before slice 4
        nrt_capture_ioproc(0, &time, list, &time, &none, &time, capture);
        time.mSampleTime += 512;
    }
    uint64_t positions[4] = {0};
    assert(nrt_capture_discontinuities(capture, positions, 4) == 1 && positions[0] == 4 * 512);
    assert(nrt_capture_frames(capture) == 6 * 512 && nrt_capture_overflow(capture) == 0);
    float frame[2];
    for (uint32_t i = 0; i < 6 * 512; i++) {
        assert(nrt_ring_read(ring, frame, 1) == 1);
        assert(frame[0] == (float)i && frame[1] == -(float)i);
    }
    // A full ring loses frames, and says where.
    for (int slice = 0; slice < 10; slice++) {
        nrt_capture_ioproc(0, &time, list, &time, &none, &time, capture);
        time.mSampleTime += 512;
    }
    assert(nrt_capture_overflow(capture) == 10 * 512 - nrt_ring_capacity(ring));
    // Two slices didn't fit: two events, both where the ring filled.
    assert(nrt_capture_discontinuities(capture, positions, 4) == 3);
    assert(positions[1] == 6 * 512 + nrt_ring_capacity(ring) && positions[2] == positions[1]);
    // No input buffers, or empty ones: nothing recorded, no crash.
    nrt_capture_ioproc(0, &time, &none, &time, &none, &time, capture);
    list->mBuffers[1].mData = NULL;
    nrt_ring_reset(ring);
    nrt_capture_ioproc(0, &time, list, &time, &none, &time, capture);
    assert(nrt_ring_readable(ring) == 512);
    free(list);
    nrt_capture_destroy(capture);
    nrt_ring_destroy(ring);
}

int main(void) {
    capture_audit();
    alarm(30);
    concurrent_ring = nrt_ring_create(256, 1);
    assert(concurrent_ring);
    pthread_t thread;
    // Not inside assert(): with -DNDEBUG the thread would never start.
    int started = pthread_create(&thread, NULL, producer, NULL);
    assert(!started); (void)started;
    for (unsigned i = 0; i < 200000; i++) {
        float sample;
        while (!nrt_ring_read(concurrent_ring, &sample, 1)) {}
        assert(sample == (float)i);
    }
    pthread_join(thread, NULL);
    nrt_ring_destroy(concurrent_ring);

    NRTRing *ring = nrt_ring_create(1024, 2);
    NRTRenderContext *ctx = nrt_context_create(ring, 512);
    concurrent_context = ctx;
    started = pthread_create(&thread, NULL, tap_reader, NULL);
    assert(!started);
    float data[2048] = {0}, output[2048];
    for (int i = 0; i < 10000; i++) {
        nrt_ring_write(ring, data, 1024);
        nrt_context_render_interleaved(ctx, output, 1024, 2);
    }
    pthread_join(thread, NULL);

    AudioTimeStamp timestamp = {0};
    AudioBufferList input = {.mNumberBuffers = 0};
    AudioBufferList *list = calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
    list->mNumberBuffers = 2;
    list->mBuffers[0] = (AudioBuffer){.mNumberChannels = 1, .mDataByteSize = 8 * sizeof(float), .mData = calloc(8, sizeof(float))};
    list->mBuffers[1] = (AudioBuffer){.mNumberChannels = 1, .mDataByteSize = 4 * sizeof(float), .mData = calloc(4, sizeof(float))};
    nrt_device_ioproc(0, &timestamp, &input, &timestamp, list, &timestamp, ctx);
    free(list->mBuffers[0].mData); free(list->mBuffers[1].mData);
    list->mNumberBuffers = 1;
    list->mBuffers[0] = (AudioBuffer){.mNumberChannels = 2, .mDataByteSize = 16, .mData = NULL};
    nrt_device_ioproc(0, &timestamp, &input, &timestamp, list, &timestamp, ctx);
    free(list);
    nrt_context_destroy(ctx); nrt_ring_destroy(ring);

    test_dop_silence(false);
    test_dop_silence(true);
    test_pcm_silence_is_zeros();
    test_dop_threads();
    test_concurrent_rewind();
    test_concurrent_eq();
    test_room();
    test_concurrent_room();
    test_fir();
    test_concurrent_fir();
    return 0;
}
