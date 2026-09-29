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
};

int64_t ndts_find_sync(const uint8_t *p, int64_t size) {
    for (int64_t i = 0; i + 6 <= size; i += 2) {
        uint32_t le = (uint32_t)p[i] | (uint32_t)p[i + 1] << 8 | (uint32_t)p[i + 2] << 16 | (uint32_t)p[i + 3] << 24;
        // 14-bit LE (DTS CD), 16-bit LE, as stored in little-endian PCM words.
        if (le == 0xE8001FFFu && (p[i + 4] & 0xF0) == 0xF0 && p[i + 5] == 0x07) return i;   // 1F FF E8 00 07 Fx
        if (le == 0x80017FFEu) return i;                                                      // FE 7F 01 80 as words
        // 14-bit / 16-bit big-endian word order.
        if (p[i] == 0x1F && p[i + 1] == 0xFF && p[i + 2] == 0xE8 && p[i + 3] == 0x00 && p[i + 4] == 0x07 && (p[i + 5] & 0xF0) == 0xF0) return i;
        if (p[i] == 0x7F && p[i + 1] == 0xFE && p[i + 2] == 0x80 && p[i + 3] == 0x01) return i;
        if (p[i] == 0xFF && p[i + 1] == 0x1F && p[i + 2] == 0x00 && p[i + 3] == 0xE8 && (p[i + 4] & 0xF0) == 0xF0 && p[i + 5] == 0x07) return i;
    }
    return -1;
}

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
    free(d);
}

void ndts_reset(NDTSDecoder *d) {
    avcodec_flush_buffers(d->ctx);
    av_parser_close(d->parser);
    d->parser = av_parser_init(AV_CODEC_ID_DTS);
    d->fifoFrames = 0;
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
    while (size > 0) {
        uint8_t *out = NULL; int outSize = 0;
        int used = av_parser_parse2(d->parser, d->ctx, &out, &outSize, data, size, AV_NOPTS_VALUE, AV_NOPTS_VALUE, 0);
        if (used < 0) return false;
        data += used; size -= used;
        if (outSize > 0) {
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
