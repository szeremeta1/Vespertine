//
// Vespertine: one interface over the decoder libraries the phone brings (Monkey's Audio, WavPack, Ogg Vorbis, Opus).
// A file is read through a function that gives a range of it, and decoded from any frame.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#ifndef VESPERTINE_DECODERS_H
#define VESPERTINE_DECODERS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The file: its size, and a function that copies up to `count` bytes from `offset` into `buffer` and returns how many
/// it copied (fewer only at the end of the file), or -1 when the file can't be read.
typedef struct vsp_source {
    void *context;
    int64_t size;
    int64_t (*read)(void *context, int64_t offset, void *buffer, int64_t count);
} vsp_source;

enum { VSP_APE = 1, VSP_WAVPACK = 2, VSP_VORBIS = 3, VSP_OPUS = 4 };
enum { VSP_OPENED = 0, VSP_UNREADABLE = 1, VSP_NEEDS_THE_MAC = 2 };

typedef struct vsp_info {
    double sample_rate;
    int32_t channels;
    /// The file's bit depth; 0 for lossy audio.
    int32_t bit_depth;
    /// Bytes of a sample as `vsp_read` gives it: 1 to 4 for whole numbers, 0 for 32-bit floats.
    int32_t sample_bytes;
    int64_t frames;
} vsp_info;

typedef struct vsp_decoder vsp_decoder;

/// Opens a file of one of the kinds above. `*decoder` is set only for VSP_OPENED.
int vsp_open(int kind, vsp_source source, vsp_decoder **decoder);
vsp_info vsp_get_info(const vsp_decoder *decoder);

/// The file's tags, in the file's order: a name and its text (UTF-8).
int vsp_tag_count(const vsp_decoder *decoder);
const char *vsp_tag_name(const vsp_decoder *decoder, int index);
const char *vsp_tag_text(const vsp_decoder *decoder, int index);

/// Decodes up to `count` frames from `frame` into `out` (room for count * channels * sample size bytes): the channels in
/// turn, big-endian. Returns the frames decoded (fewer only at the end of the file), or -1 when decoding failed.
int64_t vsp_read(vsp_decoder *decoder, int64_t frame, int64_t count, uint8_t *out);

void vsp_close(vsp_decoder *decoder);

#ifdef __cplusplus
}
#endif

#endif
