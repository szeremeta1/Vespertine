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

@interface VTCacheInputSource : SFBInputSource
- (instancetype)initWithURL:(NSURL *)url length:(int64_t)length read:(VTCacheReadBlock)read;
@end

NS_ASSUME_NONNULL_END
