//
// Vespertine — DTS (DCA) decoding for DTS CDs / DTS-in-WAV, on FFmpeg's decoder.
// SPDX-License-Identifier: GPL-3.0-or-later
//
#include "CVespertineDTS.h"
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/frame.h>
#include <libavutil/mem.h>
#include <stdlib.h>
#include <string.h>

struct NDTSDecoder {
    AVCodecContext *ctx;
    AVCodecParserContext *parser;
    AVPacket *packet;
    AVFrame *frame;
    float *fifo;          // interleaved decoded audio
    int fifoFrames, fifoCapacity;
    int channels, rate;
    uint64_t mask;
    int framesFound;      // frames the parser delimited since the last reset
    uint8_t *input;       // the caller's bytes plus the zeroed padding FFmpeg's parser reads past the end
    size_t inputCapacity;
};

// MARK: - Finding the bitstream
//
// A sync word alone proves nothing: as 16-bit PCM, 7F FE 80 01 is just the samples -385 and +384, which
// ordinary music contains now and then. So a sync word counts only when a valid core frame header follows
// it, and the next frame starts exactly where that header says.

enum { PACK_NONE, PACK_16_BE, PACK_16_LE, PACK_14_BE, PACK_14_LE };

/// How the DTS words are stored, from the sync word's bytes at `p` (6 bytes read).
static int packing(const uint8_t *p) {
    if (p[0] == 0x7F && p[1] == 0xFE && p[2] == 0x80 && p[3] == 0x01) return PACK_16_BE;
    if (p[0] == 0xFE && p[1] == 0x7F && p[2] == 0x01 && p[3] == 0x80) return PACK_16_LE;
    if (p[0] == 0x1F && p[1] == 0xFF && p[2] == 0xE8 && p[3] == 0x00 && p[4] == 0x07 && (p[5] & 0xF0) == 0xF0) return PACK_14_BE;
    if (p[0] == 0xFF && p[1] == 0x1F && p[2] == 0x00 && p[3] == 0xE8 && (p[4] & 0xF0) == 0xF0 && p[5] == 0x07) return PACK_14_LE;   // DTS CD
    return PACK_NONE;
}

/// Stored bytes that hold a core frame header in any packing (12 words: 168 bits at 14 per word).
#define HEADER_BYTES 24

typedef struct {
    int samples;      // per frame
    int frameSize;    // bytes of bitstream
    int rateCode;
} CoreHeader;

static uint32_t take(const uint8_t *bits, int *pos, int n) {
    uint32_t v = 0;
    for (; n > 0; n--, (*pos)++) v = v << 1 | ((bits[*pos >> 3] >> (7 - (*pos & 7))) & 1u);
    return v;
}

/// Parses the core frame header at `p` (HEADER_BYTES stored bytes), rejecting what FFmpeg's decoder rejects.
static bool core_header(const uint8_t *p, int pack, CoreHeader *h) {
    // As one big-endian bitstream: the 14-bit packings carry 14 bits in each 16-bit word.
    const bool le = pack == PACK_16_LE || pack == PACK_14_LE;
    const int width = pack == PACK_14_BE || pack == PACK_14_LE ? 14 : 16;
    uint8_t bits[HEADER_BYTES] = {0};
    int n = 0;
    for (int w = 0; w < HEADER_BYTES / 2; w++) {
        const uint32_t word = le ? (uint32_t)p[2 * w] | (uint32_t)p[2 * w + 1] << 8 : (uint32_t)p[2 * w] << 8 | p[2 * w + 1];
        for (int b = width - 1; b >= 0; b--, n++) if ((word >> b) & 1u) bits[n >> 3] |= (uint8_t)(0x80u >> (n & 7));
    }
    // Sample rate codes with a rate (ff_dca_sample_rates) and PCM resolutions with a bit depth.
    static const bool rates[16] = { [1] = 1, [2] = 1, [3] = 1, [6] = 1, [7] = 1, [8] = 1, [11] = 1, [12] = 1, [13] = 1, [14] = 1, [15] = 1 };
    static const bool resolutions[8] = { [0] = 1, [1] = 1, [2] = 1, [3] = 1, [5] = 1, [6] = 1 };
    int pos = 0;
    if (take(bits, &pos, 32) != 0x7FFE8001u) return false;
    take(bits, &pos, 1);                                        // frame type
    if (take(bits, &pos, 5) != 31) return false;                // deficit sample count
    const uint32_t crc = take(bits, &pos, 1);
    const int blocks = (int)take(bits, &pos, 7) + 1;            // PCM blocks of 32 samples
    if (blocks % 8) return false;
    const int frameSize = (int)take(bits, &pos, 14) + 1;
    if (frameSize < 96) return false;
    if (take(bits, &pos, 6) >= 10) return false;                // channel arrangement
    const int rateCode = (int)take(bits, &pos, 4);
    if (!rates[rateCode]) return false;
    take(bits, &pos, 5);                                        // bit rate
    if (take(bits, &pos, 1)) return false;                      // reserved
    take(bits, &pos, 9);                                        // DRC, time stamp, aux, HDCD, extension type and flag, sync
    if (take(bits, &pos, 2) == 3) return false;                 // LFE
    take(bits, &pos, 1);                                        // predictor history
    if (crc) take(bits, &pos, 16);
    take(bits, &pos, 7);                                        // filter, encoder version, copy history
    if (!resolutions[take(bits, &pos, 3)]) return false;
    h->samples = blocks * 32;
    h->frameSize = frameSize;
    h->rateCode = rateCode;
    return true;
}

