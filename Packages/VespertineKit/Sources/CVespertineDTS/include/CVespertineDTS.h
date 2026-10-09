//
// Vespertine — DTS (DCA) decoding for DTS CDs / DTS-in-WAV, on FFmpeg's decoder.
// SPDX-License-Identifier: GPL-3.0-or-later
//
#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct NDTSDecoder NDTSDecoder;

/// Where the DTS bitstream starts in a buffer of 16-bit little-endian PCM words (a WAV/FLAC data chunk),
/// or -1. Recognizes the 14-bit and 16-bit packings used by DTS CDs and DTS-WAV files. A sync word counts
/// only with a valid core frame header, and with the next frame where that header puts it when that
/// lies inside the buffer.
int64_t ndts_find_sync(const uint8_t *_Nonnull data, int64_t size);
/// Like ndts_find_sync, but the next frame must also be inside the buffer: for telling a DTS CD from
/// ordinary PCM, where a sync word on its own is just two sample values.
int64_t ndts_find_stream(const uint8_t *_Nonnull data, int64_t size);

NDTSDecoder *_Nullable ndts_create(void);
void ndts_destroy(NDTSDecoder *_Nullable d);
/// Drops buffered input and output (after a seek).
void ndts_reset(NDTSDecoder *_Nonnull d);
/// Feeds raw bitstream bytes (the PCM words as stored). Returns false on a fatal decoder error.
bool ndts_feed(NDTSDecoder *_Nonnull d, const uint8_t *_Nonnull data, int size);
/// Flushes the decoder at end of input.
void ndts_finish(NDTSDecoder *_Nonnull d);
/// Decoded frames waiting to be read.
int ndts_available(const NDTSDecoder *_Nonnull d);
/// Copies up to `frames` decoded frames into `planes` (one float buffer per channel), dropping them.
int ndts_read(NDTSDecoder *_Nonnull d, float *_Nonnull const *_Nonnull planes, int frames);
/// Discards up to `frames` decoded frames. Returns how many were discarded.
int ndts_skip(NDTSDecoder *_Nonnull d, int frames);
/// Stream properties, known after the first decoded frame (0 before).
int ndts_channels(const NDTSDecoder *_Nonnull d);
int ndts_sample_rate(const NDTSDecoder *_Nonnull d);
/// FFmpeg channel mask (AV_CH_* bits, in output order).
uint64_t ndts_channel_mask(const NDTSDecoder *_Nonnull d);
/// Frames the parser has delimited since creation or the last reset, decodable or not.
int ndts_frames_found(const NDTSDecoder *_Nonnull d);
#include "CVespertineFF.h"
#include "CVespertineDST.h"
