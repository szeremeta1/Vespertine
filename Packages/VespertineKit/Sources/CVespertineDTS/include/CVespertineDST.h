//
// Vespertine — DST (Direct Stream Transfer), the lossless compression of SACD audio, decoded to raw DSD.
// SPDX-License-Identifier: LGPL-2.1-or-later (derived from FFmpeg's DST decoder; see vespertine_dst.c)
//
#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct NDSTDecoder NDSTDecoder;

/// A decoder for `channels` (1 to 6) channels of DST frames that each hold `frameBytes` DSD bytes per channel
/// (4704 for DSD64: 1/75 s). NULL if the shape is unsupported.
NDSTDecoder *_Nullable ndst_create(int channels, int frameBytes);
void ndst_destroy(NDSTDecoder *_Nullable d);
/// Decodes one DST frame into `out`: channels × frameBytes DSD bytes, interleaved by channel (one byte of each
/// channel in turn), most significant bit first in time. A frame stored uncompressed is copied. Returns false
/// for a damaged or unsupported frame (`out` then holds DSD silence).
bool ndst_decode(NDSTDecoder *_Nonnull d, const uint8_t *_Nonnull data, int size, uint8_t *_Nonnull out);
