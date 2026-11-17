//
// Vespertine: WavPack, with libwavpack. Opened as SFBAudioEngine opens it on the Mac, so the samples are the same.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#include "decoder.h"

#include <wavpack/wavpack.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { WV_CHUNK = 4096 };

typedef struct wv_state {
    WavpackContext *context;
    WavpackStreamReader64 reader;
    int32_t *buffer;
    int is_float;
} wv_state;

static int32_t wv_read_bytes(void *id, void *data, int32_t count) { return (int32_t)vsp_cursor_read((vsp_cursor *)id, data, count); }
static int64_t wv_get_pos(void *id) { return ((vsp_cursor *)id)->at; }
static int wv_set_pos_abs(void *id, int64_t pos) { return vsp_cursor_seek((vsp_cursor *)id, pos, SEEK_SET); }
static int wv_set_pos_rel(void *id, int64_t delta, int mode) { return vsp_cursor_seek((vsp_cursor *)id, delta, mode); }
static int wv_push_back_byte(void *id, int c) {
    vsp_cursor *cursor = id;
    if (cursor->at > 0) cursor->at -= 1;
    return c;
}
static int64_t wv_get_length(void *id) { return ((vsp_cursor *)id)->source.size; }
static int wv_can_seek(void *id) { (void)id; return 1; }

static int64_t wv_read(vsp_decoder *decoder, int64_t count, uint8_t *out) {
    wv_state *state = decoder->state;
    uint32_t wanted = (uint32_t)(count > WV_CHUNK ? WV_CHUNK : count);
    uint32_t got = WavpackUnpackSamples(state->context, state->buffer, wanted);
    int channels = decoder->info.channels;
    size_t total = (size_t)got * (size_t)channels;
    if (state->is_float) {
        // The 32 bits of each float, as they are.
        for (size_t i = 0; i < total; i++) {
            uint32_t bits = (uint32_t)state->buffer[i];
            out[0] = (uint8_t)(bits >> 24); out[1] = (uint8_t)(bits >> 16); out[2] = (uint8_t)(bits >> 8); out[3] = (uint8_t)bits;
            out += 4;
        }
        return got;
    }
    int bytes = decoder->info.sample_bytes;
    int64_t top = ((int64_t)1 << (8 * bytes - 1)) - 1, bottom = -top - 1;
    for (size_t i = 0; i < total; i++) {
        // A lossy file can decode past full scale.
        int64_t value = state->buffer[i];
        if (value > top) value = top;
        if (value < bottom) value = bottom;
        for (int b = bytes - 1; b >= 0; b--) *out++ = (uint8_t)((uint64_t)value >> (8 * b));
    }
    return got;
}

static int wv_seek(vsp_decoder *decoder, int64_t frame) {
    wv_state *state = decoder->state;
    return WavpackSeekSample64(state->context, frame) ? 0 : -1;
}

static void wv_close(vsp_decoder *decoder) {
    wv_state *state = decoder->state;
    if (!state) return;
    if (state->context) WavpackCloseFile(state->context);
    free(state->buffer);
    free(state);
    decoder->state = NULL;
}

int vsp_open_wavpack(vsp_decoder *decoder) {
    wv_state *state = calloc(1, sizeof(wv_state));
    if (!state) return VSP_UNREADABLE;
    state->reader.read_bytes = wv_read_bytes;
    state->reader.get_pos = wv_get_pos;
    state->reader.set_pos_abs = wv_set_pos_abs;
    state->reader.set_pos_rel = wv_set_pos_rel;
    state->reader.push_back_byte = wv_push_back_byte;
    state->reader.get_length = wv_get_length;
    state->reader.can_seek = wv_can_seek;
    decoder->state = state;
    decoder->read = wv_read;
    decoder->seek = wv_seek;
    decoder->close = wv_close;

    char error[81] = {0};
    // As the Mac opens it, plus the tags at the end of the file.
    state->context = WavpackOpenFileInputEx64(&state->reader, &decoder->cursor, NULL, error, OPEN_WVC | OPEN_NORMALIZE | OPEN_TAGS, 0);
    if (!state->context) {
        // This build of the library leaves DSD out, and says so.
        int dsd = strstr(error, "DSD") != NULL;
        wv_close(decoder);
        return dsd ? VSP_NEEDS_THE_MAC : VSP_UNREADABLE;
    }
    if (WavpackGetQualifyMode(state->context) & QMODE_DSD_AUDIO) {
        wv_close(decoder);
        return VSP_NEEDS_THE_MAC;
    }
    int mode = WavpackGetMode(state->context);
    int channels = WavpackGetNumChannels(state->context);
    int bytes = WavpackGetBytesPerSample(state->context);
    int64_t frames = WavpackGetNumSamples64(state->context);
    if (channels < 1 || channels > 64 || bytes < 1 || bytes > 4 || frames < 0) {
        wv_close(decoder);
        return VSP_UNREADABLE;
    }
    state->is_float = (mode & MODE_FLOAT) != 0;
    state->buffer = malloc(sizeof(int32_t) * WV_CHUNK * (size_t)channels);
    if (!state->buffer) {
        wv_close(decoder);
        return VSP_UNREADABLE;
    }
    decoder->info.sample_rate = WavpackGetSampleRate(state->context);
    decoder->info.channels = channels;
    decoder->info.bit_depth = (mode & MODE_LOSSLESS) ? WavpackGetBitsPerSample(state->context) : 0;
    decoder->info.sample_bytes = state->is_float ? 0 : bytes;
    decoder->info.frames = frames;

    int items = WavpackGetNumTagItems(state->context);
    for (int i = 0; i < items && i < 4096; i++) {
        int name_length = WavpackGetTagItemIndexed(state->context, i, NULL, 0);
        if (name_length <= 0 || name_length > 1024) continue;
        char *name = malloc((size_t)name_length + 1);
        if (!name) break;
        WavpackGetTagItemIndexed(state->context, i, name, name_length + 1);
        int text_length = WavpackGetTagItem(state->context, name, NULL, 0);
        if (text_length > 0 && text_length <= 1 << 16) {
            char *text = malloc((size_t)text_length + 1);
            if (text) {
                WavpackGetTagItem(state->context, name, text, text_length + 1);
                vsp_tags_add(&decoder->tags, name, text);
                free(text);
            }
        }
        free(name);
    }
    return VSP_OPENED;
}
