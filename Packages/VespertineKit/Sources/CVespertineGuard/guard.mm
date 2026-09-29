//
// Vespertine — decoder calls with every exception caught.
// SPDX-License-Identifier: GPL-3.0-or-later
//
#import "CVespertineGuard.h"
#import <objc/message.h>
#include <exception>

static NSError *failure(NSString *what) {
    return [NSError errorWithDomain:@"org.szeremeta.vespertine.decoder" code:-1
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"The file couldn't be decoded (%@).", what]}];
}

template <typename F> static BOOL guarded(F body, NSError **error) {
    @try {
        try { return body(); }
        catch (const std::exception &e) { if (error) *error = failure([NSString stringWithUTF8String:e.what()]); return NO; }
        catch (...) { if (error) *error = failure(@"damaged data"); return NO; }
    } @catch (NSException *e) {
        if (error) *error = failure(e.reason ?: e.name);
        return NO;
    }
}

BOOL nguard_open(id decoder, NSError **error) {
    return guarded([&] { return ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(decoder, @selector(openReturningError:), error); }, error);
}

BOOL nguard_decode(id decoder, AVAudioPCMBuffer *buffer, AVAudioFrameCount length, NSError **error) {
    return guarded([&] {
        return ((BOOL (*)(id, SEL, AVAudioPCMBuffer *, AVAudioFrameCount, NSError **))objc_msgSend)(
            decoder, @selector(decodeIntoBuffer:frameLength:error:), buffer, length, error);
    }, error);
}

BOOL nguard_seek(id decoder, AVAudioFramePosition frame, NSError **error) {
    return guarded([&] {
        return ((BOOL (*)(id, SEL, AVAudioFramePosition, NSError **))objc_msgSend)(decoder, @selector(seekToFrame:error:), frame, error);
    }, error);
}
