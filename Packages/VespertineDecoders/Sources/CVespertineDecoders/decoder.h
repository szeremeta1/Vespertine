//
// Vespertine: what the decoders share. Not part of the interface.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#ifndef VESPERTINE_DECODER_INTERNAL_H
#define VESPERTINE_DECODER_INTERNAL_H

#include "vespertine_decoders.h"

#ifdef __cplusplus
extern "C" {
#endif

/// The file with a place in it, as the libraries read: in order, with seeks.
typedef struct vsp_cursor {
    vsp_source source;
    int64_t at;
    /// A read failed: the file couldn't be reached (rather than the file being damaged).
    int failed;
} vsp_cursor;

/// Reads up to `count` bytes at the cursor and moves it. Returns the bytes read; 0 at the end or when reading failed.
int64_t vsp_cursor_read(vsp_cursor *cursor, void *buffer, int64_t count);
/// Moves the cursor: whence as SEEK_SET, SEEK_CUR, SEEK_END. Returns 0, or -1 for a place outside the file.
int vsp_cursor_seek(vsp_cursor *cursor, int64_t offset, int whence);

typedef struct vsp_tags {
    char **names;
    char **texts;
    int count;
} vsp_tags;

/// Adds a tag (copies of both strings).
void vsp_tags_add(vsp_tags *tags, const char *name, const char *text);
/// Adds a "NAME=text" comment, as Vorbis and Opus files hold them.
void vsp_tags_add_comment(vsp_tags *tags, const char *comment, int length);
void vsp_tags_free(vsp_tags *tags);

/// One kind of decoder: what `vsp_open` fills in.
struct vsp_decoder {
    vsp_cursor cursor;
    vsp_info info;
    vsp_tags tags;
    /// The frame the library will decode next; -1 when not known (after a failed read).
    int64_t next;
    void *state;
    int64_t (*read)(struct vsp_decoder *decoder, int64_t count, uint8_t *out);
    int (*seek)(struct vsp_decoder *decoder, int64_t frame);
    void (*close)(struct vsp_decoder *decoder);
};

int vsp_open_wavpack(struct vsp_decoder *decoder);
int vsp_open_vorbis(struct vsp_decoder *decoder);
int vsp_open_opus(struct vsp_decoder *decoder);
int vsp_open_ape(struct vsp_decoder *decoder);

static inline void vsp_put_float(uint8_t *out, float value) {
    uint32_t bits;
    __builtin_memcpy(&bits, &value, 4);
    out[0] = (uint8_t)(bits >> 24); out[1] = (uint8_t)(bits >> 16); out[2] = (uint8_t)(bits >> 8); out[3] = (uint8_t)bits;
}

#ifdef __cplusplus
}
#endif

#endif
