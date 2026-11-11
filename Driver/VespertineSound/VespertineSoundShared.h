//
// Vespertine: Mac Sound Output (beta): what the driver and Vespertine agree on, and the driver's pure helpers.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plain C with no Core Audio types, so tests/sound-driver-audit.c can run these under the sanitizers on any machine.
//

#ifndef VESPERTINE_SOUND_SHARED_H
#define VESPERTINE_SOUND_SHARED_H

#include <stdint.h>
#include <string.h>

// The plug-in's bundle ID: Vespertine finds the plug-in object through kAudioHardwarePropertyTranslateBundleIDToPlugIn.
#define VESPERTINE_SOUND_BUNDLE_ID "org.szeremeta.vespertine.sound"

// The custom property on the plug-in object that holds the published devices ('vcfg').
#define kVespertineSoundPropertyConfiguration 0x76636667u

// At most this many published outputs, each with at most this many channels (the speaker-group engine's own limit).
#define VESPERTINE_SOUND_MAX_DEVICES 8
#define VESPERTINE_SOUND_MAX_CHANNELS 16

// A published output that isn't refreshed for this long goes away. Vespertine refreshes every few seconds.
#define VESPERTINE_SOUND_REFRESH_TIMEOUT_SECONDS 20

// Core Audio channel labels used for the defaults below (CoreAudioTypes.h values).
enum {
    VS_LABEL_LEFT = 1,
    VS_LABEL_RIGHT = 2,
    VS_LABEL_CENTER = 3,
    VS_LABEL_LFE = 4,
    VS_LABEL_LEFT_SURROUND = 5,
    VS_LABEL_RIGHT_SURROUND = 6,
    VS_LABEL_REAR_LEFT = 33,
    VS_LABEL_REAR_RIGHT = 34,
    VS_LABEL_MONO = 42,
    VS_LABEL_DISCRETE_0 = 1 << 16,
};

// The layout a device shows when Vespertine sends no labels: the standard order for the common channel counts, and
// numbered channels otherwise.
static inline void VespertineSoundDefaultLabels(uint32_t channels, uint32_t *labels) {
    static const uint32_t quad[4] = { VS_LABEL_LEFT, VS_LABEL_RIGHT, VS_LABEL_LEFT_SURROUND, VS_LABEL_RIGHT_SURROUND };
    static const uint32_t five1[6] = { VS_LABEL_LEFT, VS_LABEL_RIGHT, VS_LABEL_CENTER, VS_LABEL_LFE, VS_LABEL_LEFT_SURROUND, VS_LABEL_RIGHT_SURROUND };
    static const uint32_t seven1[8] = { VS_LABEL_LEFT, VS_LABEL_RIGHT, VS_LABEL_CENTER, VS_LABEL_LFE, VS_LABEL_LEFT_SURROUND, VS_LABEL_RIGHT_SURROUND, VS_LABEL_REAR_LEFT, VS_LABEL_REAR_RIGHT };
    for (uint32_t c = 0; c < VESPERTINE_SOUND_MAX_CHANNELS; c++) labels[c] = VS_LABEL_DISCRETE_0 + c;
    switch (channels) {
        case 1: labels[0] = VS_LABEL_MONO; break;
        case 2: labels[0] = VS_LABEL_LEFT; labels[1] = VS_LABEL_RIGHT; break;
        case 4: memcpy(labels, quad, sizeof(quad)); break;
        case 6: memcpy(labels, five1, sizeof(five1)); break;
        case 8: memcpy(labels, seven1, sizeof(seven1)); break;
        default: break;
    }
}

// What other apps play (the mix the host hands the output device) goes into the ring at its sample time, scaled by the
// device's volume. The ring holds ringFrames frames of `stride` samples; a device with fewer channels leaves the rest.
static inline void VespertineSoundWriteRing(float *ring, uint32_t ringFrames, uint32_t stride,
                                            const float *buffer, uint32_t frames, uint32_t channels,
                                            uint64_t sampleTime, float gain) {
    if (channels > stride) channels = stride;
    uint32_t position = (uint32_t)(sampleTime % ringFrames);
    for (uint32_t f = 0; f < frames; f++) {
        float *frame = ring + (size_t)position * stride;
        const float *source = buffer + (size_t)f * channels;
        for (uint32_t c = 0; c < channels; c++) frame[c] = source[c] * gain;
        if (++position == ringFrames) position = 0;
    }
}

// The capture device reads the ring at its own sample time and clears what it read, so a stretch nobody wrote (the
// apps stopped playing) reads back as silence instead of the last sound, a ring's length ago.
static inline void VespertineSoundReadRing(float *ring, uint32_t ringFrames, uint32_t stride,
                                           float *buffer, uint32_t frames, uint32_t channels,
                                           uint64_t sampleTime) {
    if (channels > stride) channels = stride;
    uint32_t position = (uint32_t)(sampleTime % ringFrames);
    for (uint32_t f = 0; f < frames; f++) {
        float *frame = ring + (size_t)position * stride;
        float *target = buffer + (size_t)f * channels;
        for (uint32_t c = 0; c < channels; c++) {
            target[c] = frame[c];
            frame[c] = 0;
        }
        if (++position == ringFrames) position = 0;
    }
}

#endif
