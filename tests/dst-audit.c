// The DST decoder on frames that can't be valid, under the address and undefined-behavior sanitizers (scripts/audit.sh
// builds it with -fno-sanitize-recover, so any overflow or out-of-bounds read stops the audit). Every frame here is
// made up; none comes from a disc.
#include "CVespertineDST.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FRAME_BYTES 4704

typedef struct { uint8_t *b; long bit; } Bits;

static void put(Bits *w, unsigned v, int n) {
    for (int i = n - 1; i >= 0; i--) {
        if (v >> i & 1) w->b[w->bit >> 3] |= (uint8_t)(0x80 >> (w->bit & 7));
        w->bit++;
    }
}

static bool decode(NDSTDecoder *d, const uint8_t *frame, int size, int channels) {
    uint8_t *out = malloc((size_t)FRAME_BYTES * (size_t)channels);
    bool ok = ndst_decode(d, frame, size, out);
    if (!ok) for (int i = 0; i < FRAME_BYTES * channels; i++) assert(out[i] == 0x69);   // rejected frames are DSD silence
    free(out);
    return ok;
}

int main(void) {
    NDSTDecoder *d = ndst_create(2, FRAME_BYTES);
    assert(d);

    // A stored frame with 1 byte of its 9408.
    const uint8_t stored[] = {0x00, 0x12};
    assert(!decode(d, stored, sizeof stored, 2));

    // A Rice-coded filter whose prediction would reach INT_MIN: method 1, two zero coefficients, a residual of 2^22,
    // then zeros (k = 7). FFmpeg's arithmetic negates INT_MIN here.
    Bits w = { calloc(1, 1 << 16), 0 };
    put(&w, 1, 1); put(&w, 7, 3); put(&w, 1, 1); put(&w, 1, 1); put(&w, 0, 2);
    put(&w, 127, 7); put(&w, 1, 1); put(&w, 1, 2); put(&w, 0, 9); put(&w, 0, 9); put(&w, 7, 3);
    w.bit += 1 << 15; put(&w, 1, 1); put(&w, 0, 7); put(&w, 0, 1);
    for (int j = 3; j < 128; j++) { put(&w, 1, 1); put(&w, 0, 7); }
    put(&w, 0, 6); put(&w, 0, 1); put(&w, 0, 7); put(&w, 0, 1);
    assert(!decode(d, w.b, (int)((w.bit + 7) / 8) + 64, 2));
    free(w.b);

    // A coded frame of zeros past its header is valid DST (the reference decoder takes it too): it decodes, and
    // reading past its end stays inside the decoder's padding.
    const uint8_t zeros[] = {0xFC, 0, 0, 0, 0, 0, 0, 0};
    assert(decode(d, zeros, sizeof zeros, 2));
    ndst_destroy(d);

    // Random frames, every size from 1 byte up, for each channel count: whatever they decode to, nothing overflows.
    srand(7);
    int rejected = 0, runs = 0;
    for (int channels = 1; channels <= 6; channels++) {
        NDSTDecoder *c = ndst_create(channels, FRAME_BYTES);
        for (int r = 0; r < 300; r++) {
            int size = 1 + rand() % 6000;
            uint8_t *frame = malloc((size_t)size);
            for (int i = 0; i < size; i++) frame[i] = (uint8_t)rand();
            if (r % 2) frame[0] |= 0xF0;      // DST-coded, one segment: reach the tables and the arithmetic decoder
            rejected += !decode(c, frame, size, channels);
            runs++;
            free(frame);
        }
        ndst_destroy(c);
    }
    printf("dst-audit: %d random frames, %d rejected; crafted frames handled\n", runs, rejected);
    return 0;
}
