//
// Vespertine verification: stand-ins for the two Audio Unit calls vespertine_rt.c makes. Linux has no Audio
// Units; the spatial bridge isn't tested there, so these only report failure.
// SPDX-License-Identifier: GPL-3.0-or-later
//

#include <AudioToolbox/AudioToolbox.h>

OSStatus AudioUnitSetProperty(AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope,
                              AudioUnitElement inElement, const void *inData, UInt32 inDataSize) {
    (void)inUnit; (void)inID; (void)inScope; (void)inElement; (void)inData; (void)inDataSize;
    return -4;   // kAudio_UnimplementedError
}

OSStatus AudioUnitRender(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp,
                         UInt32 inOutputBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    (void)inUnit; (void)ioActionFlags; (void)inTimeStamp; (void)inOutputBusNumber; (void)inNumberFrames; (void)ioData;
    return -4;
}
