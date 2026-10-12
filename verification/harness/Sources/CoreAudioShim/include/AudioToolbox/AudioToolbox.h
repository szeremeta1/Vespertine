//
// Vespertine verification: the few Audio Unit names vespertine_rt.c's spatial bridge uses, so the file compiles
// unchanged on Linux. The bridge itself isn't run there; the two functions fail if called (shim.c).
// SPDX-License-Identifier: GPL-3.0-or-later
//

#ifndef VERIFICATION_AUDIOTOOLBOX_SHIM_H
#define VERIFICATION_AUDIOTOOLBOX_SHIM_H

#include <CoreAudio/CoreAudio.h>

typedef struct OpaqueAudioComponentInstance *AudioUnit;
typedef UInt32 AudioUnitRenderActionFlags;
typedef UInt32 AudioUnitPropertyID;
typedef UInt32 AudioUnitScope;
typedef UInt32 AudioUnitElement;

typedef OSStatus (*AURenderCallback)(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                                     const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames,
                                     AudioBufferList *ioData);

typedef struct AURenderCallbackStruct {
    AURenderCallback inputProc;
    void *inputProcRefCon;
} AURenderCallbackStruct;

enum { kAudioUnitProperty_SetRenderCallback = 23 };
enum { kAudioUnitScope_Input = 1 };

OSStatus AudioUnitSetProperty(AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope,
                              AudioUnitElement inElement, const void *inData, UInt32 inDataSize);
OSStatus AudioUnitRender(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp,
                         UInt32 inOutputBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData);

#endif
