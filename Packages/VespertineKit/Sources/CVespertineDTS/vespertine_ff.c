//
// Vespertine — FFmpeg-decoded files: DTS / DTS-HD MA and Dolby TrueHD in their containers.
// SPDX-License-Identifier: GPL-3.0-or-later
//
#include "CVespertineFF.h"
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/frame.h>
#include <libavutil/mem.h>
#include <stdlib.h>
#include <string.h>

struct NFFDecoder {
    AVFormatContext *fmt;
    AVCodecContext *ctx;
    AVPacket *packet;
    AVFrame *frame;
    int stream;
    float *fifo;              // interleaved
    int fifoFrames, fifoCapacity;
    int channels, rate, bits;
    uint64_t mask;
    int64_t length, position;
    int64_t discard;          // frames to drop after a seek
    bool eof, flushed;
    int badFrames;            // damaged frames in a row (skipped, up to NFF_MAX_BAD_FRAMES)
    char profile[64];
    // Raw DSD reading
    uint8_t *dsd;             // per-channel planes, dsdCapacity bytes each
    int dsdBytes, dsdCapacity;
    int64_t dsdDiscard;
};

static void fail(char *error, int size, const char *msg, int code) {
    if (!error || size <= 0) return;
    char text[128] = {0};
    if (code < 0) av_strerror(code, text, sizeof text);
    snprintf(error, (size_t)size, "%s%s%s", msg, code < 0 ? ": " : "", text);
}

