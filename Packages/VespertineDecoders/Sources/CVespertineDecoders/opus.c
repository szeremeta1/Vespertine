//
// Vespertine: Opus in Ogg, with libopusfile. Read as SFBAudioEngine reads it on the Mac, so the samples are the same.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#include "decoder.h"

#include <opus/opusfile.h>

#include <stdio.h>
#include <stdlib.h>

enum { OP_CHUNK = 5760 };   // the longest Opus packet: 120 ms at 48 kHz
enum { OP_SETTLE = 48000 }; // frames decoded and thrown away before a place that was seeked to

typedef struct op_state {
    OggOpusFile *file;
    float *buffer;
} op_state;

static int op_read_bytes(void *stream, unsigned char *ptr, int count) { return (int)vsp_cursor_read((vsp_cursor *)stream, ptr, count); }
static int op_seek_bytes(void *stream, opus_int64 offset, int whence) { return vsp_cursor_seek((vsp_cursor *)stream, offset, whence); }
static opus_int64 op_tell_bytes(void *stream) { return ((vsp_cursor *)stream)->at; }

static int64_t op_read_frames(vsp_decoder *decoder, int64_t count, uint8_t *out) {
    op_state *state = decoder->state;
    int channels = decoder->info.channels;
    int wanted = (int)(count > OP_CHUNK ? OP_CHUNK : count);
    int got = op_read_float(state->file, state->buffer, wanted * channels, NULL);
    // A gap in the file: the library carries on after it.
    if (got == OP_HOLE) return op_read_frames(decoder, count, out);
    if (got < 0) return -1;
    for (int i = 0; i < got * channels; i++) {
        vsp_put_float(out, state->buffer[i]);
        out += 4;
    }
    return got;
}

/// Opus carries what it has decoded from one packet into the next, so decoding that starts at a seek takes a tenth of a
/// second to settle to what reading in order gives. A read from a new place therefore starts a second early and throws
/// that second away: what it returns is the same sound as reading in order, to within rounding.
static int op_seek_frame(vsp_decoder *decoder, int64_t frame) {
    op_state *state = decoder->state;
    int channels = decoder->info.channels;
    int64_t from = frame > OP_SETTLE ? frame - OP_SETTLE : 0;
    if (op_pcm_seek(state->file, from) != 0) return -1;
    int64_t left = frame - from;
    while (left > 0) {
        int wanted = (int)(left > OP_CHUNK ? OP_CHUNK : left);
        int got = op_read_float(state->file, state->buffer, wanted * channels, NULL);
        if (got == OP_HOLE) continue;
        if (got <= 0 || decoder->cursor.failed) return -1;
        left -= got;
    }
    return 0;
}

static void op_close(vsp_decoder *decoder) {
    op_state *state = decoder->state;
    if (!state) return;
    if (state->file) op_free(state->file);
    free(state->buffer);
    free(state);
    decoder->state = NULL;
}

int vsp_open_opus(vsp_decoder *decoder) {
    op_state *state = calloc(1, sizeof(op_state));
    if (!state) return VSP_UNREADABLE;
    decoder->state = state;
    decoder->read = op_read_frames;
    decoder->seek = op_seek_frame;
    decoder->close = op_close;
    OpusFileCallbacks callbacks = {.read = op_read_bytes, .seek = op_seek_bytes, .tell = op_tell_bytes, .close = NULL};
    state->file = op_open_callbacks(&decoder->cursor, &callbacks, NULL, 0, NULL);
    if (!state->file) {
        op_close(decoder);
        return VSP_UNREADABLE;
    }
    int channels = op_channel_count(state->file, -1);
    ogg_int64_t frames = op_pcm_total(state->file, -1);
    if (channels < 1 || channels > 255 || frames < 0) {
        op_close(decoder);
        return VSP_UNREADABLE;
    }
    state->buffer = malloc(sizeof(float) * OP_CHUNK * (size_t)channels);
    if (!state->buffer) {
        op_close(decoder);
        return VSP_UNREADABLE;
    }
    // Opus always decodes at 48 kHz, whatever the rate of what was encoded.
    decoder->info.sample_rate = 48000;
    decoder->info.channels = channels;
    decoder->info.bit_depth = 0;
    decoder->info.sample_bytes = 0;
    decoder->info.frames = frames;
    const OpusTags *tags = op_tags(state->file, -1);
    if (tags) {
        for (int i = 0; i < tags->comments; i++) vsp_tags_add_comment(&decoder->tags, tags->user_comments[i], tags->comment_lengths[i]);
    }
    return VSP_OPENED;
}