/// Bytes a frame takes as stored (14-bit packings spread each 14 bits over a 16-bit word).
static int64_t stored_size(const CoreHeader *h, int pack) {
    if (pack == PACK_14_BE || pack == PACK_14_LE) return ((int64_t)h->frameSize * 8 + 13) / 14 * 2;
    return h->frameSize;
}

/// Moves to the frame after the one at `*at`: right behind it (or behind it padded to a whole word), or where
/// its duration ends in the 16-bit stereo carrier (frames padded to keep time with it).
/// 1 found, 0 not there, -1 can't tell (the buffer ends first).
static int next_frame(const uint8_t *p, int64_t size, int pack, int64_t *at, CoreHeader *h) {
    const int64_t end = *at + stored_size(h, pack);
    const int64_t candidates[3] = { end, end + (end & 1), *at + (int64_t)h->samples * 4 };
    bool beyond = false;
    for (int k = 0; k < 3; k++) {
        const int64_t n = candidates[k];
        if ((k > 0 && n == candidates[k - 1]) || (k == 2 && n == candidates[0])) continue;
        if (n + HEADER_BYTES > size) { beyond = true; continue; }
        CoreHeader next;
        if (packing(p + n) == pack && core_header(p + n, pack, &next) && next.rateCode == h->rateCode) {
            *at = n;
            *h = next;
            return 1;
        }
    }
    return beyond ? -1 : 0;
}

/// The first frame with a valid header followed by `frames - 1` more, each where the one before it ends.
/// `partial`: also accept one whose next frame would lie past the end of the buffer (unchecked).
static int64_t find_frames(const uint8_t *p, int64_t size, int frames, bool partial) {
    for (int64_t i = 0; i + HEADER_BYTES <= size; i += 2) {
        const int pack = packing(p + i);
        CoreHeader h;
        if (pack == PACK_NONE || !core_header(p + i, pack, &h)) continue;
        int64_t at = i;
        int found = 1, step = 1;
        while (found < frames && (step = next_frame(p, size, pack, &at, &h)) == 1) found++;
        if (found >= frames || (partial && step < 0)) return i;
    }
    return -1;
}

int64_t ndts_find_sync(const uint8_t *p, int64_t size) { return find_frames(p, size, 2, true); }

int64_t ndts_find_stream(const uint8_t *p, int64_t size) { return find_frames(p, size, 2, false); }

NDTSDecoder *ndts_create(void) {
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_DTS);
    if (!codec) return NULL;
    NDTSDecoder *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    d->ctx = avcodec_alloc_context3(codec);
    d->parser = av_parser_init(AV_CODEC_ID_DTS);
    d->packet = av_packet_alloc();
    d->frame = av_frame_alloc();
    if (!d->ctx || !d->parser || !d->packet || !d->frame) { ndts_destroy(d); return NULL; }
    d->ctx->request_sample_fmt = AV_SAMPLE_FMT_FLTP;
    if (avcodec_open2(d->ctx, codec, NULL) < 0) { ndts_destroy(d); return NULL; }
    return d;
}

void ndts_destroy(NDTSDecoder *d) {
    if (!d) return;
    if (d->parser) av_parser_close(d->parser);
    avcodec_free_context(&d->ctx);
    av_packet_free(&d->packet);
    av_frame_free(&d->frame);
    free(d->fifo);
    free(d->input);
    free(d);
}

void ndts_reset(NDTSDecoder *d) {
    avcodec_flush_buffers(d->ctx);
    av_parser_close(d->parser);
    d->parser = av_parser_init(AV_CODEC_ID_DTS);
    d->fifoFrames = 0;
    d->framesFound = 0;
}

