//
// Vespertine: see CVespertineCacheInput.h.
// SPDX-License-Identifier: GPL-3.0-or-later
//
#import "CVespertineCacheInput.h"

// SFBInputSource keeps its designated initializer out of the public header; SFBAudioEngine is pinned to one exact version.
@interface SFBInputSource (VTDesignated)
- (instancetype)initWithURL:(nullable NSURL *)url;
- (NSError *)posixErrorWithCode:(NSInteger)code;
@end

@implementation VTCacheInputSource {
    int64_t _length;
    int64_t _offset;
    BOOL _open;
    /// Where the block first answered "end of file" short of `_length` (a file cut short on the share, or a copy that ended early):
    /// the end of the file as far as any decoder is concerned. -1 until then.
    int64_t _endedAt;
    VTCacheReadBlock _read;
}

- (instancetype)initWithURL:(NSURL *)url length:(int64_t)length read:(VTCacheReadBlock)read {
    if ((self = [super initWithURL:url])) {
        _length = length;
        _endedAt = -1;
        _read = [read copy];
    }
    return self;
}

- (BOOL)openReturningError:(NSError **)error { _open = YES; _offset = 0; return YES; }
- (BOOL)closeReturningError:(NSError **)error { _open = NO; return YES; }
- (BOOL)isOpen { return _open; }
- (BOOL)supportsSeeking { return YES; }

/// Where this source ends: its length, or earlier where the block said the file stops.
- (int64_t)effectiveLength { return _endedAt >= 0 ? MIN(_length, _endedAt) : _length; }

/// SFBInputSource's own `atEOF` is a stub that always answers NO. SFBFLACDecoder ends the stream only for a zero-byte read at
/// `atEOF`, so without this libFLAC took every read at the end of a file (a truncated one, or one with no sample count) for "more
/// to come" and searched for a frame sync inside one `decode` call for ever, at 100% of a core and holding the engine's read-ahead
/// thread, so the song never ended.
- (BOOL)atEOF { return _offset >= [self effectiveLength]; }

- (BOOL)readBytes:(void *)buffer length:(NSInteger)length bytesRead:(NSInteger *)bytesRead error:(NSError **)error {
    NSInteger want = MIN((int64_t)length, MAX((int64_t)0, [self effectiveLength] - _offset));
    NSInteger got = 0;
    while (got < want) {
        NSInteger n = _read(_offset + got, (char *)buffer + got, want - got);
        if (n < 0) {
            if (error) *error = [self posixErrorWithCode:EIO];
            return NO;
        }
        if (n == 0) {
            // The block's end of file: nothing more will come, however long the source claimed to be.
            if (_offset + got < _length) _endedAt = _offset + got;
            break;
        }
        got += n;
    }
    _offset += got;
    if (bytesRead) *bytesRead = got;
    return YES;
}

- (BOOL)getOffset:(NSInteger *)offset error:(NSError **)error { *offset = (NSInteger)_offset; return YES; }
- (BOOL)getLength:(NSInteger *)length error:(NSError **)error { *length = (NSInteger)[self effectiveLength]; return YES; }

- (BOOL)seekToOffset:(NSInteger)offset error:(NSError **)error {
    if (offset < 0 || offset > [self effectiveLength]) {
        if (error) *error = [self posixErrorWithCode:EINVAL];
        return NO;
    }
    _offset = offset;
    return YES;
}

@end
