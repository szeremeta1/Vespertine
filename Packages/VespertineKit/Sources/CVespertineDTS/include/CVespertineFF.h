//
// Vespertine — FFmpeg-decoded files: DTS / DTS-HD Master Audio and Dolby TrueHD in .dts, .dtshd,
// .thd/.mlp and Matroska. Decoded to float, one plane per channel.
// SPDX-License-Identifier: GPL-3.0-or-later
//
#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct NFFDecoder NFFDecoder;

/// Opens the best audio stream of a file. NULL (and a message in `error`) if there's none it can decode.
NFFDecoder *_Nullable nff_open(const char *_Nonnull path, char *_Nullable error, int errorSize);
void nff_close(NFFDecoder *_Nullable d);

int nff_channels(const NFFDecoder *_Nonnull d);
int nff_sample_rate(const NFFDecoder *_Nonnull d);
/// FFmpeg channel mask (AV_CH_* bits) in output order, 0 if unknown.
uint64_t nff_channel_mask(const NFFDecoder *_Nonnull d);
/// Total frames (from the container's duration), 0 if unknown.
int64_t nff_length(const NFFDecoder *_Nonnull d);
/// "dts" or "truehd"/"mlp".
const char *_Nonnull nff_codec(const NFFDecoder *_Nonnull d);
/// FFmpeg's profile name ("DTS-HD MA", "DTS-HD MA + DTS:X", "Dolby TrueHD + Dolby Atmos", …) or "".
const char *_Nonnull nff_profile(const NFFDecoder *_Nonnull d);
/// Significant bits of the decoded samples (24 for DTS-HD MA / TrueHD), 0 if unknown.
int nff_bits(const NFFDecoder *_Nonnull d);
/// A container tag ("title", "artist", "album", "date", "track", …), or NULL.
const char *_Nullable nff_tag(const NFFDecoder *_Nonnull d, const char *_Nonnull key);

/// Decodes up to `frames` frames into `planes` (one float buffer per channel). Returns frames written, 0 at the end, -1 on error.
int nff_read(NFFDecoder *_Nonnull d, float *_Nonnull const *_Nonnull planes, int frames);
/// Positions at `frame` exactly (decoding from the nearest earlier point and dropping the surplus).
bool nff_seek(NFFDecoder *_Nonnull d, int64_t frame);
/// Current frame position.
int64_t nff_position(const NFFDecoder *_Nonnull d);

// MARK: Raw DSD (for DoP): the 1-bit stream itself, per channel, most significant bit first in time.

/// Whether the stream is DSD (DSF / DSDIFF). Its "sample rate" is then bytes per second per channel (DSD rate / 8).
bool nff_is_dsd(const NFFDecoder *_Nonnull d);
/// Reads up to `bytes` DSD bytes per channel into `planes` (one buffer per channel), MSB = earliest bit.
/// Returns bytes per channel written, 0 at the end. Don't mix with nff_read on the same decoder.
int nff_read_dsd(NFFDecoder *_Nonnull d, uint8_t *_Nonnull const *_Nonnull planes, int bytes);
/// Positions raw reading at byte `offset` (per channel).
bool nff_seek_dsd(NFFDecoder *_Nonnull d, int64_t offset);
