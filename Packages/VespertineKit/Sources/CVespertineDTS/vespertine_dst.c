//
// Vespertine — DST (Direct Stream Transfer) decoding to raw DSD, for SACD images.
//
// Derived from FFmpeg's DST decoder (libavcodec/dstdec.c, Copyright (c) 2014 Peter Ross <pross@xvid.org>),
// which is free software under the GNU Lesser General Public License, version 2.1 or later. This file keeps
// that license: you can redistribute it and/or modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU Lesser General Public
// License (Vendor/FFmpegDCA.xcframework/LICENSE.FFmpeg-LGPL-2.1.txt) for details.
//
// Changed from FFmpeg's decoder for Vespertine on 2026-10-09: it stands alone (its own bit reader instead of
// FFmpeg's internal one); it hands back the decoded DSD itself, so it can go out over DoP, instead of converting
// it to PCM; and it rejects frames that are cut short or can't be valid (a short stored frame, tables that run
// past the frame, filter coefficients out of range, arithmetic code left unread) instead of decoding them.
//
// The format: ISO/IEC 14496-3, subpart 10 (lossless coding of oversampled audio).
//
// SPDX-License-Identifier: LGPL-2.1-or-later
//
#include "CVespertineDST.h"
#include <stdlib.h>
#include <string.h>

#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "The filter status below is read as little-endian bytes"
#endif

#define DST_MAX_CHANNELS 6
#define DST_MAX_ELEMENTS (2 * DST_MAX_CHANNELS)
/// The silence pattern for DSD bytes.
#define DSD_SILENCE 0x69

static const int8_t fsets_code_pred_coeff[3][3] = {
    {  -8 },
    { -16,  8 },
    {  -9, -5, 6 },
};

static const int8_t probs_code_pred_coeff[3][3] = {
    {  -8 },
    { -16,  8 },
    { -24, 24, -8 },
};

typedef struct {
    unsigned elements;
    unsigned length[DST_MAX_ELEMENTS];
    int coeff[DST_MAX_ELEMENTS][128];
} Table;

/// Most significant bit first. Reads past the end give zeros (the buffer has 4 zero bytes of padding).
typedef struct {
    const uint8_t *data;
    int64_t bits, pos;
} BitReader;

struct NDSTDecoder {
    int channels, frameBytes;
    Table fsets, probs;
    union { uint64_t word[2]; uint8_t byte[16]; } status[DST_MAX_CHANNELS];
    int16_t filter[DST_MAX_ELEMENTS][16][256];
    uint8_t *input;           // the frame plus zero padding
    int inputCapacity;
};