static bool append(NDTSDecoder *d, const AVFrame *f) {
    int ch = f->ch_layout.nb_channels;
    if (ch <= 0 || f->nb_samples <= 0) return true;
    if (d->channels == 0) {
        d->channels = ch;
        d->rate = f->sample_rate;
        d->mask = f->ch_layout.order == AV_CHANNEL_ORDER_NATIVE ? f->ch_layout.u.mask : 0;
    }
    if (ch != d->channels) return true;   // a mid-stream layout change isn't playable as one stream; skip it
    int need = d->fifoFrames + f->nb_samples;
    if (need > d->fifoCapacity) {
        int cap = need * 2;
        float *grown = realloc(d->fifo, (size_t)cap * ch * sizeof(float));
        if (!grown) return false;
        d->fifo = grown;
        d->fifoCapacity = cap;
    }
    float *out = d->fifo + (size_t)d->fifoFrames * ch;
    for (int s = 0; s < f->nb_samples; s++) {
        for (int c = 0; c < ch; c++) {
            float v;
            switch (f->format) {
            case AV_SAMPLE_FMT_FLTP: v = ((const float *)f->extended_data[c])[s]; break;
            case AV_SAMPLE_FMT_FLT:  v = ((const float *)f->extended_data[0])[s * ch + c]; break;
            case AV_SAMPLE_FMT_S32P: v = (float)(((const int32_t *)f->extended_data[c])[s] / 2147483648.0); break;
            case AV_SAMPLE_FMT_S16P: v = ((const int16_t *)f->extended_data[c])[s] / 32768.0f; break;
            default: v = 0; break;
            }
            out[(size_t)s * ch + c] = v;
        }
    }
    d->fifoFrames = need;
    return true;
}

static bool drain(NDTSDecoder *d) {
    for (;;) {
        int r = avcodec_receive_frame(d->ctx, d->frame);
        if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) return true;
        if (r < 0) return true;   // a damaged frame: keep going
        bool ok = append(d, d->frame);
        av_frame_unref(d->frame);
        if (!ok) return false;
    }
}

bool ndts_feed(NDTSDecoder *d, const uint8_t *data, int size) {
    if (size <= 0) return true;
    // av_parser_parse2 may read AV_INPUT_BUFFER_PADDING_SIZE bytes past the end of its input (it copies a
    // frame's end plus padding), so it gets a zero-padded copy rather than the caller's exact-size buffer.
    const size_t needed = (size_t)size + AV_INPUT_BUFFER_PADDING_SIZE;
    if (needed > d->inputCapacity) {
        uint8_t *grown = realloc(d->input, needed);
        if (!grown) return false;
        d->input = grown;
        d->inputCapacity = needed;
    }
    memcpy(d->input, data, (size_t)size);
    memset(d->input + size, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    const uint8_t *in = d->input;
    while (size > 0) {
        uint8_t *out = NULL; int outSize = 0;
        int used = av_parser_parse2(d->parser, d->ctx, &out, &outSize, in, size, AV_NOPTS_VALUE, AV_NOPTS_VALUE, 0);
        if (used < 0) return false;
        in += used; size -= used;
        if (outSize > 0) {
            d->framesFound++;
            d->packet->data = out; d->packet->size = outSize;
            int r = avcodec_send_packet(d->ctx, d->packet);
            if (r < 0 && r != AVERROR(EAGAIN) && r != AVERROR_INVALIDDATA) return false;
            if (!drain(d)) return false;
        }
        if (used == 0 && outSize == 0) break;
    }
    return true;
}

void ndts_finish(NDTSDecoder *d) {
    uint8_t *out = NULL; int outSize = 0;
    av_parser_parse2(d->parser, d->ctx, &out, &outSize, NULL, 0, AV_NOPTS_VALUE, AV_NOPTS_VALUE, 0);
    if (outSize > 0) {
        d->packet->data = out; d->packet->size = outSize;
        avcodec_send_packet(d->ctx, d->packet);
    }
    avcodec_send_packet(d->ctx, NULL);
    drain(d);
}

int ndts_available(const NDTSDecoder *d) { return d->fifoFrames; }

int ndts_read(NDTSDecoder *d, float *const *planes, int frames) {
    int n = frames < d->fifoFrames ? frames : d->fifoFrames;
    int ch = d->channels;
    for (int s = 0; s < n; s++)
        for (int c = 0; c < ch; c++) planes[c][s] = d->fifo[(size_t)s * ch + c];
    memmove(d->fifo, d->fifo + (size_t)n * ch, (size_t)(d->fifoFrames - n) * ch * sizeof(float));
    d->fifoFrames -= n;
    return n;
}

int ndts_skip(NDTSDecoder *d, int frames) {
    int n = frames < d->fifoFrames ? frames : d->fifoFrames;
    memmove(d->fifo, d->fifo + (size_t)n * d->channels, (size_t)(d->fifoFrames - n) * d->channels * sizeof(float));
    d->fifoFrames -= n;
    return n;
}

int ndts_channels(const NDTSDecoder *d) { return d->channels; }
int ndts_sample_rate(const NDTSDecoder *d) { return d->rate; }
uint64_t ndts_channel_mask(const NDTSDecoder *d) { return d->mask; }
int ndts_frames_found(const NDTSDecoder *d) { return d->framesFound; }
