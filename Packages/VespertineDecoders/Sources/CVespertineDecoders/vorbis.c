//
// Vespertine: Ogg Vorbis, with libvorbisfile. Read as SFBAudioEngine reads it on the Mac, so the samples are the same.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#include "decoder.h"

#include <vorbis/vorbisfile.h>

#include <stdio.h>
#include <stdlib.h>

static size_t vb_read_bytes(void *ptr, size_t size, size_t count, void *source) {
    if (size == 0) return 0;
    return (size_t)vsp_cursor_read((vsp_cursor *)source, ptr, (int64_t)(size * count)) / size;
}
static int vb_seek_bytes(void *source, ogg_int64_t offset, int whence) { return vsp_cursor_seek((vsp_cursor *)source, offset, whence); }
static long vb_tell(void *source) { return (long)((vsp_cursor *)source)->at; }

static int64_t vb_read(vsp_decoder *decoder, int64_t count, uint8_t *out) {
    OggVorbis_File *file = decoder->state;
    float **pcm = NULL;
    int bitstream = 0;
    long got = ov_read_float(file, &pcm, (int)(count > 4096 ? 4096 : count), &bitstream);
    // A gap in the file: the library carries on after it.
    if (got == OV_HOLE) return vb_read(decoder, count, out);
    if (got < 0) return -1;
    int channels = decoder->info.channels;
    for (long i = 0; i < got; i++) {
        for (int c = 0; c < channels; c++) {
            vsp_put_float(out, pcm[c][i]);
            out += 4;
        }
    }
    return got;
}

static int vb_seek(vsp_decoder *decoder, int64_t frame) { return ov_pcm_seek((OggVorbis_File *)decoder->state, frame) == 0 ? 0 : -1; }

static void vb_close(vsp_decoder *decoder) {
    if (!decoder->state) return;
    ov_clear((OggVorbis_File *)decoder->state);
    free(decoder->state);
    decoder->state = NULL;
}

int vsp_open_vorbis(vsp_decoder *decoder) {
    OggVorbis_File *file = calloc(1, sizeof(OggVorbis_File));
    if (!file) return VSP_UNREADABLE;
    ov_callbacks callbacks = {.read_func = vb_read_bytes, .seek_func = vb_seek_bytes, .close_func = NULL, .tell_func = vb_tell};
    if (ov_open_callbacks(&decoder->cursor, file, NULL, 0, callbacks) != 0) {
        free(file);
        return VSP_UNREADABLE;
    }
    decoder->state = file;
    decoder->read = vb_read;
    decoder->seek = vb_seek;
    decoder->close = vb_close;
    vorbis_info *info = ov_info(file, -1);
    ogg_int64_t frames = ov_pcm_total(file, -1);
    if (!info || frames < 0) {
        vb_close(decoder);
        return VSP_UNREADABLE;
    }
    decoder->info.sample_rate = (double)info->rate;
    decoder->info.channels = info->channels;
    decoder->info.bit_depth = 0;
    decoder->info.sample_bytes = 0;
    decoder->info.frames = frames;
    vorbis_comment *comments = ov_comment(file, -1);
    if (comments) {
        for (int i = 0; i < comments->comments; i++) vsp_tags_add_comment(&decoder->tags, comments->user_comments[i], comments->comment_lengths[i]);
    }
    return VSP_OPENED;
}
