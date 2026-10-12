//
// Vespertine verification: the few Core Audio types vespertine_rt.c names, so it compiles unchanged on Linux.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Layouts follow Apple's CoreAudioBaseTypes.h and AudioHardwareBase.h. Only the render path is tested on Linux
// (nrt_context_render_interleaved); nothing here talks to a device.

#ifndef VERIFICATION_COREAUDIO_SHIM_H
#define VERIFICATION_COREAUDIO_SHIM_H

#include <stdint.h>

typedef int32_t OSStatus;
typedef uint32_t UInt32;
typedef uint64_t UInt64;
typedef int16_t SInt16;
typedef uint16_t UInt16;
typedef double Float64;
typedef UInt32 AudioObjectID;

enum { noErr = 0 };

typedef struct SMPTETime {
    SInt16 mSubframes;
    SInt16 mSubframeDivisor;
    UInt32 mCounter;
    UInt32 mType;
    UInt32 mFlags;
    SInt16 mHours;
    SInt16 mMinutes;
    SInt16 mSeconds;
    SInt16 mFrames;
} SMPTETime;

typedef struct AudioTimeStamp {
    Float64 mSampleTime;
    UInt64 mHostTime;
    Float64 mRateScalar;
    UInt64 mWordClockTime;
    SMPTETime mSMPTETime;
    UInt32 mFlags;
    UInt32 mReserved;
} AudioTimeStamp;

enum { kAudioTimeStampSampleTimeValid = (1U << 0) };

typedef struct AudioBuffer {
    UInt32 mNumberChannels;
    UInt32 mDataByteSize;
    void *mData;
} AudioBuffer;

typedef struct AudioBufferList {
    UInt32 mNumberBuffers;
    AudioBuffer mBuffers[1];
} AudioBufferList;

#endif
