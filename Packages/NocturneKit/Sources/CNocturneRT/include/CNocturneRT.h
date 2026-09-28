//
// Nocturne — real-time audio primitives.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Everything in this module may be called from the Core Audio I/O thread.
// No locks, no allocation, no Objective-C/Swift runtime on that path.
//

#ifndef CNOCTURNE_RT_H
#define CNOCTURNE_RT_H

#include <AudioToolbox/AudioToolbox.h>
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
/// Network streams: hold in silence (consuming nothing) when the ring can't fill a slice, and resume
/// once `resumeFrames` are buffered. 0 turns it off. Clamped to ¾ of the ring.
void nrt_context_set_rebuffer(NRTRenderContext *_Nonnull ctx, uint32_t resumeFrames);
bool nrt_context_is_starved(const NRTRenderContext *_Nonnull ctx);
/// Times playback had to hold for data since the last call.
uint32_t nrt_context_take_stalls(NRTRenderContext *_Nonnull ctx);

#define NRT_METER_CHANNELS 16u

/// Peak (absolute, linear) since the last call, per decoded channel (0 … NRT_METER_CHANNELS-1).
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

// MARK: - Output processor (spatial audio), run on the I/O thread after gain and meters

/// Turns `frames` of `inChannels` interleaved samples into `outChannels` interleaved samples.
typedef void (*NRTProcessFn)(void *_Nullable user, const float *_Nonnull in, uint32_t inChannels,
                             float *_Nonnull out, uint32_t outChannels, uint32_t frames);

/// Installs (or removes, with fn == NULL) a processor. Call only while the device is stopped.
/// `outChannels` is how many channels the processor writes per frame. Returns false if out of memory.
bool nrt_context_set_processor(NRTRenderContext *_Nonnull ctx, NRTProcessFn _Nullable fn,
                               void *_Nullable user, uint32_t outChannels);

// MARK: - Spatial audio bridge: pulls an AUSpatialMixer from the I/O thread

typedef struct NRTSpatial NRTSpatial;

/// `au` must be an initialized AUSpatialMixer with a non-interleaved Float32 input of `inChannels`
/// channels on bus 0 and a non-interleaved stereo Float32 output; `maxFrames` ≥ any slice rendered.
NRTSpatial *_Nullable nrt_spatial_create(AudioUnit _Nonnull au, uint32_t inChannels, uint32_t maxFrames);
void nrt_spatial_destroy(NRTSpatial *_Nullable spatial);
/// Sets the mixer's input render callback to feed it from the bridge.
OSStatus nrt_spatial_install(NRTSpatial *_Nonnull spatial);
/// NRTProcessFn: pass with the NRTSpatial as `user`.
void nrt_spatial_process(void *_Nullable user, const float *_Nonnull in, uint32_t inChannels,
                         float *_Nonnull out, uint32_t outChannels, uint32_t frames);

/// Renders `frames` into a caller buffer exactly as the IOProc would (used by tests).
void nrt_context_render_interleaved(NRTRenderContext *_Nonnull ctx, float *_Nonnull out,
                                    uint32_t frames, uint32_t outChannels);

#ifdef __cplusplus
}
#endif

#endif
