//
// Vespertine: an input source for SFBAudioEngine's decoders that reads through a caller's block, so a decoder can start on a share
// file that is still being copied: each read waits (inside the block) until the bytes it asks for are on disk.
// SPDX-License-Identifier: GPL-3.0-or-later
//
#pragma once
#import <Foundation/Foundation.h>
#import <SFBAudioEngine/SFBInputSource.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads up to `count` bytes at `offset` into `buffer`; returns how many (0 at the end of the file), or -1 for an error.
typedef NSInteger (^VTCacheReadBlock)(int64_t offset, void *buffer, NSInteger count);

/// As `VTCacheReadBlock`, and a failed read (-1) can say why through `error`.
typedef NSInteger (^VTCacheReadWithErrorBlock)(int64_t offset, void *buffer, NSInteger count, NSError * _Nullable * _Nullable error);

@interface VTCacheInputSource : SFBInputSource
- (instancetype)initWithURL:(NSURL *)url length:(int64_t)length read:(VTCacheReadBlock)read;
/// A failed read keeps its cause in `lastReadError`: SFBAudioEngine's decoders drop the error an input source reports (a FLAC
/// read that fails is `FLAC__STREAM_DECODER_ABORTED`, then "An error occurred during PCM audio decoding."), so whoever sees
/// the decoder fail asks the source why.
- (instancetype)initWithURL:(NSURL *)url length:(int64_t)length readReportingErrors:(VTCacheReadWithErrorBlock)read;
/// Why the last read that failed did, until a read succeeds (nil: the last read worked, or none has failed). Any thread.
@property (atomic, readonly, nullable) NSError *lastReadError;
@end

NS_ASSUME_NONNULL_END
