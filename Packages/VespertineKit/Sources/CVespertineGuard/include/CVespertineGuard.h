//
// Vespertine — calls into decoders with every exception caught (C++ and Objective-C), so a damaged
// file becomes an error instead of terminating the app. Some codec libraries (Monkey's Audio) throw
// C++ exceptions that their Objective-C wrappers don't catch.
// SPDX-License-Identifier: GPL-3.0-or-later
//
#pragma once
#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN
#ifdef __cplusplus
extern "C" {
#endif
/// -openReturningError:
BOOL nguard_open(id decoder, NSError *_Nullable *_Nullable error);
/// -decodeIntoBuffer:frameLength:error:
BOOL nguard_decode(id decoder, AVAudioPCMBuffer *buffer, AVAudioFrameCount length, NSError *_Nullable *_Nullable error);
/// -seekToFrame:error:
BOOL nguard_seek(id decoder, AVAudioFramePosition frame, NSError *_Nullable *_Nullable error);
#ifdef __cplusplus
}
#endif
NS_ASSUME_NONNULL_END