NFFDecoder *nff_open(const char *path, char *error, int errorSize) {
    NFFDecoder *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    // Every format opened here describes itself in its header or first frames (DSF/DSDIFF headers, DTS and
    // TrueHD frames carry their layout). FFmpeg's default analysis reads up to 5 MB / 5 s first, which on a
    // busy network share takes many seconds, every time a song starts or moves to another output.
    AVDictionary *options = NULL;
    av_dict_set(&options, "probesize", "262144", 0);
    av_dict_set(&options, "analyzeduration", "100000", 0);   // microseconds
    int r = avformat_open_input(&d->fmt, path, NULL, &options);
    av_dict_free(&options);
    if (r < 0) { fail(error, errorSize, "open", r); free(d); return NULL; }
    if ((r = avformat_find_stream_info(d->fmt, NULL)) < 0) { fail(error, errorSize, "read stream info", r); nff_close(d); return NULL; }
    const AVCodec *codec = NULL;
    d->stream = av_find_best_stream(d->fmt, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
    if (d->stream < 0 || !codec) { fail(error, errorSize, "no audio stream FFmpeg can decode here", d->stream); nff_close(d); return NULL; }
    AVStream *st = d->fmt->streams[d->stream];
    for (unsigned i = 0; i < d->fmt->nb_streams; i++) if ((int)i != d->stream) d->fmt->streams[i]->discard = AVDISCARD_ALL;
    d->ctx = avcodec_alloc_context3(codec);
    d->packet = av_packet_alloc();
    d->frame = av_frame_alloc();
    if (!d->ctx || !d->packet || !d->frame) { fail(error, errorSize, "allocate", 0); nff_close(d); return NULL; }
    avcodec_parameters_to_context(d->ctx, st->codecpar);
    d->ctx->pkt_timebase = st->time_base;
    // Dolby Digital: FFmpeg applies the stream's dynamic range compression unless told not to. Full range, as mastered.
    AVDictionary *codecOptions = NULL;
    if (codec->id == AV_CODEC_ID_AC3 || codec->id == AV_CODEC_ID_EAC3) av_dict_set(&codecOptions, "drc_scale", "0", 0);
    r = avcodec_open2(d->ctx, codec, &codecOptions);
    av_dict_free(&codecOptions);
    if (r < 0) { fail(error, errorSize, "open decoder", r); nff_close(d); return NULL; }
    d->channels = d->ctx->ch_layout.nb_channels;
    d->rate = d->ctx->sample_rate;
    d->mask = d->ctx->ch_layout.order == AV_CHANNEL_ORDER_NATIVE ? d->ctx->ch_layout.u.mask : 0;
    d->bits = d->ctx->bits_per_raw_sample;
    const char *profile = avcodec_profile_name(codec->id, st->codecpar->profile);
    snprintf(d->profile, sizeof d->profile, "%s", profile ? profile : "");
    int64_t duration = st->duration != AV_NOPTS_VALUE ? av_rescale_q(st->duration, st->time_base, (AVRational){1, d->rate})
                     : (d->fmt->duration != AV_NOPTS_VALUE ? av_rescale(d->fmt->duration, d->rate, AV_TIME_BASE) : 0);
    d->length = duration > 0 ? duration : 0;
    if (d->length == 0) {
        // Raw streams (.thd, .mlp) don't say how long they are: add up the packets (no decoding), then rewind.
        int64_t total = 0;
        while (av_read_frame(d->fmt, d->packet) >= 0) {
            if (d->packet->stream_index == d->stream && d->packet->duration > 0) total += d->packet->duration;
            av_packet_unref(d->packet);
        }
        d->length = av_rescale_q(total, st->time_base, (AVRational){1, d->rate});
        if (av_seek_frame(d->fmt, d->stream, 0, AVSEEK_FLAG_BACKWARD) < 0) av_seek_frame(d->fmt, -1, 0, AVSEEK_FLAG_BYTE);
    }
    return d;
}

void nff_close(NFFDecoder *d) {
    if (!d) return;
    avcodec_free_context(&d->ctx);
    av_packet_free(&d->packet);
    av_frame_free(&d->frame);
    if (d->fmt) avformat_close_input(&d->fmt);
    free(d->fifo);
    free(d->dsd);
    free(d);
}

int nff_channels(const NFFDecoder *d) { return d->channels; }
int nff_sample_rate(const NFFDecoder *d) { return d->rate; }
uint64_t nff_channel_mask(const NFFDecoder *d) { return d->mask; }
int64_t nff_length(const NFFDecoder *d) { return d->length; }
const char *nff_codec(const NFFDecoder *d) { return d->ctx->codec->name; }
const char *nff_profile(const NFFDecoder *d) { return d->profile; }
int nff_bits(const NFFDecoder *d) { return d->bits; }
int64_t nff_position(const NFFDecoder *d) { return d->position; }

const char *nff_tag(const NFFDecoder *d, const char *key) {
    AVDictionaryEntry *e = av_dict_get(d->fmt->metadata, key, NULL, 0);
    if (!e) e = av_dict_get(d->fmt->streams[d->stream]->metadata, key, NULL, 0);
    return e ? e->value : NULL;
}

static bool append(NFFDecoder *d, const AVFrame *f) {
    int ch = d->channels, n = f->nb_samples;
    if (f->ch_layout.nb_channels != ch || n <= 0) return true;
    int drop = 0;
    if (d->discard > 0) { drop = d->discard < n ? (int)d->discard : n; d->discard -= drop; }
    int keep = n - drop;
    if (keep <= 0) return true;
    if (d->fifoFrames + keep > d->fifoCapacity) {
        int cap = (d->fifoFrames + keep) * 2;
        float *grown = realloc(d->fifo, (size_t)cap * ch * sizeof(float));
        if (!grown) return false;
        d->fifo = grown; d->fifoCapacity = cap;
    }
    float *out = d->fifo + (size_t)d->fifoFrames * ch;
    for (int s = 0; s < keep; s++) {
        int i = s + drop;
        for (int c = 0; c < ch; c++) {
            float v;
            switch (f->format) {
            case AV_SAMPLE_FMT_FLTP: v = ((const float *)f->extended_data[c])[i]; break;
            case AV_SAMPLE_FMT_FLT:  v = ((const float *)f->extended_data[0])[i * ch + c]; break;
            case AV_SAMPLE_FMT_S32P: v = (float)(((const int32_t *)f->extended_data[c])[i] / 2147483648.0); break;
            case AV_SAMPLE_FMT_S32:  v = (float)(((const int32_t *)f->extended_data[0])[i * ch + c] / 2147483648.0); break;
            case AV_SAMPLE_FMT_S16P: v = ((const int16_t *)f->extended_data[c])[i] / 32768.0f; break;
            case AV_SAMPLE_FMT_S16:  v = ((const int16_t *)f->extended_data[0])[i * ch + c] / 32768.0f; break;
            default: v = 0;
            }
            out[(size_t)s * ch + c] = v;
        }
    }
    d->fifoFrames += keep;
    return true;
}

/// A damaged frame (a bad sector, a broken rip) is skipped rather than ending the track, unless this many come in a row.
#define NFF_MAX_BAD_FRAMES 32

/// Skips a damaged frame; false once too many came in a row.
static bool skip_bad_frame(NFFDecoder *d) { return ++d->badFrames <= NFF_MAX_BAD_FRAMES; }

/// Decodes more into the FIFO. Returns false at the end (or on a fatal error).
static bool pump(NFFDecoder *d) {
    for (;;) {
        int r = avcodec_receive_frame(d->ctx, d->frame);
        if (r == AVERROR_INVALIDDATA) { if (!skip_bad_frame(d)) return false; continue; }
        if (r == 0) { d->badFrames = 0; bool ok = append(d, d->frame); av_frame_unref(d->frame); if (!ok) return false; if (d->fifoFrames > 0) return true; continue; }
        if (r == AVERROR_EOF) return false;
        if (r != AVERROR(EAGAIN)) return false;
        if (d->eof) {
            if (d->flushed) return false;
            avcodec_send_packet(d->ctx, NULL); d->flushed = true; continue;
        }
        r = av_read_frame(d->fmt, d->packet);
        if (r < 0) { d->eof = true; continue; }
        if (d->packet->stream_index == d->stream) avcodec_send_packet(d->ctx, d->packet);
        av_packet_unref(d->packet);
    }
}

int nff_read(NFFDecoder *d, float *const *planes, int frames) {
    while (d->fifoFrames < frames) if (!pump(d)) break;
    int n = frames < d->fifoFrames ? frames : d->fifoFrames;
    int ch = d->channels;
    for (int s = 0; s < n; s++) for (int c = 0; c < ch; c++) planes[c][s] = d->fifo[(size_t)s * ch + c];
    memmove(d->fifo, d->fifo + (size_t)n * ch, (size_t)(d->fifoFrames - n) * ch * sizeof(float));
    d->fifoFrames -= n;
    d->position += n;
    return n;
}

bool nff_seek(NFFDecoder *d, int64_t target) {
    if (target < 0) target = 0;
    AVStream *st = d->fmt->streams[d->stream];
    // Seek a little early so the decoder settles, then drop frames up to the target by timestamp.
    int64_t early = target - d->rate / 2; if (early < 0) early = 0;
    int64_t ts = av_rescale_q(early, (AVRational){1, d->rate}, st->time_base);
    if (av_seek_frame(d->fmt, d->stream, ts, AVSEEK_FLAG_BACKWARD) < 0 && av_seek_frame(d->fmt, d->stream, 0, AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_BYTE) < 0)
        return false;
    avcodec_flush_buffers(d->ctx);
    d->fifoFrames = 0; d->eof = false; d->flushed = false; d->badFrames = 0;
    // Find where decoding restarts: the first frame's timestamp.
    int64_t start = -1;
    for (;;) {
        int r = avcodec_receive_frame(d->ctx, d->frame);
        if (r == AVERROR_INVALIDDATA) { if (!skip_bad_frame(d)) return false; continue; }
        if (r == 0) {
            d->badFrames = 0;
            int64_t pts = d->frame->best_effort_timestamp;
            start = pts == AV_NOPTS_VALUE ? 0 : av_rescale_q(pts, st->time_base, (AVRational){1, d->rate});
            d->discard = target > start ? target - start : 0;
            bool ok = append(d, d->frame);
            av_frame_unref(d->frame);
            if (!ok) return false;
            break;
        }
        if (r != AVERROR(EAGAIN)) return false;
        r = av_read_frame(d->fmt, d->packet);
        if (r < 0) { d->eof = true; return false; }
        if (d->packet->stream_index == d->stream) avcodec_send_packet(d->ctx, d->packet);
        av_packet_unref(d->packet);
    }
    while (d->discard > 0) { if (!pump(d)) break; }
    d->position = target;
    return true;
}

// MARK: - Raw DSD

bool nff_is_dsd(const NFFDecoder *d) {
    enum AVCodecID id = d->ctx->codec_id;
    return id == AV_CODEC_ID_DSD_LSBF || id == AV_CODEC_ID_DSD_MSBF || id == AV_CODEC_ID_DSD_LSBF_PLANAR || id == AV_CODEC_ID_DSD_MSBF_PLANAR;
}

static uint8_t reverse_bits(uint8_t b) {
    b = (uint8_t)((b & 0xF0) >> 4 | (b & 0x0F) << 4);
    b = (uint8_t)((b & 0xCC) >> 2 | (b & 0x33) << 2);
    return (uint8_t)((b & 0xAA) >> 1 | (b & 0x55) << 1);
}

/// Appends one packet's DSD to the per-channel planes (deinterleaving, and MSB-first).
static bool append_dsd(NFFDecoder *d, const AVPacket *p) {
    int ch = d->channels;
    if (ch <= 0 || p->size <= 0) return true;
    enum AVCodecID id = d->ctx->codec_id;
    bool planar = id == AV_CODEC_ID_DSD_LSBF_PLANAR || id == AV_CODEC_ID_DSD_MSBF_PLANAR;
    bool lsbf = id == AV_CODEC_ID_DSD_LSBF || id == AV_CODEC_ID_DSD_LSBF_PLANAR;
    int per = p->size / ch;
    int skip = 0;
    if (d->dsdDiscard > 0) { skip = d->dsdDiscard < per ? (int)d->dsdDiscard : per; d->dsdDiscard -= skip; }
    int keep = per - skip;
    if (keep <= 0) return true;
    if (d->dsdBytes + keep > d->dsdCapacity) {
        int cap = (d->dsdBytes + keep) * 2;
        uint8_t *grown = malloc((size_t)cap * ch);
        if (!grown) return false;
        for (int c = 0; c < ch; c++) if (d->dsd) memcpy(grown + (size_t)c * cap, d->dsd + (size_t)c * d->dsdCapacity, (size_t)d->dsdBytes);
        free(d->dsd); d->dsd = grown; d->dsdCapacity = cap;
    }
    // DSF packets hold whole blocks per channel (planar); DSDIFF interleaves one byte per channel.
    int blockAlign = d->fmt->streams[d->stream]->codecpar->block_align;
    // FFmpeg's DSF reader packs the last (short) packet as each channel's remaining bytes back to back.
    int blockPer = planar && blockAlign > 0 && p->size >= blockAlign ? blockAlign / ch : per;
    for (int i = 0; i < keep; i++) {
        int k = i + skip;
        for (int c = 0; c < ch; c++) {
            uint8_t b = planar ? p->data[(k / blockPer) * blockPer * ch + c * blockPer + (k % blockPer)] : p->data[k * ch + c];
            d->dsd[(size_t)c * d->dsdCapacity + d->dsdBytes + i] = lsbf ? reverse_bits(b) : b;
        }
    }
    d->dsdBytes += keep;
    return true;
}

int nff_read_dsd(NFFDecoder *d, uint8_t *const *planes, int bytes) {
    while (d->dsdBytes < bytes && !d->eof) {
        int r = av_read_frame(d->fmt, d->packet);
        if (r < 0) { d->eof = true; break; }
        bool ok = d->packet->stream_index != d->stream || append_dsd(d, d->packet);
        av_packet_unref(d->packet);
        if (!ok) return -1;
    }
    int n = bytes < d->dsdBytes ? bytes : d->dsdBytes;
    for (int c = 0; c < d->channels; c++) {
        uint8_t *plane = d->dsd + (size_t)c * d->dsdCapacity;
        memcpy(planes[c], plane, (size_t)n);
        memmove(plane, plane + n, (size_t)(d->dsdBytes - n));
    }
    d->dsdBytes -= n;
    d->position += n;
    return n;
}

bool nff_seek_dsd(NFFDecoder *d, int64_t offset) {
    if (offset < 0) offset = 0;
    AVStream *st = d->fmt->streams[d->stream];
    int64_t ts = av_rescale_q(offset, (AVRational){1, d->rate}, st->time_base);
    if (av_seek_frame(d->fmt, d->stream, ts, AVSEEK_FLAG_BACKWARD) < 0) return false;
    d->dsdBytes = 0; d->eof = false;
    // Find where the next packet starts, and drop up to the target.
    int r = av_read_frame(d->fmt, d->packet);
    if (r < 0) { d->eof = true; return false; }
    int64_t start = d->packet->pts == AV_NOPTS_VALUE ? 0 : av_rescale_q(d->packet->pts, st->time_base, (AVRational){1, d->rate});
    d->dsdDiscard = offset > start ? offset - start : 0;
    bool ok = d->packet->stream_index != d->stream || append_dsd(d, d->packet);
    av_packet_unref(d->packet);
    d->position = offset;
    return ok;
}
