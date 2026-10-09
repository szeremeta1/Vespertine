//
// Vespertine — real-time audio primitives.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Everything in this module may be called from the Core Audio I/O thread.
// No locks, no allocation, no Objective-C/Swift runtime on that path.
//

#ifndef CVESPERTINE_RT_H
#define CVESPERTINE_RT_H

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

/// Producer side, safe while the consumer runs: takes back everything written after `totalWritten`
/// (look-ahead that is no longer wanted), but only when that point is at least `margin` frames ahead
/// of the reader, so the consumer can never be reading the frames being taken back. Returns whether it did.
/// The consumer stays wait-free: it is held back to `totalWritten` while this decides, and this may wait out
/// one read (or render pass) already under way.
bool nrt_ring_rewind(NRTRing *_Nonnull ring, uint64_t totalWritten, uint32_t margin);

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

/// Muted: the output plays silence and nothing is taken from the ring. Set from any thread the moment a
/// skip, seek, pause or output change is asked for, so the old song stops at once instead of playing on
/// from the buffer until the engine thread gets to the request (it may be waiting on a network read).
void nrt_context_set_muted(NRTRenderContext *_Nonnull ctx, bool muted);

/// The DSD idle pattern (01101001: as many ones as zeros, so a DAC reads it as silence). DSD silence is this, not
/// all-zero bits.
#define NRT_DOP_IDLE 0x69u

/// DoP: samples still go out untouched, but meters and the spectrum tap read the DSD bits in each frame
/// (a 16-bit bit count, display only). Every frame that carries no music (muted, holding for data, run dry) is a DoP
/// idle frame instead of zeros: two NRT_DOP_IDLE bytes behind the marker that continues the 0x05 / 0xFA alternation,
/// so the DAC stays locked in DSD. The markers never repeat: where the next frame from the ring carries the marker of
/// the frame before it (after idle frames, or at a join that broke the sequence), one idle frame goes first.
void nrt_context_set_dop(NRTRenderContext *_Nonnull ctx, bool dop);

/// Producer side, safe while the device runs: asks the I/O thread to drop everything written so far, on its next
/// cycle, muted or not, so a seek or skip can keep a DoP stream going instead of stopping the device. Frames written
/// after the call are kept. Returns the ring position the drop reaches: it's done once nrt_ring_total_read() gets there.
uint64_t nrt_context_discard(NRTRenderContext *_Nonnull ctx);
/// Withdraws a discard the I/O thread hasn't done. Only while the device is stopped (before nrt_ring_reset).
void nrt_context_cancel_discard(NRTRenderContext *_Nonnull ctx);

/// When set, running dry is the expected end of the stream and is not counted as an underrun.
void nrt_context_set_draining(NRTRenderContext *_Nonnull ctx, bool draining);
/// Integer mode: the ring carries 32-bit integer samples (bit patterns in the float slots) for a device set
/// to a non-mixable Int32 format. They're copied untouched (implies passthrough); meters read them as integers.
void nrt_context_set_integer(NRTRenderContext *_Nonnull ctx, bool integer);
uint32_t nrt_context_take_underruns(NRTRenderContext *_Nonnull ctx);
/// Network streams: hold in silence (consuming nothing) when the ring can't fill a slice, and resume
/// once `resumeFrames` are buffered. 0 turns it off. Clamped to ¾ of the ring.
void nrt_context_set_rebuffer(NRTRenderContext *_Nonnull ctx, uint32_t resumeFrames);
bool nrt_context_is_starved(const NRTRenderContext *_Nonnull ctx);
/// Times playback had to hold for data since the last call.
uint32_t nrt_context_take_stalls(NRTRenderContext *_Nonnull ctx);

// MARK: - Equalizer, run on the I/O thread before gain and dither

#define NRT_EQ_MAX_SECTIONS 20u

/// One biquad section, normalized so a0 = 1: y = b0·x + b1·x[-1] + b2·x[-2] − a1·y[-1] − a2·y[-2].
typedef struct {
    double b0, b1, b2, a1, a2;
} NRTBiquad;

/// Sets the equalizer while the device runs: every channel is scaled by `preamp` (linear) and then runs through
/// `count` sections (at most NRT_EQ_MAX_SECTIONS) in series, in double precision, before gain and dither. No
/// sections and a preamp of exactly 1.0 turns it off and keeps the bit-transparent path. Takes effect on the next
/// I/O cycle. Filter memory carries over when the number of sections is unchanged, so moving a band doesn't click,
/// and is cleared otherwise. Never applied to passthrough (DoP) or integer samples. One caller at a time.
void nrt_context_set_eq(NRTRenderContext *_Nonnull ctx, const NRTBiquad *_Nullable sections, uint32_t count, double preamp);

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
