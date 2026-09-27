//
// Nocturne — real-time audio primitives.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Everything in this module may be called from the Core Audio I/O thread.
// No locks, no allocation, no Objective-C/Swift runtime on that path.
//

#ifndef CNOCTURNE_RT_H
#define CNOCTURNE_RT_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Single-producer / single-consumer ring buffer of interleaved Float32 frames

typedef struct NRTRing NRTRing;

/// Creates a ring holding at least `minimumFrames` frames (rounded up to a power of two).
NRTRing *_Nullable nrt_ring_create(uint32_t minimumFrames, uint32_t channels);
void nrt_ring_destroy(NRTRing *_Nullable ring);

uint32_t nrt_ring_channels(const NRTRing *_Nonnull ring);
uint32_t nrt_ring_capacity(const NRTRing *_Nonnull ring);
uint32_t nrt_ring_readable(const NRTRing *_Nonnull ring);
uint32_t nrt_ring_writable(const NRTRing *_Nonnull ring);

/// Producer side. Returns frames actually written (may be fewer than requested).
uint32_t nrt_ring_write(NRTRing *_Nonnull ring, const float *_Nonnull interleaved, uint32_t frames);
/// Consumer side. Returns frames actually read.
uint32_t nrt_ring_read(NRTRing *_Nonnull ring, float *_Nonnull interleaved, uint32_t frames);

/// Monotonic counters since creation / last reset.
uint64_t nrt_ring_total_written(const NRTRing *_Nonnull ring);
uint64_t nrt_ring_total_read(const NRTRing *_Nonnull ring);

/// Discards all content. Only call while neither side is running.
void nrt_ring_reset(NRTRing *_Nonnull ring);

// MARK: - Render context driven by a HAL IOProc

#define NRT_TAP_SIZE 8192u

typedef struct NRTRenderContext NRTRenderContext;

NRTRenderContext *_Nullable nrt_context_create(NRTRing *_Nonnull ring, uint32_t maxFramesPerSlice);
void nrt_context_destroy(NRTRenderContext *_Nullable ctx);

/// Linear gain applied in double precision with TPDF dither at `ditherBits`.
/// A gain of exactly 1.0 leaves samples untouched (bit-transparent path).
void nrt_context_set_gain(NRTRenderContext *_Nonnull ctx, double gain, uint32_t ditherBits);
double nrt_context_gain(const NRTRenderContext *_Nonnull ctx);

/// When set (DoP), samples are never modified and meters are not computed.
void nrt_context_set_passthrough(NRTRenderContext *_Nonnull ctx, bool passthrough);

/// When set, running dry is the expected end of the stream and is not counted as an underrun.
void nrt_context_set_draining(NRTRenderContext *_Nonnull ctx, bool draining);
uint32_t nrt_context_take_underruns(NRTRenderContext *_Nonnull ctx);

/// Peak (absolute, linear) since the last call, per channel (0 or 1).
float nrt_context_take_peak(NRTRenderContext *_Nonnull ctx, uint32_t channel);

/// Copies the most recent `count` mono samples (≤ NRT_TAP_SIZE) oldest-first.
uint32_t nrt_context_copy_tap(const NRTRenderContext *_Nonnull ctx, float *_Nonnull out, uint32_t count);

/// Total frames delivered to the device (including silence while dry).
uint64_t nrt_context_frames_rendered(const NRTRenderContext *_Nonnull ctx);

/// Pass to AudioDeviceCreateIOProcID with the context as client data.
OSStatus nrt_device_ioproc(AudioObjectID inDevice,
                           const AudioTimeStamp *_Nonnull inNow,
                           const AudioBufferList *_Nonnull inInputData,
                           const AudioTimeStamp *_Nonnull inInputTime,
                           AudioBufferList *_Nonnull outOutputData,
                           const AudioTimeStamp *_Nonnull inOutputTime,
                           void *_Nullable inClientData);

/// Renders `frames` into a caller buffer exactly as the IOProc would (used by tests).
void nrt_context_render_interleaved(NRTRenderContext *_Nonnull ctx, float *_Nonnull out,
                                    uint32_t frames, uint32_t outChannels);

#ifdef __cplusplus
}
#endif

#endif
