//
// Vespertine: the part of the decoder interface that is the same for every library.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#include "decoder.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int64_t vsp_cursor_read(vsp_cursor *cursor, void *buffer, int64_t count) {
    int64_t total = 0;
    if (count > cursor->source.size - cursor->at) count = cursor->source.size - cursor->at;
    while (total < count) {
        int64_t got = cursor->source.read(cursor->source.context, cursor->at, (uint8_t *)buffer + total, count - total);
        if (got < 0) { cursor->failed = 1; break; }
        if (got == 0) break;
        total += got;
        cursor->at += got;
    }
    return total;
}

int vsp_cursor_seek(vsp_cursor *cursor, int64_t offset, int whence) {
    int64_t to = whence == SEEK_SET ? offset : whence == SEEK_CUR ? cursor->at + offset : cursor->source.size + offset;
    if (to < 0 || to > cursor->source.size) return -1;
    cursor->at = to;
    return 0;
}

static char *copy(const char *text, size_t length) {
    char *out = malloc(length + 1);
    if (out) { memcpy(out, text, length); out[length] = 0; }
    return out;
}

void vsp_tags_add(vsp_tags *tags, const char *name, const char *text) {
    if (!name || !text || tags->count >= 4096) return;
    char **names = realloc(tags->names, sizeof(char *) * (size_t)(tags->count + 1));
    if (!names) return;
    tags->names = names;
    char **texts = realloc(tags->texts, sizeof(char *) * (size_t)(tags->count + 1));
    if (!texts) return;
    tags->texts = texts;
    char *n = copy(name, strlen(name)), *t = copy(text, strlen(text));
    if (!n || !t) { free(n); free(t); return; }
    tags->names[tags->count] = n;
    tags->texts[tags->count] = t;
    tags->count += 1;
}

void vsp_tags_add_comment(vsp_tags *tags, const char *comment, int length) {
    if (!comment || length <= 0) return;
    const char *equals = memchr(comment, '=', (size_t)length);
    // Pictures (base64, large) are not text anyone reads.
    if (!equals || equals == comment || length > 1 << 16) return;
    char *name = copy(comment, (size_t)(equals - comment));
    char *text = copy(equals + 1, (size_t)(length - (int)(equals - comment) - 1));
    if (name && text) vsp_tags_add(tags, name, text);
    free(name);
    free(text);
}

void vsp_tags_free(vsp_tags *tags) {
    for (int i = 0; i < tags->count; i++) { free(tags->names[i]); free(tags->texts[i]); }
    free(tags->names);
    free(tags->texts);
    tags->names = NULL;
    tags->texts = NULL;
    tags->count = 0;
}

int vsp_open(int kind, vsp_source source, vsp_decoder **out) {
    *out = NULL;
    if (!source.read || source.size <= 0) return VSP_UNREADABLE;
    vsp_decoder *decoder = calloc(1, sizeof(vsp_decoder));
    if (!decoder) return VSP_UNREADABLE;
    decoder->cursor.source = source;
    int result;
    switch (kind) {
    case VSP_APE: result = vsp_open_ape(decoder); break;
    case VSP_WAVPACK: result = vsp_open_wavpack(decoder); break;
    case VSP_VORBIS: result = vsp_open_vorbis(decoder); break;
    case VSP_OPUS: result = vsp_open_opus(decoder); break;
    default: result = VSP_UNREADABLE;
    }
    if (result == VSP_OPENED && (decoder->info.channels < 1 || decoder->info.sample_rate <= 0 || decoder->info.frames < 0)) {
        decoder->close(decoder);
        result = VSP_UNREADABLE;
    }
    if (result != VSP_OPENED) {
        vsp_tags_free(&decoder->tags);
        free(decoder);
        return result;
    }
    *out = decoder;
    return VSP_OPENED;
}

vsp_info vsp_get_info(const vsp_decoder *decoder) { return decoder->info; }
int vsp_tag_count(const vsp_decoder *decoder) { return decoder->tags.count; }
const char *vsp_tag_name(const vsp_decoder *decoder, int index) { return index >= 0 && index < decoder->tags.count ? decoder->tags.names[index] : ""; }
const char *vsp_tag_text(const vsp_decoder *decoder, int index) { return index >= 0 && index < decoder->tags.count ? decoder->tags.texts[index] : ""; }

int64_t vsp_read(vsp_decoder *decoder, int64_t frame, int64_t count, uint8_t *out) {
    if (frame < 0 || count < 0) return -1;
    if (frame >= decoder->info.frames) return 0;
    if (count > decoder->info.frames - frame) count = decoder->info.frames - frame;
    decoder->cursor.failed = 0;
    // Reads in order go on from where the library is; anything else is a seek.
    if (decoder->next != frame) {
        decoder->next = -1;
        if (decoder->seek(decoder, frame) != 0) return -1;
        decoder->next = frame;
    }
    int size = decoder->info.channels * (decoder->info.sample_bytes == 0 ? 4 : decoder->info.sample_bytes);
    int64_t done = 0;
    while (done < count) {
        int64_t got = decoder->read(decoder, count - done, out + done * size);
        if (got < 0 || decoder->cursor.failed) { decoder->next = -1; return -1; }
        if (got == 0) break;
        done += got;
        decoder->next += got;
    }
    return done;
}

void vsp_close(vsp_decoder *decoder) {
    if (!decoder) return;
    decoder->close(decoder);
    vsp_tags_free(&decoder->tags);
    free(decoder);
}