static inline unsigned get_bits(BitReader *b, int n) {
    if (n == 0) return 0;
    if (b->pos >= b->bits) { b->pos += n; return 0; }
    const uint8_t *p = b->data + (b->pos >> 3);
    uint32_t w = (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
    unsigned v = (w << (b->pos & 7)) >> (32 - n);
    b->pos += n;
    return v;
}

static inline unsigned get_bit(BitReader *b) { return get_bits(b, 1); }
static inline int get_sbits(BitReader *b, int n) { return (int)(get_bits(b, n) << (32 - n)) >> (32 - n); }
static inline int64_t bits_left(const BitReader *b) { return b->bits - b->pos; }

static inline int log2_floor(unsigned v) { return v ? 31 - __builtin_clz(v) : 0; }

static uint8_t reverse8(uint8_t b) {
    b = (uint8_t)((b & 0xF0) >> 4 | (b & 0x0F) << 4);
    b = (uint8_t)((b & 0xCC) >> 2 | (b & 0x33) << 2);
    return (uint8_t)((b & 0xAA) >> 1 | (b & 0x55) << 1);
}

NDSTDecoder *ndst_create(int channels, int frameBytes) {
    if (channels < 1 || channels > DST_MAX_CHANNELS || frameBytes <= 0 || frameBytes > 4704 * 8) return NULL;
    NDSTDecoder *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    d->channels = channels;
    d->frameBytes = frameBytes;
    return d;
}

void ndst_destroy(NDSTDecoder *d) {
    if (!d) return;
    free(d->input);
    free(d);
}

static bool read_map(BitReader *gb, Table *t, unsigned map[DST_MAX_CHANNELS], int channels) {
    t->elements = 1;
    map[0] = 0;
    if (!get_bit(gb)) {
        for (int ch = 1; ch < channels; ch++) {
            int bits = log2_floor(t->elements) + 1;
            map[ch] = get_bits(gb, bits);
            if (map[ch] == t->elements) {
                t->elements++;
                if (t->elements >= DST_MAX_ELEMENTS) return false;
            } else if (map[ch] > t->elements) {
                return false;
            }
        }
    } else {
        memset(map, 0, sizeof(*map) * DST_MAX_CHANNELS);
    }
    return true;
}

/// Unsigned Rice code: a run of zeros ended by a one, then k bits (FFmpeg's get_ur_golomb_jpegls with the
/// rest of the frame as the limit and no escape). -1 when the run reaches the end of the frame.
static int get_ur_golomb(BitReader *gb, int k) {
    int64_t limit = bits_left(gb), i = 0;
    while (i < limit && get_bit(gb) == 0 && bits_left(gb) > 0) i++;
    if (i < limit - 1 && i < (1 << 20)) return (int)(get_bits(gb, k) + ((unsigned)i << k));
    return -1;
}

/// A signed Rice code: false when it runs past the end of the frame.
static bool get_sr_golomb_dst(BitReader *gb, int k, int *v) {
    *v = get_ur_golomb(gb, k);
    if (*v < 0) return false;
    if (*v && get_bit(gb)) *v = -*v;
    return true;
}

static void read_uncoded_coeff(BitReader *gb, int *dst, unsigned elements, int coeff_bits, int is_signed, int offset) {
    for (unsigned i = 0; i < elements; i++)
        dst[i] = (is_signed ? get_sbits(gb, coeff_bits) : (int)get_bits(gb, coeff_bits)) + offset;
}

/// Filter coefficients are 9-bit signed, probabilities 1 to 128: a coded value outside that range can't come from
/// a valid frame (and unchecked, the next prediction could overflow).
static bool read_table(BitReader *gb, Table *t, const int8_t code_pred_coeff[3][3],
                       int length_bits, int coeff_bits, int is_signed, int offset) {
    const int64_t low = is_signed ? -(1 << (coeff_bits - 1)) : offset;
    const int64_t high = is_signed ? (1 << (coeff_bits - 1)) - 1 : offset + (1 << coeff_bits) - 1;
    for (unsigned i = 0; i < t->elements; i++) {
        t->length[i] = get_bits(gb, length_bits) + 1;
        if (!get_bit(gb)) {
            read_uncoded_coeff(gb, t->coeff[i], t->length[i], coeff_bits, is_signed, offset);
        } else {
            int method = (int)get_bits(gb, 2);
            if (method == 3) return false;
            read_uncoded_coeff(gb, t->coeff[i], (unsigned)method + 1, coeff_bits, is_signed, offset);
            int lsb_size = (int)get_bits(gb, 3);
            for (unsigned j = (unsigned)method + 1; j < t->length[i]; j++) {
                int64_t x = 0, c;
                int residual;
                for (int k = 0; k < method + 1; k++)
                    x += code_pred_coeff[method][k] * (int64_t)t->coeff[i][j - k - 1];
                if (!get_sr_golomb_dst(gb, lsb_size, &residual)) return false;
                c = residual;
                if (x >= 0) c -= (x + 4) / 8;
                else c += (-x + 3) / 8;
                if (c < low || c > high) return false;
                t->coeff[i][j] = (int)c;
            }
        }
    }
    return true;
}

static bool build_filter(int16_t table[DST_MAX_ELEMENTS][16][256], const Table *fsets) {
    for (unsigned i = 0; i < fsets->elements; i++) {
        int length = (int)fsets->length[i];
        for (int j = 0; j < 16; j++) {
            int total = length - j * 8;
            total = total < 0 ? 0 : total > 8 ? 8 : total;
            for (int k = 0; k < 256; k++) {
                int64_t v = 0;
                for (int l = 0; l < total; l++) v += (((k >> l) & 1) * 2 - 1) * fsets->coeff[i][j * 8 + l];
                if ((int16_t)v != v) return false;
                table[i][j][k] = (int16_t)v;
            }
        }
    }
    return true;
}

// The arithmetic decoder (subpart 10, 10.11).
typedef struct { unsigned a, c; } ArithCoder;

static void ac_init(ArithCoder *ac, BitReader *gb) {
    ac->a = 4095;
    ac->c = get_bits(gb, 12);
}

static inline int ac_get(ArithCoder *ac, BitReader *gb, int p) {
    unsigned k = (ac->a >> 8) | ((ac->a >> 7) & 1);
    unsigned q = k * (unsigned)p;
    unsigned a_q = ac->a - q;
    int e = ac->c < a_q;
    if (e) {
        ac->a = a_q;
    } else {
        ac->a = q;
        ac->c -= a_q;
    }
    if (ac->a < 2048) {
        int n = 11 - log2_floor(ac->a);
        ac->a <<= n;
        ac->c = (ac->c << n) | get_bits(gb, n);
    }
    return e;
}

static uint8_t prob_dst_x_bit(int c) { return (uint8_t)((reverse8((uint8_t)(c & 127)) >> 1) + 1); }

static bool decode(NDSTDecoder *d, const uint8_t *data, int size, uint8_t *dsd) {
    const int channels = d->channels;
    const unsigned samples = (unsigned)d->frameBytes * 8, total = (unsigned)d->frameBytes * (unsigned)channels;
    unsigned map_ch_to_felem[DST_MAX_CHANNELS], map_ch_to_pelem[DST_MAX_CHANNELS], half_prob[DST_MAX_CHANNELS];
    if (size <= 1) return false;
    if (d->inputCapacity < size + 4) {
        uint8_t *grown = realloc(d->input, (size_t)size + 4);
        if (!grown) return false;
        d->input = grown;
        d->inputCapacity = size + 4;
    }
    memcpy(d->input, data, (size_t)size);
    memset(d->input + size, 0, 4);
    BitReader gb = { d->input, (int64_t)size * 8, 0 };

    if (!get_bit(&gb)) {
        // Stored uncompressed: the header byte, then the whole frame of DSD.
        get_bit(&gb);
        if (get_bits(&gb, 6) || (unsigned)(size - 1) < total) return false;
        memcpy(dsd, data + 1, total);
        return true;
    }

    // Segmentation (10.4, 10.5, 10.6): only "the same, single segment for every channel" is in use.
    if (!get_bit(&gb) || !get_bit(&gb) || !get_bit(&gb)) return false;

    // Mapping (10.7, 10.8, 10.9)
    unsigned same_map = get_bit(&gb);
    if (!read_map(&gb, &d->fsets, map_ch_to_felem, channels)) return false;
    if (same_map) {
        d->probs.elements = d->fsets.elements;
        memcpy(map_ch_to_pelem, map_ch_to_felem, sizeof map_ch_to_felem);
    } else if (!read_map(&gb, &d->probs, map_ch_to_pelem, channels)) {
        return false;
    }

    // Half probability (10.10)
    for (int ch = 0; ch < channels; ch++) half_prob[ch] = get_bit(&gb);

    // Filter coefficient sets (10.12) and probability tables (10.13)
    if (!read_table(&gb, &d->fsets, fsets_code_pred_coeff, 7, 9, 1, 0)) return false;
    if (!read_table(&gb, &d->probs, probs_code_pred_coeff, 6, 7, 0, 1)) return false;

    // Arithmetic-coded data (10.11), which starts inside the frame.
    if (bits_left(&gb) <= 0 || get_bit(&gb)) return false;
    ArithCoder ac;
    ac_init(&ac, &gb);
    if (!build_filter(d->filter, &d->fsets)) return false;

    memset(d->status, 0xAA, sizeof d->status);
    memset(dsd, 0, total);

    (void)ac_get(&ac, &gb, prob_dst_x_bit(d->fsets.coeff[0][0]));

    for (unsigned i = 0; i < samples; i++) {
        for (int ch = 0; ch < channels; ch++) {
            const unsigned felem = map_ch_to_felem[ch];
            int16_t (*filter)[256] = d->filter[felem];
            const uint8_t *status = d->status[ch].byte;
            int prob;
#define F(x) filter[(x)][status[(x)]]
            const int16_t predict = (int16_t)(F( 0) + F( 1) + F( 2) + F( 3) +
                                              F( 4) + F( 5) + F( 6) + F( 7) +
                                              F( 8) + F( 9) + F(10) + F(11) +
                                              F(12) + F(13) + F(14) + F(15));
#undef F
            if (!half_prob[ch] || i >= d->fsets.length[felem]) {
                unsigned pelem = map_ch_to_pelem[ch];
                unsigned index = (unsigned)abs(predict) >> 3;
                prob = d->probs.coeff[pelem][index < d->probs.length[pelem] - 1 ? index : d->probs.length[pelem] - 1];
            } else {
                prob = 128;
            }
            int residual = ac_get(&ac, &gb, prob);
            int v = ((predict >> 15) ^ residual) & 1;
            dsd[(i >> 3) * (unsigned)channels + (unsigned)ch] |= (uint8_t)(v << (7 - (i & 7)));
            uint64_t *w = d->status[ch].word;
            w[1] = (w[1] << 1) | (w[0] >> 63);
            w[0] = (w[0] << 1) | (uint64_t)v;
        }
    }
    // As the reference decoder checks: all but at most 7 bits of the arithmetic code were read. (Reading past the
    // end is allowed: the encoder drops the code's trailing zeros. Real frames end 4 to a few hundred bits past it.)
    return bits_left(&gb) <= 7;
}

bool ndst_decode(NDSTDecoder *d, const uint8_t *data, int size, uint8_t *out) {
    if (decode(d, data, size, out)) return true;
    memset(out, DSD_SILENCE, (size_t)d->frameBytes * (size_t)d->channels);
    return false;
}
