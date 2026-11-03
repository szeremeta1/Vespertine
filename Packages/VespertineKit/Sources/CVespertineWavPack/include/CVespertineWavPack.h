//
// Vespertine — the part of libwavpack (Vendor/WavPackDSD.xcframework, built with DSD support by
// scripts/build-wavpack-dsd.sh) the WavPack DSD reader uses. Declarations follow WavPack 5.8.1's wavpack.h
// (BSD-3-Clause, Copyright (c) David Bryant); every symbol carries the build's `vtwv_` prefix.
// SPDX-License-Identifier: GPL-3.0-or-later
//
#pragma once
#include <stdint.h>

typedef struct WavpackContext WavpackContext;

typedef struct {
    int32_t (*read_bytes)(void *id, void *data, int32_t bcount);
    int32_t (*write_bytes)(void *id, void *data, int32_t bcount);
    int64_t (*get_pos)(void *id);
    int (*set_pos_abs)(void *id, int64_t pos);
    int (*set_pos_rel)(void *id, int64_t delta, int mode);
    int (*push_back_byte)(void *id, int c);
    int64_t (*get_length)(void *id);
    int (*can_seek)(void *id);
    int (*truncate_here)(void *id);
    int (*close)(void *id);
} WavpackStreamReader64;

#define OPEN_DSD_NATIVE 0x100   // open DSD files as bitstreams (8-bit "samples" in 32-bit words, MSB first)
#define OPEN_ALT_TYPES  0x400

WavpackContext *vtwv_WavpackOpenFileInputEx64(WavpackStreamReader64 *reader, void *wv_id, void *wvc_id, char *error, int flags, int norm_offset);
WavpackContext *vtwv_WavpackCloseFile(WavpackContext *wpc);
uint32_t vtwv_WavpackGetSampleRate(WavpackContext *wpc);
uint32_t vtwv_WavpackGetNativeSampleRate(WavpackContext *wpc);
int vtwv_WavpackGetNumChannels(WavpackContext *wpc);
int vtwv_WavpackGetChannelMask(WavpackContext *wpc);
int64_t vtwv_WavpackGetNumSamples64(WavpackContext *wpc);
uint32_t vtwv_WavpackUnpackSamples(WavpackContext *wpc, int32_t *buffer, uint32_t samples);
int vtwv_WavpackGetNumErrors(WavpackContext *wpc);
int vtwv_WavpackSeekSample64(WavpackContext *wpc, int64_t sample);
int vtwv_WavpackGetNumTagItems(WavpackContext *wpc);
int vtwv_WavpackGetTagItemIndexed(WavpackContext *wpc, int index, char *item, int size);
int vtwv_WavpackGetTagItem(WavpackContext *wpc, const char *item, char *value, int size);
