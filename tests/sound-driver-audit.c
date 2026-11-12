// Mac Sound Output (beta): the driver's pure helpers under the sanitizers. Runs anywhere (no Core Audio):
//   clang -std=c11 -O1 -g -fsanitize=address,undefined -I Driver/VespertineSound tests/sound-driver-audit.c -o sound-driver-audit && ./sound-driver-audit

#include "VespertineSoundShared.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#define RING 64u
#define STRIDE VESPERTINE_SOUND_MAX_CHANNELS

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static float sample(uint64_t frame, uint32_t channel) { return (float)(frame % 1000) / 1000.0f + (float)channel; }

// What is written at a sample time comes back at the same sample time, channel for channel, scaled by the gain.
static void roundTrip(uint32_t channels, float gain, uint64_t start, uint32_t frames) {
    float *ring = calloc((size_t)RING * STRIDE, sizeof(float));
    float *in = malloc((size_t)frames * channels * sizeof(float));
    float *out = malloc((size_t)frames * channels * sizeof(float));
    for (uint32_t f = 0; f < frames; f++) for (uint32_t c = 0; c < channels; c++) in[f * channels + c] = sample(start + f, c);
    VespertineSoundWriteRing(ring, RING, STRIDE, in, frames, channels, start, gain);
    VespertineSoundReadRing(ring, RING, STRIDE, out, frames, channels, start);
    for (uint32_t f = 0; f < frames; f++) for (uint32_t c = 0; c < channels; c++) {
        float want = sample(start + f, c) * gain;
        CHECK(out[f * channels + c] == want, "channels %u frame %u ch %u: %f != %f", channels, f, c, out[f * channels + c], want);
    }
    // Read again: what was read has been cleared, so a stretch nobody wrote again is silence.
    VespertineSoundReadRing(ring, RING, STRIDE, out, frames, channels, start);
    for (uint32_t i = 0; i < frames * channels; i++) CHECK(out[i] == 0, "stale sample %u after read: %f", i, out[i]);
    free(ring); free(in); free(out);
}

int main(void) {
    // Every channel count a group can have, across the ring's wrap, at unity, at a cut and muted.
    for (uint32_t channels = 1; channels <= VESPERTINE_SOUND_MAX_CHANNELS; channels++) {
        roundTrip(channels, 1.0f, 0, 16);
        roundTrip(channels, 0.5f, RING - 5, 16);          // wraps
        roundTrip(channels, 0.0f, 3 * RING + 7, RING);    // a whole ring, muted
    }

    // Channels past the device's count are never touched (the ring is shared stride, channels vary).
    {
        float ring[RING * STRIDE];
        for (uint32_t i = 0; i < RING * STRIDE; i++) ring[i] = 7.0f;
        float in[2 * 4] = { 1, 2, 3, 4, 5, 6, 7, 8 };
        VespertineSoundWriteRing(ring, RING, STRIDE, in, 4, 2, 10, 1.0f);
        for (uint32_t f = 10; f < 14; f++) for (uint32_t c = 2; c < STRIDE; c++) CHECK(ring[f * STRIDE + c] == 7.0f, "channel %u of frame %u was written", c, f);
    }

    // More channels than the stride are clamped, never written past the frame.
    {
        float ring[RING * STRIDE + 1];
        ring[RING * STRIDE] = 42.0f;
        float in[20 * 1];
        for (int i = 0; i < 20; i++) in[i] = 1.0f;
        VespertineSoundWriteRing(ring, RING, STRIDE, in, 1, 20, RING - 1, 1.0f);
        CHECK(ring[RING * STRIDE] == 42.0f, "write went past the ring");
    }

    // Default layouts: stereo is L R, 5.1 is L R C LFE Ls Rs, odd counts are numbered channels.
    {
        uint32_t labels[VESPERTINE_SOUND_MAX_CHANNELS];
        VespertineSoundDefaultLabels(2, labels);
        CHECK(labels[0] == VS_LABEL_LEFT && labels[1] == VS_LABEL_RIGHT, "stereo labels");
        VespertineSoundDefaultLabels(6, labels);
        CHECK(labels[2] == VS_LABEL_CENTER && labels[3] == VS_LABEL_LFE && labels[5] == VS_LABEL_RIGHT_SURROUND, "5.1 labels");
        VespertineSoundDefaultLabels(12, labels);
        CHECK(labels[0] == VS_LABEL_DISCRETE_0 && labels[11] == VS_LABEL_DISCRETE_0 + 11, "discrete labels");
    }

    if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    printf("sound driver audit: all checks passed\n");
    return 0;
}
